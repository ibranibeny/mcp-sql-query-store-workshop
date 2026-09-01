[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $RunId,

    [Parameter(Mandatory)]
    [object] $Evidence,

    [Parameter()]
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [switch] $AllowReplaceCompletedRun,

    [Parameter(DontShow)]
    [scriptblock] $SemanticValidator
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Workshop.Workload.psd1') -Force

if ($PSCmdlet.ShouldProcess($RunId, 'Validate and export workshop evidence')) {
    $parameters = @{
        RunId = $RunId.ToString('D')
        Evidence = $Evidence
        RepositoryRoot = $RepositoryRoot
        AllowReplaceCompletedRun = $AllowReplaceCompletedRun
        Confirm = $false
    }
    if ($SemanticValidator) { $parameters.SemanticValidator = $SemanticValidator }
    Export-WorkshopEvidenceFile @parameters
}
