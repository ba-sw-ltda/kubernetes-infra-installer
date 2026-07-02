# Custom image for the active/passive/passive Mosquitto HA component
# (_charts/mosquitto-ha). Adds the runtime tools the leader-election/retain-sync
# scripts need on top of the official Mosquitto image — the scripts themselves
# come from a ConfigMap mount at runtime (/scripts), not baked in here, so they
# can be iterated on without rebuilding this image. See
# 10-mqtt-mosquitto/README.md for the full design.
FROM eclipse-mosquitto:2

# mosquitto-clients explicitly installed rather than assumed present on the
# base image — the official eclipse-mosquitto image prioritizes minimal size
# and does not reliably ship mosquitto_pub/mosquitto_sub.
# coreutils+bash replace busybox ash/sh so the scripts can use bash features
# (process substitution, arrays) and GNU comm for the retained-message diff.
RUN apk add --no-cache bash coreutils curl redis mosquitto-clients
