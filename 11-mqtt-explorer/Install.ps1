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

Write-Host "  Image:      $($FullConfig.Image):$($FullConfig.Version)" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Broker:     ${BrokerHost}:${BrokerPort}" -ForegroundColor Gray
Write-Host ""

$manifests = @"
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
      containers:
        - name: mqtt-explorer
          image: "$($FullConfig.Image):$($FullConfig.Version)"
          ports:
            - name: http
              containerPort: $($UserConfig.Port)
          env:
            - name: MQTT_EXPLORER_DEFAULT_BROKER_HOST
              value: "$BrokerHost"
            - name: MQTT_EXPLORER_DEFAULT_BROKER_PORT
              value: "$BrokerPort"
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
Register-PortalEntry -Name "MQTT Explorer" -Url "${scheme}://$Hostname" `
    -Category "MQTT" -Subtitle "MQTT broker web UI" -Order 11

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l "app.kubernetes.io/name=$Name"
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  URL:       ${scheme}://$Hostname" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
