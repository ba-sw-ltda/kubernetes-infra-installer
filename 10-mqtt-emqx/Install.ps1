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

# Namespace (idempotent — safe even when shared with sibling components)
& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject

# ── RadioGroup sibling swap: EMQX and Mosquitto share the Helm release name
# "$($FullConfig.Name)" (one chart can occupy it at a time), so switching
# brokers means the previous one must be fully uninstalled first. Checked
# silently — only surfaces output if a swap is actually needed.
$siblingExpectedChart = "mosquitto-ha"
$releaseJson    = & helm get metadata $FullConfig.Name --namespace $Namespace --output json 2>$null
$releaseObj     = if ($releaseJson) { try { $releaseJson | ConvertFrom-Json } catch { $null } } else { $null }
$installedChart = if ($releaseObj) { $releaseObj.chart } else { $null }
if ($installedChart -eq $siblingExpectedChart) {
    $siblingUninstall = Join-Path $BaseDir "10-mqtt-mosquitto\Uninstall.ps1"
    $exitCode = Invoke-ScriptBlockWithSpinner -Message "Removing previous MQTT broker (Mosquitto)..." -ScriptBlock {
        param($path, $kubeconfig, $script, $platform, $namespace)
        $env:PATH = $path
        if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
        & $script -Platform $platform -Namespace $namespace *>&1 | Out-Null
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE }
    } -ArgumentList @($env:PATH, $env:KUBECONFIG, $siblingUninstall, $Platform, $Namespace) | Select-Object -Last 1 -ExpandProperty ExitCode
    if ($exitCode -ne 0) { Write-Error "Failed to remove previous MQTT broker (Mosquitto)"; exit 1 }
    Write-Host "  ✓ Previous MQTT broker (Mosquitto) removed" -ForegroundColor Green
}

# ── MQTT client authentication (username/password) — same Vault path shared
# with Mosquitto ("$Namespace/mqtt-client-auth"), so switching brokers via the
# RadioGroup swap above reuses the same "explorer" credential instead of
# minting a new one. EMQX additionally needs a bootstrap CSV for its
# built_in_database authenticator (see HelmArgs below, plain hash — no bcrypt
# tooling available in PowerShell, same simplification as Mosquitto's
# plaintext password file). Both keys are written together since 'bao kv put'
# replaces the entire secret rather than merging — read both first so an
# existing password (set by Mosquitto) isn't rotated just to add the CSV.
$mqttAuthVaultPath = "$Namespace/mqtt-client-auth"
$mqttAuthUser = "explorer"
$authCsi = $null
$existingMqttAuth         = Get-ClusterSecret -Path $mqttAuthVaultPath -Keys @("explorer", "bootstrap.csv") -Platform $Platform -BaseDir $BaseDir
$existingMqttAuthPassword = $existingMqttAuth["explorer"]
$existingBootstrapCsv     = $existingMqttAuth["bootstrap.csv"]
if (-not $existingMqttAuthPassword -or -not $existingBootstrapCsv) {
    Write-Host "  · Preparing MQTT client credential for '$mqttAuthUser'..." -ForegroundColor DarkGray
    $mqttAuthPassword = if ($existingMqttAuthPassword) { $existingMqttAuthPassword } else {
        -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    }
    $bootstrapCsv = "user_id,password`n$mqttAuthUser,$mqttAuthPassword`n"
    $ok = Write-ClusterSecret -Path $mqttAuthVaultPath -Data @{ explorer = $mqttAuthPassword; "bootstrap.csv" = $bootstrapCsv } -Platform $Platform -BaseDir $BaseDir
    if (-not $ok) { Write-Error "Failed to store MQTT client credential in Vault"; exit 1 }
    Write-Host "  ✓ MQTT client credential ready in Vault" -ForegroundColor Green
} else {
    Write-Host "  ✓ MQTT client credential already in Vault — reusing" -ForegroundColor Green
}

