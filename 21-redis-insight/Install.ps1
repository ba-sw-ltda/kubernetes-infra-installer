<#
.SYNOPSIS
    Install Redis Insight (web UI for Redis) — raw manifests, no Helm chart.
    Credentials are read from Vault via CSI mount. A sidecar watches the
    mounted password file and updates the stored Redis connection via Redis
    Insight's REST API whenever the secret is rotated in Vault (~60 s lag).
.PARAMETER Platform
    Target platform
.PARAMETER Namespace
    Shared-infra namespace
.PARAMETER Hostname
    Ingress hostname (from Prompt.ps1)
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Platform,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$Hostname
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 21 - Redis Insight" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$UserConfig = $FullConfig.UserConfig
$Name       = $FullConfig.Name

# Redis connection details — fixed by convention: the Redis component always
# publishes its master under <release>-master.<namespace>.svc.cluster.local
# (Bitnami chart, release name "redis", confirmed via live install).
$redisHost = "redis-master.$Namespace.svc.cluster.local"
$redisPort = "6379"
$redisUser = "default"
$vaultPath = "$Namespace/redis-acl-users"

Write-Host "  Image:      $($UserConfig.Image):$($UserConfig.Version)" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Hostname:   $Hostname" -ForegroundColor Gray
Write-Host "  Redis:      ${redisHost}:${redisPort}" -ForegroundColor Gray
Write-Host ""

# ── 1. CSI: mount the 'default' user password from Vault ─────────────────────
# Uses the same Vault path as the Redis installer wrote to — Redis Insight
# only needs read access to the 'default' key, so its policy is scoped to
# exactly that path (least privilege, separate Vault role from Redis itself).
$csi = New-CsiSecretMount -AppName $Name -VaultPath $vaultPath -Keys @($redisUser) `
    -Namespace $Namespace -ServiceAccount $Name -Platform $Platform `
    -MountPath "/vault/secrets" -BaseDir $BaseDir
if (-not $csi.Installed) {
    Write-Error "Secrets backend not available — RequiredPrereqs=secrets-backend should have caught this earlier"
    exit 1
}

$csi.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply SecretProviderClass '$($csi.SpcName)'"; exit 1 }
Write-Host "  ✓ SecretProviderClass '$($csi.SpcName)' applied" -ForegroundColor Green

# ── 2. Sidecar sync script ConfigMap ─────────────────────────────────────────
# Single-quoted here-string: $ belongs to the shell, not PowerShell.
# The sidecar:
#   1. Waits for Redis Insight's /api/databases to become available
#   2. Registers the Redis connection via POST (or finds an existing one)
#   3. Polls the mounted password file every 60 s; on sha256 change, PATCHes
#      the stored connection with the new password — no pod restart needed.
$syncScript = @'
#!/bin/sh
VAULT_FILE="/vault/secrets/default"
RI_URL="http://localhost:5540"
DB_NAME="Redis (shared-infra)"
REDIS_HOST="${REDIS_HOST:-redis-master.shared-infra}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_USER="${REDIS_USER:-default}"
POLL_INTERVAL="${SYNC_INTERVAL:-60}"

DB_ID=""
LAST_HASH=""

log() { printf '[%s] %s\n' "$(date -u +%T)" "$*"; }

wait_for_ri() {
  log "Waiting for Redis Insight..."
  until curl -sf "${RI_URL}/api/databases" > /dev/null 2>&1; do sleep 3; done
  log "Redis Insight ready."
}

register_or_update() {
  PASSWORD="$(cat "${VAULT_FILE}")"
  EXISTING=$(curl -sf "${RI_URL}/api/databases" 2>/dev/null)
  EXISTING_ID=$(printf '%s' "${EXISTING}" \
    | jq -r ".[] | select(.name == \"${DB_NAME}\") | .id" 2>/dev/null | head -1)

  if [ -n "${EXISTING_ID}" ]; then
    PATCH=$(jq -n --arg pw "${PASSWORD}" '{"password":$pw}')
    curl -sf -X PATCH "${RI_URL}/api/databases/${EXISTING_ID}" \
      -H "Content-Type: application/json" -d "${PATCH}" > /dev/null 2>&1
    DB_ID="${EXISTING_ID}"
    log "Updated password for existing connection (id=${DB_ID})"
  else
    PAYLOAD=$(jq -n \
      --arg  name "${DB_NAME}"   \
      --arg  host "${REDIS_HOST}" \
      --argjson port "${REDIS_PORT}" \
      --arg  user "${REDIS_USER}" \
      --arg  pw   "${PASSWORD}"  \
      '{"name":$name,"host":$host,"port":$port,"username":$user,"password":$pw}')
    RESPONSE=$(curl -sf -X POST "${RI_URL}/api/databases" \
      -H "Content-Type: application/json" -d "${PAYLOAD}" 2>/dev/null)
    DB_ID=$(printf '%s' "${RESPONSE}" | jq -r '.id' 2>/dev/null)
    log "Registered new connection (id=${DB_ID})"
  fi
  LAST_HASH="$(sha256sum "${VAULT_FILE}" | cut -d' ' -f1)"
}

watch_rotation() {
  while true; do
    sleep "${POLL_INTERVAL}"
    CURRENT_HASH="$(sha256sum "${VAULT_FILE}" | cut -d' ' -f1)"
    if [ "${CURRENT_HASH}" != "${LAST_HASH}" ] && [ -n "${DB_ID}" ]; then
      log "Secret rotated — updating Redis Insight connection..."
      PASSWORD="$(cat "${VAULT_FILE}")"
      PATCH=$(jq -n --arg pw "${PASSWORD}" '{"password":$pw}')
      curl -sf -X PATCH "${RI_URL}/api/databases/${DB_ID}" \
        -H "Content-Type: application/json" -d "${PATCH}" > /dev/null 2>&1
      LAST_HASH="${CURRENT_HASH}"
      log "Password updated."
    fi
  done
}

