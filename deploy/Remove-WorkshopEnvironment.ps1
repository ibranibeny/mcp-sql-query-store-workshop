[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ConfirmationPhrase,

    [ValidateRange(1, 100)]
    [int] $MaximumAttempts = 40,

    [hashtable] $Operations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredPhrase = 'DELETE rg-mcp-sql-workshop'
if ($ConfirmationPhrase -cne $requiredPhrase) {
    throw "Removal confirmation phrase must be exactly '$requiredPhrase'."
}

Import-Module (Join-Path $PSScriptRoot 'Workshop.Azure.psd1') -Force
$config = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'WorkshopConfig.psd1')

if (-not $PSCmdlet.ShouldProcess($config.ResourceGroupName, 'Permanently remove the tagged workshop resource group')) {
    return [pscustomobject][ordered]@{ Completed = $false; Checkpoint = @('ShouldProcess declined') }
}

$parameters = @{
    Config = $config
    SubscriptionId = $SubscriptionId
    ConfirmationPhrase = $ConfirmationPhrase
    MaximumAttempts = $MaximumAttempts
    Operations = $Operations
    Confirm = $false
}
if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
    $parameters.TenantId = $TenantId
}
Remove-WorkshopEnvironment @parameters
