# MQTT Explorer (Web UI)

Official web/Docker-mode image (`ghcr.io/thomasnordquist/mqtt-explorer`) for
browsing topics/retained messages on either broker. No official Helm chart
exists for it, so this is raw `kubectl apply` manifests (ServiceAccount +
Deployment + Service + PVC + optional Ingress), not a Helm release —
`Uninstall.ps1` deletes by name rather than `helm uninstall`.

Its own admin password is provisioned through Vault/CSI — generated once by
`Install.ps1`, reused on re-install, mounted into the pod at
`/vault/secrets/password` (`New-CsiSecretMount`, same pattern as `20-redis`'s
ACL credentials). No Kubernetes `Secret` exists for it at any point: the
container's entrypoint is overridden (`command`/`args` in `Install.ps1`) to
export `MQTT_EXPLORER_PASSWORD` from that mounted file before exec'ing the
real `node dist/src/server.js` process, since the upstream image only reads
that credential from a literal env var.

Standalone — works with either broker (`10-mqtt-mosquitto` or `10-mqtt-emqx`).
`Prompt.ps1` auto-detects whichever one is already installed in `shared-infra`
(checked live against the cluster) and defaults to it; falls back to manual
host/port entry otherwise (e.g. pointing at a broker outside this cluster).

## Quick reference

- URL: the Ingress hostname collected via `Prompt.ps1`, or
  `kubectl port-forward -n shared-infra svc/mqtt-explorer 3000:3000` →
  http://localhost:3000
- Login: username collected via `Prompt.ps1` (default `admin`); password is
  generated and stored in Vault by `Install.ps1`, shown again at the end of
  its output, or re-read any time via
  `kubectl exec -n openbao openbao-0 -- bao kv get secret/shared-infra/mqtt-explorer-auth`.
- Data (saved connections etc.) persists in a 1Gi PVC mounted at `/app/data`.
