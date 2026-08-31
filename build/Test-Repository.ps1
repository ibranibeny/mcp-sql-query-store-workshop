[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:GateFailures = [System.Collections.Generic.List[string]]::new()

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

    $output = & git -C $script:RepositoryRoot @ArgumentList 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git failed while enumerating repository files (exit code $LASTEXITCODE)."
    }

    return @($output | ForEach-Object { $_.ToString() } | Where-Object { $_ })
}

function Get-PowerShellFile {
    $relativePaths = Get-GitFile -ArgumentList @(
        'ls-files', '--cached', '--others', '--exclude-standard', '--',
        '*.ps1', '*.psm1', '*.psd1'
    )

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
    if (-not $analyzer) {
        throw 'PSScriptAnalyzer is not installed. Run build/Install-DevDependencies.ps1.'
    }

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
    $excludedDirectoryPattern = '(^|/)(\.git|\.worktrees|\.venv|site)(/|$)'
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($path in Get-ChildItem -LiteralPath $script:RepositoryRoot -Filter '*.json' -File -Recurse) {
        $relativePath = [System.IO.Path]::GetRelativePath($script:RepositoryRoot, $path.FullName).Replace('\', '/')
        if ($relativePath -match $excludedDirectoryPattern) {
            continue
        }

        try {
            [void] (Get-Content -LiteralPath $path.FullName -Raw | ConvertFrom-Json -ErrorAction Stop)
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
    $trackedFiles = Get-GitFile -ArgumentList @('ls-files')
    $privateKeyPattern = '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
    $passwordPattern = '(?i)(?:password|pwd)\s*=\s*(?!(?:WORKSHOP-PLACEHOLDER|SET_LOCALLY_ON_ADMIN_VM)(?:[;\r\n]|$))[^;\r\n\s][^;\r\n]*'
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

        if ($content -match $privateKeyPattern) {
            $findings.Add("$relativePath contains a private-key marker")
        }
        if ($content -match $passwordPattern) {
            $findings.Add("$relativePath contains a likely password-bearing connection string")
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
    Invoke-NativeCommand -FilePath 'git' -ArgumentList @(
        '-C', $script:RepositoryRoot, 'diff', '--check'
    )
    Invoke-NativeCommand -FilePath 'git' -ArgumentList @(
        '-C', $script:RepositoryRoot, 'diff', '--cached', '--check'
    )
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

Push-Location $script:RepositoryRoot
try {
    Invoke-ValidationGate -Name 'Python tests' -Validation { Test-Python }
    Invoke-ValidationGate -Name 'PowerShell syntax' -Validation { Test-PowerShellSyntax }
    Invoke-ValidationGate -Name 'PSScriptAnalyzer' -Validation { Test-PowerShellAnalysis }
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

Write-Host 'Repository validation passed.'
