<#
.SYNOPSIS
    Collect Redis Insight settings upfront.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain passed in from Install-Infra.ps1
.PARAMETER Namespace
    Shared-infra namespace (unused — Redis connection details are fixed by convention)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain    = "kubernetes.local",
    [string]$Namespace
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$defaultHostname = "redis-insight.$Domain"

$hostname = Read-Plain `
    -Prompt "Redis Insight hostname" `
    -Default $defaultHostname `
    -ContextTitle "21 - Redis Insight" `
    -ContextHint "DNS name under which Redis Insight will be reachable" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Domain = $Domain })

return @{
    Hostname = $hostname.Trim()
}
