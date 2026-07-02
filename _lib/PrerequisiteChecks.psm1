<#
.SYNOPSIS
    Live-cluster checks for prerequisites that infra components may depend on.
    Unlike the baseline installer's local state files, these check the cluster
    itself — this installer may run on a different machine than the one
    that set up the cluster, so local state can't be trusted.
#>

function Test-IngressPresent {
    $names = & kubectl get ingressclass -o name 2>$null
    return ($LASTEXITCODE -eq 0) -and ($null -ne $names) -and (@($names).Count -gt 0)
}

function Test-CertManagerPresent {
    & kubectl get crd certificates.cert-manager.io 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-SecretsBackendPresent {
    # 'cluster-secrets' is the fixed ClusterSecretStore name Write-ClusterSecret
    # (Installer.Ui.psm1) targets — a single platform-agnostic check covers
    # OpenBao, Azure Key Vault, AWS Secrets Manager and GCP Secret Manager alike.
    & kubectl get clustersecretstore cluster-secrets 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-DefaultStorageClassPresent {
    $default = & kubectl get storageclass `
        -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' `
        2>$null
    return -not [string]::IsNullOrWhiteSpace($default)
}

# -------------------------
# Test-ClusterPrerequisites — runs all known checks once, returns a hashtable
# keyed by the same prereq names components declare in Config.psd1's
# RequiredPrereqs (e.g. @("ingress", "cert-manager")).
# -------------------------
function Test-ClusterPrerequisites {
    return @{
        "ingress"         = Test-IngressPresent
        "cert-manager"    = Test-CertManagerPresent
        "secrets-backend" = Test-SecretsBackendPresent
        "storage"         = Test-DefaultStorageClassPresent
    }
}

# -------------------------
# Get-MissingPrerequisites — cross-checks a component's RequiredPrereqs
# against the detected set. Returns an empty array when nothing is missing
# or the component declared no requirements.
# -------------------------
function Get-MissingPrerequisites {
    param(
        [string[]]$RequiredPrereqs = @(),
        [hashtable]$Detected
    )
    # A component with no RequiredPrereqs key at all in Config.psd1 binds $null
    # here (explicit $null overrides the default), and $null | Where-Object still
    # runs once with $_ = $null, so $Detected[$null] throws — guard explicitly.
    if (-not $RequiredPrereqs) { return @() }
    return @($RequiredPrereqs | Where-Object { -not $Detected[$_] })
}

Export-ModuleMember -Function Test-IngressPresent, Test-CertManagerPresent, Test-SecretsBackendPresent, Test-DefaultStorageClassPresent, Test-ClusterPrerequisites, Get-MissingPrerequisites
