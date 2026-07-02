<#
.SYNOPSIS
    Install EMQX (official chart, native clustering).
.PARAMETER Platform
    Target platform
.PARAMETER Namespace
    Shared-infra namespace
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER ExternalExposure
    $true = Service type LoadBalancer, $false = ClusterIP
.PARAMETER DashboardHostname
    Ingress hostname for the EMQX Dashboard — mandatory, since Authelia
    forward-auth (mandatory cluster baseline) is the dashboard's only
    authentication besides its own admin password and requires the Ingress
.PARAMETER DashboardPassword
    Dashboard admin password (collected/generated via Prompt.ps1)
.PARAMETER Domain
    Cluster base domain — used to derive the MQTT TLS certificate's hostname
    (mqtt.<Domain>) when OpenBao's PKI engine is available
.PARAMETER LoadBalancerIp
    Fixed IP from the MetalLB pool to assign to the broker's LoadBalancer
    Service (RKE2 only) — same mechanism the Ingress controller uses
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'DashboardPassword',
    Justification = 'Passed through to helm --set — SecureString would need converting back to plain text anyway.')]
param(
    [string]$ConfigPath,
    [string]$Platform,
    [Parameter(Mandatory)][string]$Namespace,
    [bool]$ExternalExposure = $false,
    [Parameter(Mandatory)][string]$DashboardHostname,
    [string]$DashboardPassword,
    [string]$Domain = "",
    [string]$LoadBalancerIp = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 10 - MQTT (EMQX)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$UserConfig = $FullConfig.UserConfig

Write-Host "  Chart:       $($FullConfig.ChartName) v$($FullConfig.Version)" -ForegroundColor Gray
Write-Host "  Namespace:   $Namespace" -ForegroundColor Gray
Write-Host "  Replicas:    $($UserConfig.ReplicaCount)" -ForegroundColor Gray
Write-Host "  Exposure:    $(if ($ExternalExposure) { 'LoadBalancer' } else { 'ClusterIP' })" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "emqx", $FullConfig.Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

# ── Server-side TLS (port 8883) via OpenBao's PKI engine, only where it's ──
# available (RKE2/Kind — see Get-ClusterIssuerName). Server-side only, not
# mTLS — same scope boundary as Kubernetes.BaseLine's own CERTIFICATES.md
# draws around client-cert enrollment (still an open problem there too).
# EMQX's own ServiceAccount is named after fullnameOverride directly (no
# "-emqx" suffix, unlike its Service — confirmed via 'helm template').
$tlsCsi = $null
$mqttHostname = if ($Domain) { "mqtt.$Domain" } else { "" }
if ($mqttHostname -and (Get-ClusterIssuerName -Platform $Platform)) {
    $tlsVaultPath = "$Namespace/emqx-tls"
    if (-not (Read-ClusterSecret -Path $tlsVaultPath -Key "certificate" -Platform $Platform -BaseDir $BaseDir)) {
        Write-Host "  Issuing TLS certificate for '$mqttHostname' from OpenBao PKI..." -ForegroundColor Gray
        $cert = New-PkiServerCert -CommonName $mqttHostname -Platform $Platform -BaseDir $BaseDir
        if ($cert) {
            $ok = Write-ClusterSecret -Path $tlsVaultPath -Data $cert -Platform $Platform -BaseDir $BaseDir
            if (-not $ok) { Write-Warning "  Failed to store TLS certificate in Vault — continuing without MQTT TLS" }
        } else {
            Write-Warning "  Could not issue TLS certificate from OpenBao PKI — continuing without MQTT TLS"
        }
    } else {
        Write-Host "  ✓ TLS certificate for '$mqttHostname' already in Vault — reusing" -ForegroundColor Green
    }

    if (Read-ClusterSecret -Path $tlsVaultPath -Key "certificate" -Platform $Platform -BaseDir $BaseDir) {
        $tlsCsi = New-CsiSecretMount -AppName "emqx-tls" -VaultPath $tlsVaultPath -Keys @("certificate", "private_key", "issuing_ca") `
            -Namespace $Namespace -ServiceAccount $FullConfig.Name -Platform $Platform -MountPath "/vault/tls" -BaseDir $BaseDir
        if ($tlsCsi.Installed) {
            $tlsCsi.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply SecretProviderClass '$($tlsCsi.SpcName)'"; exit 1 }
            Write-Host "  ✓ SecretProviderClass '$($tlsCsi.SpcName)' applied" -ForegroundColor Green
        } else {
            $tlsCsi = $null
        }
    }
}

# ── Fixed LoadBalancer IP via MetalLB, same mechanism the Ingress controller
# already uses (a dedicated single-IP pool, not a shared one — keeps the
# IP-to-service mapping deterministic instead of letting MetalLB pick from a
# multi-IP pool shared with something else).
$mqttPoolName = "mqtt-pool"
if ($ExternalExposure -and $LoadBalancerIp) {
    $poolYaml = @"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: $mqttPoolName
  namespace: metallb-system
spec:
  addresses:
  - $LoadBalancerIp/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: $mqttPoolName
  namespace: metallb-system
spec:
  ipAddressPools:
  - $mqttPoolName
"@
    $poolYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply MetalLB IPAddressPool '$mqttPoolName'"; exit 1 }
    Write-Host "  ✓ MetalLB pool '$mqttPoolName' ($LoadBalancerIp) applied" -ForegroundColor Green
}

Reset-StuckHelmRelease -ReleaseName $FullConfig.Name -Namespace $Namespace

$HelmArgs = @(
    "upgrade", "--install", $FullConfig.Name, "emqx/$($FullConfig.ChartName)",
    "--namespace", $Namespace,
    "--version", $FullConfig.Version,
    # Pin resource names to the generic release name explicitly — the chart's
    # own fullname template only does this automatically when the release name
    # contains "emqx", which "mqtt-broker" doesn't.
    "--set", "fullnameOverride=$($FullConfig.Name)",
    "--set", "replicaCount=$($UserConfig.ReplicaCount)",
    "--set", "persistence.enabled=true",
    "--set", "persistence.size=$($UserConfig.Persistence.Size)",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set", "service.type=$(if ($ExternalExposure) { 'LoadBalancer' } else { 'ClusterIP' })",
    "--set", "emqxConfig.EMQX_DASHBOARD__DEFAULT_USERNAME=admin",
    "--set", "emqxConfig.EMQX_DASHBOARD__DEFAULT_PASSWORD=$DashboardPassword"
)
if ($ExternalExposure -and $LoadBalancerIp) {
    $HelmArgs += @("--set", "service.annotations.metallb\.universe\.tf/address-pool=$mqttPoolName")
}
if ($tlsCsi) {
    # HOCON env-var override, same convention as EMQX_DASHBOARD__... above.
    # NOTE: not live-verified against a running EMQX instance (Mosquitto is
    # the currently-installed broker, RadioGroup-exclusive with EMQX) — these
    # are EMQX 5.x's documented listener config keys; double-check against
    # the deployed chart's appVersion if the SSL listener doesn't come up.
    $HelmArgs += @(
        "--set", "emqxConfig.EMQX_LISTENERS__SSL__DEFAULT__ENABLE=true",
        "--set", "emqxConfig.EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__CERTFILE=$($tlsCsi.MountPath)/certificate",
        "--set", "emqxConfig.EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__KEYFILE=$($tlsCsi.MountPath)/private_key",
        "--set", "emqxConfig.EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__CACERTFILE=$($tlsCsi.MountPath)/issuing_ca"
    ) + $tlsCsi.HelmArgs
}
$ingressClass = Get-IngressClass

# Forward-auth via Authelia, same as Longhorn/Prometheus etc. in
# Kubernetes.BaseLine — the EMQX OSS dashboard has no native OIDC support
# (that's the Rancher-only path), so this is on top of its own admin
# password. ingress.dashboard.annotations/.tls are free-form passthrough in
# the emqx/emqx chart (confirmed via 'helm show values emqx/emqx') —
# --set-json avoids hand-escaping the dotted/slashed annotation keys.
$issuerName = Get-ClusterIssuerName -Platform $Platform
$dashboardAnnotations = [ordered]@{
    "nginx.ingress.kubernetes.io/ssl-redirect" = if ($issuerName) { "true" } else { "false" }
}
if ($issuerName) { $dashboardAnnotations["cert-manager.io/cluster-issuer"] = $issuerName }
# Authelia is mandatory cluster baseline, not optional — Protect-ComponentIngress
# is called unconditionally, no Test-AutheliaInstalled fallback gate.
$protect = Protect-ComponentIngress -Hostname $DashboardHostname -Platform $Platform
foreach ($kv in $protect.Annotations.GetEnumerator()) { $dashboardAnnotations[$kv.Key] = $kv.Value }

$HelmArgs += @(
    "--set", "ingress.dashboard.enabled=true",
    "--set", "ingress.dashboard.ingressClassName=$ingressClass",
    "--set", "ingress.dashboard.hosts[0]=$DashboardHostname",
    "--set-json", "ingress.dashboard.annotations=$(ConvertTo-Json -Depth 5 -Compress $dashboardAnnotations)"
)
if ($issuerName) {
    $tlsSecretName = "$($DashboardHostname -replace '\.', '-')-tls"
    $tlsJson = ConvertTo-Json -Depth 5 -Compress @(@{ hosts = @($DashboardHostname); secretName = $tlsSecretName })
    $HelmArgs += @("--set-json", "ingress.dashboard.tls=$tlsJson")
}

$exitCode = Invoke-WithSpinner -Message "Deploying EMQX..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy EMQX (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "statefulset/$($FullConfig.Name)", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete"; exit 1 }
Write-Host "  ✓ Ready" -ForegroundColor Green

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l "app.kubernetes.io/instance=$($FullConfig.Name)"
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  MQTT (cluster-internal):  $($FullConfig.Name).$Namespace.svc.cluster.local:1883" -ForegroundColor Yellow
if ($tlsCsi) {
    Write-Host "  TLS (cluster-internal):   $($FullConfig.Name).$Namespace.svc.cluster.local:8883  ($mqttHostname)" -ForegroundColor Yellow
}
if ($ExternalExposure) {
    if ($LoadBalancerIp) {
        Write-Host "  External IP:              $LoadBalancerIp" -ForegroundColor Yellow
    } else {
        Write-Host "  External IP:              kubectl get svc $($FullConfig.Name) -n $Namespace" -ForegroundColor Yellow
    }
}
$scheme = if (Get-ClusterIssuerName -Platform $Platform) { "https" } else { "http" }
Write-Host "  Dashboard:                ${scheme}://$DashboardHostname" -ForegroundColor Yellow
Write-Host "  Dashboard login:          admin / $DashboardPassword" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
