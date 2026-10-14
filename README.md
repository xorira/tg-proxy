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

## Running the published image

A ready image is built from this repository by GitHub Actions and published to
`ghcr.io/xorira/tg-webproxy`. Configuration is entirely environment driven, so
there are no files to prepare:

```bash
docker run -d --name tg-webproxy --restart unless-stopped \
  -e PUBLIC_HOSTNAME=proxy.example.com \
  -e SECRET=dd00112233445566778899aabbccddeeff \
  -e SOCKS5=socks5://10.0.0.5:1080 \
  -v tgwebproxy:/data \
  -v /srv/my-site:/srv/tproxy-site:ro \
  ghcr.io/xorira/tg-webproxy:latest
```

The container prints the client link on startup:

```
tg-webproxy: server    : proxy.example.com/t7k2xwpbq3abcd
tg-webproxy: secret    : cN0AESIzRFVmd4iZqrvM3e7_
tg-webproxy: link      : https://t.me/webproxy?server=...&secret=...
```

Point your front proxy at the container's port **8082** and route the whole
hostname to it, exactly as in `traefik/webproxy.yml`.

### Environment

| Variable | Required | Meaning |
|---|---|---|
| `PUBLIC_HOSTNAME` | **yes** | the name clients connect to; the bridge capability is bound to it |
| `SECRET` | **yes** | client-facing MTProxy secret, `dd`-prefixed or 16-byte hex. Must be a stock MTProxy secret: the same bytes go to the backend |
| `BASE_PATH` | no | path prefix; generated as random base32 when omitted. **Pin it** — a new value changes every client link |
| `SOCKS5` | no | upstream proxy for the backend. Without it the backend dials Telegram directly, which fails on a censored uplink |
| `CARRIER_MODE` | no | `https` (default), `https-lanes`, `websocket`, `websocket-lanes` |
| `ALLOW_PLACEHOLDER_SITE` | no | set to `yes` to run with the bundled placeholder. See below |
| `DNS` | no | resolver for the backend, defaults to Docker's `127.0.0.11` |

### Two things the image insists on

**Mount a volume at `/data`.** It holds the 32-byte session signing key. Without
a volume the key is regenerated whenever the container is replaced and every live
session drops.

**Supply your own site.** The relay presents itself as an ordinary website. A
placeholder shared by everyone who pulls this image is an active-probing
signature, so the entrypoint refuses to fall back to it unless you pass
`-e ALLOW_PLACEHOLDER_SITE=yes`. Mount yours at `/srv/tproxy-site`.

### Hosts with restrictive AppArmor

On a host where AppArmor mediates `AF_UNIX` and `docker-default` has no `unix`
rules, `socat` dies with `SIGILL` and takes the stack with it. Add:

```bash
--security-opt apparmor=unconfined
```

The container then reports `component 'socat' exited` in its logs. See
[`docs/04-troubleshooting.md`](docs/04-troubleshooting.md) for the diagnosis.

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
