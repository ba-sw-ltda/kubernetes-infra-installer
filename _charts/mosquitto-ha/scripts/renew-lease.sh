#!/bin/bash
# Runs only inside the pod that already won leadership (started by entrypoint.sh
# after it broke out of the wait loop). Keeps the Redis lock alive at roughly a
# third of the TTL so transient delays don't cause a spurious failover.
set -uo pipefail

LEADER_KEY="${LEADER_KEY:-mosquitto:leader}"
LEADER_TTL_MS="${LEADER_TTL_MS:-15000}"
INTERVAL=$(( LEADER_TTL_MS / 1000 / 3 ))
[ "$INTERVAL" -lt 1 ] && INTERVAL=1

REDIS_AUTH=()
if [ -n "${REDIS_PASSWORD_FILE:-}" ] && [ -f "$REDIS_PASSWORD_FILE" ]; then
  REDIS_AUTH=(--user "${REDIS_USERNAME:-default}" -a "$(cat "$REDIS_PASSWORD_FILE")" --no-auth-warning)
elif [ -n "${REDIS_PASSWORD:-}" ]; then
  REDIS_AUTH=(--user "${REDIS_USERNAME:-default}" -a "$REDIS_PASSWORD" --no-auth-warning)
fi
rcli() { redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "${REDIS_AUTH[@]}" "$@"; }

while true; do
  sleep "$INTERVAL"
  # Lua: only renew the TTL if we still hold the key — never extend a lease we
  # no longer own (e.g. after a brief partition where someone else took over).
  rcli EVAL \
    "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('PEXPIRE', KEYS[1], ARGV[2]) else return 0 end" \
    1 "$LEADER_KEY" "$HOSTNAME" "$LEADER_TTL_MS" >/dev/null 2>&1
done
