<#
.SYNOPSIS
    Build and deploy the custom Mosquitto-HA image + _charts/mosquitto-ha chart.
.DESCRIPTION
    Unlike every other component in this installer, this one builds a custom
    container image first (no public chart provides active/passive/passive
    Mosquitto HA — see README.md for the design) and makes it pullable by the
    target cluster before installing the chart.
.PARAMETER Platform
    Target platform
.PARAMETER Namespace
    Shared-infra namespace
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER ExternalExposure
    $true = Service type LoadBalancer, $false = ClusterIP
.PARAMETER Domain
    Cluster base domain — used to derive the TLS certificate's hostname
    (mqtt.<Domain>) when OpenBao's PKI engine is available
.PARAMETER LoadBalancerIp
    Fixed IP from the MetalLB pool to assign to the broker's LoadBalancer
    Service (RKE2 only) — same mechanism the Ingress controller uses
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Platform,
    [Parameter(Mandatory)][string]$Namespace,
    [bool]$ExternalExposure = $false,
    [string]$Domain = "",
    [string]$LoadBalancerIp = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 10 - MQTT (Mosquitto HA)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$UserConfig = $FullConfig.UserConfig
$ChartPath  = Join-Path $BaseDir $FullConfig.ChartPath

# RequiresComponents=@("20-redis") in Config.psd1 force-selects Redis and
# Install-Infra.ps1's dependency ordering installs it before this script ever
# runs, so its host is resolved live here rather than asked for. The password
# is never read into this script at all — it's mounted straight from Vault
# into this chart's own pod via CSI (New-CsiSecretMount below), the same Vault
# path 20-redis provisioned its "mosquitto" ACL user into. No Kubernetes
# Secret exists for it at any point — see the "Redis ACL credentials" design
# notes (NIS2/CRA — no long-lived Secret copy of these credentials in etcd).
$redisConfig = Import-PowerShellDataFile -Path (Join-Path $BaseDir "20-redis\Config.psd1")
$redisName   = $redisConfig.Name
$RedisHost   = "$redisName-master.$Namespace.svc.cluster.local"
$RedisPort   = "6379"
$redisAclUser = "mosquitto"
$vaultPath    = "$Namespace/redis-acl-users"

Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Redis:      ${RedisHost}:${RedisPort}" -ForegroundColor Gray
Write-Host "  Exposure:   $(if ($ExternalExposure) { 'LoadBalancer' } else { 'ClusterIP' })" -ForegroundColor Gray
Write-Host ""

& kubectl get svc "$redisName-master" -n $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Redis Service '$redisName-master' nicht gefunden in Namespace '$Namespace' — wurde 20-redis installiert?"; exit 1 }

if (-not (Read-ClusterSecret -Path $vaultPath -Key $redisAclUser -Platform $Platform -BaseDir $BaseDir)) {
    Write-Error "Redis ACL user '$redisAclUser' nicht in Vault gefunden ('$vaultPath') — wurde 20-redis installiert?"
    exit 1
}

$csi = New-CsiSecretMount -AppName "mosquitto" -VaultPath $vaultPath -Keys @($redisAclUser) `
    -Namespace $Namespace -ServiceAccount $FullConfig.Name -Platform $Platform `
    -MountPath "/vault/secrets" -BaseDir $BaseDir
if (-not $csi.Installed) { Write-Error "Secrets backend not available for CSI mount"; exit 1 }

$csi.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply SecretProviderClass '$($csi.SpcName)'"; exit 1 }
Write-Host "  ✓ SecretProviderClass '$($csi.SpcName)' applied" -ForegroundColor Green

