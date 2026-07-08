<#
.SYNOPSIS
    Thin wrapper: re-exports the powershell-menu-ui sibling module's interactive
    console UI primitives, plus Infra-specific Vault/CSI secret handling and
    Config.psd1 loading that have no generic-library equivalent.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\..\powershell-menu-ui\PowerShellMenuUI.psd1") -Force -Verbose:$false

# Module-level base directory — one level up from _lib/.
# All functions use this as default so callers never need to pass -BaseDir or -Platform.
$script:InstallerBaseDir  = Split-Path $PSScriptRoot -Parent
$script:InstallerPlatform = ""   # every caller in this repo passes -Platform explicitly today

# -------------------------
# ClusterSecret — platform-agnostic dispatcher that writes secrets to the
# appropriate backend (OpenBao for RKE2/Kind, Azure Key Vault for AKS, etc.)
# and ensures a ClusterSecretStore named 'cluster-secrets' is the target.
# Returns $true on success, $false if no secrets backend is configured.
# -------------------------
function Write-ClusterSecret {
    param(
        [string]$Path,
        [hashtable]$Data,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Write-ClusterSecret: -Platform ist erforderlich."
            return $false
        }
    }

    $frames = @('|','/','-','\'); $fi = 0
    [Console]::Write("`r  $($frames[$fi++ % 4]) Schreibe Secret '$Path' in Vault...")

    $result = switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            Write-OpenBaoSecret -Path $Path -Data $Data -BaseDir $BaseDir -Platform $Platform
        }
        "Azure AKS" {
            Write-AzureKeyVaultSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        "AWS EKS" {
            Write-AwsSecretsManagerSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        "Google GKE" {
            Write-GcpSecretManagerSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        default { $false }
    }

    if ($result) {
        Write-Host ("`r  ✓ Secret '$Path' in Vault gespeichert" + (" " * 10)) -ForegroundColor Green
    } else {
        [Console]::Write("`r" + (" " * 60) + "`r")
    }
    return $result
}

# -------------------------
# OpenBao runs on both RKE2 and Kind, and installer scripts are routinely run
# against either from the same BaseDir checkout (e.g. testing on Kind, then
# deploying to RKE2) — a single shared ".openbao-state.json" would let
# whichever platform was last (re-)installed silently overwrite the other's
# root token, with no error until some later write fails with a confusing
# permission-denied. Ported from Kubernetes.BaseLine, where this exact
# collision broke a real RKE2 install after Kind-cluster testing from the
# same checkout. Every other platform already gets its own state file
# (.rke2-state.json, .kind-state.json, .aks-state.json, ...) — OpenBao's
# needs the same per-platform scoping.
# -------------------------
function Get-OpenBaoStateFile {
    param(
        [string]$BaseDir,
        [string]$Platform
    )
    $slug = switch ($Platform) {
        "RKE2 (On-Premise)" { "rke2" }
        "Kind (Local)"      { "kind" }
        default             { "unknown" }
    }
    return Join-Path $BaseDir ".openbao-state-$slug.json"
}

# -------------------------
# Which cert-manager ClusterIssuer to use for a component's Ingress TLS, per
# platform. RKE2 and Kind both run their own OpenBao with a PKI root CA (see
# OpenBao's Install.ps1 in Kubernetes.BaseLine), so both use the same issuer
# name — it's a different CA/ClusterIssuer instance per cluster, just the
# same mechanism. Empty string means "no issuer configured for this platform
# yet" — caller skips TLS (cloud platforms are not wired up yet).
# -------------------------
function Get-ClusterIssuerName {
    param([string]$Platform)
    switch ($Platform) {
        "RKE2 (On-Premise)" { return "openbao-pki" }
        "Kind (Local)"      { return "openbao-pki" }
        default             { return "" }
    }
}

# -------------------------
# New-PkiServerCert — issues a server certificate from OpenBao's PKI engine
# (the same 'ingress' role cert-manager uses via the openbao-pki ClusterIssuer)
# for a given hostname. Server-side TLS only — this is not a client cert /
# mTLS mechanism. Platform-gated: only RKE2/Kind run OpenBao's PKI engine
# today (see Get-ClusterIssuerName) — returns $null on any other platform,
# or if OpenBao/the role isn't reachable, so callers can fall back to "no
# TLS" cleanly instead of failing the whole install.
# Does NOT check Vault for an already-issued cert itself — callers should
# Read-ClusterSecret first and only call this when nothing's cached yet
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

# -------------------------
# OpenBao — writes key/value pairs to OpenBao KV-v2 at the given path.
# Returns $true on success, $false if OpenBao is not installed or not ready.
# Callers fall back to direct Helm --set when $false is returned.
# -------------------------
function Write-OpenBaoSecret {
    param(
        [string]$Path,
        [hashtable]$Data,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) { return $false }

    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) { return $false }

    # A single status read right after another component's Helm deploy can
    # transiently miss — retry briefly instead of failing the whole write on
    # what's usually just API-server/scheduler lag, confirmed live on RKE2.
    $podStatus = $null
    for ($i = 0; $i -lt 5; $i++) {
        $podStatus = & kubectl get pod openbao-0 -n openbao `
            --no-headers -o custom-columns="S:.status.phase" 2>$null
        if ($podStatus -eq "Running") { break }
        Start-Sleep -Seconds 2
    }
    if ($podStatus -ne "Running") {
        Write-Warning "Write-OpenBaoSecret('$Path'): openbao-0 pod status is '$podStatus', not Running"
        return $false
    }

    # Values go through a file + 'kubectl cp' + 'key=@file' rather than an inline
    # "key=value" shell string — needed once a value can contain newlines/quotes
    # (e.g. a PEM-encoded certificate/private key from New-PkiServerCert, or
    # Authelia's rendered multi-line config), and harmless for the simple
    # single-line passwords/tokens every other caller writes.
    $remoteDir = "/tmp/installer-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    & kubectl exec openbao-0 -n openbao -- mkdir -p $remoteDir 2>$null | Out-Null

    $kvArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Data.GetEnumerator()) {
        $tmpFile = New-TemporaryFile
        Set-Content -Path $tmpFile.FullName -Value $entry.Value -Encoding UTF8 -NoNewline
        $remoteFile = "$remoteDir/$($entry.Key -replace '[^\w.-]', '_')"
        # kubectl cp on Windows misparses an absolute "C:\..." local path as a
        # remote namespace:path spec (the drive letter looks like a colon
        # prefix) — cd into the temp file's folder and pass a relative name.
        Push-Location (Split-Path $tmpFile.FullName)
        & kubectl cp "./$(Split-Path $tmpFile.FullName -Leaf)" "openbao/openbao-0:$remoteFile" 2>$null | Out-Null
        Pop-Location
        Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
        $kvArgs.Add("$($entry.Key)=@$remoteFile") | Out-Null
    }

    $putOut = & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao kv put secret/$Path $($kvArgs -join ' ')" 2>&1
    $ok = $LASTEXITCODE -eq 0
    if (-not $ok) { Write-Warning "Write-OpenBaoSecret('$Path'): bao kv put failed — $putOut" }

    & kubectl exec openbao-0 -n openbao -- rm -rf $remoteDir 2>$null | Out-Null
    return $ok
}

# -------------------------
# Remove-ClusterSecret — platform-agnostic dispatcher that deletes an entire
# secret path from the backend (the delete-side counterpart to
# Write-ClusterSecret). Used by Uninstall.ps1 scripts so removing a component
# also removes the Vault-stored credentials it owns, not just its Kubernetes
# resources. Returns $true on success — including "there was nothing to
# delete", which is not a failure here.
# -------------------------
function Remove-ClusterSecret {
    param(
        [string]$Path,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) { return $false }
    }

    switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            return Remove-OpenBaoSecret -Path $Path -BaseDir $BaseDir -Platform $Platform
        }
        "Azure AKS" {
            return Remove-AzureKeyVaultSecret -Path $Path -BaseDir $BaseDir
        }
        "AWS EKS" {
            return Remove-AwsSecretsManagerSecret -Path $Path -BaseDir $BaseDir
        }
        "Google GKE" {
            return Remove-GcpSecretManagerSecret -Path $Path -BaseDir $BaseDir
        }
        default { return $false }
    }
}

# -------------------------
# OpenBao — deletes an entire KV-v2 path, including all versions/metadata
# (not a soft "kv delete", which only marks the latest version deleted but
# keeps it recoverable — full removal is the point here). Treats OpenBao
# being absent/unreachable as "nothing to clean up", not a failure.
# -------------------------
function Remove-OpenBaoSecret {
    param([string]$Path, [string]$BaseDir = $script:InstallerBaseDir, [string]$Platform = "")

    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) { return $true }

    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) { return $true }

    $podStatus = & kubectl get pod openbao-0 -n openbao `
        --no-headers -o custom-columns="S:.status.phase" 2>$null
    if ($podStatus -ne "Running") { return $true }

    & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao kv metadata delete secret/$Path" 2>$null | Out-Null

    return $true
}

# -------------------------
# ReadClusterSecret — platform-agnostic dispatcher that reads a single key's
# current value back out of the secrets backend (the read-side counterpart to
# Write-ClusterSecret). Used to check "does this credential already exist"
# before generating a new one, so re-running an installer step doesn't rotate
# a credential that's already in use. Returns $null if the path/key/backend
# isn't there — callers treat that as "needs generating", not an error.
# -------------------------
function Read-ClusterSecret {
    param(
        [string]$Path,
        [string]$Key,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) { return $null }
    }

    switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            return Read-OpenBaoSecret -Path $Path -Key $Key -BaseDir $BaseDir -Platform $Platform
        }
        "Azure AKS" {
            return Read-AzureKeyVaultSecret -Path $Path -Key $Key -BaseDir $BaseDir
        }
        "AWS EKS" {
            return Read-AwsSecretsManagerSecret -Path $Path -Key $Key -BaseDir $BaseDir
        }
        "Google GKE" {
            return Read-GcpSecretManagerSecret -Path $Path -Key $Key -BaseDir $BaseDir
        }
        default { return $null }
    }
}

