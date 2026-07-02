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

# persistence.enabled creates a PVC via the StatefulSet's volumeClaimTemplates
# — helm uninstall never removes those, only the StatefulSet itself. Matched
# by label rather than a guessed name so it still works regardless of
# replica count.
& kubectl delete pvc -n $Namespace -l "app.kubernetes.io/instance=$($Config.Name)" --ignore-not-found 2>&1 | Out-Null

exit 0
