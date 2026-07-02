#!/bin/bash
# Runs once, right after this pod becomes active. Replays every retained message
# Redis knows about into the freshly started local broker, so a newly-promoted
# active pod's retained-message table converges with the cluster's last known
# state instead of starting empty. Races the broker's own startup (started
# concurrently by entrypoint.sh) — retries until it's reachable rather than
# waiting on an explicit "broker ready" signal mosquitto doesn't expose.
set -uo pipefail

RETAIN_PREFIX="${RETAIN_PREFIX:-mqtt:retain:}"
REDIS_AUTH=()
if [ -n "${REDIS_PASSWORD_FILE:-}" ] && [ -f "$REDIS_PASSWORD_FILE" ]; then
  REDIS_AUTH=(--user "${REDIS_USERNAME:-default}" -a "$(cat "$REDIS_PASSWORD_FILE")" --no-auth-warning)
elif [ -n "${REDIS_PASSWORD:-}" ]; then
  REDIS_AUTH=(--user "${REDIS_USERNAME:-default}" -a "$REDIS_PASSWORD" --no-auth-warning)
fi
rcli() { redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "${REDIS_AUTH[@]}" "$@"; }

i=0
until mosquitto_pub -h localhost -p 1883 -t '$internal/healthcheck' -m x -q 0 >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then echo "[replay] broker not reachable after 30s, giving up"; exit 1; fi
  sleep 1
done

count=0
for key in $(rcli --scan --pattern "${RETAIN_PREFIX}*" 2>/dev/null); do
  topic="${key#"$RETAIN_PREFIX"}"
  payload="$(rcli GET "$key")"
  mosquitto_pub -h localhost -p 1883 -t "$topic" -m "$payload" -r -q 1 >/dev/null 2>&1
  count=$((count + 1))
done
echo "[replay] replayed $count retained topic(s) from Redis"
