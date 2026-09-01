[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $RunId,

    [Parameter()]
    [string] $Server,

    [Parameter()]
    [string] $Database = 'AdventureWorks2022',

    [Parameter()]
    [pscredential] $Credential,

    [Parameter()]
    [string] $HostNameInCertificate = $Server,

    [Parameter()]
    [ValidateRange(1, 4)]
    [int] $MaximumWorkers = 4,

    [Parameter()]
    [ValidateRange(60, 600)]
    [int] $MaximumDurationSeconds = 600,

    [Parameter()]
    [ValidateRange(5, 30)]
    [int] $SampleIntervalSeconds = 5,

    [Parameter()]
    [ValidateRange(20, 60)]
    [int] $WorkerRampSeconds = 20,

    [Parameter()]
    [ValidateRange(1, 60)]
    [int] $CommandTimeoutSeconds = 1,

    [Parameter()]
    [ValidateRange(0.10, 0.80)]
    [decimal] $BaselineCalibrationFraction = [decimal]'0.60',

    [Parameter(DontShow)]
    [System.Collections.IDictionary] $OperationSet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Workshop.Workload.psd1') -Force

if ($PSCmdlet.ShouldProcess($RunId, 'Start bounded memory-grant workshop lab')) {
    if (-not $OperationSet -and ([string]::IsNullOrWhiteSpace($Server) -or $null -eq $Credential)) {
        throw 'Server and Credential are required unless a complete test OperationSet is injected.'
    }
    $operationFactory = if ($OperationSet) { { $OperationSet }.GetNewClosure() } else { $null }
    Invoke-WorkshopStartup -RunId $RunId -Server $Server -Database $Database `
        -Credential $Credential -HostNameInCertificate $HostNameInCertificate `
        -OperationFactory $operationFactory `
        -MaximumWorkers $MaximumWorkers -MaximumDurationSeconds $MaximumDurationSeconds `
        -SampleIntervalSeconds $SampleIntervalSeconds -WorkerRampSeconds $WorkerRampSeconds `
        -CommandTimeoutSeconds $CommandTimeoutSeconds `
        -BaselineCalibrationFraction $BaselineCalibrationFraction
}
