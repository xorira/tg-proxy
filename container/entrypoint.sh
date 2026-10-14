#!/bin/sh
# Everything this image needs comes from the environment, so it can be started
# with nothing but `docker run -e ...`. Three processes are supervised together:
#
#   socat :8082  ->  tproxy-server 127.0.0.1:8080  ->  mtg 127.0.0.1:3128
#
# The relay only accepts numeric loopback addresses for its listener and for the
# backend, so the backend shares this network namespace and socat is the single
# thing binding a routable address. socat forwards bytes verbatim, which keeps the
# front proxy's single-value X-Forwarded-For intact.
set -eu

CONF_DIR=/run/tgwebproxy
DATA_DIR=/data
SITE_DIR=/srv/tproxy-site
PLACEHOLDER=/app/placeholder-site

log() { echo "tg-webproxy: $*"; }
die() { echo "tg-webproxy: ERROR: $*" >&2; exit 1; }

[ -n "${PUBLIC_HOSTNAME:-}" ] || die "PUBLIC_HOSTNAME is required, e.g. -e PUBLIC_HOSTNAME=proxy.example.com"
[ -n "${SECRET:-}" ]         || die "SECRET is required: the client-facing MTProto secret (dd-prefixed or 16-byte hex)"

mkdir -p "$CONF_DIR" "$DATA_DIR"

# ---------------------------------------------------------------- base path ---
if [ -z "${BASE_PATH:-}" ]; then
	BASE_PATH="$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z' | tr -d '=')"
	log "BASE_PATH was not set, generated: $BASE_PATH"
	log "pin it with -e BASE_PATH=... — a new value changes every client link"
fi

# --------------------------------------------------------------- token key ----
# Must stay identical across restarts, otherwise every live session is dropped.
if [ ! -f "$DATA_DIR/token.key" ]; then
	head -c 32 /dev/urandom > "$DATA_DIR/token.key"
	chmod 0400 "$DATA_DIR/token.key"
	if [ "$(stat -c %d "$DATA_DIR")" = "$(stat -c %d /)" ]; then
		log "WARNING: /data is not a volume, so the session signing key is regenerated"
		log "         whenever this container is replaced. Mount one: -v tgwebproxy:/data"
	fi
fi

# --------------------------------------------------------------- decoy site ---
if [ ! -d "$SITE_DIR" ] || [ -z "$(ls -A "$SITE_DIR" 2>/dev/null)" ]; then
	if [ "${ALLOW_PLACEHOLDER_SITE:-}" != "yes" ]; then
		die "no website mounted at $SITE_DIR.

  The relay presents itself as an ordinary website; that is the point of the
  design. A placeholder shared by everyone who pulls this image would be an
  active-probing signature, so it is not used unless you say so.

    mount your own:   -v /path/to/your/site:$SITE_DIR:ro
    or accept it:     -e ALLOW_PLACEHOLDER_SITE=yes"
	fi
	log "WARNING: running with the bundled placeholder site. Write your own and mount"
	log "         it at $SITE_DIR — see container/placeholder-site/README.md"
	SITE_DIR="$PLACEHOLDER"
fi

# ------------------------------------------------------------------ config ----
if [ -n "${SOCKS5:-}" ]; then
	PROXIES="[\"$SOCKS5\"]"
else
	PROXIES="[]"
fi

subst() {
	sed -e "s|__PUBLIC_HOSTNAME__|$PUBLIC_HOSTNAME|g" \
	    -e "s|__BASE_PATH__|$BASE_PATH|g" \
	    -e "s|__SECRET__|$SECRET|g" \
	    -e "s|__PROXIES__|$PROXIES|g" \
	    -e "s|__CARRIER_MODE__|${CARRIER_MODE:-https}|g" \
	    -e "s|__SITE_DIR__|$SITE_DIR|g" \
	    -e "s|__DNS__|${DNS:-127.0.0.11}|g" \
	    "$1"
}

subst /app/templates/config.json.tmpl   > "$CONF_DIR/config.json"
subst /app/templates/profiles.json.tmpl > "$CONF_DIR/profiles.json"
subst /app/templates/mtg.toml.tmpl      > "$CONF_DIR/mtg.toml"
chmod 0400 "$CONF_DIR/profiles.json" "$CONF_DIR/mtg.toml"

# --------------------------------------------------------------- client link --
# The link secret is the marked form, 0x70 || secret, base64url without padding.
MARKED="$( { printf '\x70'; printf "$(printf '%s' "$SECRET" | sed 's/../\\x&/g')"; } \
	| base64 | tr '+/' '-_' | tr -d '=\n' )"
SERVER_ENC="$(printf '%s' "$PUBLIC_HOSTNAME/$BASE_PATH" | sed 's|/|%2F|g')"

log "backend   : mtg-obfuscated2 -> ${SOCKS5:-direct} -> Telegram"
log "public    : https://$PUBLIC_HOSTNAME/$BASE_PATH/"
log "server    : $PUBLIC_HOSTNAME/$BASE_PATH"
log "secret    : $MARKED"
log "link      : https://t.me/webproxy?server=$SERVER_ENC&secret=$MARKED"

# -------------------------------------------------------------------- run -----
/app/mtg-obfuscated2 run "$CONF_DIR/mtg.toml" &
FORK_PID=$!

socat TCP-LISTEN:8082,fork,reuseaddr,nodelay TCP:127.0.0.1:8080 &
SOCAT_PID=$!

/app/tproxy-server -config "$CONF_DIR/config.json" &
RELAY_PID=$!

cleanup() { kill "$FORK_PID" "$SOCAT_PID" "$RELAY_PID" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup INT TERM

while :; do
	for component in "mtg-obfuscated2:$FORK_PID" "socat:$SOCAT_PID" "tproxy-server:$RELAY_PID"; do
		name=${component%%:*}
		pid=${component##*:}

		if ! kill -0 "$pid" 2>/dev/null; then
			log "component '$name' (pid $pid) exited, shutting the stack down"
			cleanup
			exit 1
		fi
	done

	sleep 2
done
