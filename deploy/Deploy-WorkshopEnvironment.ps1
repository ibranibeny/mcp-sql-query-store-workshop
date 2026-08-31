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

    [ValidateNotNullOrEmpty()]
    [string] $TimeZoneId = 'UTC',

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
        NewAdminVm = {
            param($Parameters)
            New-WorkshopAdminVm @Parameters
        }
        NewSqlVm = {
            param($Parameters)
            New-WorkshopSqlVm @Parameters
        }
        RegisterSqlIaas = {
            param($Parameters)
            Register-WorkshopSqlIaas @Parameters
        }
        SetAutoShutdown = {
            param($Parameters)
            Set-WorkshopAutoShutdown @Parameters
        }
        TestVmBoundary = {
            param($Parameters)
            Test-WorkshopVmBoundary @Parameters
        }
    }
}
foreach ($operationName in @(
    'SetContext', 'TestPrerequisites', 'NewNetwork', 'TestBoundary', 'NewAdminVm',
    'NewSqlVm', 'RegisterSqlIaas', 'SetAutoShutdown', 'TestVmBoundary'
)) {
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

if ($null -eq $preflight.ResolvedImages) {
    throw 'Preflight did not return both approved immutable image records. No Azure resources were created.'
}
foreach ($imageRequirement in @(
    @{ Role = 'Admin'; Expected = $config.AdminVm }
    @{ Role = 'Sql'; Expected = $config.SqlVm }
)) {
    $role = $imageRequirement.Role
    $resolvedImagesProperties = @($preflight.ResolvedImages.PSObject.Properties.Name)
    $record = if ($resolvedImagesProperties -contains $role) {
        $preflight.ResolvedImages.$role
    }
    else {
        $null
    }
    $recordProperties = if ($null -eq $record) { @() } else { @($record.PSObject.Properties.Name) }
    $expected = $imageRequirement.Expected
    $parsedVersion = $null
    $recordValid = $null -ne $record -and
        @('Publisher', 'Offer', 'Sku', 'Version' | Where-Object { $recordProperties -notcontains $_ }).Count -eq 0
    if ($recordValid) {
        $recordValid = $record.Publisher -is [string] -and $record.Publisher -ceq $expected.Publisher -and
            $record.Offer -is [string] -and $record.Offer -ceq $expected.Offer -and
            $record.Sku -is [string] -and $record.Sku -ceq $expected.Sku -and
            $record.Version -is [string] -and $record.Version -match '^\d+(\.\d+){2,3}$' -and
            [version]::TryParse($record.Version, [ref] $parsedVersion)
    }
    if (-not $recordValid) {
        throw "Preflight did not return the approved immutable image record for $role. No Azure resources were created."
    }
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
    if ($null -eq $network -or $network.PSObject.Properties.Name -notcontains 'Completed' -or
        $network.Completed -isnot [bool] -or -not $network.Completed) {
        throw 'Network deployment stage did not complete.'
    }
    $boundary = & $Operations.TestBoundary $networkParameters
    if (-not $boundary.Passed) {
        $failedChecks = @($boundary.Checks | Where-Object Status -EQ 'Failed' | ForEach-Object Name)
        throw "Network boundary verification failed: $($failedChecks -join ', ')."
    }
    $adminParameters = @{
        Config = $config
        ImageVersion = [string] $preflight.ResolvedImages.Admin.Version
        Credential = $Credential
        WindowsClientLicenseAttested = $WindowsClientLicenseAttested.IsPresent
    }
    if ($Operations.ContainsKey('VmOperations')) { $adminParameters.Operations = $Operations.VmOperations }
    $adminVm = & $Operations.NewAdminVm $adminParameters
    if ($null -eq $adminVm -or $adminVm.PSObject.Properties.Name -notcontains 'Completed' -or
        $adminVm.Completed -isnot [bool] -or -not $adminVm.Completed) {
        throw 'Administration VM deployment stage did not complete.'
    }

    $sqlParameters = @{
        Config = $config
        ImageVersion = [string] $preflight.ResolvedImages.Sql.Version
        Credential = $Credential
    }
    if ($Operations.ContainsKey('VmOperations')) { $sqlParameters.Operations = $Operations.VmOperations }
    $sqlVm = & $Operations.NewSqlVm $sqlParameters
    if ($null -eq $sqlVm -or $sqlVm.PSObject.Properties.Name -notcontains 'Completed' -or
        $sqlVm.Completed -isnot [bool] -or -not $sqlVm.Completed) {
        throw 'SQL VM deployment stage did not complete.'
    }

    $sqlIaasParameters = @{ Config = $config }
    $shutdownParameters = @{ Config = $config; TimeZoneId = $TimeZoneId }
    if ($Operations.ContainsKey('ServiceOperations')) {
        $sqlIaasParameters.Operations = $Operations.ServiceOperations
        $shutdownParameters.Operations = $Operations.ServiceOperations
    }
    $sqlIaas = & $Operations.RegisterSqlIaas $sqlIaasParameters
    if ($null -eq $sqlIaas -or $sqlIaas.PSObject.Properties.Name -notcontains 'Completed' -or
        $sqlIaas.Completed -isnot [bool] -or -not $sqlIaas.Completed) {
        throw 'SQL IaaS registration stage did not complete.'
    }
    $shutdown = & $Operations.SetAutoShutdown $shutdownParameters
    if ($null -eq $shutdown -or $shutdown.PSObject.Properties.Name -notcontains 'Completed' -or
        $shutdown.Completed -isnot [bool] -or -not $shutdown.Completed) {
        throw 'Auto-shutdown configuration stage did not complete.'
    }

    $vmBoundaryParameters = @{
        Config = $config
        ResolvedImages = @{
            Admin = $preflight.ResolvedImages.Admin
            Sql = $preflight.ResolvedImages.Sql
        }
    }
    if ($Operations.ContainsKey('VmOperations')) { $vmBoundaryParameters.Operations = $Operations.VmOperations }
    $vmBoundary = & $Operations.TestVmBoundary $vmBoundaryParameters
    if (-not $vmBoundary.Passed) {
        $failedChecks = @($vmBoundary.Checks | Where-Object Status -EQ 'Failed' | ForEach-Object Name)
        throw "VM boundary verification failed: $($failedChecks -join ', ')."
    }
    $checkpoint = @(
        @($network.Checkpoint)
        @($adminVm.Checkpoint)
        @($sqlVm.Checkpoint)
        @($sqlIaas.Checkpoint)
        @($shutdown.Checkpoint)
    )
    [pscustomobject][ordered]@{
        Completed = $true
        Checkpoint = $checkpoint
        Boundary = $boundary
        VmBoundary = $vmBoundary
    }
}
catch {
    $safeMessage = [regex]::Replace([string] $_.Exception.Message, '[\x00-\x1F\x7F]+', ' ')
    throw "$safeMessage No automatic rollback was attempted. Review the network checkpoint and remediate the partial deployment before resuming."
}
