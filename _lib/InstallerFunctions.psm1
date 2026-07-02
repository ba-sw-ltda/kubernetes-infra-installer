<#
.SYNOPSIS
    Thin wrapper: re-exports the powershell-cluster-bootstrap submodule's tool
    installation, cluster connect, and cloud secret-writing functions.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "powershell-cluster-bootstrap\PowerShellClusterBootstrap.psd1") -Force -Verbose:$false

# Keep the project-local .tools\ convention (downloaded kubectl/helm/kind/plink
# binaries live next to this repo checkout) instead of the submodule's default
# shared %LOCALAPPDATA% cache.
Set-ClusterBootstrapToolsDir -Path (Join-Path $PSScriptRoot "..\.tools")

Export-ModuleMember -Function @(
  'Set-ClusterBootstrapToolsDir'
  'Test-CommandExists'
  'Get-Os'
  'Install-Kubectl'
  'Install-Helm'
  'Install-RancherCli'
  'Install-PlatformTools'
  'Update-HostsFile'
  'Reset-StuckHelmRelease'
  'Confirm-KubectlContext'
  'Get-AksIngressIp'
  'Get-EksIngressIp'
  'Get-IngressClass'
  'Initialize-AksCluster'
  'Initialize-EksCluster'
  'Initialize-GkeCluster'
  'Initialize-KindCluster'
  'Initialize-Rke2Cluster'
  'Initialize-ClusterEnvironment'
  'Set-ClusterContext'
  'Write-AzureKeyVaultSecret'
  'Write-AwsSecretsManagerSecret'
  'Write-GcpSecretManagerSecret'
  'Remove-AzureKeyVaultSecret'
  'Remove-AwsSecretsManagerSecret'
  'Remove-GcpSecretManagerSecret'
  'Test-AutheliaInstalled'
)
