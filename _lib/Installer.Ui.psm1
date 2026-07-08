<#
.SYNOPSIS
    Thin wrapper: re-exports the powershell-menu-ui sibling module's interactive
    console UI primitives and the powershell-cluster-bootstrap sibling module's
    Vault/CSI secret handling, portal registration, and Config.psd1 loading,
    plus Infra-specific PKI cert issuance that has no generic-library equivalent.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\..\powershell-menu-ui\PowerShellMenuUI.psd1") -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot "..\..\powershell-cluster-bootstrap\PowerShellClusterBootstrap.psd1") -Force -Verbose:$false

# Module-level base directory — one level up from _lib/.
# New-PkiServerCert (Infra-only, kept local) defaults its -BaseDir/-Platform to this.
$script:InstallerBaseDir  = Split-Path $PSScriptRoot -Parent
$script:InstallerPlatform = ""   # every caller in this repo passes -Platform explicitly today

# -------------------------
# New-PkiServerCert — issues a server certificate from OpenBao's PKI engine
# (the same 'ingress' role cert-manager uses via the openbao-pki ClusterIssuer)
# for a given hostname. Server-side TLS only — this is not a client cert /
# mTLS mechanism. Platform-gated: only RKE2/Kind run OpenBao's PKI engine
# today (see Get-ClusterIssuerName) — returns $null on any other platform,
# or if OpenBao/the role isn't reachable, so callers can fall back to "no
# TLS" cleanly instead of failing the whole install.
# Does NOT check Vault for an already-issued cert itself — callers should
# Get-ClusterSecret first and only call this when nothing's cached yet
# (generate-once-and-reuse, same convention as every other credential in
# this installer). Renewal before the cert's TTL expires is not handled here
# — a known, deferred follow-up, same as Kubernetes.BaseLine's own
# CERTIFICATES.md flags for client-cert enrollment.
# -------------------------
function New-PkiServerCert {
    param(
        [Parameter(Mandatory)][string]$CommonName,
        [string]$Role     = "ingress",
        [string]$Ttl      = "720h",
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    if ($Platform -notin @("RKE2 (On-Premise)", "Kind (Local)")) { return $null }

    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) { return $null }
    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) { return $null }

    $raw = & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao write -format=json pki/issue/$Role common_name=$CommonName ttl=$Ttl" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }

    $parsed = ($raw -join "`n") | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $parsed -or -not $parsed.data -or -not $parsed.data.certificate) { return $null }

    return @{
        certificate = $parsed.data.certificate
        private_key = $parsed.data.private_key
        issuing_ca  = $parsed.data.issuing_ca
    }
}

Export-ModuleMember -Function @(
  # Re-exported from powershell-menu-ui
  'ToSafeName'
  'Write-Context'
  'Write-Section'
  'ConvertTo-UiOptions'
  'Read-SelectIndex'
  'Read-SelectValue'
  'Read-YesNo'
  'Confirm-RetryOrExit'
  'Read-MultiSelectValues'
  'Read-ComponentSelectionScreen'
  'Read-Plain'
  'Read-SecretPlain'
  'Read-SecretPlainConfirm'
  'Invoke-WithSpinner'
  'Invoke-ScriptBlockWithSpinner'
  'Invoke-DownloadWithSpinner'
  # Re-exported from powershell-cluster-bootstrap: Vault/CSI secrets, portal, config loading
  'Write-ClusterSecret'
  'Get-ClusterSecret'
  'Get-OpenBaoStateFile'
  'Get-OpenBaoSecret'
  'Get-ClusterIssuerName'
  'Write-OpenBaoSecret'
  'Remove-ClusterSecret'
  'Remove-OpenBaoSecret'
  'New-CsiSecretMount'
  'Remove-CsiSecretMount'
  'Protect-ComponentIngress'
  'Register-PortalEntry'
  'Get-PortalIconDataUri'
  'Unregister-PortalEntry'
  'Merge-Config'
  'Get-ComponentConfig'
  # Infra-specific: PKI server cert issuance (no generic-library equivalent)
  'New-PkiServerCert'
)
