# Scheme B — Telegram WEB proxy

The relay terminates HTTPS from the Telegram app and forwards each demultiplexed
stream as plain obfuscated2 TCP to a patched mtg that chains to Telegram through a
SOCKS5 tunnel. This document covers the deployment that actually works behind a
censoring ISP; see [`01-obfuscated2-fork.md`](01-obfuscated2-fork.md) for the
backend and [`04-troubleshooting.md`](04-troubleshooting.md) for the reasons
behind each constraint.

## Before you start

Confirm the two things that cannot be worked around:

```bash
# 1. Telegram is reachable *through your tunnel*, not directly.
curl -s -x socks5h://127.0.0.1:1080 -o /dev/null -w '%{http_code}\n' https://core.telegram.org/

# 2. Your Telegram app has the WEB proxy type
#    Settings -> Proxy -> Add proxy -> look for "WEB proxy".
```

If the second one is missing there is nothing to deploy: the proxy type is a
client feature and no server change adds it.

## One container, and why

The relay enforces loopback for **both** of its addresses:

```
configuration error: listen: must use a numeric loopback address
configuration error: profile "default" backend: must use a numeric loopback address
```

That is the reference layout — in the upstream design Caddy owns 80/443 and
everything else stays on loopback. Two consequences follow:

* the backend must share the relay's network namespace, so it cannot be a
  separate container reached by name;
* something has to face the container network, and that something must not touch
  `X-Forwarded-For`, because the relay rejects a list there and needs exactly one
  address.

`socat` is the right tool: it forwards bytes verbatim, so the single-value
`X-Forwarded-For` set by the front proxy arrives intact, and WebSocket upgrades,
long polls and 2 MiB carrier batches pass through untouched.

```
front proxy ──► socat :8082 ──► relay 127.0.0.1:8080 ──► mtg 127.0.0.1:3128
```

## Build the backend

See [`01-obfuscated2-fork.md`](01-obfuscated2-fork.md). You end up with a
`mtg-obfuscated2` binary. Place it next to the relay binary in the build context.

## Generate the two secrets

They are independent and must not be reused:

```bash
# client-facing MTProxy secret: dd + 16 random bytes, hex
SECRET="dd$(openssl rand -hex 16)"

# signing key for the relay's session tokens: exactly 32 bytes
head -c 32 /dev/urandom > token.key
chmod 0400 token.key
```

The **same** `SECRET` appears in the relay profile and in the backend config — the
relay forwards the client's obfuscated2 stream verbatim, so both ends must agree.

## Pick a base path

The relay can serve its whole surface under a path prefix so that the hostname can
also be an ordinary website. Upstream calls this the recommended default:

```bash
head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z'
```

The prefix is not authorization, but while the link is shared privately it is a
real second unknown: a scanner probing the hostname finds a website and nothing
else. `webproxy/config.json.example` has the field.

## Configuration

`webproxy/` contains everything: `config.json.example`, `profiles.json.example`,
`mtg.toml.example`, `Dockerfile`, `entrypoint.sh` and the compose file. Mount the
configs read-only and keep them out of the image.

The relay's limits are the safety boundary; the defaults in the example are the
upstream defaults. Two are worth understanding before you expose anything:

* `max_sessions_global` — live WebView carrier sessions.
* `max_pending_global` — buffered relay data. The relay refuses to start if the
  per-session control reserve times this out leaves no room for data.

## Front proxy

`traefik/webproxy.yml` is a complete fragment. Point it at the container and give
it a real certificate — the Telegram WebView will not accept a self-signed one and
upstream forbids teaching a client to bypass that.

Nothing here requires restarting the front proxy: a file-provider directory with
`watch=true` picks the router up live. That matters if the same instance also
serves a TCP passthrough for a direct MTProto proxy, where a restart drops every
connected client.

## Client link

A client sees exactly two values: server and secret. With a base path the secret
is transmitted in a **marked** form, `0x70 || secret`, base64url without padding:

```bash
python3 - <<'PY'
import base64, urllib.parse
host, slug, secret_hex = "proxy.example.com", "<BASE_PATH>", "<WEBPROXY_SECRET>"
marked = base64.urlsafe_b64encode(b"\x70" + bytes.fromhex(secret_hex)).decode().rstrip("=")
print(f"https://t.me/webproxy?server={urllib.parse.quote(f'{host}/{slug}', safe='')}&secret={marked}")
PY
```

The marker exists so that a client without base-path support fails loudly instead
of silently connecting to the wrong place. A pathless deployment keeps the plain
hex secret.

## Verify

```bash
# the decoy site, and no relay tell on ordinary paths
curl -sI https://proxy.example.com/                     # 200
curl -sI https://proxy.example.com/<BASE_PATH>/         # the site's 404
curl -sI https://proxy.example.com/api/v1/session       # the site's response, not the relay

# the relay's own view (from inside the container; admin stays on loopback)
docker exec <container> wget -qO- http://127.0.0.1:8081/readyz   # "ready"
```

`readyz` reports backend reachability, so it is the fastest way to tell a broken
tunnel from a broken relay.

Finally, confirm the bridge page is served for a correctly derived capability —
this exercises everything except the app itself:

```bash
python3 - <<'PY'
import hmac, hashlib, base64
host, slug, secret_hex = "proxy.example.com", "<BASE_PATH>", "<WEBPROXY_SECRET>"
ctx = f"tdesktop-web-proxy-bridge-v2\n{host}\n{slug}".encode()
print(base64.urlsafe_b64encode(hmac.new(bytes.fromhex(secret_hex), ctx, hashlib.sha256).digest()).decode().rstrip("="))
PY
# then: curl "https://proxy.example.com/<BASE_PATH>/?bridge=<capability>"
# expect 200 text/html containing the bridge script
```

Do not paste that URL anywhere: it carries the capability.
