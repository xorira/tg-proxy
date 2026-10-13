# Scheme A — direct MTProto proxy

A plain MTProto proxy that any Telegram app can use. `mtg` in FakeTLS mode behind a
TCP passthrough router is the least moving parts, and it is what
`traefik/mtproto-tcp.yml` and `mtg/mtg.toml.example` show.

## The routing constraint

The front proxy can only route by hostname if there is a hostname to read:

| Secret mode | Wire format | SNI present | Routable by `HostSNI` |
|---|---|---|---|
| `ee` (FakeTLS) | TLS ClientHello | yes | yes |
| `dd` (secured) | obfuscated2 | no | **no** |
| prefixless (simple) | obfuscated2 | no | **no** |

obfuscated2 starts with 64 bytes of noise carrying an encrypted key; there is no
plaintext field to match on. So:

* **FakeTLS on 443** — route by `HostSNI`, share the port with everything else.
* **obfuscated2** — needs its own port and a catch-all router, or a direct
  published port. The hostname is then only a DNS alias.

If you want obfuscated2 *and* hostname-based routing, the only way is to make the
client send something routable, and it will not.

## Minimal deployment

```toml
# mtg.toml — see mtg/mtg.toml.example
secret = "<MTG_SECRET>"
bind-to = "0.0.0.0:3128"
```

```yaml
# traefik dynamic file — see traefik/mtproto-tcp.yml
tcp:
  routers:
    mtproto:
      rule: "HostSNI(`proxy.example.com`)"
      entryPoints: [websecure]
      service: mtg
      tls:
        passthrough: true          # mtg terminates its own FakeTLS
  services:
    mtg:
      loadBalancer:
        servers:
          - address: "mtg:3128"
```

Generate the secret with a hostname you can plausibly front to:

```bash
mtg generate-secret proxy.example.com
```

## Read this before choosing the fronting hostname

The `ee` secret **embeds a hostname**, and mtg dials it. If that name resolves
back to the proxy itself, mtg fronts to itself through your own front proxy and
burns CPU in a tight loop. This is not hypothetical — see the loop entry in
[`04-troubleshooting.md`](04-troubleshooting.md), including why the
`[domain-fronting]` option in the config file does not rescue you.

Rule of thumb: the hostname inside the secret must resolve to something that is
**not** your proxy host.

## Sharing

```bash
mtg access /etc/mtg.toml        # prints tg:// and t.me links plus QR codes
```

Rotating the secret changes every link you have handed out, so treat the secret
and the client list as one artifact.
