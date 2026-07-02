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

# The chart has no persistent volumes today, but matches the other
# components' cleanup defensively in case that ever changes.
& kubectl delete pvc -n $Namespace -l "app.kubernetes.io/instance=$($Config.Name)" --ignore-not-found 2>&1 | Out-Null

exit 0