wait_for_ri
register_or_update
watch_rotation
'@

$scriptTmp = New-TemporaryFile
try {
    Set-Content -Path $scriptTmp.FullName -Value $syncScript -Encoding UTF8
    & kubectl create configmap "$Name-sidecar-script" -n $Namespace `
        --from-file="sync.sh=$($scriptTmp.FullName)" `
        --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
} finally {
    Remove-Item $scriptTmp.FullName -Force -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create sidecar script ConfigMap"; exit 1 }
Write-Host "  ✓ Sidecar script ConfigMap ready" -ForegroundColor Green

# ── 3. Core manifests: ServiceAccount, PVC, Deployment, Service ──────────────
$manifests = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $Name
  namespace: $Namespace
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $Name
  namespace: $Namespace
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: $($UserConfig.Persistence.Size)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $Name
  namespace: $Namespace
  labels:
    app.kubernetes.io/name: $Name
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: $Name
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $Name
    spec:
      serviceAccountName: $Name
      containers:
      - name: redis-insight
        image: "$($UserConfig.Image):$($UserConfig.Version)"
        ports:
        - name: http
          containerPort: $($UserConfig.Port)
        resources:
          limits:
            cpu: $($UserConfig.Resources.Limits.Cpu)
            memory: $($UserConfig.Resources.Limits.Memory)
          requests:
            cpu: $($UserConfig.Resources.Requests.Cpu)
            memory: $($UserConfig.Resources.Requests.Memory)
        volumeMounts:
        - name: data
          mountPath: /data
        - name: vault-secrets
          mountPath: /vault/secrets
          readOnly: true
      - name: connection-sync
        image: $($UserConfig.SidecarImage)
        command: ["/bin/sh", "/scripts/sync.sh"]
        env:
        - name: REDIS_HOST
          value: "$redisHost"
        - name: REDIS_PORT
          value: "$redisPort"
        - name: REDIS_USER
          value: "$redisUser"
        - name: SYNC_INTERVAL
          value: "60"
        resources:
          limits:
            cpu: $($UserConfig.SidecarResources.Limits.Cpu)
            memory: $($UserConfig.SidecarResources.Limits.Memory)
          requests:
            cpu: $($UserConfig.SidecarResources.Requests.Cpu)
            memory: $($UserConfig.SidecarResources.Requests.Memory)
        volumeMounts:
        - name: vault-secrets
          mountPath: /vault/secrets
          readOnly: true
        - name: sidecar-script
          mountPath: /scripts
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: $Name
      - name: vault-secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: $($csi.SpcName)
      - name: sidecar-script
        configMap:
          name: $Name-sidecar-script
          defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: $Name
  namespace: $Namespace
spec:
  selector:
    app.kubernetes.io/name: $Name
  ports:
  - name: http
    port: $($UserConfig.Port)
    targetPort: http
"@

$applyOutput = $manifests | & kubectl apply -f - 2>&1
if ($LASTEXITCODE -ne 0) {
    foreach ($line in $applyOutput) { Write-Host $line -ForegroundColor Red }
    Write-Error "Failed to apply Redis Insight manifests"
    exit 1
}
Write-Host "  ✓ Manifests applied" -ForegroundColor Green

# ── 4. Rollout ────────────────────────────────────────────────────────────────
$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/$Name", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete"; exit 1 }
Write-Host "  ✓ Ready" -ForegroundColor Green

# ── 5. Ingress ────────────────────────────────────────────────────────────────
$ingressClass = Get-IngressClass
$protect      = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform
$authAnnotations = "`n" + (($protect.Annotations.GetEnumerator() | ForEach-Object { "    $($_.Key): `"$($_.Value)`"" }) -join "`n")

$issuerName           = Get-ClusterIssuerName -Platform $Platform
$sslRedirect          = if ($issuerName) { "true" } else { "false" }
$issuerAnnotationLine = if ($issuerName) { "`n    cert-manager.io/cluster-issuer: $issuerName" } else { "" }
$tlsSecretName        = "$($Hostname -replace '\.', '-')-tls"
$tlsBlock = if ($issuerName) {
@"
  tls:
  - hosts:
    - $Hostname
    secretName: $tlsSecretName
"@
} else { "" }

$ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $Name
  namespace: $Namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "$sslRedirect"$issuerAnnotationLine$authAnnotations
spec:
  ingressClassName: $ingressClass
$tlsBlock
  rules:
  - host: $Hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $Name
            port:
              number: $($UserConfig.Port)
"@

$ingressYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green }
else { Write-Warning "  Could not apply Ingress — check cluster ingress controller" }

# ── 6. Portal entry ───────────────────────────────────────────────────────────
$scheme = if ($issuerName) { "https" } else { "http" }
Register-PortalEntry -Name "Redis Insight" -Url "${scheme}://$Hostname" `
    -Category "Data" -Subtitle "Redis browser & monitoring" -Order 21

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l "app.kubernetes.io/name=$Name"
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  URL:        ${scheme}://$Hostname" -ForegroundColor Yellow
Write-Host "  Redis:      ${redisHost}:${redisPort}  (user: $redisUser)" -ForegroundColor Gray
Write-Host "  Connection is pre-configured automatically via sidecar." -ForegroundColor Gray
Write-Host "  On Vault rotation the sidecar updates the password within ~60 s." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