$authCsi = New-CsiSecretMount -AppName "emqx-mqtt-auth" -VaultPath $mqttAuthVaultPath -Keys @("explorer", "bootstrap.csv") `
    -Namespace $Namespace -ServiceAccount $FullConfig.Name -Platform $Platform -MountPath "/vault/mqtt-auth" -BaseDir $BaseDir
if ($authCsi.Installed) {
    $authCsi.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply SecretProviderClass '$($authCsi.SpcName)'"; exit 1 }
    Write-Host "  ✓ SecretProviderClass '$($authCsi.SpcName)' applied" -ForegroundColor Green
} else {
    $authCsi = $null
}

# ── ACL override — EMQX ships with a default file-based authorizer
# (etc/acl.conf) that denies subscription to "$SYS/#", "#" and "+/#" for
# everyone except the "dashboard" user and localhost. That's invisible to
# normal pub/sub (a trailing {allow, all} catch-all lets everything else
# through), but it silently hides every broker system topic from Explorer —
# unlike Mosquitto, which has no ACL configured in this repo at all. Mounted
# at the same default path so it replaces the shipped file outright; the
# only change from EMQX's own default is inserting an explicit allow for the
# "explorer" user ahead of the deny rule.
$aclConfigMapName = "$($FullConfig.Name)-acl"
$aclConfLines = @(
    '{allow, {user, "dashboard"}, subscribe, ["$SYS/#"]}.'
    ('{{allow, {{user, "{0}"}}, subscribe, ["$SYS/#"]}}.' -f $mqttAuthUser)
    '{allow, {ipaddr, "127.0.0.1"}, all}.'
    '{deny, all, subscribe, ["$SYS/#", {eq, "#"}, {eq, "+/#"}]}.'
    '{allow, all}.'
)
$aclConfigMap = [ordered]@{
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = @{ name = $aclConfigMapName; namespace = $Namespace }
    data       = @{ "acl.conf" = ($aclConfLines -join "`n") }
}
(ConvertTo-Json -Depth 5 -Compress $aclConfigMap) | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply ACL ConfigMap '$aclConfigMapName'"; exit 1 }
Write-Host "  ✓ ACL ConfigMap '$aclConfigMapName' applied (grants '$mqttAuthUser' access to `$SYS topics)" -ForegroundColor Green

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
    $existingTls = Get-ClusterSecret -Path $tlsVaultPath -Keys @("certificate") -Platform $Platform -BaseDir $BaseDir
    if (-not $existingTls["certificate"]) {
        Write-Host "  · Issuing TLS certificate for '$mqttHostname' from OpenBao PKI..." -ForegroundColor DarkGray
        $cert = New-PkiServerCert -CommonName $mqttHostname -Platform $Platform -BaseDir $BaseDir
        if ($cert) {
            $ok = Write-ClusterSecret -Path $tlsVaultPath -Data $cert -Platform $Platform -BaseDir $BaseDir
            if (-not $ok) { Write-Warning "  Failed to store TLS certificate in Vault — continuing without MQTT TLS" }
            else { $existingTls = $cert }
        } else {
            Write-Warning "  Could not issue TLS certificate from OpenBao PKI — continuing without MQTT TLS"
        }
    } else {
        Write-Host "  ✓ TLS certificate for '$mqttHostname' already in Vault — reusing" -ForegroundColor Green
    }

    if ($existingTls["certificate"]) {
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

# ── Dashboard admin password — generate-once-and-reuse, same convention as
# the MQTT client credential and Redis ACL passwords above. Required because
# EMQX only applies EMQX_DASHBOARD__DEFAULT_PASSWORD when the dashboard's
# admin record is created on a fresh data volume (see the chart's own
# desc.en.hocon: "changing the default password after it has been
# initialized has no effect") — on every reinstall after the first, the
# persisted PVC already has an admin record, so a freshly-prompted/generated
# password here would be silently ignored by EMQX while still being the one
# displayed to the user. Reusing the Vault-stored value keeps what's shown
# in sync with what's actually live.
$dashboardAuthVaultPath = "$Namespace/emqx-dashboard-auth"
$existingDashboardPassword = (Get-ClusterSecret -Path $dashboardAuthVaultPath -Keys @("admin") -Platform $Platform -BaseDir $BaseDir)["admin"]
if ($existingDashboardPassword) {
    $DashboardPassword = $existingDashboardPassword
} else {
    $ok = Write-ClusterSecret -Path $dashboardAuthVaultPath -Data @{ admin = $DashboardPassword } -Platform $Platform -BaseDir $BaseDir
    if (-not $ok) { Write-Error "Failed to store EMQX dashboard password in Vault"; exit 1 }
}

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
    "--set", "emqxConfig.EMQX_DASHBOARD__DEFAULT_PASSWORD=$DashboardPassword",
    # Explicit file authorizer pointed at the mounted acl.conf (see the ACL
    # ConfigMap above) rather than relying on the image's own undocumented
    # default source/path — same file the chart's default ships at, just
    # with the "explorer" allow rule added ahead of the $SYS deny.
    "--set", "emqxConfig.EMQX_AUTHORIZATION__SOURCES__1__TYPE=file",
    "--set", "emqxConfig.EMQX_AUTHORIZATION__SOURCES__1__ENABLE=true",
    "--set", "emqxConfig.EMQX_AUTHORIZATION__SOURCES__1__PATH=/opt/emqx/etc/acl.conf",
    "--set", "emqxConfig.EMQX_AUTHORIZATION__NO_MATCH=allow"
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
    )
}
if ($authCsi) {
    # Explorer username/password authentication via EMQX's built_in_database
    # backend, seeded once from the CSI/Vault-mounted bootstrap CSV (see the
    # credential block above). "plain" hashing mirrors Mosquitto's own
    # simplification — no bcrypt tooling available in PowerShell to pre-hash
    # the password ourselves.
    $HelmArgs += @(
        "--set", "emqxConfig.EMQX_AUTHENTICATION__1__BACKEND=built_in_database",
        "--set", "emqxConfig.EMQX_AUTHENTICATION__1__MECHANISM=password_based",
        "--set", "emqxConfig.EMQX_AUTHENTICATION__1__ENABLE=true",
        "--set", "emqxConfig.EMQX_AUTHENTICATION__1__USER_ID_TYPE=username",
        "--set", "emqxConfig.EMQX_AUTHENTICATION__1__BOOTSTRAP_FILE=$($authCsi.MountPath)/bootstrap.csv",
        "--set", "emqxConfig.EMQX_AUTHENTICATION__1__BOOTSTRAP_TYPE=plain",
        "--set", "emqxConfig.EMQX_AUTHENTICATION__1__PASSWORD_HASH_ALGORITHM__NAME=plain",
        "--set", "emqxConfig.EMQX_AUTHENTICATION__1__PASSWORD_HASH_ALGORITHM__SALT_POSITION=disable"
    )
}
# ── Vehicle mTLS listener — scaffolding only, disabled until vehicle PKI
# issuance/enrollment is decided (same scope boundary as Mosquitto's own
# mtls block in _charts/mosquitto-ha/values.yaml — no cert/key/cacert paths
# set here, nothing to mount yet). Kept on its own port/listener so it can
# evolve independently of the Explorer's username/password listener above;
# peer_cert_as_username is set globally since it's inert without a client-
# presented certificate, and only this listener will enforce verify_peer +
# fail_if_no_peer_cert.
$HelmArgs += @(
    "--set", "emqxConfig.EMQX_LISTENERS__SSL__VEHICLE_MTLS__ENABLE=false",
    "--set", "emqxConfig.EMQX_LISTENERS__SSL__VEHICLE_MTLS__BIND=0.0.0.0:8884",
    "--set", "emqxConfig.EMQX_LISTENERS__SSL__VEHICLE_MTLS__SSL_OPTIONS__VERIFY=verify_peer",
    "--set", "emqxConfig.EMQX_LISTENERS__SSL__VEHICLE_MTLS__SSL_OPTIONS__FAIL_IF_NO_PEER_CERT=true",
    "--set", "emqxConfig.EMQX_MQTT__PEER_CERT_AS_USERNAME=cn"
)
# Manual multi-volume construction (same pattern as
# 10-mqtt-mosquitto/Install.ps1) — New-CsiSecretMount's own .HelmArgs always
# target extraVolumes[0]/extraVolumeMounts[0], so with more than one extra
# mount (ACL + auth + tls) they'd collide at the same index if any of them
# used their raw .HelmArgs directly. The ACL ConfigMap mount is unconditional
# — it's the fix for the default $SYS ACL deny above and applies regardless
# of whether Vault-backed auth/TLS ended up configured this run.
$extraVolumes = [System.Collections.Generic.List[hashtable]]::new()
$extraVolumeMounts = [System.Collections.Generic.List[hashtable]]::new()
$extraVolumes.Add(@{ name = "emqx-acl"; configMap = @{ name = $aclConfigMapName } }) | Out-Null
$extraVolumeMounts.Add(@{ name = "emqx-acl"; mountPath = "/opt/emqx/etc/acl.conf"; subPath = "acl.conf"; readOnly = $true }) | Out-Null
if ($authCsi) {
    $extraVolumes.Add(@{ name = "vault-mqtt-auth"; csi = @{ driver = "secrets-store.csi.k8s.io"; readOnly = $true; volumeAttributes = @{ secretProviderClass = $authCsi.SpcName } } }) | Out-Null
    $extraVolumeMounts.Add(@{ name = "vault-mqtt-auth"; mountPath = $authCsi.MountPath; readOnly = $true }) | Out-Null
}
if ($tlsCsi) {
    $extraVolumes.Add(@{ name = "vault-tls"; csi = @{ driver = "secrets-store.csi.k8s.io"; readOnly = $true; volumeAttributes = @{ secretProviderClass = $tlsCsi.SpcName } } }) | Out-Null
    $extraVolumeMounts.Add(@{ name = "vault-tls"; mountPath = $tlsCsi.MountPath; readOnly = $true }) | Out-Null
}
$HelmArgs += @(
    "--set-json", "extraVolumes=$(ConvertTo-Json -Depth 10 -Compress @($extraVolumes))",
    "--set-json", "extraVolumeMounts=$(ConvertTo-Json -Depth 10 -Compress @($extraVolumeMounts))"
)
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
if ($authCsi) {
    Write-Host "  Explorer username:        $mqttAuthUser" -ForegroundColor Yellow
    Write-Host "  Explorer password:        bao kv get -mount=secret $mqttAuthVaultPath" -ForegroundColor Yellow
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
