[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $FacilitatorCidr,

    [Parameter(Mandatory)]
    [PSCredential] $Credential,

    [Parameter(Mandatory)]
    [Security.SecureString] $DatabaseMasterKeyPassword,

    [Parameter(Mandatory)]
    [Security.SecureString] $McpReaderPassword,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://github\.com/[^/]+/[^/]+(?:\.git)?$')]
    [string] $RepositoryUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $RepositoryCommit,

    [Parameter(Mandatory)]
    [switch] $WindowsClientLicenseAttested,

    [ValidateNotNullOrEmpty()]
    [string] $ConfirmationPhrase,

    [hashtable] $Operations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq $Credential -or [string]::IsNullOrWhiteSpace($Credential.UserName) -or
    $Credential.Password.Length -eq 0) {
    throw 'A nonempty administrator credential is required before resuming.'
}
if ($DatabaseMasterKeyPassword.Length -eq 0 -or $McpReaderPassword.Length -eq 0) {
    throw 'Nonempty SecureString bootstrap secrets are required before resuming.'
}
if (-not $WindowsClientLicenseAttested.IsPresent) {
    throw 'Windows client license attestation is required before resuming.'
}

Import-Module (Join-Path $PSScriptRoot 'Workshop.Azure.psd1') -Force
$config = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'WorkshopConfig.psd1')

$normalizedRepositoryUrl = $RepositoryUrl -replace '\.git$', ''
if ($normalizedRepositoryUrl -cne $config.ApprovedRepositoryUrl) {
    throw "RepositoryUrl must identify the approved repository '$($config.ApprovedRepositoryUrl)'."
}

if ($null -eq $Operations) { $Operations = @{} }
$readGroup = if ($Operations.ContainsKey('GetResourceGroup')) {
    $Operations.GetResourceGroup
}
else {
    {
        param($Name)
        Set-AzContext -SubscriptionId $SubscriptionId -Tenant $TenantId -ErrorAction Stop | Out-Null
        Get-AzResourceGroup -Name $Name -ErrorAction Stop
    }.GetNewClosure()
}

# Resume is the inverse of deployment: it must refuse when there is nothing to resume.
$resourceGroup = & $readGroup $config.ResourceGroupName
if ($null -eq $resourceGroup) {
    throw "Resource group '$($config.ResourceGroupName)' does not exist. Use Deploy-WorkshopEnvironment.ps1 instead."
}
# The approved shape is compared against the recorded expiry, so reuse the deployed tag
# rather than asking the facilitator to remember it.
$existingExpiry = if ($null -ne $resourceGroup.Tags -and $resourceGroup.Tags.ContainsKey('expiresOn')) {
    [string] $resourceGroup.Tags['expiresOn']
}
else {
    ''
}
if ($existingExpiry -notmatch '^\d{4}-\d{2}-\d{2}$') {
    throw "Resource group '$($config.ResourceGroupName)' has no usable expiresOn tag to resume against."
}
$config.Tags.expiresOn = $existingExpiry

$requiredPhrase = "RESUME $($config.ResourceGroupName)"
if (-not $PSBoundParameters.ContainsKey('ConfirmationPhrase')) {
    $ConfirmationPhrase = Read-Host "Type '$requiredPhrase' to continue"
}
if ($ConfirmationPhrase -cne $requiredPhrase) {
    throw 'Resume confirmation phrase did not match exactly. No resources were changed.'
}

if (-not $PSCmdlet.ShouldProcess($config.ResourceGroupName, 'Resume bootstrap on the existing workshop environment')) {
    return [pscustomobject][ordered]@{ Completed = $false; Checkpoint = @('ShouldProcess declined') }
}

$networkParameters = @{ Config = $config; FacilitatorCidr = $FacilitatorCidr }
if ($Operations.ContainsKey('NetworkOperations')) {
    $networkParameters.Operations = $Operations.NetworkOperations
}
$network = New-WorkshopNetwork @networkParameters
if ($null -eq $network -or $network.Completed -isnot [bool] -or -not $network.Completed) {
    throw 'Network reconciliation stage did not complete.'
}
$boundary = Test-WorkshopNetworkBoundary @networkParameters
if (-not $boundary.Passed) {
    $failed = @($boundary.Checks | Where-Object Status -EQ 'Failed' | ForEach-Object Name)
    throw "Network boundary verification failed: $($failed -join ', ')."
}

$deploymentId = [guid]::NewGuid().ToString('D')
$sqlParameters = @{
    Config = $config
    AdministratorCredential = $Credential
    DatabaseMasterKeyPassword = $DatabaseMasterKeyPassword
    McpReaderPassword = $McpReaderPassword
    RepositoryUrl = $RepositoryUrl
    RepositoryCommit = $RepositoryCommit
    DeploymentId = $deploymentId
}
if ($Operations.ContainsKey('BootstrapOperations')) {
    $sqlParameters.Operations = $Operations.BootstrapOperations
}
$sqlBootstrap = Initialize-WorkshopSqlVm @sqlParameters
if ($null -eq $sqlBootstrap -or $sqlBootstrap.Completed -isnot [bool] -or -not $sqlBootstrap.Completed) {
    throw 'SQL VM bootstrap stage did not complete.'
}

$adminParameters = @{
    Config = $config
    McpReaderPassword = $McpReaderPassword
    RepositoryUrl = $RepositoryUrl
    RepositoryCommit = $RepositoryCommit
    DeploymentId = $deploymentId
    InteractiveUserName = $Credential.UserName
    WindowsClientLicenseAttested = $WindowsClientLicenseAttested.IsPresent
    SqlReadiness = $sqlBootstrap.Readiness
}
if ($Operations.ContainsKey('BootstrapOperations')) {
    $adminParameters.Operations = $Operations.BootstrapOperations
}
$adminBootstrap = Initialize-WorkshopAdminVm @adminParameters
if ($null -eq $adminBootstrap -or $adminBootstrap.Completed -isnot [bool] -or -not $adminBootstrap.Completed) {
    throw 'Administration VM bootstrap stage did not complete.'
}

$readiness = Test-WorkshopReadiness -SqlReadiness $sqlBootstrap.Readiness `
    -AdminReadiness $adminBootstrap.Readiness
if ($null -eq $readiness -or $readiness.Passed -isnot [bool] -or -not $readiness.Passed) {
    $failed = @($readiness.Checks | Where-Object Status -EQ 'Failed' | ForEach-Object Name)
    throw "End-to-end readiness verification failed: $($failed -join ', ')."
}

[pscustomobject][ordered]@{
    Completed = $true
    DeploymentId = $deploymentId
    Checkpoint = @(@($network.Checkpoint); @($sqlBootstrap.Checkpoint); @($adminBootstrap.Checkpoint))
    Boundary = $boundary
    Readiness = $readiness
}