# ── Server-side TLS (port 8883) via OpenBao's PKI engine, only where it's ──
# available (RKE2/Kind — see Get-ClusterIssuerName). Server-side only, not
# mTLS — same scope boundary as Kubernetes.BaseLine's own CERTIFICATES.md
# draws around client-cert enrollment (still an open problem there too).
$tlsCsi = $null
$mqttHostname = if ($Domain) { "mqtt.$Domain" } else { "" }
if ($mqttHostname -and (Get-ClusterIssuerName -Platform $Platform)) {
    $tlsVaultPath = "$Namespace/mosquitto-tls"
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
        $tlsCsi = New-CsiSecretMount -AppName "mosquitto-tls" -VaultPath $tlsVaultPath -Keys @("certificate", "private_key", "issuing_ca") `
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

# Built manually rather than splatting $csi.HelmArgs/$tlsCsi.HelmArgs verbatim
# — New-CsiSecretMount's returned HelmArgs always target index [0]
# (extraVolumes[0]/extraVolumeMounts[0]), assuming a chart mounts exactly one
# CSI secret. With two (Redis password + TLS cert), the second --set would
# silently overwrite the first at the same index instead of adding to it.
$extraVolumes = [System.Collections.Generic.List[hashtable]]::new()
$extraVolumeMounts = [System.Collections.Generic.List[hashtable]]::new()
$extraVolumes.Add(@{ name = "vault-secrets"; csi = @{ driver = "secrets-store.csi.k8s.io"; readOnly = $true; volumeAttributes = @{ secretProviderClass = $csi.SpcName } } }) | Out-Null
$extraVolumeMounts.Add(@{ name = "vault-secrets"; mountPath = $csi.MountPath; readOnly = $true }) | Out-Null
if ($tlsCsi) {
    $extraVolumes.Add(@{ name = "vault-tls"; csi = @{ driver = "secrets-store.csi.k8s.io"; readOnly = $true; volumeAttributes = @{ secretProviderClass = $tlsCsi.SpcName } } }) | Out-Null
    $extraVolumeMounts.Add(@{ name = "vault-tls"; mountPath = $tlsCsi.MountPath; readOnly = $true }) | Out-Null
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

# ── 1. Build the custom image ────────────────────────────────────────────
$imageName = "mosquitto-ha"
$imageTag  = "latest"
$localRef  = "${imageName}:${imageTag}"
$imageDir  = Join-Path $ScriptRoot "image"

$exitCode = Invoke-WithSpinner -Message "Building image '$localRef'..." -Executable "docker" `
    -Arguments @("build", "-t", $localRef, $imageDir) -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "docker build failed"; exit 1 }
Write-Host "  ✓ Image built" -ForegroundColor Green

# ── 2. Make it pullable by the target cluster ────────────────────────────
# Tracked as separate repo/tag throughout (not re-split from a combined
# "repo:tag" string) since a registry host can itself contain a colon
# (e.g. "myregistry:5000"), which would break a naive split.
# Pushed tag is deliberately not "latest" — registries can enforce a
# semver2-only tag policy (e.g. ProGet feeds configured that way reject
# "latest" outright). The local build/Kind-load tag above is unaffected.
$imageRepo    = $imageName
$imageTagOnly = "1.0.0"

if ($Platform -eq "Kind (Local)") {
    $kindState = Get-Content (Join-Path $BaseDir ".kind-state.json") | ConvertFrom-Json
    & kind load docker-image $localRef --name $kindState.ClusterName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "kind load docker-image failed"; exit 1 }
    Write-Host "  ✓ Image loaded into Kind cluster '$($kindState.ClusterName)'" -ForegroundColor Green
} elseif (-not [string]::IsNullOrWhiteSpace($UserConfig.ImageRegistry)) {
    $imageRepo = "$($UserConfig.ImageRegistry)/$imageName"
    $pushRef   = "${imageRepo}:${imageTagOnly}"
    & docker tag $localRef $pushRef 2>&1 | Out-Null
    & docker push $pushRef 2>&1 | ForEach-Object { if ($verbose) { Write-Host "    $_" -ForegroundColor DarkGray } }
    if ($LASTEXITCODE -ne 0) { Write-Error "docker push to '$($UserConfig.ImageRegistry)' failed — run 'docker login' first?"; exit 1 }
    Write-Host "  ✓ Image pushed to $pushRef" -ForegroundColor Green
} else {
    Write-Error "UserConfig.ImageRegistry is not set in Config.psd1 — required on every platform except Kind so the cluster can pull the custom image. Set it (or a Config.$($Platform)-specific override) and re-run."
    exit 1
}

