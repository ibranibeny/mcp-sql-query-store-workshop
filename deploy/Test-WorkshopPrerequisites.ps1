[CmdletBinding()]
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
    [datetime] $ExpiresOn,

    [switch] $WindowsClientLicenseAttested,

    [switch] $SqlEnterpriseCostAcknowledged
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'Workshop.Azure.psd1'
$configPath = Join-Path $PSScriptRoot 'WorkshopConfig.psd1'
Import-Module $modulePath -Force
$config = Import-PowerShellDataFile $configPath

$parameters = @{
    Config = $config
    SubscriptionId = $SubscriptionId
    FacilitatorCidr = $FacilitatorCidr
    ExpiresOn = $ExpiresOn
    WindowsClientLicenseAttested = $WindowsClientLicenseAttested.IsPresent
    SqlEnterpriseCostAcknowledged = $SqlEnterpriseCostAcknowledged.IsPresent
}
if ($PSBoundParameters.ContainsKey('TenantId')) {
    $parameters.TenantId = $TenantId
}

$result = Test-WorkshopPrerequisites @parameters
$result.Checks |
    Select-Object Name, Status, Detail, Remediation |
    Format-Table -AutoSize -Wrap |
    Out-String |
    Write-Output

if ($null -ne $result.Plan) {
    Format-WorkshopPlanCard -Plan $result.Plan | Write-Output
}
else {
    Write-Output 'Plan card unavailable until the facilitator CIDR is valid.'
}

if ($result.Passed) {
    exit 0
}
exit 1
