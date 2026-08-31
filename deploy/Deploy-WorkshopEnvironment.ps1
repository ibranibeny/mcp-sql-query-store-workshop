[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [ValidateNotNullOrEmpty()]
    [string] $FacilitatorCidr,

    [Nullable[datetime]] $ExpiresOn,

    [Parameter(Mandatory)]
    [PSCredential] $Credential,

    [Parameter(Mandatory)]
    [switch] $WindowsClientLicenseAttested,

    [Parameter(Mandatory)]
    [switch] $SqlEnterpriseCostAcknowledged,

    [Parameter(Mandatory)]
    [switch] $BillableResourcesAcknowledged,

    [Parameter(Mandatory)]
    [switch] $ApproveBillableDeployment,

    [ValidateNotNullOrEmpty()]
    [string] $ConfirmationPhrase,

    [hashtable] $Operations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq $Credential -or [string]::IsNullOrWhiteSpace($Credential.UserName)) {
    throw 'A nonempty administrator credential is required before deployment can continue.'
}
if ($Credential.Password -isnot [Security.SecureString] -or $Credential.Password.Length -eq 0) {
    throw 'A nonempty SecureString password is required before deployment can continue.'
}

$modulePath = Join-Path $PSScriptRoot 'Workshop.Azure.psd1'
$configPath = Join-Path $PSScriptRoot 'WorkshopConfig.psd1'
Import-Module $modulePath -Force
$config = Import-PowerShellDataFile $configPath

if (-not $WindowsClientLicenseAttested.IsPresent -or
    -not $SqlEnterpriseCostAcknowledged.IsPresent -or
    -not $BillableResourcesAcknowledged.IsPresent -or
    -not $ApproveBillableDeployment.IsPresent) {
    throw 'All three acknowledgements and ApproveBillableDeployment are required before selecting an Azure target.'
}

if ([string]::IsNullOrWhiteSpace($FacilitatorCidr)) {
    $FacilitatorCidr = Read-Host 'Enter the facilitator public IPv4 host CIDR (/32)'
}
if ($null -eq $ExpiresOn) {
    $expirationText = Read-Host 'Enter the expiration date (yyyy-MM-dd, within seven days)'
    $parsedExpiration = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
            $expirationText,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref] $parsedExpiration)) {
        throw 'Expiration date must use yyyy-MM-dd format.'
    }
    $ExpiresOn = $parsedExpiration
}

if ($null -eq $Operations) {
    $Operations = @{
        SetContext = {
            param($TargetSubscriptionId, $TargetTenantId)
            $contextParameters = @{
                SubscriptionId = $TargetSubscriptionId
                ErrorAction = 'Stop'
            }
            if (-not [string]::IsNullOrWhiteSpace($TargetTenantId)) {
                $contextParameters.Tenant = $TargetTenantId
            }
            Set-AzContext @contextParameters
        }
        TestPrerequisites = {
            param($Parameters)
            Test-WorkshopPrerequisites @Parameters
        }
        NewNetwork = {
            param($Parameters)
            New-WorkshopNetwork @Parameters
        }
        TestBoundary = {
            param($Parameters)
            Test-WorkshopNetworkBoundary @Parameters
        }
    }
}
foreach ($operationName in @('SetContext', 'TestPrerequisites', 'NewNetwork', 'TestBoundary')) {
    if (-not $Operations.ContainsKey($operationName) -or $Operations[$operationName] -isnot [scriptblock]) {
        throw "Operations must provide scriptblock '$operationName'."
    }
}

$null = & $Operations.SetContext $SubscriptionId $TenantId

$preflightParameters = @{
    Config = $config
    SubscriptionId = $SubscriptionId
    FacilitatorCidr = $FacilitatorCidr
    ExpiresOn = [datetime] $ExpiresOn
    WindowsClientLicenseAttested = $WindowsClientLicenseAttested.IsPresent
    SqlEnterpriseCostAcknowledged = $SqlEnterpriseCostAcknowledged.IsPresent
    BillableResourcesAcknowledged = $BillableResourcesAcknowledged.IsPresent
}
if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
    $preflightParameters.TenantId = $TenantId
}
if ($Operations.ContainsKey('PreflightOperations')) {
    $preflightParameters.Operations = $Operations.PreflightOperations
}
$preflight = & $Operations.TestPrerequisites $preflightParameters
$preflight.Checks |
    Select-Object Name, Status, Detail, Remediation |
    Format-Table -AutoSize -Wrap |
    Out-String |
    Write-Output
if ($null -ne $preflight.Plan) {
    Format-WorkshopPlanCard -Plan $preflight.Plan | Write-Output
}
if (-not $preflight.Passed) {
    throw 'Workshop prerequisite validation failed. No Azure resources were created.'
}

$requiredPhrase = 'DEPLOY rg-mcp-sql-workshop'
if (-not $PSBoundParameters.ContainsKey('ConfirmationPhrase')) {
    $ConfirmationPhrase = Read-Host "Type '$requiredPhrase' to continue"
}
if ($ConfirmationPhrase -cne $requiredPhrase) {
    throw 'Deployment confirmation phrase did not match exactly. No Azure resources were created.'
}

if (-not $PSCmdlet.ShouldProcess($config.ResourceGroupName, 'Create the approved billable workshop network')) {
    return [pscustomobject][ordered]@{
        Completed = $false
        Checkpoint = @('Preflight passed', 'Confirmation phrase matched', 'ShouldProcess declined')
        Remediation = 'Rerun without WhatIf and approve ShouldProcess only when billable deployment is intended.'
    }
}

$config.Tags.expiresOn = ([datetime] $ExpiresOn).Date.ToString(
    'yyyy-MM-dd',
    [System.Globalization.CultureInfo]::InvariantCulture
)
$networkParameters = @{
    Config = $config
    FacilitatorCidr = $FacilitatorCidr
}
if ($Operations.ContainsKey('NetworkOperations')) {
    $networkParameters.Operations = $Operations.NetworkOperations
}
try {
    $network = & $Operations.NewNetwork $networkParameters
    $boundary = & $Operations.TestBoundary $networkParameters
    if (-not $boundary.Passed) {
        $failedChecks = @($boundary.Checks | Where-Object Status -EQ 'Failed' | ForEach-Object Name)
        throw "Network boundary verification failed: $($failedChecks -join ', ')."
    }
    [pscustomobject][ordered]@{
        Completed = $true
        Checkpoint = $network.Checkpoint
        Boundary = $boundary
    }
}
catch {
    $safeMessage = [regex]::Replace([string] $_.Exception.Message, '[\x00-\x1F\x7F]+', ' ')
    throw "$safeMessage No automatic rollback was attempted. Review the network checkpoint and remediate the partial deployment before resuming."
}
