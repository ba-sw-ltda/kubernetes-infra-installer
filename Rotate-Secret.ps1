<#
.SYNOPSIS
    Rotate a secret in the cluster vault backend — platform-agnostic.
    Reads the current keys from OpenBao / Azure Key Vault / AWS Secrets Manager / GCP Secret Manager,
    accepts new values, writes them to the backend, forces ESO to resync, and optionally
    restarts affected workloads.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Platform selection ────────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json")) { $platforms += @{ Label = "RKE2 (On-Premise)"; Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json")) { $platforms += @{ Label = "Kind (Local)";       Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))  { $platforms += @{ Label = "Azure AKS";          Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))  { $platforms += @{ Label = "AWS EKS";            Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))  { $platforms += @{ Label = "Google GKE";         Value = "Google GKE" } }

if ($platforms.Count -eq 0) {
    Write-Host "`n  No installed cluster state files found. Run Install-Base.ps1 first." -ForegroundColor Red
    exit 1
}

$platform = if ($platforms.Count -eq 1) { $platforms[0].Value } else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 2. Secret path ───────────────────────────────────────────────
$secretPath = Read-Plain `
    -Prompt "Secret path in vault" `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Same path used during installation, e.g.  infrastructure/database-credentials" `
    -ContextCurrent ([ordered]@{ Platform = $platform })

if ([string]::IsNullOrWhiteSpace($secretPath)) {
    Write-Host "  Cancelled." -ForegroundColor Yellow; exit 0
}
$secretPath = $secretPath.Trim()

# ── 3. Read current keys from vault (best-effort) ────────────────
Write-Host ""
Write-Host "  Reading current secret keys..." -ForegroundColor DarkGray

$currentKeys = @()
switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        $stateFile = Join-Path $BaseDir ".openbao-state.json"
        if (Test-Path $stateFile) {
            $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
            $raw = & kubectl exec openbao-0 -n openbao -- `
                sh -c "BAO_TOKEN=$rootToken bao kv get -format=json secret/$secretPath 2>/dev/null" 2>$null
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $jsonStart = ($raw -join "`n").IndexOf('{')
                if ($jsonStart -ge 0) {
                    $parsed = ($raw -join "`n").Substring($jsonStart) | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($parsed -and $parsed.data -and $parsed.data.data) {
                        $currentKeys = @($parsed.data.data.PSObject.Properties.Name)
                    }
                }
            }
        }
    }
    "Azure AKS" {
        $stateFile = Join-Path $BaseDir ".aks-state.json"
        if (Test-Path $stateFile) {
            $vaultName = (Get-Content $stateFile | ConvertFrom-Json).VaultName
            if ($vaultName) {
                $prefix = $secretPath -replace '/', '-'
                $list = & az keyvault secret list --vault-name $vaultName `
                    --query "[?starts_with(name, '$prefix')].name" -o tsv 2>$null
                if ($list) {
                    $currentKeys = @($list -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) |
                        ForEach-Object { ($_ -replace "^$prefix-?", '') } | Where-Object { $_ }
                    if ($currentKeys.Count -eq 0) { $currentKeys = @($prefix) }
                }
            }
        }
    }
    "AWS EKS" {
        $stateFile = Join-Path $BaseDir ".eks-state.json"
        if (Test-Path $stateFile) {
            $region = (Get-Content $stateFile | ConvertFrom-Json).Region
            if ($region) {
                $prefix = $secretPath -replace '/', '-'
                $list = & aws secretsmanager list-secrets --region $region `
                    --query "SecretList[?starts_with(Name, '$prefix')].Name" --output text 2>$null
                if ($list) {
                    $currentKeys = @($list -split '\s+' | Where-Object { $_ }) |
                        ForEach-Object { ($_ -replace "^$prefix-?", '') } | Where-Object { $_ }
                    if ($currentKeys.Count -eq 0) { $currentKeys = @($prefix) }
                }
            }
        }
    }
    "Google GKE" {
        $stateFile = Join-Path $BaseDir ".gke-state.json"
        if (Test-Path $stateFile) {
            $projectId = (Get-Content $stateFile | ConvertFrom-Json).ProjectId
            if ($projectId) {
                $filter = $secretPath -replace '/', '-'
                $list = & gcloud secrets list --project $projectId `
                    --filter="name~^$filter" --format="value(name)" 2>$null
                if ($list) {
                    $currentKeys = @($list -split "`n" | Where-Object { $_ }) |
                        ForEach-Object { ($_ -replace "^$filter-?", '') } | Where-Object { $_ }
                    if ($currentKeys.Count -eq 0) { $currentKeys = @($filter) }
                }
            }
        }
    }
}

if ($currentKeys.Count -gt 0) {
    Write-Host "  Current keys: $($currentKeys -join ', ')" -ForegroundColor DarkGray
} else {
    Write-Host "  (Could not read keys — path may not exist yet or vault is unavailable)" -ForegroundColor DarkGray
}

# ── 4. Collect new values ────────────────────────────────────────
Write-Host ""
$newData = [ordered]@{}

