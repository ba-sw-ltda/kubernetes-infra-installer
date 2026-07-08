<#
.SYNOPSIS
    Collect MQTT Explorer inputs upfront.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Base domain for the optional Ingress hostname
.PARAMETER Namespace
    Shared-infra namespace
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "",
    [Parameter(Mandatory)][string]$Namespace
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# No broker host/port prompt — both 10-mqtt-mosquitto and 10-mqtt-emqx always
# publish under the fixed Service name "mqtt-broker" on the standard MQTT
# port 1883 (deliberate convention, see those components' own Install.ps1),
# so this is never something the end user needs to know or choose. Install.ps1
# derives it itself from -Namespace, no live cluster check needed here.

# No admin login prompt either — Authelia forward-auth on the Ingress is the
# only authentication now (see Install.ps1); the app's own native login was
# removed as a redundant second login layer.

# Hostname is mandatory, not optional — there's no longer any fallback
# (no-Ingress/port-forward) path, since that would mean zero authentication
# now that the app's own login is gone. Authelia is mandatory cluster
# baseline, so every install must go through the Ingress.
$defaultHostname = if ($Domain) { "mqtt-explorer.$Domain" } else { "" }
$hostname = Read-Plain -Prompt "Hostname fuer MQTT Explorer" -Default $defaultHostname `
    -ContextTitle "MQTT Explorer" -ContextCurrent ([ordered]@{ Platform = $Platform })
if ([string]::IsNullOrWhiteSpace($hostname)) { Write-Host "  Hostname ist erforderlich (Authelia-Schutz setzt einen Ingress voraus)." -ForegroundColor Red; exit 1 }

return @{
    Hostname = $hostname.Trim()
}
