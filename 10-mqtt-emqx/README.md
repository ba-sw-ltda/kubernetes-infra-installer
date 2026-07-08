# MQTT — EMQX

Official `emqx/emqx` chart (`https://repos.emqx.io/charts`), open-source/community
edition. Real distributed clustering (native session/subscription replication
across nodes) — the reason to pick this over `10-mqtt-mosquitto` instead of the
custom active/passive/passive design there. Mutually exclusive with
`10-mqtt-mosquitto` (pick one per cluster).

## What you get vs. Mosquitto HA

- True multi-node clustering, not a single active broker with hot standbys —
  all replicas serve traffic simultaneously, sessions/subscriptions are
  replicated cluster-wide.
- A built-in web Dashboard (port 18083) for monitoring/browsing — no need for
  `11-mqtt-explorer` if this is your broker, though that component still works
  fine pointed at EMQX too.
- No persistence-design caveats like Mosquitto HA's retained-message-only sync
  — this is a real production-grade clustering implementation, not something
  bolted on for this installer.
- An official, config-only dynamic authorization backend
  (`authorization.sources` type `redis`) — ACLs can be looked up per-client at
  connect/subscribe time instead of provisioned statically. Mosquitto has no
  equivalent (see `10-mqtt-mosquitto`'s "Accepted limitations"). **This is why
  a future multi-plant deployment (several physical "Anlagen" behind one
  shared/central broker, each vehicle restricted to only the topics of the
  plant it's currently at) must run on EMQX, not Mosquitto** — that scheme
  needs per-vehicle ACLs resolved dynamically against an external store (e.g.
  Redis, already deployed via `20-redis`), not a hand-maintained ACL file.
  Not wired up yet — currently only the file-based authorizer is configured
  (see the ACL ConfigMap in `Install.ps1`, added to fix `$SYS` topic
  visibility); the Redis source would be a new `EMQX_AUTHORIZATION__SOURCES__`
  entry added ahead of it.

## Quick reference

- MQTT (cluster-internal): `mqtt-broker.shared-infra.svc.cluster.local:1883`
- Dashboard: the Ingress hostname collected via `Prompt.ps1`, or
  `kubectl port-forward -n shared-infra svc/mqtt-broker 18083:18083` →
  http://localhost:18083
- Dashboard login: `admin` / the password collected (or generated) via
  `Prompt.ps1` — shown again at the end of `Install.ps1`'s output.

## Odd replica counts

EMQX recommends an odd number of nodes so the cluster can heal cleanly after a
net-split — `Config.psd1`'s default of 3 follows that; change with care.
