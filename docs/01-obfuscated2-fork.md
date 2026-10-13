# The obfuscated2 patch for mtg v2

## What the stock binary does

`mtglib/secret.go` in mtg v2 accepts exactly one shape of secret:

```go
const secretFakeTLSFirstByte byte = 0xee
...
if decoded[0] != secretFakeTLSFirstByte {
    return fmt.Errorf("incorrect first byte of secret: %#x", decoded[0])
}
```

and the type carries a mandatory hostname:

```go
type Secret struct {
    Key  [SecretKeyLength]byte
    Host string
}
```

The source comment says the rest is history:

> Actually, in the past we also had `dd` secrets and prefixless ones. But this is
> history. Currently, we do have only `ee` secrets which mean faketls + protection
> from statistical attacks on a length.

So a stock mtg v2 refuses to start on a `dd` secret. That is the whole blocker for
using it as a WEB proxy backend, because the relay forwards the client's
obfuscated2 stream verbatim and the backend has to accept those same bytes.

## Why the work is smaller than it looks

`mtglib/internal/obfuscation` is a complete, tested implementation of MTProto
transport obfuscation: the 64-byte frame layout from the spec, AES-CTR key
derivation with a mixed-in secret, and both directions.

```go
func (o Obfuscator) ReadHandshake(r essentials.Conn) (int, essentials.Conn, error)
func (o Obfuscator) SendHandshake(w essentials.Conn, dc int) (essentials.Conn, error)
```

It is live in stock mtg v2: `SendHandshake` is the outgoing leg to Telegram, and
`ReadHandshake` runs as the **inner** layer under the FakeTLS wrapper. The proxy
already calls it on the client connection:

```go
// mtglib/proxy.go
if !p.doFakeTLSHandshake(ctx) {
    return
}
...
if err := p.doObfuscatedHandshake(ctx); err != nil {
    return
}
```

Stock mtg is therefore `FakeTLS(obfuscated2(MTProto))` and always requires both. A
stock MTProxy client does obfuscated2 with **no** TLS wrapper, so the patch has to
make the outer layer conditional.

## What the patch changes

| File | Change |
|---|---|
| `mtglib/secret.go` | Three modes — `ee` (FakeTLS), `dd` (secured, 17 bytes), prefixless (simple, 16 bytes) — disambiguated by length, as in canonical MTProxy. `Host` is only meaningful in FakeTLS mode. |
| `mtglib/proxy.go` | The FakeTLS handshake and the doppelganger wrapper run only for FakeTLS secrets; obfuscated2 modes go straight to `doObfuscatedHandshake`. `DomainFrontingAddress` returns empty when there is no hostname. |
| `mtglib/internal/obfuscation/handshake_frame.go` | Accept all three stock transport markers (`ef`/`ee`/`dd`), not only the padded-intermediate one. mtg relays the inner stream opaquely, so restricting this set only rejects valid clients. |
| `mtglib/internal/obfuscation/obfuscator.go` | Uses the set instead of a single constant. |
| `internal/cli/doctor.go` | The fronting-domain and SNI checks are FakeTLS concepts and are skipped otherwise. |
| `mtglib/secret_test.go` | Expectations updated, plus new cases for the added modes. |

## Build

```bash
git clone --depth 1 --branch v2 https://github.com/9seconds/mtg.git
cd mtg
git apply /path/to/mtg-obfuscated2.patch
go build -trimpath -ldflags="-s -w" -o mtg-obfuscated2 .
go test ./mtglib/...
```

The patch was written against `v2` at `83a31e0`. It is a fork: every upstream
update needs a rebase, and the secret parser plus the transport-marker set are the
parts most likely to conflict.

## Check it before you rely on it

`doctor` validates the whole egress path, and for a `dd` secret it now skips the
FakeTLS-only sections instead of failing them:

```bash
./mtg-obfuscated2 doctor /etc/mtg/config.toml
```

```
Validate network connectivity with proxy socks5://127.0.0.1:1080
  ✅ DC 1
  ✅ DC 2
  ...
```

Then prove it end to end with a real obfuscated2 client. `tools/obftest` performs
the handshake and one `req_pq_multi` and expects a `resPQ` back — the same check
the tproxy documentation recommends for a healthy MTProxy. It must live **inside**
the mtg tree, because it imports an `internal` package:

```bash
mkdir -p mtglib/obftest
cp /path/to/obftest.go mtglib/obftest/main.go
go build -o obftest ./mtglib/obftest
./obftest -secret dd00112233445566778899aabbccddeeff -addr 127.0.0.1:3128 -dc 2
```

```
OK: obfuscated2 handshake accepted
OK: resPQ received — the proxy reaches Telegram
```

A wrong secret must fail — the server resets the connection once the handshake
does not authenticate. If you get `unsupported connection type: 0x...`, the
client is using a marker the set does not cover: add it to `hfConnectionTypeSet`.
