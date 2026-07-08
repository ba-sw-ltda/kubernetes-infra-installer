<#
.SYNOPSIS
    Uninstall Redis.
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

# Remove dependent components first (Redis Insight reads Redis credentials from Vault)
$dependentScript = Join-Path $BaseDir "21-redis-insight\Uninstall.ps1"
if (Test-Path $dependentScript) {
    & $dependentScript -Platform $Platform -Namespace $Namespace
}

Write-Host "  Removing Redis..." -ForegroundColor Cyan
& helm uninstall $Config.Name --namespace $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Helm release '$($Config.Name)' removed" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Release '$($Config.Name)' not found (already removed?)" -ForegroundColor Yellow
}

# Reverses New-CsiSecretMount's auth-side setup plus its SecretProviderClass
# — both applied outside the Helm release, so helm uninstall never touches
# them. AppName is "redis" (matches Install.ps1's New-CsiSecretMount call,
# not necessarily $Config.Name), ServiceAccount is the Bitnami chart's own
# "$Name-master" SA (confirmed via 'kubectl get sa', not $Config.Name either).
Remove-CsiSecretMount -AppName "redis" -Namespace $Namespace -ServiceAccount "$($Config.Name)-master" -Platform $Platform -BaseDir $BaseDir | Out-Null

# master.persistence creates a PVC via the StatefulSet's volumeClaimTemplates
# — helm uninstall never removes those, only the StatefulSet itself. Matched
# by label rather than a guessed name (e.g. "redis-data-redis-master-0") so
# it still works regardless of replica count or architecture.
& kubectl delete pvc -n $Namespace -l "app.kubernetes.io/instance=$($Config.Name)" --ignore-not-found 2>&1 | Out-Null

# This is the only component that writes to this Vault path (others only
# read the "mosquitto" key from it) — removing Redis removes its credentials.
$vaultPath = "$Namespace/redis-acl-users"
if (Remove-ClusterSecret -Path $vaultPath -Platform $Platform -BaseDir $BaseDir) {
    Write-Host "  ✓ Vault credentials at '$vaultPath' removed" -ForegroundColor Green
} else {
    Write-Warning "  ⚠ Could not remove Vault credentials at '$vaultPath'"
}

# Rancher project assignment: only unlink once nothing else is running in
# this (possibly shared) namespace — checked live against the cluster so
# this is correct however this script is invoked (standalone, as a
# dependent, or alongside/without sibling components in the same run).
$remainingWorkloads = & kubectl get deployments,statefulsets,daemonsets -n $Namespace --no-headers 2>$null
if (-not $remainingWorkloads) {
    Remove-RancherProjectAssignment -Namespace $Namespace -ProjectName $Config.RancherProject
}

exit 0
