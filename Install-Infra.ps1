<#
.SYNOPSIS
    Main script for installing cluster-shared infrastructure (MQTT, Redis, ...) onto an
    already-existing Kubernetes cluster.
.DESCRIPTION
    Built on the same principle as the Kubernetes baseline installer: identical menu system,
    identical tool/prerequisite installation, identical Config.psd1/Prompt.ps1/Install.ps1
    contract per component. Differences from the baseline installer:
      - never creates or replaces a cluster — the target cluster must already exist
      - fully standalone: may run on a different machine than the one that set up the
        cluster, so it never relies on the baseline installer's local state files
      - checks prerequisites (ingress, cert-manager, secrets backend, storage) against the
        live cluster before offering components that depend on them
    Unlike the per-tenant Navios App-Installer, every component here installs once per
    cluster into one of a small set of fixed, function-grouped namespaces (mqtt, redis —
    see Get-ComponentNamespace) rather than a single shared one — there's no per-instance
    namespace prompt.
#>
[CmdletBinding()]
param()

[Console]::TreatControlCAsInput = $false

Import-Module "$PSScriptRoot/_lib/Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$PSScriptRoot/_lib/InstallerFunctions.psm1" -Force -Verbose:$false
Import-Module "$PSScriptRoot/_lib/PrerequisiteChecks.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Installation aborted: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    Write-Host "" -ForegroundColor DarkGray
    Write-Host "  Stack trace:" -ForegroundColor DarkGray
    $_.ScriptStackTrace -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    exit 1
}

function Get-ComponentNamespace {
    <#
    .SYNOPSIS
        Maps a component folder name (e.g. "10-mqtt-emqx", "21-redis-insight") to its
        namespace group ("mqtt" / "redis"), by name convention alone — no config lookup.
    #>
    param([Parameter(Mandatory)][string]$FolderName)
    if ($FolderName -match 'mqtt')  { return "mqtt" }
    if ($FolderName -match 'redis') { return "redis" }
    throw "Get-ComponentNamespace: no namespace group known for component '$FolderName'"
}

function Connect-ExistingAksCluster {
    $stepTitle = "Step 2: Connecting to Cluster — Azure AKS"
    $stateFile = Join-Path $PSScriptRoot ".aks-state.json"
    $existing  = if (Test-Path $stateFile) { Get-Content $stateFile | ConvertFrom-Json } else { $null }

    Write-Context -Title $stepTitle -Current ([ordered]@{})
    $exitCode = Invoke-WithSpinner -Message "Checking Azure login..." -Executable "az" -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        do {
            Write-Host "`n  Azure login required. Open the following URL in your browser:" -ForegroundColor Cyan
            Write-Host "    https://microsoft.com/devicelogin" -ForegroundColor Yellow
            Write-Host ""
            & az login --use-device-code
        } while ($LASTEXITCODE -ne 0 -and (Confirm-RetryOrExit -Reason "Azure login failed"))
    }

    $defaultSub = if ($existing.SubscriptionId) { $existing.SubscriptionId } else { "" }
    $subscriptionId = Read-Plain `
        -Prompt "Azure Subscription ID" -Default $defaultSub `
        -ContextTitle $stepTitle -ContextHint "Find it in Azure Portal > Subscriptions" -ContextCurrent ([ordered]@{})
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) { Write-Host "  Subscription ID is required." -ForegroundColor Red; exit 1 }
    & az account set --subscription $subscriptionId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  Failed to set subscription '$subscriptionId'." -ForegroundColor Red; exit 1 }

    $listRef = [ref]$null
    Invoke-WithSpinner -Message "Loading AKS clusters..." -Executable "az" `
        -Arguments @("aks", "list", "--query", "[].{name:name, rg:resourceGroup, location:location}", "--output", "json") `
        -OutputVariable $listRef | Out-Null
    $clusters = try { ($listRef.Value -join "`n") | ConvertFrom-Json } catch { @() }
    if (-not $clusters -or @($clusters).Count -eq 0) {
        Write-Host "`n  No existing AKS cluster found in subscription '$subscriptionId'." -ForegroundColor Red
        Write-Host "  Run the Baseline installer first to create one." -ForegroundColor Yellow
        exit 1
    }

    $options = @($clusters | ForEach-Object { @{ Label = "$($_.name)  ($($_.rg) · $($_.location))"; Value = "$($_.name)|$($_.rg)|$($_.location)" } })
    $selected = Read-SelectValue -Title "Select AKS cluster" -Message "Which cluster should this connect to?" `
        -Options $options -Default 0 -ContextTitle $stepTitle -ContextCurrent ([ordered]@{ Subscription = $subscriptionId })
    if (-not $selected) { Write-Host "Aborted." -ForegroundColor Red; exit 1 }

    $parts = $selected -split '\|'
    @{
        SubscriptionId = $subscriptionId
        ClusterName    = $parts[0]
        ResourceGroup  = $parts[1]
        Location       = $parts[2]
        CreatedAt      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8

    # Fresh redraw right before the action — without this, whatever prompt screen
    # was last on screen (e.g. the cluster picker) just sits there while the
    # connect spinners below append to it.
    Write-Context -Title $stepTitle -Current ([ordered]@{ Subscription = $subscriptionId; Cluster = $parts[0] })
    Write-Host ""
    Write-Host "Connecting to cluster" -ForegroundColor Cyan
    Write-Host ""
    Initialize-AksCluster -SubscriptionId $subscriptionId -ResourceGroup $parts[1] `
        -Location $parts[2] -ClusterName $parts[0] -UseExisting $true | Out-Null
}

