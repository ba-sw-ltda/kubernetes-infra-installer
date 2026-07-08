<#
.SYNOPSIS
    Uninstall EMQX.
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
# release name (Mosquitto won the RadioGroup selection instead). If no release
# exists at all (already removed, or never installed), fall through and run
# the idempotent cleanup below anyway — CSI/Vault residue can outlive the
# Helm release and still needs to be reversed.
$expectedChart  = $Config.ChartName   # "emqx"
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

Write-Host "  Removing EMQX..." -ForegroundColor Cyan
& helm uninstall $Config.Name --namespace $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Helm release '$($Config.Name)' removed" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Release '$($Config.Name)' not found (already removed?)" -ForegroundColor Yellow
}

# Reverses New-CsiSecretMount's auth-side setup for the TLS CSI mount (AppName
# "emqx-tls") plus its SecretProviderClass — applied outside the Helm release,
# so helm uninstall never touches them. Also removes the Vault-stored server
# cert itself, which is owned solely by this component.
Remove-CsiSecretMount -AppName "emqx-tls" -Namespace $Namespace -ServiceAccount $Config.Name -Platform $Platform -BaseDir $BaseDir | Out-Null
Remove-ClusterSecret -Path "$Namespace/emqx-tls" -Platform $Platform -BaseDir $BaseDir | Out-Null

# persistence.enabled creates a PVC via the StatefulSet's volumeClaimTemplates
# — helm uninstall never removes those, only the StatefulSet itself. Matched
# by label rather than a guessed name so it still works regardless of
# replica count.
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
