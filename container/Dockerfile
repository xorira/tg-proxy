# syntax=docker/dockerfile:1
#
# Built entirely from public sources, so the published image is reproducible:
#   stage 1  mtg v2 + patches/mtg-obfuscated2.patch  -> the obfuscated2 backend
#   stage 2  telegramdesktop/tproxy-server          -> the relay
#   stage 3  alpine + socat                         -> runtime, env-configured
#
# Build with the repository root as the context:
#   docker build -f container/Dockerfile -t tg-webproxy .

# ------------------------------------------------------- patched backend ------
FROM golang:1.26-alpine AS backend

RUN apk add --no-cache git

WORKDIR /src

# The patch tracks the v2 branch; pin MTG_REF to a commit for a frozen build.
ARG MTG_REF=v2
RUN git clone --depth 1 --branch "${MTG_REF}" https://github.com/9seconds/mtg.git .

COPY patches/mtg-obfuscated2.patch /tmp/mtg-obfuscated2.patch
RUN git apply /tmp/mtg-obfuscated2.patch \
 && go test ./mtglib/... \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/mtg-obfuscated2 .

# ------------------------------------------------------------------ relay -----
FROM golang:1.26-alpine AS relay

RUN apk add --no-cache git

WORKDIR /src

ARG TPROXY_REF=master
RUN git clone --depth 1 --branch "${TPROXY_REF}" https://github.com/telegramdesktop/tproxy-server.git .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tproxy-server ./cmd/tproxy-server

# ---------------------------------------------------------------- runtime -----
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata socat \
 && adduser -D -u 1001 -h /app tproxy

WORKDIR /app

COPY --from=backend /out/mtg-obfuscated2    ./mtg-obfuscated2
COPY --from=relay   /out/tproxy-server      ./tproxy-server
COPY container/entrypoint.sh                ./entrypoint.sh
COPY container/templates/                   ./templates/
COPY container/placeholder-site/            ./placeholder-site/

# Directories the unprivileged user must own. /data holds the session signing
# key; /run/tgwebproxy holds the generated configuration.
RUN chmod 0755 ./entrypoint.sh ./mtg-obfuscated2 ./tproxy-server \
 && mkdir -p /data /run/tgwebproxy \
 && chown tproxy:tproxy /data /run/tgwebproxy

# Run unprivileged. This is not cosmetic: in at least one container runtime socat
# dies with SIGILL when it runs as root, which takes the whole stack down with it.
USER tproxy

# The session signing key lives here; mount a volume so it survives replacement.
VOLUME ["/data"]

# Only the container-facing forwarder is exposed; the front proxy talks to it.
EXPOSE 8082

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8081/readyz >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