function Connect-ExistingEksCluster {
    $stepTitle = "Step 2: Connecting to Cluster — AWS EKS"
    $stateFile = Join-Path $PSScriptRoot ".eks-state.json"
    $existing  = if (Test-Path $stateFile) { Get-Content $stateFile | ConvertFrom-Json } else { $null }

    Write-Context -Title $stepTitle -Current ([ordered]@{})
    $exitCode = Invoke-WithSpinner -Message "Checking AWS credentials..." -Executable "aws" -Arguments @("sts", "get-caller-identity")
    if ($exitCode -ne 0) {
        $defaultKeyId = if ($existing.AccessKeyId) { $existing.AccessKeyId } else { "" }
        do {
            $accessKeyId = Read-Plain -Prompt "AWS Access Key ID" -Default $defaultKeyId `
                -ContextTitle $stepTitle -ContextHint "IAM user with EKS read permissions" -ContextCurrent ([ordered]@{})
            if ([string]::IsNullOrWhiteSpace($accessKeyId)) { Write-Host "  Access Key ID is required." -ForegroundColor Red; exit 1 }

            $secretAccessKey = Read-SecretPlain -Prompt "AWS Secret Access Key" `
                -ContextTitle $stepTitle -ContextCurrent ([ordered]@{ AccessKeyId = $accessKeyId })
            if ([string]::IsNullOrWhiteSpace($secretAccessKey)) { Write-Host "  Secret Access Key is required." -ForegroundColor Red; exit 1 }

            & aws configure set aws_access_key_id     $accessKeyId     2>&1 | Out-Null
            & aws configure set aws_secret_access_key $secretAccessKey 2>&1 | Out-Null
            & aws sts get-caller-identity 2>&1 | Out-Null
            $awsAuthOk    = $LASTEXITCODE -eq 0
            $defaultKeyId = $accessKeyId
        } while (-not $awsAuthOk -and (Confirm-RetryOrExit -Reason "AWS authentication failed — check Access Key ID and Secret"))
    }

    $defaultRegion = if ($existing.Region) { $existing.Region } else { "" }
    $region = Read-SelectValue `
        -Title "Select AWS Region" -Message "Region the cluster is in" `
        -Options @(
            @{ Label = "EU West 1       (Ireland)";       Value = "eu-west-1" }
            @{ Label = "EU Central 1    (Frankfurt)";     Value = "eu-central-1" }
            @{ Label = "EU North 1      (Stockholm)";     Value = "eu-north-1" }
            @{ Label = "EU West 2       (London)";        Value = "eu-west-2" }
            @{ Label = "US East 1       (N. Virginia)";   Value = "us-east-1" }
            @{ Label = "US East 2       (Ohio)";          Value = "us-east-2" }
            @{ Label = "US West 2       (Oregon)";        Value = "us-west-2" }
            @{ Label = "AP Southeast 1  (Singapore)";     Value = "ap-southeast-1" }
            @{ Label = "AP Northeast 1  (Tokyo)";         Value = "ap-northeast-1" }
        ) -Default 0 -DefaultValue $defaultRegion -ContextTitle $stepTitle -ContextCurrent ([ordered]@{})
    if (-not $region) { Write-Host "  Region is required." -ForegroundColor Red; exit 1 }
    & aws configure set default.region $region 2>&1 | Out-Null

    $listRef = [ref]$null
    Invoke-WithSpinner -Message "Loading EKS clusters..." -Executable "aws" `
        -Arguments @("eks", "list-clusters", "--region", $region, "--query", "clusters", "--output", "json") `
        -OutputVariable $listRef | Out-Null
    $clusterNames = try { ($listRef.Value -join "`n") | ConvertFrom-Json } catch { @() }
    if (-not $clusterNames -or @($clusterNames).Count -eq 0) {
        Write-Host "`n  No existing EKS cluster found in region '$region'." -ForegroundColor Red
        Write-Host "  Run the Baseline installer first to create one." -ForegroundColor Yellow
        exit 1
    }

    $options = @($clusterNames | ForEach-Object { @{ Label = $_; Value = $_ } })
    $clusterName = Read-SelectValue -Title "Select EKS cluster" -Message "Which cluster should this connect to?" `
        -Options $options -Default 0 -ContextTitle $stepTitle -ContextCurrent ([ordered]@{ Region = $region })
    if (-not $clusterName) { Write-Host "Aborted." -ForegroundColor Red; exit 1 }

    @{
        AccessKeyId = (& aws configure get aws_access_key_id 2>$null).Trim()
        Region      = $region
        ClusterName = $clusterName
        CreatedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8

    Write-Context -Title $stepTitle -Current ([ordered]@{ Region = $region; Cluster = $clusterName })
    Write-Host ""
    Write-Host "Connecting to cluster" -ForegroundColor Cyan
    Write-Host ""
    Initialize-EksCluster -Region $region -ClusterName $clusterName -UseExisting $true | Out-Null
}

function Connect-ExistingGkeCluster {
    $stepTitle = "Step 2: Connecting to Cluster — Google GKE"
    $stateFile = Join-Path $PSScriptRoot ".gke-state.json"
    $existing  = if (Test-Path $stateFile) { Get-Content $stateFile | ConvertFrom-Json } else { $null }

    Write-Context -Title $stepTitle -Current ([ordered]@{})
    $accountRef = [ref]$null
    Invoke-WithSpinner -Message "Checking Google login..." -Executable "gcloud" `
        -Arguments @("config", "get-value", "account") -OutputVariable $accountRef | Out-Null
    $gcloudAccount = ($accountRef.Value -join "").Trim()
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        do {
            Write-Host "`n  Google login required..." -ForegroundColor Cyan
            & gcloud auth login --no-launch-browser
        } while ($LASTEXITCODE -ne 0 -and (Confirm-RetryOrExit -Reason "Google login failed"))
    }

    $defaultProject = if ($existing.ProjectId) { $existing.ProjectId } else { "" }
    $projectId = Read-Plain -Prompt "Google Cloud Project ID" -Default $defaultProject `
        -ContextTitle $stepTitle -ContextHint "Find it in Google Cloud Console — top navigation bar" -ContextCurrent ([ordered]@{})
    if ([string]::IsNullOrWhiteSpace($projectId)) { Write-Host "  Project ID is required." -ForegroundColor Red; exit 1 }
    & gcloud config set project $projectId 2>&1 | Out-Null

    $listRef = [ref]$null
    Invoke-WithSpinner -Message "Loading GKE clusters..." -Executable "gcloud" `
        -Arguments @("container", "clusters", "list", "--project", $projectId, "--format", "json(name,zone,status)") `
        -OutputVariable $listRef | Out-Null
    $clusters = try { ($listRef.Value -join "`n") | ConvertFrom-Json } catch { @() }
    if (-not $clusters -or @($clusters).Count -eq 0) {
        Write-Host "`n  No existing GKE cluster found in project '$projectId'." -ForegroundColor Red
        Write-Host "  Run the Baseline installer first to create one." -ForegroundColor Yellow
        exit 1
    }

    $options = @($clusters | ForEach-Object { @{ Label = "$($_.name)  ($($_.zone))  [$($_.status)]"; Value = "$($_.name)|$($_.zone)" } })
    $selected = Read-SelectValue -Title "Select GKE cluster" -Message "Which cluster should this connect to?" `
        -Options $options -Default 0 -ContextTitle $stepTitle -ContextCurrent ([ordered]@{ Project = $projectId })
    if (-not $selected) { Write-Host "Aborted." -ForegroundColor Red; exit 1 }

    $parts = $selected -split '\|'
    @{
        ProjectId   = $projectId
        ClusterName = $parts[0]
        Zone        = $parts[1]
        CreatedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8

    Write-Context -Title $stepTitle -Current ([ordered]@{ Project = $projectId; Cluster = $parts[0] })
    Write-Host ""
    Write-Host "Connecting to cluster" -ForegroundColor Cyan
    Write-Host ""
    Initialize-GkeCluster -ProjectId $projectId -Zone $parts[1] -ClusterName $parts[0] -UseExisting $true | Out-Null
}

function Connect-ExistingRke2Cluster {
    $stepTitle = "Step 2: Connecting to Cluster — RKE2 (On-Premise)"
    $stateFile = Join-Path $PSScriptRoot ".rke2-state.json"
    $existing  = if (Test-Path $stateFile) { Get-Content $stateFile | ConvertFrom-Json } else { $null }

    $sshServer = $null; $sshUser = "root"; $sshKeyPath = $null; $sshPassword = $null; $kubeconfigPath = $null
    # When reusing the saved connection we deliberately do NOT pass $sshServer to
    # Initialize-Rke2Cluster below (left empty) — we never persist the SSH password,
    # so re-running the SSH fetch would just fail. The kubeconfig from the previous
    # successful connection is still on disk and doesn't need re-fetching; only
    # connectivity gets re-verified. $sshServer/$sshUser/$sshKeyPath are still kept
    # around so the state file write at the end doesn't lose that metadata.
    $skipSshFetch = $false

    if ($existing) {
        $reuse = Read-YesNo `
            -Title "Use known RKE2 cluster: $($existing.SshServer)?" -DefaultYes $true `
            -YesLabel "Use it  (existing kubeconfig, no new SSH login)" -NoLabel "Enter different connection details" `
            -ContextTitle $stepTitle -ContextCurrent ([ordered]@{})
        if ($reuse) {
            $sshServer = $existing.SshServer; $sshUser = $existing.SshUser
            $sshKeyPath = $existing.SshKeyPath; $kubeconfigPath = $existing.KubeconfigPath
            $skipSshFetch = $true
        }
    }

    if (-not $skipSshFetch) {
        $sshAvailable = $null -ne (Get-Command "ssh.exe" -ErrorAction SilentlyContinue)
        $useSsh = $false
        if ($sshAvailable) {
            $useSsh = Read-YesNo `
                -Title "Fetch kubeconfig automatically via SSH?" -DefaultYes $true `
                -YesLabel "Auto-fetch via SSH" -NoLabel "Manual path  (file is already local)" `
                -ContextTitle $stepTitle -ContextCurrent ([ordered]@{})
        }

        if ($useSsh) {
            $authMethod = Read-SelectValue -Title "SSH Authentication" -Options @(
                @{ Label = "SSH Key  (recommended)"; Value = "key" }
                @{ Label = "Password (via plink.exe)"; Value = "password" }
            ) -Default 0 -ContextTitle $stepTitle -ContextCurrent ([ordered]@{})

            $sshServer = Read-Plain -Prompt "RKE2 server IP or hostname" -ContextTitle $stepTitle -ContextCurrent ([ordered]@{ Auth = $authMethod })
            if ([string]::IsNullOrWhiteSpace($sshServer)) { Write-Host "Server IP is required." -ForegroundColor Red; exit 1 }

            $sshUser = Read-Plain -Prompt "SSH user (default: root)" -ContextTitle $stepTitle -ContextCurrent ([ordered]@{ Auth = $authMethod; Server = $sshServer })
            if ([string]::IsNullOrWhiteSpace($sshUser)) { $sshUser = "root" }

            if ($authMethod -eq "key") {
                $sshKeyPath = Read-Plain -Prompt "SSH key path (leave empty for ssh-agent / default key)" -ContextTitle $stepTitle -ContextCurrent ([ordered]@{ Auth = $authMethod; Server = $sshServer; User = $sshUser })
            } else {
                $sshPassword = Read-SecretPlain -Prompt "SSH password for $sshUser@$sshServer" -ContextTitle $stepTitle -ContextCurrent ([ordered]@{ Auth = $authMethod; Server = $sshServer; User = $sshUser })
            }
            $kubeconfigPath = "$env:USERPROFILE\.kube\rke2-config"
        } else {
            $defaultKubeconfig = "$env:USERPROFILE\.kube\config"
            $kubeconfigPath = Read-Plain -Prompt "Local path to kubeconfig (default: $defaultKubeconfig)" `
                -ContextTitle $stepTitle -ContextHint "Copy manually: scp user@<node>:/etc/rancher/rke2/rke2.yaml $defaultKubeconfig" -ContextCurrent ([ordered]@{})
            if ([string]::IsNullOrWhiteSpace($kubeconfigPath)) { $kubeconfigPath = $defaultKubeconfig }
        }
    }

    # Fresh redraw right before the action — without this, picking "Use it"
    # above (which skips every prompt below) leaves that Y/N screen sitting
    # there while the connectivity-check spinner appends below it.
    Write-Context -Title $stepTitle -Current ([ordered]@{ Server = $sshServer })
    Write-Host ""
    Write-Host "Connecting to cluster" -ForegroundColor Cyan
    Write-Host ""

    # Initialize-Rke2Cluster (powershell-cluster-bootstrap) now handles every
    # failure internally — it retries SSH/connectivity checks via
    # Confirm-RetryOrExit and exits the process directly if the user declines,
    # rather than returning $false for this caller to react to. So reaching
    # the line below always means success; there's nothing left to retry here.
    $fetchSshServer = if ($skipSshFetch) { "" } else { $sshServer }
    Initialize-Rke2Cluster -KubeconfigPath $kubeconfigPath -SshServer $fetchSshServer -SshUser $sshUser `
        -SshKeyPath $sshKeyPath -SshPassword $sshPassword | Out-Null

    @{
        SshServer      = $sshServer
        SshUser        = $sshUser
        SshKeyPath     = $sshKeyPath
        KubeconfigPath = $kubeconfigPath
        ConnectedAt    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
}

function Connect-ExistingKindCluster {
    $stepTitle = "Step 2: Connecting to Cluster — Kind (Local)"
    $stateFile = Join-Path $PSScriptRoot ".kind-state.json"
    $kindExe   = Join-Path $PSScriptRoot ".tools\kind.exe"

    Write-Context -Title $stepTitle -Current ([ordered]@{})
    $existingClusters = & $kindExe get clusters 2>&1
    $clusterList = @($existingClusters | Where-Object { $_ -and $_ -notmatch "^No kind clusters" })
    if ($clusterList.Count -eq 0) {
        Write-Host "`n  No existing Kind cluster found." -ForegroundColor Red
        Write-Host "  Run the Baseline installer first to create one." -ForegroundColor Yellow
        exit 1
    }

    $clusterName = if ($clusterList.Count -eq 1) { $clusterList[0] } else {
        Read-SelectValue -Title "Select Kind cluster" -Message "Which cluster should this connect to?" `
            -Options @($clusterList | ForEach-Object { @{ Label = $_; Value = $_ } }) -Default 0 -ContextTitle $stepTitle -ContextCurrent ([ordered]@{})
    }
    if (-not $clusterName) { Write-Host "Aborted." -ForegroundColor Red; exit 1 }

    @{
        ClusterName = $clusterName
        CreatedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8

    Write-Context -Title $stepTitle -Current ([ordered]@{ Cluster = $clusterName })
    Write-Host ""
    Write-Host "Connecting to cluster" -ForegroundColor Cyan
    Write-Host ""
    $kubefile = Join-Path $env:USERPROFILE ".kube\kind-$clusterName.yaml"
    & $kindExe export kubeconfig --name $clusterName --kubeconfig $kubefile 2>&1 | Out-Null
    $env:KUBECONFIG = $kubefile
    Write-Host "  ✓ kubectl context set to kind-$clusterName" -ForegroundColor Green
}

function Start-InfraInstallation {

    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          Infra Installer                                 ║" -ForegroundColor Cyan
    Write-Host "  ║          AKS · EKS · GKE · RKE2 · Kind                   ║" -ForegroundColor Cyan
    Write-Host "  ╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║  Installs shared infra (MQTT, Redis, ...) onto an        ║" -ForegroundColor DarkCyan
    Write-Host "  ║  EXISTING cluster. The cluster itself is never created   ║" -ForegroundColor DarkCyan
    Write-Host "  ║  or modified here.                                       ║" -ForegroundColor DarkCyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  All inputs are collected upfront. No prompts during installation." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null
    Clear-Host

    $platform = Read-SelectValue `
        -Title "Select Target Platform" -Message "Which (already existing) cluster should this install onto?" `
        -Options @(
            @{ Label = "Azure AKS"; Value = "Azure AKS" }
            @{ Label = "AWS EKS"; Value = "AWS EKS" }
            @{ Label = "Google GKE"; Value = "Google GKE" }
            @{ Label = "RKE2 (On-Premise)"; Value = "RKE2 (On-Premise)" }
            @{ Label = "Kind (Local)"; Value = "Kind (Local)" }
        ) -Default 0
    if (-not $platform) { Write-Host "Installation cancelled." -ForegroundColor Red; exit }

    # Running UI context (the -ContextCurrent hashmap shown on every screen from
    # here on) — NOT kubectl context. Platform is never put in here: it's already
    # folded into every step's title ("Step N: ... — $platform"), a separate
    # "Platform: ..." line would just repeat it. Grows as each step resolves —
    # cluster identity next, then namespace — carried into every subsequent
    # prompt instead of each step rebuilding its own.
    $uiContext = [ordered]@{}

    Write-Section -Title "Step 1: Checking and Installing Tools — $platform" `
        -Hint "Downloads kubectl, helm, and the platform CLI if missing" `
        -Current $uiContext
    Write-Host ""
    Write-Host "Installing tools" -ForegroundColor Cyan
    Write-Host ""
    Install-Kubectl
    Install-Helm
    Install-PlatformTools -Platform $platform
    Write-Host "`nTools ready." -ForegroundColor Green
    Start-Sleep -Seconds 1
    # TEMP debug aid: pause for visual inspection of each step's screen — remove once the new Step UX is confirmed to look right.
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null

    # Step 2: Connecting to Cluster — $platform. Each Connect-Existing*Cluster
    # function draws its own "Step 2: ... — <platform>" screen(s) internally
    # (it's a multi-prompt sub-flow, not a flat task log like Step 1), so there's
    # no separate Write-Section call here.
    switch ($platform) {
        "Azure AKS"          { Connect-ExistingAksCluster }
        "AWS EKS"            { Connect-ExistingEksCluster }
        "Google GKE"         { Connect-ExistingGkeCluster }
        "RKE2 (On-Premise)"  { Connect-ExistingRke2Cluster }
        "Kind (Local)"       { Connect-ExistingKindCluster }
    }
    # Explicit, canonical context (re-)establishment from whatever state file was
    # just written — same mechanism every component's Install.ps1/Uninstall.ps1
    # uses, so we have one guaranteed-clean checkpoint here regardless of platform
    # or which connect path (fresh vs. reused) was taken above.
    Set-ClusterContext -BaseDir $PSScriptRoot -Platform $platform

    $clusterStateFile = switch ($platform) {
        "Azure AKS"          { ".aks-state.json" }
        "AWS EKS"            { ".eks-state.json" }
        "Google GKE"         { ".gke-state.json" }
        "RKE2 (On-Premise)"  { ".rke2-state.json" }
        "Kind (Local)"       { ".kind-state.json" }
    }
    $clusterState = Get-Content (Join-Path $PSScriptRoot $clusterStateFile) | ConvertFrom-Json
    $clusterDisplay = switch ($platform) {
        "Azure AKS"          { "$($clusterState.ClusterName) ($($clusterState.ResourceGroup))" }
        "AWS EKS"            { "$($clusterState.ClusterName) ($($clusterState.Region))" }
        "Google GKE"         { "$($clusterState.ClusterName) ($($clusterState.Zone))" }
        "RKE2 (On-Premise)"  { $clusterState.SshServer }
        "Kind (Local)"       { $clusterState.ClusterName }
    }
    $uiContext.Cluster = $clusterDisplay

    # Kubernetes version check — components like OpenBao require >= 1.30.
    # This is the actual verification that the connection is good, not just
    # that Set-ClusterContext didn't throw: a stale/unreachable kubeconfig
    # still "connects" without error but fails this check. Runs before the
    # "Connected" confirmation below — same check, same order, for every
    # platform — so that confirmation is the true final word, not printed
    # before the connection has actually been verified to work. A failed
    # check aborts the installer outright — there's no point continuing
    # into component selection against a cluster version we already know
    # is unsupported.
    # Invoke-WithSpinner merges stdout+stderr (2>&1) inside its background job,
    # which corrupts the JSON if kubectl writes anything at all to stderr
    # (e.g. a client/server version skew warning) — same bug found in
    # Kubernetes.DSA. Use Invoke-ScriptBlockWithSpinner instead so stderr can
    # be discarded explicitly (2>$null).
    # Retried up to 3x — a kubeconfig that was just written/re-pointed a few
    # lines above can hit a momentary connection blip on the very first call
    # against it, same transient-lag rationale as Write-OpenBaoSecret's pod-
    # status retry. Not retried indefinitely: a genuinely unreachable/too-old
    # cluster should still abort, just not on a one-off network hiccup.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $versionOutput = Invoke-ScriptBlockWithSpinner -Message "Checking Kubernetes version..." -ScriptBlock {
            param($path, $kubeconfig)
            $env:PATH = $path
            if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
            & kubectl version --output json 2>$null
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE }
        } -ArgumentList @($env:PATH, $env:KUBECONFIG)
        # The job's last output object carries the exit code; everything before
        # it is kubectl's own stdout (still a flat array, not yet joined).
        $versionExit = $versionOutput | Select-Object -Last 1 | ForEach-Object { $_.ExitCode }
        $versionJson = $versionOutput | Select-Object -SkipLast 1
        $k8sVersion = try { ($versionJson -join "`n") | ConvertFrom-Json -ErrorAction SilentlyContinue } catch { $null }
        if ($k8sVersion -and $k8sVersion.serverVersion) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    $serverVersion = if ($k8sVersion -and $k8sVersion.serverVersion) {
        "$($k8sVersion.serverVersion.major).$($k8sVersion.serverVersion.minor -replace '[^0-9]','')"
    } else { "0.0" }
    $k8sMajor = [int]($serverVersion -split '\.')[0]
    $k8sMinor = [int]($serverVersion -split '\.')[1]
    if ($k8sMajor -lt 1 -or ($k8sMajor -eq 1 -and $k8sMinor -lt 30)) {
        Write-Host "  ✗ Kubernetes $serverVersion detected — some components (e.g. OpenBao) require >= 1.30." -ForegroundColor Red
        if ($serverVersion -eq "0.0") {
            # Couldn't parse a version at all — show what 'kubectl version' actually
            # returned instead of silently exiting on an unexplained "0.0".
            Write-Host "  Could not parse 'kubectl version --output json' (exit code $versionExit). Raw output:" -ForegroundColor Yellow
            if ($versionJson) { $versionJson | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow } }
            else { Write-Host "    (empty)" -ForegroundColor Yellow }
        }
        Write-Host "  Please upgrade the cluster to 1.30+ and re-run the installer." -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ Kubernetes $serverVersion" -ForegroundColor Green
    Write-Host "`nConnected to $platform." -ForegroundColor Green
    Start-Sleep -Seconds 1
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null

    Write-Section -Title "Step 3: Checking Cluster Prerequisites — $platform" `
        -Hint "Creates the mqtt/redis namespaces (Rancher project 'Shared Infrastructure') and checks ingress, cert-manager, secrets backend, and storage class against the live cluster" `
        -Current $uiContext
    Write-Host ""
    Write-Host "Checking prerequisites" -ForegroundColor Cyan
    Write-Host ""
    # Every infra component installs into one of a small set of fixed,
    # cluster-wide namespaces here, grouped by function (mqtt/redis) rather
    # than one shared "shared-infra" namespace — unlike the per-tenant Navios
    # App-Installer which creates one navios-<kuerzel> namespace per Anlage
    # instance. No prompt, no state file. Get-ComponentNamespace (below) maps
    # each component folder to its group; both namespaces are ensured (and
    # assigned to the Rancher project "Shared Infrastructure") right
    # alongside the other prerequisites — a one-time, once-per-cluster setup
    # step, not substantial enough to warrant its own page.
    $namespaces = @("mqtt", "redis")

    # Invoke-ScriptBlockWithSpinner's background job has no access to this
    # session's env vars, so PATH/KUBECONFIG must be forwarded explicitly
    # (Invoke-WithSpinner does this automatically; this one doesn't) — same
    # pattern as Kubernetes.DSA's namespace-creation step. Project lookup/
    # create-and-assign itself is shared (powershell-cluster-bootstrap's
    # Set-RancherProjectAssignment) rather than duplicated inline here.
    foreach ($namespace in $namespaces) {
        $namespaceExists = Invoke-ScriptBlockWithSpinner -Message "Checking namespace '$namespace'..." -ScriptBlock {
            param($path, $kubeconfig, $ns)
            $env:PATH = $path
            if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
            & kubectl get namespace $ns 2>$null | Out-Null
            $LASTEXITCODE -eq 0
        } -ArgumentList @($env:PATH, $env:KUBECONFIG, $namespace)

        if ($namespaceExists) {
            Write-Host "  ✓ namespace '$namespace'" -ForegroundColor Green
        } else {
            $nsResult = Invoke-ScriptBlockWithSpinner -Message "Creating namespace '$namespace'..." -ScriptBlock {
                param($path, $kubeconfig, $ns)
                $env:PATH = $path
                if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
                $out = & kubectl create namespace $ns --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1
                [PSCustomObject]@{ Output = $out; ExitCode = $LASTEXITCODE }
            } -ArgumentList @($env:PATH, $env:KUBECONFIG, $namespace)
            if ($nsResult.ExitCode -ne 0) { Write-Error "Failed to create namespace '$namespace': $($nsResult.Output)"; exit 1 }
            Write-Host "  ✓ namespace '$namespace' (created)" -ForegroundColor Green
        }

        Set-RancherProjectAssignment -Namespace $namespace -ProjectName "Shared Infrastructure"
    }
    $uiContext.Namespace = ($namespaces -join " / ")

    # Each remaining prereq is checked and reported individually — its own
    # spinner, then its own immediate ✓/✗ result — same pattern as the
    # namespace check above, rather than batching everything into one
    # spinner and only revealing results once everything has finished.
    # PrerequisiteChecks.psm1 has to be re-imported inside each ScriptBlock,
    # same env-forwarding pattern as above.
    $modulePath = "$PSScriptRoot/_lib/PrerequisiteChecks.psm1"
    $prereqChecks = [ordered]@{
        "ingress"         = "Test-IngressPresent"
        "cert-manager"    = "Test-CertManagerPresent"
        "secrets-backend" = "Test-SecretsBackendPresent"
        "storage"         = "Test-DefaultStorageClassPresent"
    }
    $prereqs = @{}
    foreach ($key in $prereqChecks.Keys) {
        $prereqs[$key] = Invoke-ScriptBlockWithSpinner -Message "Checking $key..." -ScriptBlock {
            param($path, $kubeconfig, $modulePath, $funcName)
            $env:PATH = $path
            if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
            Import-Module $modulePath -Force
            & $funcName
        } -ArgumentList @($env:PATH, $env:KUBECONFIG, $modulePath, $prereqChecks[$key])
        $mark = if ($prereqs[$key]) { "✓" } else { "✗" }
        $color = if ($prereqs[$key]) { "Green" } else { "Yellow" }
        Write-Host "  $mark $key" -ForegroundColor $color
    }
    if (-not ($prereqs.Values -contains $false)) {
        Write-Host "`nAll prerequisites met." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null

    # Discover app components: numbered folders ("NN-name") containing a Config.psd1
    $componentDirs = Get-ChildItem -Path $PSScriptRoot -Directory |
        Where-Object { $_.Name -match '^\d{2}-' -and (Test-Path (Join-Path $_.FullName "Config.psd1")) } |
        Sort-Object { [int]($_.Name -split '-', 2)[0] }

    if ($componentDirs.Count -eq 0) {
        Write-Host "`n  No components found — nothing to install." -ForegroundColor Yellow
        return
    }

    $components = foreach ($dir in $componentDirs) {
        $config = Import-PowerShellDataFile -Path (Join-Path $dir.FullName "Config.psd1")
        $missing = Get-MissingPrerequisites -RequiredPrereqs $config.RequiredPrereqs -Detected $prereqs
        [pscustomobject]@{
            FolderName         = $dir.Name
            DisplayName        = if ($config.DisplayName) { $config.DisplayName } else { $dir.Name }
            ConfigPath         = (Join-Path $dir.FullName "Config.psd1")
            PromptScript       = Join-Path $dir.FullName "Prompt.ps1"
            InstallScript      = Join-Path $dir.FullName "Install.ps1"
            MissingPrereqs     = $missing
            RadioGroup         = $config.RadioGroup
            RadioGroupLabel    = $config.RadioGroupLabel
            RadioDefault       = [bool]$config.RadioDefault
            DefaultSelected    = if ($config.Keys -contains 'DefaultSelected') { [bool]$config.DefaultSelected } else { $true }
            RequiresComponents = @($config.RequiresComponents) + @($config.RequiresGroups | ForEach-Object { "__group_$_`__" })
        }
    }

    # One tree screen for everything: components sharing a RadioGroup (e.g.
    # "mqtt-broker": Mosquitto vs. EMQX) become a checkable group with radio
    # children, standalone components become plain checkboxes. A component's
    # RequiresComponents (e.g. Mosquitto -> 20-redis) force-selects and locks
    # the required one for as long as the requiring item is checked.
    $radioGroups = @($components | Where-Object { $_.RadioGroup } | Group-Object RadioGroup)
    $standalone  = @($components | Where-Object { -not $_.RadioGroup })
    $sectionItems = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($group in $radioGroups) {
        $members = @($group.Group)
        # Read-ComponentSelectionScreen has no greying-out for unmet prereqs
        # (only for Requires-locking) — members with unmet prereqs are left
        # out of the list entirely rather than shown disabled.
        $available = @($members | Where-Object { $_.MissingPrereqs.Count -eq 0 })
        foreach ($m in @($members | Where-Object { $_.MissingPrereqs.Count -gt 0 })) {
            Write-Host "  ⚠ $($m.DisplayName) not available (missing: $($m.MissingPrereqs -join ', '))" -ForegroundColor Yellow
        }
        if ($available.Count -eq 0) { continue }

        $groupLabel = ($available | Where-Object { $_.RadioGroupLabel } | Select-Object -First 1 -ExpandProperty RadioGroupLabel)
        if (-not $groupLabel) { $groupLabel = $group.Name }

        $children = @($available | ForEach-Object {
            @{ Label = $_.DisplayName; Value = $_.FolderName; Type = "radio"; RadioGroup = $group.Name; Default = $_.RadioDefault; Requires = $_.RequiresComponents }
        })
        $sectionItems.Add(@{ Label = $groupLabel; Value = "__group_$($group.Name)__"; Type = "group"; Default = $true; Children = $children }) | Out-Null
    }

    foreach ($c in $standalone) {
        if ($c.MissingPrereqs.Count -gt 0) {
            Write-Host "  ⚠ $($c.DisplayName) not available (missing: $($c.MissingPrereqs -join ', '))" -ForegroundColor Yellow
            continue
        }
        $sectionItems.Add(@{ Label = $c.DisplayName; Value = $c.FolderName; Type = "check"; Default = $c.DefaultSelected; Requires = $c.RequiresComponents }) | Out-Null
    }

    if ($sectionItems.Count -eq 0) {
        # Every discovered component got filtered out above for missing
        # prerequisites — not just one component unavailable, nothing is
        # left to install at all, so this aborts instead of continuing into
        # a selection screen with nothing to select.
        Write-Host "`nPrerequisites not met — no components can be installed." -ForegroundColor Red
        Start-Sleep -Seconds 1
        Write-Host "Press any key to exit..." -ForegroundColor DarkGray
        [Console]::ReadKey($true) | Out-Null
        exit 1
    }

    $selectionResult = Read-ComponentSelectionScreen -Title "Select Components to Install" `
        -Sections @(@{ Label = "Shared Infra"; Items = @($sectionItems) }) `
        -ContextTitle "Step 4: Select Components — $platform" -ContextCurrent $uiContext
    if ($null -eq $selectionResult) { Write-Host "Installation cancelled." -ForegroundColor Red; exit }

    $selectedComponents = @($components | Where-Object { $selectionResult.ContainsKey($_.FolderName) -and $selectionResult[$_.FolderName] })
    if ($selectedComponents.Count -eq 0) {
        Write-Host "`nNo components selected." -ForegroundColor Yellow
        return
    }

    $defaultDomain = switch ($platform) {
        "Kind (Local)"      { "kubernetes.local" }
        "RKE2 (On-Premise)" { "kubernetes.ds-automotion.com" }
        default             { "" }
    }
    $domain = Read-Plain -Prompt "Cluster domain (for ingress hostnames, optional)" -Default $defaultDomain `
        -ContextTitle "Step 5: Collecting Component Inputs — $platform" `
        -ContextHint "Base domain for externally reachable components, e.g. <component>.<domain>" `
        -ContextCurrent $uiContext

    $componentInputs = @{}
    foreach ($c in $selectedComponents) {
        if (Test-Path $c.PromptScript) {
            # -Domain/-Namespace passed unconditionally — components that don't need
            # a hostname just leave the corresponding Prompt.ps1 param unused.
            $componentNamespace = Get-ComponentNamespace -FolderName $c.FolderName
            $inputs = & $c.PromptScript -Platform $platform -Domain $domain -Namespace $componentNamespace
            if ($inputs) { $componentInputs[$c.FolderName] = $inputs }
        }
    }

    # Install dependencies before dependents (e.g. Redis before Mosquitto-HA,
    # which RequiresComponents it) — numeric folder order alone doesn't
    # guarantee this, a dependency isn't necessarily lower-numbered.
    $remaining = [System.Collections.Generic.List[object]]::new()
    $remaining.AddRange([object[]]$selectedComponents)
    $ordered = [System.Collections.Generic.List[object]]::new()
    while ($remaining.Count -gt 0) {
        $remainingNames = @($remaining | ForEach-Object { $_.FolderName })
        $next = $remaining | Where-Object {
            $deps = @($_.RequiresComponents)
            @($deps | Where-Object { $remainingNames -contains $_ }).Count -eq 0
        } | Select-Object -First 1
        if (-not $next) { $next = $remaining[0] }   # dependency cycle guard, shouldn't happen
        $ordered.Add($next) | Out-Null
        $remaining.Remove($next) | Out-Null
    }
    $selectedComponents = @($ordered)

    Write-Section -Title "Step 6: Installing Components — $platform" `
        -Hint "Installs each selected component in dependency order" `
        -Current $uiContext
    Write-Host ""
    Write-Host "Installing components" -ForegroundColor Cyan
    Write-Host ""
    $extraArgs = if ($VerbosePreference -eq 'Continue') { @{ Verbose = $true } } else { @{} }
    foreach ($c in $selectedComponents) {
        if (-not (Test-Path $c.InstallScript)) {
            Write-Warning "  ⚠ Install script not found: $($c.InstallScript)"
            continue
        }
        # If this component belongs to a RadioGroup, uninstall any previously-
        # installed sibling first. Each sibling's Uninstall.ps1 has a chart
        # identity guard that makes it a safe no-op when a different chart (or
        # nothing) is under that release name, so this is unconditionally safe.
        $componentNamespace = Get-ComponentNamespace -FolderName $c.FolderName
        if ($c.RadioGroup) {
            $siblings = @($components | Where-Object { $_.RadioGroup -eq $c.RadioGroup -and $_.FolderName -ne $c.FolderName })
            foreach ($sibling in $siblings) {
                $siblingUninstall = Join-Path (Split-Path $sibling.ConfigPath -Parent) "Uninstall.ps1"
                if (Test-Path $siblingUninstall) {
                    Write-Host "  Checking if $($sibling.DisplayName) needs to be removed first..." -ForegroundColor Gray
                    & $siblingUninstall -Platform $platform -Namespace (Get-ComponentNamespace -FolderName $sibling.FolderName)
                }
            }
        }

        $promptArgs = if ($componentInputs.ContainsKey($c.FolderName)) { $componentInputs[$c.FolderName] } else { @{} }
        & $c.InstallScript -Platform $platform -Namespace $componentNamespace @extraArgs @promptArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "  ✗ $($c.DisplayName) installation failed — aborting"
            exit 1
        }
    }
    Start-Sleep -Seconds 1

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "  All installations complete!" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
}

Start-InfraInstallation