if ($currentKeys.Count -gt 0) {
    Write-Host "  Enter new value for each key (press Enter to skip / keep existing):" -ForegroundColor White
    Write-Host ""
    foreach ($key in $currentKeys) {
        $val = Read-SecretPlain `
            -Prompt $key `
            -ContextTitle "Secret Rotation — $secretPath" `
            -ContextHint "Press Enter to keep the current value"
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $newData[$key] = $val
        }
    }
} else {
    Write-Host "  Enter key=value pairs (one per line, empty line to finish):" -ForegroundColor White
    Write-Host ""
    $lineNum = 1
    while ($true) {
        $entry = Read-Plain `
            -Prompt "Entry $lineNum  (key=value, or empty to finish)" `
            -ContextTitle "Secret Rotation — $secretPath"
        if ([string]::IsNullOrWhiteSpace($entry)) { break }
        $parts = $entry -split '=', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            Write-Host "  Expected format: key=value" -ForegroundColor Yellow; continue
        }
        $newData[$parts[0].Trim()] = $parts[1]
        $lineNum++
    }
}

if ($newData.Count -eq 0) {
    Write-Host ""
    Write-Host "  No new values entered — nothing to update." -ForegroundColor Yellow
    exit 0
}

# ── 5. Write to vault ────────────────────────────────────────────
Write-Host ""
$ok = Write-ClusterSecret -Path $secretPath -BaseDir $BaseDir -Platform $platform -Data $newData
if (-not $ok) {
    Write-Host "  ✗ Failed to write secret to vault backend." -ForegroundColor Red
    exit 1
}

# ── 6. Force ESO resync ──────────────────────────────────────────
Write-Host ""
Write-Host "  Searching for ExternalSecrets that reference '$secretPath'..." -ForegroundColor DarkGray

$syncTs  = Get-Date -Format 'yyyyMMddHHmmss'
$synced  = 0
$esRaw   = & kubectl get externalsecret -A -o json 2>$null
$esList  = if ($esRaw) { ($esRaw | ConvertFrom-Json -ErrorAction SilentlyContinue).items } else { @() }

foreach ($es in @($esList)) {
    $ns   = $es.metadata.namespace
    $name = $es.metadata.name

    $matched = $false
    foreach ($d in @($es.spec.data)) {
        if ($d.remoteRef.key -like "*$secretPath*") { $matched = $true; break }
    }
    if (-not $matched) {
        foreach ($df in @($es.spec.dataFrom)) {
            if ($df.extract.key -like "*$secretPath*") { $matched = $true; break }
        }
    }

    if ($matched) {
        & kubectl annotate externalsecret $name -n $ns `
            "force-sync=$syncTs" --overwrite 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Triggered resync: $name  ($ns)" -ForegroundColor Green
            $synced++
        }
    }
}

if ($synced -eq 0) {
    Write-Host "  ⚠ No matching ExternalSecrets found — resync not triggered automatically." -ForegroundColor Yellow
    Write-Host "    Trigger manually:" -ForegroundColor DarkGray
    Write-Host "    kubectl annotate externalsecret <name> -n <ns> force-sync=$syncTs --overwrite" -ForegroundColor DarkGray
}

# ── 7. Restart affected workloads (optional) ─────────────────────
Write-Host ""
$restartNs = Read-Plain `
    -Prompt "Restart workloads in namespace" `
    -ContextTitle "Secret Rotation — Workload Restart" `
    -ContextHint "Enter a namespace to restart deployments/statefulsets there, or press Enter to skip"

if (-not [string]::IsNullOrWhiteSpace($restartNs)) {
    $restartNs = $restartNs.Trim()
    Write-Host ""

    $deploys = @(& kubectl get deployment -n $restartNs --no-headers `
        -o custom-columns="N:.metadata.name" 2>$null | Where-Object { $_ })
    $stsets  = @(& kubectl get statefulset -n $restartNs --no-headers `
        -o custom-columns="N:.metadata.name" 2>$null | Where-Object { $_ })

    if ($deploys.Count -gt 0) {
        Write-Host "  Deployments in '$restartNs':" -ForegroundColor DarkGray
        $deploys | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        $which = Read-Plain `
            -Prompt "Restart which? (names comma-separated, 'all', or empty to skip)" `
            -ContextTitle "Workload Restart"
        if (-not [string]::IsNullOrWhiteSpace($which)) {
            $targets = if ($which.Trim() -eq 'all') { $deploys } `
                       else { @($which -split ',') | ForEach-Object { $_.Trim() } }
            foreach ($t in $targets) {
                & kubectl rollout restart deployment/$t -n $restartNs 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Restarted deployment/$t" -ForegroundColor Green }
                else                     { Write-Host "  ⚠ Could not restart deployment/$t" -ForegroundColor Yellow }
            }
        }
    }

    if ($stsets.Count -gt 0) {
        Write-Host "  StatefulSets in '$restartNs':" -ForegroundColor DarkGray
        $stsets | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        $which = Read-Plain `
            -Prompt "Restart which? (names comma-separated, 'all', or empty to skip)" `
            -ContextTitle "Workload Restart"
        if (-not [string]::IsNullOrWhiteSpace($which)) {
            $targets = if ($which.Trim() -eq 'all') { $stsets } `
                       else { @($which -split ',') | ForEach-Object { $_.Trim() } }
            foreach ($t in $targets) {
                & kubectl rollout restart statefulset/$t -n $restartNs 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Restarted statefulset/$t" -ForegroundColor Green }
                else                     { Write-Host "  ⚠ Could not restart statefulset/$t" -ForegroundColor Yellow }
            }
        }
    }

    if ($deploys.Count -eq 0 -and $stsets.Count -eq 0) {
        Write-Host "  No Deployments or StatefulSets found in namespace '$restartNs'." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  ════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Secret rotation complete." -ForegroundColor Cyan
Write-Host "  ════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

exit 0
