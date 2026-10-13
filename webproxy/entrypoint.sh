#!/bin/sh
# All three processes live in this one container, mirroring the reference layout
# where the relay, its backend and the local admin surface are co-located and
# only a front proxy is exposed:
#
#   traefik -> socat :8082 -> relay 127.0.0.1:8080 -> backend 127.0.0.1:3128
#
# The relay refuses any listen or backend address that is not numeric loopback,
# so the backend must be in this network namespace and socat must be the only
# thing binding a non-loopback address. socat forwards bytes verbatim, which is
# what keeps traefik's single-value X-Forwarded-For intact.
set -e

./mtg-obf2 run /etc/mtg/config.toml &
FORK_PID=$!

socat TCP-LISTEN:8082,fork,reuseaddr,nodelay TCP:127.0.0.1:8080 &
SOCAT_PID=$!

./tproxy-server -config /etc/tproxy-server/config.json &
RELAY_PID=$!

cleanup() {
	kill "$FORK_PID" "$SOCAT_PID" "$RELAY_PID" 2>/dev/null || true
	wait 2>/dev/null || true
}
trap cleanup INT TERM

# Either a backend, the forwarder or the relay dying means the set is unhealthy.
while kill -0 "$FORK_PID" 2>/dev/null &&
      kill -0 "$SOCAT_PID" 2>/dev/null &&
      kill -0 "$RELAY_PID" 2>/dev/null; do
	sleep 2
done

echo "a component exited; shutting the container down" >&2
cleanup
exit 1
