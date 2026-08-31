[CmdletBinding()]
param(
    [Parameter()]
    [string] $BaseRef,

    [Parameter()]
    [switch] $RequirePSScriptAnalyzer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:GateFailures = [System.Collections.Generic.List[string]]::new()
$script:OptionalGateSkips = 0
$script:RequestedBaseRef = $BaseRef
$script:AnalyzerIsRequired = [bool] $RequirePSScriptAnalyzer

Import-Module (Join-Path $PSScriptRoot 'RepositoryValidation.psm1') -Force

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter()]
        [string[]] $ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Native command '$FilePath' failed with exit code $LASTEXITCODE."
    }
}

function Get-GitFile {
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList
    )

    return @(Get-RepositoryFile -RepositoryRoot $script:RepositoryRoot -PathSpec $ArgumentList)
}

function Get-PowerShellFile {
    $relativePaths = Get-GitFile -ArgumentList @('*.ps1', '*.psm1', '*.psd1')

    return @($relativePaths | ForEach-Object { Join-Path $script:RepositoryRoot $_ })
}

function Test-Python {
    $virtualEnvironmentPython = Join-Path $script:RepositoryRoot '.venv/Scripts/python.exe'
    $python = if (Test-Path -LiteralPath $virtualEnvironmentPython -PathType Leaf) {
        $virtualEnvironmentPython
    }
    else {
        (Get-Command python -ErrorAction Stop).Source
    }

    Invoke-NativeCommand -FilePath $python -ArgumentList @(
        '-m', 'pytest', (Join-Path $script:RepositoryRoot 'tests')
    )
}

function Test-Pester {
    $testPath = Join-Path $script:RepositoryRoot 'tests'
    $result = Invoke-Pester -Path $testPath -PassThru
    if ($result.FailedCount -gt 0) {
        throw "Pester reported $($result.FailedCount) failed test(s)."
    }
}

function Test-PowerShellSyntax {
    $parseErrors = [System.Collections.Generic.List[string]]::new()

    foreach ($path in Get-PowerShellFile) {
        $tokens = $null
        $errors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref] $tokens,
            [ref] $errors
        )

        foreach ($parseError in $errors) {
            $relativePath = [System.IO.Path]::GetRelativePath($script:RepositoryRoot, $path)
            $parseErrors.Add("${relativePath}:$($parseError.Extent.StartLineNumber): $($parseError.Message)")
        }
    }

    if ($parseErrors.Count -gt 0) {
        throw "PowerShell parse errors:`n$($parseErrors -join [Environment]::NewLine)"
    }
}

function Test-PowerShellAnalysis {
    $analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer |
        Sort-Object Version -Descending |
        Select-Object -First 1
    Import-Module $analyzer.Path -Force
    $settings = Join-Path $script:RepositoryRoot 'PSScriptAnalyzerSettings.psd1'
    $findings = @(
        foreach ($path in Get-PowerShellFile) {
            Invoke-ScriptAnalyzer -Path $path -Settings $settings
        }
    )
    if ($findings.Count -gt 0) {
        $summary = $findings | ForEach-Object {
            $relativePath = [System.IO.Path]::GetRelativePath($script:RepositoryRoot, $_.ScriptPath)
            "${relativePath}:$($_.Line): [$($_.Severity)] $($_.RuleName): $($_.Message)"
        }
        throw "PSScriptAnalyzer findings:`n$($summary -join [Environment]::NewLine)"
    }

}

function Test-JsonFile {
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($relativePath in Get-RepositoryJsonFile -RepositoryRoot $script:RepositoryRoot) {
        $path = Join-Path $script:RepositoryRoot $relativePath
        try {
            [void] (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            $errors.Add("$relativePath is invalid JSON: $($_.Exception.Message)")
        }
    }

    if ($errors.Count -gt 0) {
        throw ($errors -join [Environment]::NewLine)
    }
}

function Test-TrackedFileForSecret {
    $trackedFiles = Get-RepositoryFile -RepositoryRoot $script:RepositoryRoot
    $findings = [System.Collections.Generic.List[string]]::new()

    foreach ($relativePath in $trackedFiles) {
        $path = Join-Path $script:RepositoryRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        try {
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        }
        catch {
            continue
        }

        foreach ($finding in Find-RepositorySecret -Path $relativePath -Content $content) {
            $findings.Add("$($finding.Path):$($finding.Line): $($finding.Type)")
        }
    }

    if ($findings.Count -gt 0) {
        throw ($findings -join [Environment]::NewLine)
    }
}

function Test-SiteBuild {
    $siteBuilder = Join-Path $script:RepositoryRoot 'web/build_site.py'
    if (-not (Test-Path -LiteralPath $siteBuilder -PathType Leaf)) {
        return
    }

    $virtualEnvironmentPython = Join-Path $script:RepositoryRoot '.venv/Scripts/python.exe'
    $python = if (Test-Path -LiteralPath $virtualEnvironmentPython -PathType Leaf) {
        $virtualEnvironmentPython
    }
    else {
        (Get-Command python -ErrorAction Stop).Source
    }
    Invoke-NativeCommand -FilePath $python -ArgumentList @($siteBuilder)
}

function Test-GitDiff {
    Test-RepositoryWhitespace -RepositoryRoot $script:RepositoryRoot -BaseRef $script:RequestedBaseRef
}

function Invoke-ValidationGate {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [scriptblock] $Validation
    )

    try {
        & $Validation
        Write-Host "PASS: $Name"
    }
    catch {
        $script:GateFailures.Add("${Name}: $($_.Exception.Message)")
        Write-Warning "FAIL: $Name"
    }
}

function Invoke-PowerShellAnalyzerGate {
    $available = $null -ne (Get-Module -ListAvailable -Name PSScriptAnalyzer |
        Sort-Object Version -Descending |
        Select-Object -First 1)
    $gateResult = Get-PSScriptAnalyzerGateResult -AnalyzerAvailable $available `
        -Required:$script:AnalyzerIsRequired

    if ($gateResult.Failed) {
        $script:GateFailures.Add("PSScriptAnalyzer: $($gateResult.Message)")
        Write-Warning 'FAIL: PSScriptAnalyzer'
    }
    elseif ($gateResult.Skipped) {
        $script:OptionalGateSkips++
        Write-Host $gateResult.Message
    }
    else {
        Invoke-ValidationGate -Name 'PSScriptAnalyzer' -Validation { Test-PowerShellAnalysis }
    }
}

Push-Location $script:RepositoryRoot
try {
    Invoke-ValidationGate -Name 'Python tests' -Validation { Test-Python }
    Invoke-ValidationGate -Name 'Pester tests' -Validation { Test-Pester }
    Invoke-ValidationGate -Name 'PowerShell syntax' -Validation { Test-PowerShellSyntax }
    Invoke-PowerShellAnalyzerGate
    Invoke-ValidationGate -Name 'JSON parsing' -Validation { Test-JsonFile }
    Invoke-ValidationGate -Name 'Tracked-file secret scan' -Validation { Test-TrackedFileForSecret }
    Invoke-ValidationGate -Name 'Static site build' -Validation { Test-SiteBuild }
    Invoke-ValidationGate -Name 'Git whitespace check' -Validation { Test-GitDiff }
}
finally {
    Pop-Location
}

if ($script:GateFailures.Count -gt 0) {
    $failureReport = $script:GateFailures -join [Environment]::NewLine
    throw "Repository validation failed:`n$failureReport"
}

if ($script:OptionalGateSkips -gt 0) {
    Write-Host 'Repository validation passed with an optional gate skipped.'
}
else {
    Write-Host 'Repository validation passed.'
}
