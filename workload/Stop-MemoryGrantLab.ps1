[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $RunId,

    [Parameter()]
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [string] $Server,

    [Parameter()]
    [string] $Database = 'AdventureWorks2022',

    [Parameter()]
    [pscredential] $Credential,

    [Parameter()]
    [string] $HostNameInCertificate = $Server,

    [Parameter(DontShow)]
    [System.Collections.IDictionary] $OperationSet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Workshop.Workload.psd1') -Force

$canonicalRunId = $RunId.ToString('D')
$runsRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'evidence/runs'))
$runDirectory = [IO.Path]::GetFullPath((Join-Path $runsRoot $canonicalRunId))
if (-not $runDirectory.StartsWith("$runsRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Run output path escapes evidence/runs.'
}

if ($PSCmdlet.ShouldProcess($canonicalRunId, 'Request stop and terminate exact tagged workshop sessions')) {
    [void] (New-Item -ItemType Directory -Path $runDirectory -Force)
    $item = Get-Item -LiteralPath $runDirectory -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Run output cannot be a reparse point or symbolic link.'
    }
    $temporary = Join-Path $runDirectory "stop.$([guid]::NewGuid().ToString('N')).tmp"
    $stopPath = Join-Path $runDirectory 'stop.request'
    try {
        [IO.File]::WriteAllText($temporary, $canonicalRunId, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $stopPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }

    $killed = @()
    if (-not $OperationSet) {
        if ([string]::IsNullOrWhiteSpace($Server) -or $null -eq $Credential) {
            throw 'Server and Credential are required unless a complete test OperationSet is injected.'
        }
        $OperationSet = Get-WorkshopSqlOperationSet -Server $Server -Database $Database `
            -Credential $Credential -HostNameInCertificate $HostNameInCertificate
    }
    if (-not $OperationSet.Contains('KillTagged') -or $OperationSet.KillTagged -isnot [scriptblock]) {
        throw 'OperationSet.KillTagged is required.'
    }
    # KillTagged captures session evidence before executing validated integer KILL statements.
    $killed = @(& $OperationSet.KillTagged $RunId)
    [pscustomobject]@{
        RunId = $canonicalRunId
        StopRequested = $true
        StopRequestPath = $stopPath
        KilledSessionIds = @($killed)
    }
}
