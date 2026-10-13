# Telegram MTProto / WEB proxy on your own infrastructure

Two ways to give people a working Telegram proxy on a host you control, plus the
patch that makes the second one possible behind a censoring ISP.

| | **A — direct MTProto proxy** | **B — Telegram WEB proxy** |
|---|---|---|
| Client | any Telegram app, "MTProto proxy" field | apps with the WEB proxy type (Android, Aug 2026+) |
| Facing the internet | `obfuscated2` or FakeTLS on a dedicated port | always HTTPS/WebSocket on 443 |
| Routed by hostname | only in FakeTLS mode (SNI exists) | yes, ordinary `Host` routing |
| Needs a patched proxy | no | **yes** — see [`patches/`](patches/) |
| Docs | [`docs/03-mtproto-direct.md`](docs/03-mtproto-direct.md) | [`docs/02-web-proxy.md`](docs/02-web-proxy.md) |

## Why a patch

The Telegram WEB proxy (`telegramdesktop/tproxy-server`) is only the client-facing
half. It terminates HTTPS from the app and then hands every multiplexed stream to
a **local MTProxy over plain obfuscated2 TCP**:

```
Telegram app ──HTTPS/WebSocket :443──► tproxy-server relay
                                            │  obfuscated2, no TLS
                                            ▼
                                       MTProxy backend ──► Telegram DC
```

Only the first leg is HTTPS. The second leg is what has to actually reach
Telegram, and on a censored uplink that is the hard part:

* **Official MTProxy** dials Telegram's middle-end directly and has no proxy
  chaining option at all. If Telegram is blocked, it accepts clients and then
  every stream stalls forever with no error on any layer.
* **mtg v2** can chain through a SOCKS5 proxy, but it dropped the stock
  obfuscated2 secret modes: `dd`-prefixed and prefixless secrets are rejected at
  config parse with `incorrect first byte of secret`.
* **mtg v1** still speaks obfuscated2, but has no SOCKS5 chaining.

`patches/mtg-obfuscated2.patch` adds the missing half to mtg v2 — obfuscated2
secrets **and** proxy chaining in one binary. It is a contained change: the
obfuscated2 implementation already ships inside mtg v2 (it is used for the
outgoing leg and as the inner layer under FakeTLS), so the patch is mostly
wiring plus the secret parser.

## Architecture of scheme B

```
Telegram app
    │  HTTPS :443
    ▼
front proxy (traefik/caddy/nginx)     ← terminates TLS, routes by Host
    │  http
    ▼
socat :8082  ──►  tproxy-server 127.0.0.1:8080
                       │  obfuscated2
                       ▼
                  patched mtg 127.0.0.1:3128
                       │  socks5
                       ▼
                  upstream tunnel ──► Telegram
```

All of it fits in **one container**: the relay, the patched backend and the
forwarder. The relay refuses any `listen` or `backend` address that is not a
numeric loopback address, which is exactly why the backend must share its network
namespace and why `socat` — not the front proxy — is what faces the container
network. See [`docs/02-web-proxy.md`](docs/02-web-proxy.md).

## Layout

```
patches/   the obfuscated2 patch for mtg v2, and how to build it
mtg/       example config for the direct MTProto proxy (scheme A)
webproxy/  relay config, container recipe and the single-container stack (scheme B)
traefik/   dynamic configuration fragments for both schemes
docs/      deployment and troubleshooting notes
```

## What is deliberately not here

* **A ready-made public website.** The relay disguises itself as an ordinary site
  and serves one from memory. Upstream is explicit that a shared starter becomes
  an active-probing signature, so write your own — see
  [`webproxy/site/README.md`](webproxy/site/README.md).
* **Real secrets or real hostnames.** Every example uses placeholders. The MTProto
  secret, the relay profile secret, the base path and the signing key are
  deployment-specific and belong in your private store.
* **Base path values.** The path prefix in a WEB proxy deployment is a second
  unknown that a scanner cannot guess; publishing yours would throw that away.

## Requirements

* a Linux host with a public address and a reverse proxy you already run
* Docker (or the patience to run all three processes under systemd)
* Go 1.26+ and a C toolchain to build the patch
* a working egress path to Telegram — see the troubleshooting notes for what to
  check before you blame the code

## License

The patch and the documents are derived from [9seconds/mtg](https://github.com/9seconds/mtg)
(MIT). See [`LICENSE`](LICENSE). `tproxy-server` is a separate project by Telegram;
nothing here redistributes it.
