<#
.SYNOPSIS
    Install Redis (Bitnami OCI chart) — shared store used by Mosquitto HA and
    available as a general-purpose cache for other infra/components.
.DESCRIPTION
    Credentials (the "default" superuser plus one Redis ACL user per entry in
    Config.psd1's AclUsers) are provisioned in Vault and mounted into an
    initContainer via the secrets-store-csi-driver — never as a Kubernetes
    Secret. The initContainer composes users.acl from those mounted files and
    Redis loads it via --aclfile. See 20-redis/README.md and the
    "Redis ACL credentials" design notes for why (NIS2/CRA — no long-lived
    Secret copy of these credentials in etcd).
.PARAMETER Platform
    Target platform
.PARAMETER Namespace
    Shared-infra namespace (fixed: "shared-infra")
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Platform,
    [Parameter(Mandatory)][string]$Namespace
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 20 - Redis" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$UserConfig = $FullConfig.UserConfig
$AclUsers   = @($FullConfig.AclUsers)

Write-Host "  Chart:        $($FullConfig.Repository):$($FullConfig.Version)" -ForegroundColor Gray
Write-Host "  Namespace:    $Namespace" -ForegroundColor Gray
Write-Host "  Architecture: $($UserConfig.Architecture)" -ForegroundColor Gray
Write-Host ""

# ── 1. Vault-backed credentials: "default" superuser + every AclUsers entry ──
# Generate-once-and-reuse: re-running this script must not rotate a password
# that's already in use (Redis would reload it via --aclfile, but every
# consumer's already-mounted CSI file would still hold the value from when
# their own pod started — a silent mismatch until they're restarted too).
$vaultPath  = "$Namespace/redis-acl-users"
$usernames  = @("default") + @($AclUsers.Username)
$passwords  = [ordered]@{}
$generated  = @()

foreach ($user in $usernames) {
    $existing = Read-ClusterSecret -Path $vaultPath -Key $user -Platform $Platform -BaseDir $BaseDir
    if ($existing) {
        $passwords[$user] = $existing
    } else {
        $passwords[$user] = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
        $generated += $user
    }
}

if ($generated.Count -gt 0) {
    Write-Host "  Generating Redis ACL credentials for: $($generated -join ', ')" -ForegroundColor Gray
    $ok = Write-ClusterSecret -Path $vaultPath -Data $passwords -Platform $Platform -BaseDir $BaseDir
    if (-not $ok) { Write-Error "Failed to write Redis ACL credentials to Vault at '$vaultPath'"; exit 1 }
    Write-Host "  ✓ Stored in Vault at '$vaultPath'" -ForegroundColor Green
} else {
    Write-Host "  ✓ Redis ACL credentials already in Vault — reusing" -ForegroundColor Green
}

# ── 2. CSI mount: every username above, as one file per user, into Redis's ──
# own initContainer only — never into the main container, never as a Secret.
# ServiceAccount is "$Name-master" — the Bitnami chart creates one per
# sub-component (master/replica/sentinel), not a single one at the bare
# release name (confirmed via 'kubectl get sa', not assumed).
$csi = New-CsiSecretMount -AppName "redis" -VaultPath $vaultPath -Keys $usernames `
    -Namespace $Namespace -ServiceAccount "$($FullConfig.Name)-master" -Platform $Platform `
    -MountPath "/vault/secrets" -BaseDir $BaseDir
if (-not $csi.Installed) { Write-Error "Secrets backend not available — RequiredPrereqs=secrets-backend should have caught this earlier"; exit 1 }

$csi.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply SecretProviderClass '$($csi.SpcName)'"; exit 1 }
Write-Host "  ✓ SecretProviderClass '$($csi.SpcName)' applied" -ForegroundColor Green

# ── 3. InitContainer that composes users.acl from the mounted files. One ──
# printf line per AclUsers entry, generated here — adding a consumer is a
# Config.psd1 change, not an edit to this script.
$aclLines = @(
    "printf 'user default on >%s ~* &* +@all\n' `"`$(cat /vault/secrets/default)`""
)
foreach ($u in $AclUsers) {
    $aclLines += "printf 'user $($u.Username) on >%s $($u.Keys) $($u.Channels) $($u.Commands)\n' `"`$(cat /vault/secrets/$($u.Username))`""
}
$composeScript = (
    @(
        "set -e",
        "cp /vault/secrets/default /opt/bitnami/redis/secrets/redis-password",
        "{"
    ) + $aclLines + @(
        "} > /acl-build/users.acl"
    )
) -join "`n"

$initContainersJson = ConvertTo-Json -Depth 10 @(
    @{
        name         = "acl-builder"
        image        = "docker.io/library/busybox:1.36"
        command      = @("sh", "-c", $composeScript)
        volumeMounts = @(
            @{ name = "vault-secrets"; mountPath = "/vault/secrets"; readOnly = $true }
            @{ name = "redis-password"; mountPath = "/opt/bitnami/redis/secrets" }
            @{ name = "acl-build"; mountPath = "/acl-build" }
        )
    }
)

$extraVolumesJson = ConvertTo-Json -Depth 10 @(
    @{ name = "vault-secrets"; csi = @{ driver = "secrets-store.csi.k8s.io"; readOnly = $true; volumeAttributes = @{ secretProviderClass = $csi.SpcName } } }
    @{ name = "acl-build"; emptyDir = @{} }
)

$extraVolumeMountsJson = ConvertTo-Json -Depth 10 @(
    @{ name = "acl-build"; mountPath = "/acl-build"; readOnly = $true }
)

# ── 4. Deploy ──────────────────────────────────────────────────────────────
Reset-StuckHelmRelease -ReleaseName $FullConfig.Name -Namespace $Namespace

$HelmArgs = @(
    "upgrade", "--install", $FullConfig.Name, $FullConfig.Repository,
    "--version", $FullConfig.Version,
    "--namespace", $Namespace,
    "--set", "architecture=$($UserConfig.Architecture)",
    "--set", "auth.enabled=true",
    "--set", "auth.usePasswordFileFromSecret=false",
    "--set", "master.extraFlags[0]=--aclfile /acl-build/users.acl",
    "--set-json", "master.extraVolumes=$extraVolumesJson",
    "--set-json", "master.extraVolumeMounts=$extraVolumeMountsJson",
    "--set-json", "master.initContainers=$initContainersJson",
    "--set", "master.persistence.size=$($UserConfig.Persistence.Size)",
    "--set", "master.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "master.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "master.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "master.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)

$exitCode = Invoke-WithSpinner -Message "Deploying Redis..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Redis (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "statefulset/$($FullConfig.Name)-master", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete"; exit 1 }
Write-Host "  ✓ Ready" -ForegroundColor Green

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l "app.kubernetes.io/instance=$($FullConfig.Name)"
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Host (cluster-internal):  $($FullConfig.Name)-master.$Namespace.svc.cluster.local:6379" -ForegroundColor Yellow
Write-Host "  ACL users:                $($usernames -join ', ')  (Vault: secret/$vaultPath — no k8s Secret exists for these)" -ForegroundColor Yellow
Write-Host "  Read a password:          kubectl exec -n openbao openbao-0 -- bao kv get secret/$vaultPath" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
