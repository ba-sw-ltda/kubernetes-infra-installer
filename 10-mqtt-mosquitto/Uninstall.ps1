<#
.SYNOPSIS
    Uninstall Mosquitto HA.
.PARAMETER Platform
    Target platform
.PARAMETER Namespace
    Shared-infra namespace
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [Parameter(Mandatory)][string]$Namespace
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$Config = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot "Config.psd1")

# Guard: only skip if a *different* chart is installed under the shared
# release name (EMQX won the RadioGroup selection instead). If no release
# exists at all (already removed, or never installed), fall through and run
# the idempotent cleanup below anyway — CSI/Vault residue can outlive the
# Helm release and still needs to be reversed.
$expectedChart  = Split-Path $Config.ChartPath -Leaf   # "mosquitto-ha"
$releaseJson    = & helm get metadata $Config.Name --namespace $Namespace --output json 2>$null
$releaseObj     = if ($releaseJson) { try { $releaseJson | ConvertFrom-Json } catch { $null } } else { $null }
$installedChart = if ($releaseObj) { $releaseObj.chart } else { $null }
if ($installedChart -and $installedChart -ne $expectedChart) {
    Write-Host "  ⚠ Release '$($Config.Name)' has chart '$installedChart' (expected '$expectedChart') — skipping" -ForegroundColor Yellow
    exit 0
}

# Remove dependent components first (MQTT Explorer connects to this broker)
$dependentScript = Join-Path $BaseDir "11-mqtt-explorer\Uninstall.ps1"
if (Test-Path $dependentScript) {
    & $dependentScript -Platform $Platform -Namespace $Namespace
}

Write-Host "  Removing Mosquitto HA..." -ForegroundColor Cyan
& helm uninstall $Config.Name --namespace $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Helm release '$($Config.Name)' removed" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Release '$($Config.Name)' not found (already removed?)" -ForegroundColor Yellow
}

# Reverses New-CsiSecretMount's auth-side setup (AppName "mosquitto", not
# $Config.Name) plus its SecretProviderClass — both applied outside the Helm
# release, so helm uninstall never touches them. Vault data itself belongs to
# 20-redis (it only reads the "mosquitto" key from Redis's own path) — not
# removed here, that's Redis's Uninstall.ps1's responsibility.
Remove-CsiSecretMount -AppName "mosquitto" -Namespace $Namespace -ServiceAccount $Config.Name -Platform $Platform -BaseDir $BaseDir | Out-Null

# Separate TLS CSI mount (AppName "mosquitto-tls") and its own Vault-stored
# server cert — unlike the redis-acl-users path above, this Vault data is
# owned solely by this component, so it's removed here rather than by 20-redis.
Remove-CsiSecretMount -AppName "mosquitto-tls" -Namespace $Namespace -ServiceAccount $Config.Name -Platform $Platform -BaseDir $BaseDir | Out-Null
Remove-ClusterSecret -Path "$Namespace/mosquitto-tls" -Platform $Platform -BaseDir $BaseDir | Out-Null

# The chart has no persistent volumes today, but matches the other
# components' cleanup defensively in case that ever changes.
& kubectl delete pvc -n $Namespace -l "app.kubernetes.io/instance=$($Config.Name)" --ignore-not-found 2>&1 | Out-Null

# Rancher project assignment: only unlink once nothing else is running in
# this (possibly shared) namespace — checked live against the cluster so
# this is correct however this script is invoked (standalone, as a
# dependent, or alongside/without sibling components in the same run).
$remainingWorkloads = & kubectl get deployments,statefulsets,daemonsets -n $Namespace --no-headers 2>$null
if (-not $remainingWorkloads) {
    Remove-RancherProjectAssignment -Namespace $Namespace -ProjectName $Config.RancherProject
}

exit 0
