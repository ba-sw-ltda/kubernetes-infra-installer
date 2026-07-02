<#
.SYNOPSIS
    Collect EMQX inputs upfront.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Base domain for the optional Dashboard Ingress hostname
.PARAMETER Namespace
    Shared-infra namespace
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "",
    [string]$Namespace = "shared-infra"
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$externalExposure = Read-YesNo `
    -Title "MQTT-Broker extern erreichbar machen (LoadBalancer)?" -DefaultYes $false `
    -YesLabel "Ja - Service-Typ LoadBalancer (benoetigt MetalLB auf RKE2/Kind)" `
    -NoLabel  "Nein - nur cluster-intern (ClusterIP)" `
    -ContextTitle "EMQX" -ContextCurrent ([ordered]@{ Platform = $Platform })

# Fixe IP aus dem MetalLB-Pool, genau wie beim Ingress-Controller — nur RKE2
# braucht das (Kind kommt ohne eigenen MetalLB-Pool aus, siehe Baseline's
# 12-metallb/Prompt.ps1, gleiches Muster).
$loadBalancerIp = ""
if ($externalExposure -and $Platform -eq "RKE2 (On-Premise)") {
    $loadBalancerIp = Read-Plain `
        -Prompt "MQTT LoadBalancer IP" -Default "10.200.89.11" `
        -ContextTitle "EMQX" -ContextHint "Fixe IP aus dem MetalLB-Pool fuer den externen MQTT-Zugriff"
}

# Mandatory, not optional — there's no port-forward fallback anymore.
# Authelia forward-auth is mandatory cluster baseline and requires the
# Ingress, same reasoning as 11-mqtt-explorer's Hostname.
$defaultHostname = if ($Domain) { "emqx-dashboard.$Domain" } else { "" }
$dashboardHostname = Read-Plain -Prompt "Hostname fuer EMQX Dashboard" -Default $defaultHostname `
    -ContextTitle "EMQX" -ContextCurrent ([ordered]@{ Platform = $Platform })
if ([string]::IsNullOrWhiteSpace($dashboardHostname)) { Write-Host "  Hostname ist erforderlich (Authelia-Schutz setzt einen Ingress voraus)." -ForegroundColor Red; exit 1 }

$dashboardPassword = Read-SecretPlain -Prompt "EMQX Dashboard Passwort (leer = zufaellig generiert)" `
    -ContextTitle "EMQX" -ContextCurrent ([ordered]@{ Platform = $Platform })
if ([string]::IsNullOrWhiteSpace($dashboardPassword)) {
    $dashboardPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    Write-Host "  ✓ Zufaelliges Dashboard-Passwort generiert (wird nach der Installation angezeigt)" -ForegroundColor Green
}

return @{
    ExternalExposure   = $externalExposure
    DashboardHostname  = $dashboardHostname.Trim()
    DashboardPassword  = $dashboardPassword
    Domain             = $Domain
    LoadBalancerIp     = $loadBalancerIp.Trim()
}
