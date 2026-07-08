<#
.SYNOPSIS
    Install MQTT Explorer (web UI) — raw manifests, no Helm chart exists for it.
.PARAMETER Platform
    Target platform
.PARAMETER Namespace
    Shared-infra namespace
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Hostname
    Ingress hostname — mandatory, since Authelia forward-auth (mandatory
    cluster baseline) is the only authentication and requires the Ingress
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
Write-Host "  Installing: 11 - MQTT Explorer" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$UserConfig = $FullConfig.UserConfig
$Name       = $FullConfig.Name

# Fixed by convention, not asked: both 10-mqtt-mosquitto and 10-mqtt-emqx
# always publish under the Service name "mqtt-broker" on port 1883, whichever
# of the two is installed (see those components' own Install.ps1) — an
# internal implementation detail, not something the end user chooses.
$BrokerHost = "mqtt-broker.$Namespace.svc.cluster.local"
$BrokerPort = "1883"

# Same "no k8s Secret ever" credential as the broker's own Explorer auth (see
# 10-mqtt-mosquitto/Install.ps1 and 10-mqtt-emqx/Install.ps1) — this component
# only consumes it (never generates), since whichever broker is installed is
# responsible for generating/storing it first.
$mqttAuthVaultPath = "$Namespace/mqtt-client-auth"
$mqttAuthUser      = "explorer"

Write-Host "  Image:      $($FullConfig.Image):$($FullConfig.Version)" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Broker:     ${BrokerHost}:${BrokerPort}" -ForegroundColor Gray
Write-Host ""

# Namespace (idempotent — safe even when shared with sibling components)
& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject

# ── 1. MQTT client credential (CSI mount) ─────────────────────────────────────
# Read-only consumer of the credential the broker already generated/stored —
# error out clearly rather than silently pre-seeding an unauthenticated
# connection if a broker hasn't been installed yet.
if (-not (Read-ClusterSecret -Path $mqttAuthVaultPath -Key $mqttAuthUser -Platform $Platform -BaseDir $BaseDir)) {
    Write-Error "MQTT client credential '$mqttAuthUser' nicht in Vault gefunden ('$mqttAuthVaultPath') — wurde 10-mqtt-mosquitto oder 10-mqtt-emqx installiert?"
    exit 1
}

$authCsi = New-CsiSecretMount -AppName $Name -VaultPath $mqttAuthVaultPath -Keys @($mqttAuthUser) `
    -Namespace $Namespace -ServiceAccount $Name -Platform $Platform `
    -MountPath "/vault/mqtt-auth" -BaseDir $BaseDir
if (-not $authCsi.Installed) { Write-Error "Secrets backend not available for CSI mount"; exit 1 }

$authCsi.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply SecretProviderClass '$($authCsi.SpcName)'"; exit 1 }
Write-Host "  ✓ SecretProviderClass '$($authCsi.SpcName)' applied" -ForegroundColor Green

# ── 2. Init-script ConfigMap ──────────────────────────────────────────────────
# The initContainer runs this script on every pod start.
# Real settings key is "ConnectionManager_connections" (not "connections").
# Connections are stored as an object keyed by connection id.
# grep-check on our specific id: if missing → overwrite with our broker only
# (removes demo connections); if already present → preserve file untouched.
# Single-quoted PS here-string: $ belongs to the shell, not PowerShell.
# BROKER_HOST/BROKER_USERNAME are injected via env var from the initContainer
# spec below; the password is never an env var (would leak via `kubectl
# describe`) — it's read straight from the CSI-mounted file at runtime.
$initScript = @'
#!/bin/sh
SETTINGS="/app/data/settings.json"
CONN_KEY="mqtt-broker-shared-infra"
BROKER_PASSWORD=$(cat "$BROKER_PASSWORD_FILE")
CONN_JSON=$(printf '{"configVersion":1,"certValidation":true,"clientId":"mqtt-explorer-shared-infra","id":"%s","name":"MQTT Broker (shared-infra)","encryption":false,"subscriptions":[{"topic":"#","qos":0},{"topic":"$SYS/#","qos":0}],"type":"mqtt","host":"%s","port":1883,"protocol":"mqtt","username":"%s","password":"%s"}' \
  "$CONN_KEY" "$BROKER_HOST" "$BROKER_USERNAME" "$BROKER_PASSWORD")

if [ ! -f "$SETTINGS" ]; then
  # Fresh install: create file with our broker only
  printf '{"ConnectionManager_connections":{"%s":%s}}\n' "$CONN_KEY" "$CONN_JSON" > "$SETTINGS"
  echo "[init-settings] Created settings with pre-configured broker"
