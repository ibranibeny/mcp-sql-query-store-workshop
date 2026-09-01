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
$canonicalRepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$evidenceRoot = [IO.Path]::GetFullPath((Join-Path $canonicalRepositoryRoot 'evidence'))
$runsRoot = [IO.Path]::GetFullPath((Join-Path $evidenceRoot 'runs'))
$runDirectory = [IO.Path]::GetFullPath((Join-Path $runsRoot $canonicalRunId))
$stopPath = [IO.Path]::GetFullPath((Join-Path $runDirectory 'stop.request'))
$evidencePrefix = "$($evidenceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))$([IO.Path]::DirectorySeparatorChar)"
$repositoryPrefix = "$($canonicalRepositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))$([IO.Path]::DirectorySeparatorChar)"
if (-not $evidenceRoot.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not $runsRoot.StartsWith($evidencePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not $runDirectory.StartsWith("$runsRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) -or
    -not $stopPath.StartsWith("$runDirectory$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Run output path escapes evidence/runs.'
}

$assertSafeEvidencePath = {
    param([string[]] $Paths)

    foreach ($path in $Paths) {
        $canonicalPath = [IO.Path]::GetFullPath($path)
        if ($canonicalPath -ne $canonicalRepositoryRoot -and
            $canonicalPath -ne $evidenceRoot -and
            -not $canonicalPath.StartsWith($evidencePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The canonical stop request path escapes the intended evidence root.'
        }
        if (-not (Test-Path -LiteralPath $canonicalPath)) { continue }

        $item = Get-Item -LiteralPath $canonicalPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Stop request paths and ancestors cannot be symbolic links, junctions, mount points, or reparse points.'
        }
        $resolvedPath = [IO.Path]::GetFullPath($item.FullName)
        if ($resolvedPath -ne $canonicalPath -or
            $resolvedPath -ne $canonicalRepositoryRoot -and
            $resolvedPath -ne $evidenceRoot -and
            -not $resolvedPath.StartsWith($evidencePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The resolved stop request path escapes the intended evidence root.'
        }
    }
}.GetNewClosure()
$evidencePaths = @($canonicalRepositoryRoot, $evidenceRoot, $runsRoot, $runDirectory, $stopPath)
& $assertSafeEvidencePath $evidencePaths

if ($PSCmdlet.ShouldProcess($canonicalRunId, 'Request stop and terminate exact tagged workshop sessions')) {
    [void] (New-Item -ItemType Directory -Path $runDirectory -Force)
    & $assertSafeEvidencePath $evidencePaths
    $temporary = Join-Path $runDirectory "stop.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $canonicalRunId, [Text.UTF8Encoding]::new($false))
        & $assertSafeEvidencePath ($evidencePaths + $temporary)
        [IO.File]::Move($temporary, $stopPath, $true)
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
