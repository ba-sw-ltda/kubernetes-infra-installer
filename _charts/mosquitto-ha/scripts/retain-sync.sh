#!/bin/bash
# Runs only inside the active pod. Every few seconds, takes a full snapshot of
# the local broker's currently retained messages and mirrors it into Redis, so
# the next failover has up-to-date state to replay (replay-retain.sh).
#
# Capture mechanism: `mosquitto_sub --retained-only` prints only retain-flagged
# messages and exits on the first non-retained one (or after -W seconds of
# silence) — i.e. exactly one full dump of the broker's current retained set,
# without needing to distinguish the retain flag on an open-ended live feed.
#
# Known v1 limitation: payloads are captured as one line per topic (`%t %p`),
# so retained payloads containing embedded newlines won't round-trip correctly.
# Fine for the common case (JSON/plain-text status values); revisit with a
# binary-safe (hex) encoding if a real payload ever needs it.
set -uo pipefail

RETAIN_PREFIX="${RETAIN_PREFIX:-mqtt:retain:}"
REDIS_AUTH=()
if [ -n "${REDIS_PASSWORD_FILE:-}" ] && [ -f "$REDIS_PASSWORD_FILE" ]; then
  REDIS_AUTH=(--user "${REDIS_USERNAME:-default}" -a "$(cat "$REDIS_PASSWORD_FILE")" --no-auth-warning)
elif [ -n "${REDIS_PASSWORD:-}" ]; then
  REDIS_AUTH=(--user "${REDIS_USERNAME:-default}" -a "$REDIS_PASSWORD" --no-auth-warning)
fi
rcli() { redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "${REDIS_AUTH[@]}" "$@"; }

PREV=/tmp/retain-snapshot.prev
: > "$PREV"

while true; do
  sleep 5
  CURR=/tmp/retain-snapshot.curr
  : > "$CURR"

  while IFS=' ' read -r topic payload; do
    [ -z "$topic" ] && continue
    printf '%s\n' "$topic" >> "$CURR"
    rcli SET "${RETAIN_PREFIX}${topic}" "$payload" >/dev/null 2>&1
  done < <(mosquitto_sub -h localhost -p 1883 -t '#' --retained-only -W 3 -F '%t %p' 2>/dev/null)

  # Reconcile deletions: topics retained last round but not this round.
  comm -23 <(sort "$PREV") <(sort "$CURR") | while read -r gone; do
    [ -z "$gone" ] && continue
    rcli DEL "${RETAIN_PREFIX}${gone}" >/dev/null 2>&1
  done

  mv "$CURR" "$PREV"
done