elif ! grep -q "\"$CONN_KEY\"" "$SETTINGS"; then
  # File exists (has other connections) but our broker is missing: inject it.
  # sed: insert our entry after the opening brace of ConnectionManager_connections.
  sed -i "s|\"ConnectionManager_connections\":{|\"ConnectionManager_connections\":{\"$CONN_KEY\":$CONN_JSON,|" "$SETTINGS"
  echo "[init-settings] Injected broker into existing settings"
else
  echo "[init-settings] Broker already present, preserving existing settings"
fi
'@
$initTmp = New-TemporaryFile
try {
    [System.IO.File]::WriteAllText($initTmp.FullName, $initScript.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    & kubectl create configmap "$Name-init-script" -n $Namespace `
        --from-file="init.sh=$($initTmp.FullName)" `
        --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
} finally {
    Remove-Item $initTmp.FullName -Force -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create init-script ConfigMap"; exit 1 }
Write-Host "  ✓ Init-script ConfigMap ready" -ForegroundColor Green

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
      securityContext:
        fsGroup: 1000
      initContainers:
        - name: init-settings
          image: busybox:1.36
          command: ["/bin/sh", "/init-scripts/init.sh"]
          env:
            - name: BROKER_HOST
              value: "$BrokerHost"
            - name: BROKER_USERNAME
              value: "$mqttAuthUser"
            - name: BROKER_PASSWORD_FILE
              value: "/vault/mqtt-auth/$mqttAuthUser"
          volumeMounts:
            - name: data
              mountPath: /app/data
            - name: init-script
              mountPath: /init-scripts
              readOnly: true
            - name: vault-mqtt-auth
              mountPath: /vault/mqtt-auth
              readOnly: true
      containers:
        - name: mqtt-explorer
          image: "$($FullConfig.Image):$($FullConfig.Version)"
          ports:
            - name: http
              containerPort: $($UserConfig.Port)
          env:
            - name: MQTT_EXPLORER_SKIP_AUTH
              value: "true"
          volumeMounts:
            - name: data
              mountPath: /app/data
          resources:
            limits:
              cpu: $($UserConfig.Resources.Limits.Cpu)
              memory: $($UserConfig.Resources.Limits.Memory)
            requests:
              cpu: $($UserConfig.Resources.Requests.Cpu)
              memory: $($UserConfig.Resources.Requests.Memory)
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: $Name
        - name: init-script
          configMap:
            name: $Name-init-script
            defaultMode: 0755
        - name: vault-mqtt-auth
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: $($authCsi.SpcName)
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

$ingressClass = Get-IngressClass

# Forward-auth via Authelia, same as Longhorn/Prometheus etc. in
# Kubernetes.BaseLine — MQTT Explorer has no native OIDC support (that's the
# Rancher-only path), so this is the only authentication. Authelia is
# mandatory cluster baseline, not optional — Protect-ComponentIngress is
# called unconditionally, no Test-AutheliaInstalled fallback gate.
$protect = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform
$authAnnotations = "`n" + (($protect.Annotations.GetEnumerator() | ForEach-Object { "    $($_.Key): `"$($_.Value)`"" }) -join "`n")

$issuerName = Get-ClusterIssuerName -Platform $Platform
$sslRedirect = if ($issuerName) { "true" } else { "false" }
$issuerAnnotationLine = if ($issuerName) { "`n    cert-manager.io/cluster-issuer: $issuerName" } else { "" }
$tlsSecretName = "$($Hostname -replace '\.', '-')-tls"
$tlsBlock = if ($issuerName) {
@"
  tls:
  - hosts:
    - $Hostname
    secretName: $tlsSecretName
"@
} else { "" }

$manifests += @"

---
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

$applyOutput = $manifests | & kubectl apply -f - 2>&1
if ($LASTEXITCODE -ne 0) {
    foreach ($line in $applyOutput) { Write-Host $line -ForegroundColor Red }
    Write-Error "Failed to deploy MQTT Explorer"; exit 1
}
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/$Name", "-n", $Namespace, "--timeout=3m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete"; exit 1 }
Write-Host "  ✓ Ready" -ForegroundColor Green

$scheme = if (Get-ClusterIssuerName -Platform $Platform) { "https" } else { "http" }
$portalIcon = Get-PortalIconDataUri -ScriptRoot $ScriptRoot -IconFile $FullConfig.PortalIcon
Register-PortalEntry -Name $FullConfig.PortalTitle -Url "${scheme}://$Hostname" `
    -Category "MQTT" -Subtitle $FullConfig.PortalSubtitle -Order 11 `
    -LogoUrl $portalIcon

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l "app.kubernetes.io/name=$Name"
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  URL:       ${scheme}://$Hostname" -ForegroundColor Yellow
Write-Host "  Broker credential pre-seeded into the saved connection (user: $mqttAuthUser)" -ForegroundColor Yellow
Write-Host "  Retrieve:  bao kv get $mqttAuthUser $mqttAuthVaultPath" -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