# -------------------------
# OpenBao — reads a single field back out of a KV-v2 path. $null if the path,
# the field, or OpenBao itself isn't there yet (first install, not an error).
# -------------------------
function Read-OpenBaoSecret {
    param([string]$Path, [string]$Key, [string]$BaseDir = $script:InstallerBaseDir, [string]$Platform = "")

    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) { return $null }

    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) { return $null }

    $raw = & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao kv get -format=json secret/$Path 2>/dev/null" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }

    $jsonStart = ($raw -join "`n").IndexOf('{')
    if ($jsonStart -lt 0) { return $null }
    $parsed = ($raw -join "`n").Substring($jsonStart) | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $parsed -or -not $parsed.data -or -not $parsed.data.data) { return $null }

    $value = $parsed.data.data.$Key
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

# -------------------------
# Azure Key Vault — reads the "$Path-$Key" (or bare $Path for a single-key
# write) secret back. $null if it doesn't exist yet.
# -------------------------
function Read-AzureKeyVaultSecret {
    param([string]$Path, [string]$Key, [string]$BaseDir = $script:InstallerBaseDir)

    $stateFile = Join-Path $BaseDir ".aks-state.json"
    if (-not (Test-Path $stateFile)) { return $null }
    $vaultName = (Get-Content $stateFile | ConvertFrom-Json).VaultName
    if (-not $vaultName) { return $null }

    foreach ($secretName in @("$Path-$Key", $Path)) {
        $value = & az keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return $null
}

# -------------------------
# AWS Secrets Manager — reads the "$Path-$Key" (or bare $Path) secret back.
# $null if it doesn't exist yet.
# -------------------------
function Read-AwsSecretsManagerSecret {
    param([string]$Path, [string]$Key, [string]$BaseDir = $script:InstallerBaseDir)

    $stateFile = Join-Path $BaseDir ".eks-state.json"
    if (-not (Test-Path $stateFile)) { return $null }
    $region = (Get-Content $stateFile | ConvertFrom-Json).Region
    if (-not $region) { return $null }

    foreach ($secretName in @("$Path-$Key", $Path)) {
        $value = & aws secretsmanager get-secret-value --secret-id $secretName --region $region --query SecretString --output text 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return $null
}

# -------------------------
# GCP Secret Manager — reads the "$Path-$Key" (or bare $Path) secret's latest
# version back. $null if it doesn't exist yet.
# -------------------------
function Read-GcpSecretManagerSecret {
    param([string]$Path, [string]$Key, [string]$BaseDir = $script:InstallerBaseDir)

    $stateFile = Join-Path $BaseDir ".gke-state.json"
    if (-not (Test-Path $stateFile)) { return $null }
    $projectId = (Get-Content $stateFile | ConvertFrom-Json).ProjectId
    if (-not $projectId) { return $null }

    foreach ($secretName in @("$Path-$Key", $Path)) {
        $value = & gcloud secrets versions access latest --secret $secretName --project $projectId 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $null
}

# -------------------------
# New-CsiSecretMount — platform-agnostic helper that an app installer calls once.
# Handles:
#   - Workload Identity binding (AKS: Federated Credential, GKE: IAM, OpenBao: Vault role)
#   - SecretProviderClass YAML generation (platform-specific, internal)
#   - CSI Helm args (same for all platforms)
#
# Returns a hashtable:
#   Installed  = $true/$false (whether a secrets backend is configured)
#   SpcYaml    = string to pipe to 'kubectl apply -f -'
#   HelmArgs   = array to append to HelmArgs
#   SpcName    = name of the SecretProviderClass
#   MountPath  = mount path inside the pod
# -------------------------
function New-CsiSecretMount {
    param(
        [string]$AppName,
        [string]$VaultPath,
        [string[]]$Keys,
        [string]$Namespace,
        [string]$ServiceAccount,
        [string]$MountPath  = "/mnt/secrets",
        [string]$BaseDir    = $script:InstallerBaseDir,
        [string]$Platform   = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "New-CsiSecretMount: -Platform ist erforderlich."
            return @{ Installed = $false; SpcYaml = ""; HelmArgs = @(); SpcName = ""; MountPath = $MountPath }
        }
    }

    $notInstalled = @{ Installed = $false; SpcYaml = ""; HelmArgs = @(); SpcName = ""; MountPath = $MountPath }
    $spcName = "$AppName-vault"

    # ── Platform-specific auth setup + SPC YAML ──────────────────
    $spcYaml = switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            $baoStateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
            if (-not (Test-Path $baoStateFile)) { return $notInstalled }
            $baoState  = Get-Content $baoStateFile | ConvertFrom-Json
            $rootToken = $baoState.RootToken

            # Least privilege: a dedicated policy per app, scoped to that app's own
            # path only — never a shared policy that would let any app read every
            # other app's secrets just because it can authenticate at all.
            # Policy content goes through a file + kubectl cp, NOT a heredoc piped
            # through sh -c — a heredoc here is silently corrupted by Windows CRLF
            # line endings (the 'POLICY' terminator line gets a trailing \r, sh
            # never recognizes it as the end of input, and the literal word
            # "POLICY" ends up as bogus policy content) — same temp-file/kubectl-cp/
            # relative-path idiom already proven in Write-OpenBaoSecret.
            $policyName = "$AppName-readonly"
            $policyHcl  = @"
path "secret/data/$VaultPath" {
  capabilities = ["read","list"]
}
path "secret/metadata/$VaultPath" {
  capabilities = ["read","list"]
}
"@
            $policyTmpFile = New-TemporaryFile
            Set-Content -Path $policyTmpFile.FullName -Value $policyHcl -Encoding UTF8 -NoNewline
            $remotePolicyFile = "/tmp/$AppName-readonly-policy.hcl"
            Push-Location (Split-Path $policyTmpFile.FullName)
            & kubectl cp "./$(Split-Path $policyTmpFile.FullName -Leaf)" "openbao/openbao-0:$remotePolicyFile" 2>$null | Out-Null
            Pop-Location
            Remove-Item $policyTmpFile.FullName -Force -ErrorAction SilentlyContinue
            & kubectl exec openbao-0 -n openbao -- sh -c "BAO_TOKEN=$rootToken bao policy write $policyName $remotePolicyFile" 2>$null | Out-Null
            & kubectl exec openbao-0 -n openbao -- rm -f $remotePolicyFile 2>$null | Out-Null

            # Vault Kubernetes auth role — single line to avoid shell backtick/continuation issues
            $baoCmd = "BAO_TOKEN=$rootToken bao write auth/kubernetes/role/$AppName bound_service_account_names='$ServiceAccount' bound_service_account_namespaces='$Namespace' policies='$policyName' ttl='1h'"
            & kubectl exec openbao-0 -n openbao -- sh -c $baoCmd 2>$null | Out-Null

            $objects = ($Keys | ForEach-Object { @"
      - objectName: "$_"
        secretPath: "secret/data/$VaultPath"
        secretKey: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: vault
  parameters:
    vaultAddress: "http://openbao.openbao.svc.cluster.local:8200"
    roleName: "$AppName"
    objects: |
$objects
"@
        }

        "Azure AKS" {
            $aksState = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
            if (-not $aksState.VaultName) { return $notInstalled }
            $tenantId = & az account show --query tenantId --output tsv 2>$null
            if ($tenantId) { $tenantId = $tenantId.Trim() }

            # Federated Credential
            $fedName   = "$AppName-csi"
            $fedExists = & az identity federated-credential show `
                --name $fedName --identity-name $aksState.MiName `
                --resource-group $aksState.ResourceGroup 2>$null
            if (-not $fedExists) {
                & az identity federated-credential create `
                    --name $fedName `
                    --identity-name $aksState.MiName `
                    --resource-group $aksState.ResourceGroup `
                    --issuer $aksState.OidcIssuer `
                    --subject "system:serviceaccount:${Namespace}:${ServiceAccount}" `
                    --audience "api://AzureADTokenExchange" 2>$null | Out-Null
            }

            $objects = if ($Keys.Count -eq 1) {
@"
      array:
        - |
          objectName: $VaultPath
          objectType: secret
          objectAlias: $($Keys[0])
"@
            } else {
                ($Keys | ForEach-Object { @"
      array:
        - |
          objectName: $VaultPath-$_
          objectType: secret
          objectAlias: $_
"@ }) -join "`n"
            }
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "$($aksState.MiClientId)"
    keyvaultName: "$($aksState.VaultName)"
    tenantId: "$tenantId"
    objects: |
$objects
"@
        }

        "AWS EKS" {
            $eksState = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
            if (-not $eksState.CsiRoleArn) { return $notInstalled }

            # IRSA annotation — pod SA gets role via annotation, no per-app binding needed
            $objects = ($Keys | ForEach-Object { @"
      - objectName: "$_"
        objectType: "secretsmanager"
        objectAlias: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: aws
  parameters:
    objects: |
$objects
"@
        }

        "Google GKE" {
            $gkeState = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
            if (-not $gkeState.CsiGsaEmail) { return $notInstalled }

            # Workload Identity IAM binding
            & gcloud iam service-accounts add-iam-policy-binding $gkeState.CsiGsaEmail `
                --project $gkeState.ProjectId `
                --role "roles/iam.workloadIdentityUser" `
                --member "serviceAccount:$($gkeState.ProjectId).svc.id.goog[$Namespace/$ServiceAccount]" 2>$null | Out-Null

            $secrets = ($Keys | ForEach-Object { @"
      - resourceName: "projects/$($gkeState.ProjectId)/secrets/$VaultPath/versions/latest"
        fileName: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: gcp
  parameters:
    secrets: |
$secrets
"@
        }

        default { return $notInstalled }
    }

    # ── CSI Helm args — identical for all platforms ───────────────
    $helmArgs = @(
        "--set", "extraVolumes[0].name=vault-secrets",
        "--set", "extraVolumes[0].csi.driver=secrets-store.csi.k8s.io",
        "--set", "extraVolumes[0].csi.readOnly=true",
        "--set", "extraVolumes[0].csi.volumeAttributes.secretProviderClass=$spcName",
        "--set", "extraVolumeMounts[0].name=vault-secrets",
        "--set", "extraVolumeMounts[0].mountPath=$MountPath",
        "--set", "extraVolumeMounts[0].readOnly=true"
    )

    # Platform-specific pod identity labels/annotations
    if ($Platform -eq "Azure AKS") {
        $aksState = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        $helmArgs += "--set",        "serviceAccount.annotations.azure\.workload\.identity/client-id=$($aksState.MiClientId)"
        $helmArgs += "--set-string", "podLabels.azure\.workload\.identity/use=true"
    }
    if ($Platform -eq "AWS EKS") {
        $eksState = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        $helmArgs += "--set", "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$($eksState.CsiRoleArn)"
    }
    if ($Platform -eq "Google GKE") {
        $gkeState = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        $helmArgs += "--set", "serviceAccount.annotations.iam\.gke\.io/gcp-service-account=$($gkeState.CsiGsaEmail)"
    }

    return @{
        Installed = $true
        SpcYaml   = $spcYaml
        HelmArgs  = $helmArgs
        SpcName   = $spcName
        MountPath = $MountPath
    }
}

# Counterpart to New-CsiSecretMount — reverses everything it provisions on the
# auth side, plus the SecretProviderClass itself. Never touches the Vault
# secret/policy data (Remove-ClusterSecret is the caller's separate concern)
# and never deletes the shared 'csi-readonly' policy, since every CSI-mounted
# app in this cluster is bound to that same policy, not a per-app one.
function Remove-CsiSecretMount {
    param(
        [string]$AppName,
        [string]$Namespace,
        [string]$ServiceAccount,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Remove-CsiSecretMount: -Platform ist erforderlich."
            return $false
        }
    }

    $spcName = "$AppName-vault"

    switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            $baoStateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
            if (Test-Path $baoStateFile) {
                $rootToken = (Get-Content $baoStateFile | ConvertFrom-Json).RootToken
                if ($rootToken) {
                    & kubectl exec openbao-0 -n openbao -- `
                        sh -c "BAO_TOKEN=$rootToken bao delete auth/kubernetes/role/$AppName" 2>$null | Out-Null
                    & kubectl exec openbao-0 -n openbao -- `
                        sh -c "BAO_TOKEN=$rootToken bao policy delete $AppName-readonly" 2>$null | Out-Null
                }
            }
        }
        "Azure AKS" {
            $aksState = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
            if ($aksState.MiName) {
                & az identity federated-credential delete --name "$AppName-csi" `
                    --identity-name $aksState.MiName --resource-group $aksState.ResourceGroup --yes 2>$null | Out-Null
            }
        }
        "Google GKE" {
            $gkeState = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
            if ($gkeState.CsiGsaEmail) {
                & gcloud iam service-accounts remove-iam-policy-binding $gkeState.CsiGsaEmail `
                    --project $gkeState.ProjectId --role "roles/iam.workloadIdentityUser" `
                    --member "serviceAccount:$($gkeState.ProjectId).svc.id.goog[$Namespace/$ServiceAccount]" 2>$null | Out-Null
            }
        }
        # AWS EKS: IRSA is just a ServiceAccount annotation -- nothing else to revoke.
    }

    & kubectl delete secretproviderclass $spcName -n $Namespace --ignore-not-found 2>$null | Out-Null
    return $true
}

# -------------------------
# Register-PortalEntry — creates a ConfigMap in the 'portal' namespace labelled
# portal/entry=true. The Homer sidecar picks it up within 30 s and adds the
# entry to the dashboard. Safe to call whether or not Homer is installed — if
# the 'portal' namespace doesn't exist yet it is created on the fly (idempotent,
# same as Homer's own installer does). Logo is fetched automatically from the
# app's og:image / apple-touch-icon / favicon.ico, or from an explicit LogoUrl.
# -------------------------
function Register-PortalEntry {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Category,
        [string]$Subtitle = "",
        [int]   $Order    = 100,
        [string]$LogoUrl  = ""
    )
    & kubectl create namespace portal --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    $logoB64 = ""; $logoExt = "png"; $targetUrl = $LogoUrl
    if ([string]::IsNullOrWhiteSpace($targetUrl)) {
        try {
            $page = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8 -ErrorAction SilentlyContinue
            if ($page) {
                $ogImg = [regex]::Match($page.Content, '<meta[^>]+property="og:image"[^>]+content="([^"]+)"', 'IgnoreCase').Groups[1].Value
                if (-not $ogImg) {
                    $ogImg = [regex]::Match($page.Content, '<link[^>]+rel="apple-touch-icon[^"]*"[^>]+href="([^"]+)"', 'IgnoreCase').Groups[1].Value
                }
                if ($ogImg) { $targetUrl = $ogImg }
            }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($targetUrl)) {
            try {
                $u = [uri]$Url
                $targetUrl = "$($u.Scheme)://$($u.Host)/favicon.ico"
            } catch {}
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($targetUrl)) {
        try {
            $resp = Invoke-WebRequest -Uri $targetUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
            if ($resp -and $resp.Content) {
                $bytes = if ($resp.Content -is [byte[]]) { $resp.Content } else { [System.Text.Encoding]::UTF8.GetBytes($resp.Content) }
                $logoB64 = [Convert]::ToBase64String($bytes)
                $logoExt = if ($targetUrl -match '\.svg') { "svg" } elseif ($targetUrl -match '\.ico') { "ico" } elseif ($targetUrl -match '\.png') { "png" } else { "png" }
            }
        } catch {}
    }
    $slug = ($Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $cmYaml = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-entry-$slug
  namespace: portal
  labels:
    portal/entry: "true"
data:
  name: "$Name"
  subtitle: "$Subtitle"
  url: "$Url"
  category: "$Category"
  order: "$Order"
  logo.ext: "$logoExt"
"@
    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp.FullName -Value $cmYaml -Encoding UTF8
        & kubectl apply -f $tmp.FullName 2>&1 | Out-Null
    } finally {
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠ Portal: could not register entry for '$Name'" -ForegroundColor Yellow
        return
    }
    if ($logoB64) {
        $patchFile = New-TemporaryFile
        try {
            Set-Content -Path $patchFile.FullName -Value "{`"data`":{`"logo.b64`":`"$logoB64`"}}" -Encoding UTF8 -NoNewline
            & kubectl patch configmap "portal-entry-$slug" -n portal --type=merge --patch-file $patchFile.FullName 2>&1 | Out-Null
        } finally {
            Remove-Item $patchFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  ✓ Portal entry registered: $Name" -ForegroundColor Green
}

function Unregister-PortalEntry {
    param([Parameter(Mandatory)][string]$Name)
    $slug = ($Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    & kubectl delete configmap "portal-entry-$slug" -n portal --ignore-not-found 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Portal entry removed: $Name" -ForegroundColor Green
    }
}

# -------------------------
# Protect-ComponentIngress — forward-auth annotations for apps that don't
# speak OIDC themselves (the common case — Rancher-style direct OIDC needs
# the app to support it natively, ported separately if ever needed). nginx
# makes a subrequest to Authelia's verify endpoint for every request; a 401
# there redirects to Authelia's own login portal with the original URL
# preserved for redirect-after-login. Returns @{ Annotations = @{ ... } } to
# merge into the caller's own Ingress YAML metadata.annotations — same
# "pieces to merge" convention as New-CsiSecretMount.
# -------------------------
function Protect-ComponentIngress {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Protect-ComponentIngress: -Platform ist erforderlich."
            return @{ Annotations = @{} }
        }
    }

    $autheliaHost = & kubectl get ingress authelia -n authelia -o jsonpath='{.spec.rules[0].host}' 2>$null
    if (-not $autheliaHost) { $autheliaHost = "authelia.$($Hostname -replace '^[^.]+\.', '')" }
    return @{
        Annotations = @{
            "nginx.ingress.kubernetes.io/auth-url"              = "http://authelia.authelia.svc.cluster.local/api/verify"
            "nginx.ingress.kubernetes.io/auth-signin"           = "http://$autheliaHost/?rd=`$scheme://`$host`$request_uri"
            "nginx.ingress.kubernetes.io/auth-response-headers" = "Remote-User,Remote-Groups,Remote-Name,Remote-Email"
            # auth-snippet (X-Forwarded-Method) deliberately omitted — needs
            # allow-snippet-annotations enabled, which ingress-nginx disables
            # by default for good reason (arbitrary nginx config injection).
            # Not re-enabling that just for this one header.
        }
    }
}

# -------------------------
# Config loading with platform overrides
# -------------------------
function Merge-Config {
    param([hashtable]$Base, [hashtable]$Override)
    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-Config -Base $result[$key] -Override $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Get-ComponentConfig {
    param(
        [string]$ScriptRoot,
        [string]$Platform = "",
        [string]$ConfigPath = ""
    )
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        return Import-PowerShellDataFile -Path $ConfigPath
    }

    $config = Import-PowerShellDataFile -Path (Join-Path $ScriptRoot "Config.psd1")

    $platformShort = switch ($Platform) {
        "Azure AKS"         { "AzureAKS" }
        "AWS EKS"           { "AWSEKS" }
        "Google GKE"        { "GoogleGKE" }
        "RKE2 (On-Premise)" { "RKE2" }
        "Kind (Local)"      { "Kind" }
        default             { "" }
    }

    if ($platformShort) {
        $overridePath = Join-Path $ScriptRoot "Config.$platformShort.psd1"
        if (Test-Path $overridePath) {
            $override = Import-PowerShellDataFile -Path $overridePath
            $config = Merge-Config -Base $config -Override $override
        }
    }

    return $config
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
  # Infra-specific: Vault/CSI secrets + Config loading (no generic-library equivalent)
  'Write-ClusterSecret'
  'Get-OpenBaoStateFile'
  'Get-ClusterIssuerName'
  'New-PkiServerCert'
  'Write-OpenBaoSecret'
  'Read-ClusterSecret'
  'Read-OpenBaoSecret'
  'Read-AzureKeyVaultSecret'
  'Read-AwsSecretsManagerSecret'
  'Read-GcpSecretManagerSecret'
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
)
