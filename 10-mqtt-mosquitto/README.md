# MQTT — Mosquitto (active/passive/passive HA)

Custom-built component (not just chart configuration) implementing the
pre-decided architecture: active/passive/passive Mosquitto with Redis as the
shared store. No public OSS plugin gives vanilla Eclipse Mosquitto a Redis-backed
message store or multi-instance failover, so this is genuinely new software —
a small custom image plus shell scripts plus RBAC. Mutually exclusive with
`10-mqtt-emqx` (pick one per cluster).

## Design

3 replicas (`mqtt-broker-0/1/2`), no PVC per pod — Redis is the only durable
store, so any replica can become active with no data locality concerns.

- **Leader election**: Redis-native distributed lock
  (`SET mosquitto:leader <pod-name> NX PX 15000`, renewed by the current leader
  every ~5s via a Lua script that only extends the TTL if it still holds the
  key). All 3 pods run the identical entrypoint; only the one that acquires the
  lock proceeds to start the real `mosquitto` process — the other two stay in
  the wait loop, idle.
- **Becoming active**: the winning pod (a) replays every `mqtt:retain:*` key
  from Redis into its local broker via `mosquitto_pub -r` (races the broker's
  own startup, retries until reachable), (b) starts `mosquitto`, (c) patches its
  own pod label `mqtt-role=active` via the K8s API (using its own
  service-account token — RBAC restricted to the 3 known StatefulSet pod
  names, nothing broader).
- **Staying in sync while active**: every ~5s, a full dump of the broker's
  currently retained messages (`mosquitto_sub --retained-only`) is mirrored
  into Redis, with deletions reconciled against the previous snapshot.
- **Routing**: the `mqtt-broker` Service selects
  `app.kubernetes.io/name=mqtt-broker,mqtt-role=active` — always exactly
  one matching pod, so clients get one stable address that's always the live
  broker. No readiness/liveness probe on the MQTT port — passive replicas never
  open it at all by design, so a TCP probe would mark them permanently
  unhealthy and get them restarted in a loop; correctness comes from the
  label-based routing, not from probes.

Full implementation: `_charts/mosquitto-ha` (chart) + `image/Dockerfile` (the
custom image — `eclipse-mosquitto:2` plus `redis-cli`/`curl`/bash/coreutils;
the scripts themselves are ConfigMap-mounted at `/scripts`, not baked into the
image, so they can be iterated on without a rebuild).

## Accepted limitations (stated plainly, not hidden)

- In-flight QoS 1/2 message queues and persistent (`clean_session=false`)
  client sessions are **not** preserved across failover — only retained
  messages are made cluster-durable via Redis. True session continuity would
  require forking Mosquitto itself, or choosing `10-mqtt-emqx` instead (which
  is exactly why that alternative exists).
- Failover time ≈ Redis lock TTL (~15s) + broker startup + retained-message
  replay — bounded, not instant. MQTT clients are expected to auto-reconnect
  anyway.
- The retained-message sync captures one line per topic (`topic payload`) —
  payloads containing embedded newlines won't round-trip correctly. Fine for
  the common case (JSON/plain-text status values).
- No authentication wired up yet (`allow_anonymous true`) — matches this
  installer's current "plain secrets, no CSI" stance everywhere else; not for
  untrusted networks as-is.
- No dynamic, externally-backed authorization. Vanilla Eclipse Mosquitto only
  offers a static `acl_file` or its self-contained "Dynamic Security" plugin
  (own local JSON DB, managed via an MQTT admin API) — there is no official
  Redis/HTTP-backed ACL. **Decision: if a future deployment needs to run
  multiple plants ("Anlagen") behind one shared broker with per-vehicle,
  per-plant topic isolation enforced as a security control (not just
  convention), use `10-mqtt-emqx` instead** — EMQX ships an official
  `authorization.sources` Redis backend, so per-vehicle ACLs can be looked up
  dynamically instead of provisioned by hand. Getting that on Mosquitto would
  mean building an unofficial third-party auth plugin (e.g. `mosquitto-go-auth`)
  into the custom image — avoid; switch broker instead.

## Before installing on RKE2/AKS/EKS/GKE

Set `UserConfig.ImageRegistry` in `Config.psd1` (or a per-platform
`Config.<PlatformShort>.psd1` override) to a registry the target cluster can
pull from, and make sure `docker login <registry>` already succeeds on this
machine — `Install.ps1` builds the image locally and pushes it there. Kind
needs neither: the image is loaded directly into the Kind cluster's containerd.

## Manual failover test

```powershell
kubectl get pods -n shared-infra -l app.kubernetes.io/name=mqtt-broker --show-labels
kubectl delete pod mqtt-broker-0 -n shared-infra
# watch a passive pod pick up mqtt-role=active within ~15-20s
kubectl get pods -n shared-infra -l mqtt-role=active -w
```
