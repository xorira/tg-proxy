# What actually goes wrong

Every entry here cost real time to find. They are ordered by how much damage they
do when you hit them blind.

## 1. The proxy that dials itself, silently, forever

**Symptom.** Load average in the tens on a host that serves almost no traffic.
`top` shows `sy` near 90% and `id` at 0. The process list is led not by your proxy
but by `traefik` and `docker-proxy`, and the proxy's own log is *silent* — the
messages that would explain it are hours old.

**Cause.** In mtg, an `ee` secret is `[0xee][16 bytes key][hostname]`. That
hostname is not decoration: mtg presents it as SNI and falls back to dialling it
when a request fails validation. If your split-horizon DNS also publishes the
proxy's own public name pointing back at the proxy host, mtg fronts to **itself**:

```
mtg ──► 192.168.0.10:443 ──► hosted proxy ──► front proxy ──► mtg ──► ...
```

`ss` confirms it: the proxy holds hundreds of outbound connections to its own
public address, most of them parked in `FIN-WAIT-2`.

**Why the obvious fix does not work.** Setting the fronting host in the config
file looks like the answer:

```toml
[domain-fronting]
host = "www.google.com"
port = 443
```

It is not. The hostname inside the **secret** still governs the dial, and the
config value does not override it. Verify by decoding your own secret — if the
plaintext hostname is your proxy's name, this is your bug:

```bash
echo "<base64-secret>=" | base64 -d | strings
```

**Fix.** Re-issue the secret with a hostname that resolves somewhere else, update
the `HostSNI` rule to match, and redistribute the links. There is no config-only
escape.

## 2. obfuscated2 cannot be routed by hostname

A TCP router matches `HostSNI` by parsing a TLS ClientHello. obfuscated2 has no
ClientHello — the first 64 bytes are random-looking. Consequences:

* you cannot put a `dd`-secret MTProto proxy on a shared 443 and select it by
  name;
* adding a *new entrypoint* to the front proxy to work around that means
  recreating the container, which drops every client on the existing passthrough
  routes.

If you need a hostname, use FakeTLS. If you need obfuscated2, give it a port.

## 3. The relay only speaks loopback, in both directions

```
configuration error: listen: must use a numeric loopback address
configuration error: profile "default" backend: must use a numeric loopback address
```

A hostname backend such as `mtproxy:2398` is rejected outright. The backend has to
be in the same network namespace, and a co-located forwarder has to publish the
relay to the container network.

Use a **verbatim TCP** forwarder (`socat`), not an HTTP proxy adding headers. The
relay's client-address logic:

```go
forwarded := r.Header.Get("X-Forwarded-For")
if forwarded == "" { return peer.String(), nil }
if strings.Contains(forwarded, ",") || strings.TrimSpace(forwarded) != forwarded {
    return "", errors.New("invalid forwarding address")
}
```

An HTTP proxy that appends its own address turns that into a comma-separated list
and every request is rejected. Raw TCP forwarding keeps the single value your
front proxy already set.

The peer must also be loopback, so the forwarder has to live in the same
container — a sidecar container's address will not do.

## 4. Which proxy can do what

Nobody implements the whole set. This table is the reason the patch exists.

| | Telegram DC | obfuscated2 secrets | SOCKS5 chaining | middle-end RPC |
|---|---|---|---|---|
| Official MTProxy | direct only | yes | **no** | yes |
| mtg v1 | direct / chained | yes | **no** | no |
| mtg v2 | direct / chained | **no** (`ee` only) | yes | no |
| mtg v2 + patch | direct / chained | yes | yes | no |

The patch is not a feature request against mtg; it restores a mode upstream
deliberately dropped.

## 5. Test the port that matters

Telegram being blocked usually shows up first on 443, but an official MTProxy
does not use 443 — it talks to middle-end servers on 8888, listed in
`proxy-multi.conf`:

```bash
curl -s https://core.telegram.org/getProxyConfig | grep '^proxy_for' | head
```

Check those addresses and that port. A host can have 443 blocked for Telegram
while 8888 works, or the reverse, and the failure looks identical from the client
side.

## 6. Behind NAT, MTProxy fails without saying so

Official MTProxy derives its middle-end keys from its own source address. Behind
1:1 NAT the two sides derive different keys and every middle-end connection is
dropped right after the handshake. From outside everything looks healthy: clients
complete the handshake, the relay grants window, and then **every stream stalls
with no error on any layer**. The only tell is the log:

```bash
journalctl -u mtproxy | grep -c 'Disconnected from RPC Middle-End'
```

Fix with the local and public addresses:

```
MTPROXY_NAT_ARGS=--nat-info 10.0.0.5:203.0.113.7
```

This is one more reason to prefer chaining-capable mtg over official MTProxy when
you are already behind NAT.

## 7. AppArmor can break builds and containers

On hosts where AppArmor mediates `AF_UNIX` and the `docker-default` profile has no
`unix` rules, containers are refused socket creation and child processes cannot be
spawned with pipes. Symptoms seen in practice:

* `npm ci` fails with `EACCES` on `spawn sh` from an `esbuild` postinstall;
* PostgreSQL cannot create `/var/run/postgresql/.s.PGSQL.5432` and dies with
  `could not create any Unix-domain sockets`.

`security_opt: [apparmor:unconfined]` fixes it for containers. Note that this
cannot be set on a **build** stage, so build such images by running the steps in a
container you launch yourself and then assembling a thin final image.

## 8. Do not publish the operator site

The relay serves a website from memory so that probing the hostname finds a normal
site. Upstream:

> The repository deliberately does not include a deployable public website. If many
> operators installed the same starter, its body and assets would become an easy
> active-probing signature.

Copying a shared starter — including from this repository — destroys the property
the site exists to provide.

## 9. Reading the relay's own state

Both listeners are loopback, so probe them from inside the container:

```bash
docker exec <container> wget -qO- http://127.0.0.1:8081/healthz   # process alive
docker exec <container> wget -qO- http://127.0.0.1:8081/readyz    # backend reachable
```

`readyz` is the useful one: it separates "the relay is up" from "the tunnel to
Telegram is up". A container healthcheck on `readyz` turns a silent backend
failure into a restart.
