<#
.SYNOPSIS
    Uninstalls shared-infra components from the connected cluster.
.DESCRIPTION
    Counterpart to Install-Infra.ps1. Never touches the cluster itself (no node/cluster
    deletion, no DNS/hosts cleanup) — it only removes the Helm releases this installer
    deployed, using each component's Uninstall.ps1 when present. Always operates on the
    fixed "shared-infra" namespace.
#>
[CmdletBinding()]
param()

Import-Module "$PSScriptRoot/_lib/Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$PSScriptRoot/_lib/InstallerFunctions.psm1" -Force -Verbose:$false
Import-Module "$PSScriptRoot/_lib/PrerequisiteChecks.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Red
Write-Host "  Reset: Shared Infra Components" -ForegroundColor Red
Write-Host "========================================`n" -ForegroundColor Red

# ── 1. Platform selection from this installer's own connection state ────
$platforms = @()
if (Test-Path (Join-Path $PSScriptRoot ".rke2-state.json")) { $platforms += @{ Label = "RKE2 (On-Premise)"; Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $PSScriptRoot ".kind-state.json")) { $platforms += @{ Label = "Kind (Local)";       Value = "Kind (Local)" } }
if (Test-Path (Join-Path $PSScriptRoot ".aks-state.json"))  { $platforms += @{ Label = "Azure AKS";          Value = "Azure AKS" } }
if (Test-Path (Join-Path $PSScriptRoot ".eks-state.json"))  { $platforms += @{ Label = "AWS EKS";            Value = "AWS EKS" } }
if (Test-Path (Join-Path $PSScriptRoot ".gke-state.json"))  { $platforms += @{ Label = "Google GKE";         Value = "Google GKE" } }

if ($platforms.Count -eq 0) {
    Write-Host "  No connected cluster found. Run Install-Infra.ps1 first." -ForegroundColor Red
    exit 1
}

$platform = if ($platforms.Count -eq 1) { $platforms[0].Value } else {
    Read-SelectValue -Title "Select cluster" -Message "Which cluster should components be removed from?" `
        -Options $platforms -Default 0 -ContextTitle "Reset Infra"
}
if (-not $platform) { exit 0 }

Set-ClusterContext -BaseDir $PSScriptRoot -Platform $platform

# ── 2. Fixed shared-infra namespace (no per-instance selection here) ────
$namespace = "shared-infra"
Write-Host "  Namespace: $namespace" -ForegroundColor Gray

# ── 3. Discover installed infra components ───────────────────────────────
$componentDirs = Get-ChildItem -Path $PSScriptRoot -Directory |
    Where-Object { $_.Name -match '^\d{2}-' -and (Test-Path (Join-Path $_.FullName "Config.psd1")) } |
    Sort-Object { [int]($_.Name -split '-', 2)[0] }

if ($componentDirs.Count -eq 0) {
    Write-Host "`n  No components found." -ForegroundColor Yellow
    exit 0
}

$components = foreach ($dir in $componentDirs) {
    $config = Import-PowerShellDataFile -Path (Join-Path $dir.FullName "Config.psd1")
    [pscustomobject]@{
        FolderName      = $dir.Name
        DisplayName     = if ($config.DisplayName) { $config.DisplayName } else { $dir.Name }
        Name            = $config.Name
        UninstallScript = Join-Path $dir.FullName "Uninstall.ps1"
    }
}

$options = @($components | ForEach-Object { @{ Label = $_.DisplayName; Value = $_.FolderName } })
$selectedFolders = Read-MultiSelectValues `
    -Title "Select Components to Remove" -Message "Use Space to select/deselect, Enter to confirm" `
    -Options $options -DefaultValues @($components | ForEach-Object { $_.FolderName }) -ContextTitle $platform
if ($null -eq $selectedFolders -or $selectedFolders.Count -eq 0) {
    Write-Host "Aborted — nothing removed." -ForegroundColor Yellow
    exit 0
}

# ── 4. Uninstall each selected component ─────────────────────────────────
Write-Host ""
foreach ($c in ($components | Where-Object { $selectedFolders -contains $_.FolderName })) {
    Write-Host "--- Removing: $($c.DisplayName) ---" -ForegroundColor Magenta
    if (Test-Path $c.UninstallScript) {
        & $c.UninstallScript -Platform $platform -Namespace $namespace
        if ($LASTEXITCODE -ne 0) { Write-Warning "  ⚠ Uninstall.ps1 for '$($c.DisplayName)' returned a non-zero exit code — continuing" }
    } elseif ($c.Name) {
        & helm uninstall $c.Name --namespace $namespace 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Helm release '$($c.Name)' removed" -ForegroundColor Green }
        else { Write-Warning "  ⚠ Could not remove Helm release '$($c.Name)' in namespace '$namespace' — it may not exist" }
    } else {
        Write-Warning "  ⚠ No Uninstall.ps1 and no Name in Config.psd1 — skipping '$($c.DisplayName)'"
    }
}

# ── 5. Optionally clean up local connection state ────────────────────────
Write-Host ""
$cleanLocal = Read-YesNo `
    -Title "Also remove local connection data (.{platform}-state.json) and .tools\?" -DefaultYes $false `
    -YesLabel "Yes — full reset  (next run will ask for connection details again)" `
    -NoLabel  "No — keep connection data" `
    -ContextTitle "Reset Infra"
if ($cleanLocal) {
    Get-ChildItem -Path $PSScriptRoot -Filter ".*-state.json" -File | Remove-Item -Force -ErrorAction SilentlyContinue
    $toolsDir = Join-Path $PSScriptRoot ".tools"
    if (Test-Path $toolsDir) { Remove-Item -Path $toolsDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "  ✓ Local state files and .tools\ removed" -ForegroundColor Green
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Reset complete — cluster itself was not modified" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
