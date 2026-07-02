<#
.SYNOPSIS
    Collect Mosquitto-HA inputs upfront.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Used to derive the TLS certificate's hostname (mqtt.<Domain>) when OpenBao's
    PKI engine is available — no Ingress involved (MQTT is plain TCP, not HTTP).
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

# Redis itself isn't asked about here — RequiresComponents=@("20-redis") in
# Config.psd1 force-selects it, and Install-Infra.ps1's dependency ordering
# guarantees it's already up by the time this component's Install.ps1 runs, so
# host/port/password are resolved live there instead of guessed at here.
$externalExposure = Read-YesNo `
    -Title "MQTT-Broker extern erreichbar machen (LoadBalancer)?" -DefaultYes $false `
    -YesLabel "Ja - Service-Typ LoadBalancer (benoetigt MetalLB auf RKE2/Kind)" `
    -NoLabel  "Nein - nur cluster-intern (ClusterIP)" `
    -ContextTitle "Mosquitto HA"

# Fixe IP aus dem MetalLB-Pool, genau wie beim Ingress-Controller — nur RKE2
# braucht das (Kind kommt ohne eigenen MetalLB-Pool aus, siehe Baseline's
# 12-metallb/Prompt.ps1, gleiches Muster).
$loadBalancerIp = ""
if ($externalExposure -and $Platform -eq "RKE2 (On-Premise)") {
    $loadBalancerIp = Read-Plain `
        -Prompt "MQTT LoadBalancer IP" -Default "10.200.89.11" `
        -ContextTitle "Mosquitto HA" -ContextHint "Fixe IP aus dem MetalLB-Pool fuer den externen MQTT-Zugriff"
}

return @{
    ExternalExposure = $externalExposure
    Domain           = $Domain
    LoadBalancerIp   = $loadBalancerIp.Trim()
}
