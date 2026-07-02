<#
.SYNOPSIS
    Uninstall Redis Insight. Removes all raw manifests, the CSI SecretProviderClass,
    and the Vault policy/role created during install. Does NOT touch the Redis
    ACL credentials in Vault (those belong to 20-redis).
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
$Name   = $Config.Name

Write-Host "  Removing Redis Insight..." -ForegroundColor Cyan

& kubectl delete deployment/$Name service/$Name persistentvolumeclaim/$Name `
    ingress/$Name serviceaccount/$Name configmap/$Name-sidecar-script `
    -n $Namespace --ignore-not-found 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Redis Insight resources removed" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Some resources may not have existed (already removed?)" -ForegroundColor Yellow
}

Remove-CsiSecretMount -AppName $Name -Namespace $Namespace -ServiceAccount $Name -Platform $Platform -BaseDir $BaseDir

Unregister-PortalEntry -Name "Redis Insight"

exit 0