# ── 3. Deploy the chart ──────────────────────────────────────────────────
Reset-StuckHelmRelease -ReleaseName $FullConfig.Name -Namespace $Namespace

$HelmArgs = @(
    "upgrade", "--install", $FullConfig.Name, $ChartPath,
    "--namespace", $Namespace,
    "--set", "replicaCount=$($UserConfig.ReplicaCount)",
    "--set", "image.repository=$imageRepo",
    "--set", "image.tag=$imageTagOnly",
    "--set", "redis.host=$RedisHost",
    "--set", "redis.port=$RedisPort",
    "--set", "redis.username=$redisAclUser",
    "--set", "redis.passwordFile=$($csi.MountPath)/$redisAclUser",
    "--set", "service.type=$(if ($ExternalExposure) { 'LoadBalancer' } else { 'ClusterIP' })",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set-json", "extraVolumes=$(ConvertTo-Json -Depth 10 -Compress @($extraVolumes))",
    "--set-json", "extraVolumeMounts=$(ConvertTo-Json -Depth 10 -Compress @($extraVolumeMounts))"
)
if ($ExternalExposure -and $LoadBalancerIp) {
    $HelmArgs += @("--set", "service.annotations.metallb\.universe\.tf/address-pool=$mqttPoolName")
}
if ($tlsCsi) {
    $HelmArgs += @(
        "--set", "tls.enabled=true",
        "--set", "tls.certFile=$($tlsCsi.MountPath)/certificate",
        "--set", "tls.keyFile=$($tlsCsi.MountPath)/private_key",
        "--set", "tls.caFile=$($tlsCsi.MountPath)/issuing_ca"
    )
}

$exitCode = Invoke-WithSpinner -Message "Deploying Mosquitto HA..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Mosquitto HA (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for pods..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "statefulset/$($FullConfig.Name)", "-n", $Namespace, "--timeout=3m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete"; exit 1 }

# "Pods Running" doesn't mean the HA logic actually worked (a pod stuck waiting
# on an unreachable Redis still shows as Running) — explicitly wait for exactly
# one pod to self-label active, the real signal that leader-election succeeded.
$active = Invoke-ScriptBlockWithSpinner -Message "Waiting for a leader to emerge..." -ScriptBlock {
    param($path, $kubeconfig, $namespace, $name)
    $env:PATH = $path
    if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
    $elapsed = 0
    while ($elapsed -lt 60) {
        $found = & kubectl get pods -n $namespace -l "app.kubernetes.io/name=$name,mqtt-role=active" -o jsonpath='{.items[0].metadata.name}' 2>$null
        if ($found) { return $found }
        Start-Sleep -Seconds 3; $elapsed += 3
    }
} -ArgumentList @($env:PATH, $env:KUBECONFIG, $Namespace, $FullConfig.Name)
if (-not $active) {
    Write-Error "No pod became active within 60s — check Redis connectivity (${RedisHost}:${RedisPort}) and 'kubectl logs -n $Namespace -l app.kubernetes.io/name=$($FullConfig.Name)'"
    exit 1
}
Write-Host "  ✓ '$active' is active" -ForegroundColor Green

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l "app.kubernetes.io/name=$($FullConfig.Name)" --show-labels
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Host (cluster-internal):  $($FullConfig.Name).$Namespace.svc.cluster.local:1883" -ForegroundColor Yellow
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
Write-Host "  Current leader:           kubectl get pods -n $Namespace -l mqtt-role=active" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
