#!/bin/bash
# Active/passive/passive entry point. Every replica runs this same script; only
# the one that acquires the Redis lock proceeds past the wait loop and starts the
# real mosquitto process. The other two stay in the loop, idle, ready to take over.
# See 10-mqtt-mosquitto/README.md for the full design and its known limitations.
set -uo pipefail

POD_NAME="${HOSTNAME}"
NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
APISERVER="https://kubernetes.default.svc"
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
TOKEN_FILE=/var/run/secrets/kubernetes.io/serviceaccount/token

LEADER_KEY="${LEADER_KEY:-mosquitto:leader}"
LEADER_TTL_MS="${LEADER_TTL_MS:-15000}"

REDIS_AUTH=()
if [ -n "${REDIS_PASSWORD_FILE:-}" ] && [ -f "$REDIS_PASSWORD_FILE" ]; then
  REDIS_AUTH=(--user "${REDIS_USERNAME:-default}" -a "$(cat "$REDIS_PASSWORD_FILE")" --no-auth-warning)
elif [ -n "${REDIS_PASSWORD:-}" ]; then
  REDIS_AUTH=(--user "${REDIS_USERNAME:-default}" -a "$REDIS_PASSWORD" --no-auth-warning)
fi
rcli() { redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "${REDIS_AUTH[@]}" "$@"; }

label_self() {
  curl -s -k -X PATCH \
    --cacert "$CACERT" \
    -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
    -H "Content-Type: application/strategic-merge-patch+json" \
    -d "{\"metadata\":{\"labels\":{\"mqtt-role\":\"$1\"}}}" \
    "$APISERVER/api/v1/namespaces/$NAMESPACE/pods/$POD_NAME" >/dev/null 2>&1
}

label_self passive

echo "[$POD_NAME] waiting to become leader for '$LEADER_KEY'..."
while true; do
  current="$(rcli GET "$LEADER_KEY" 2>/dev/null)"
  if [ "$current" = "$POD_NAME" ]; then break; fi
  if [ -z "$current" ]; then
    result="$(rcli SET "$LEADER_KEY" "$POD_NAME" NX PX "$LEADER_TTL_MS" 2>/dev/null)"
    if [ "$result" = "OK" ]; then break; fi
  fi
  sleep 3
done

echo "[$POD_NAME] acquired leadership"
label_self active

/scripts/renew-lease.sh &
/scripts/replay-retain.sh &
/scripts/retain-sync.sh &

exec mosquitto -c /mosquitto/config/mosquitto.conf
