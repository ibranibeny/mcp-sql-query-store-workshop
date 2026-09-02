[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [hashtable] $Operations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Workshop.Azure.psd1') -Force
$config = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'WorkshopConfig.psd1')

if (-not $PSCmdlet.ShouldProcess($config.ResourceGroupName, 'Start the approved workshop VMs that are not already running')) {
    return [pscustomobject][ordered]@{ Completed = $false; Checkpoint = @('ShouldProcess declined') }
}

$parameters = @{
    Config = $config
    SubscriptionId = $SubscriptionId
    Operations = $Operations
    Confirm = $false
}
if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
    $parameters.TenantId = $TenantId
}
Start-WorkshopEnvironment @parameters
