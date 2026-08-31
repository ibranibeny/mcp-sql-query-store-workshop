[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot

foreach ($module in @(
    @{ Name = 'Pester'; MinimumVersion = [version]'5.6.1' },
    @{ Name = 'PSScriptAnalyzer'; MinimumVersion = [version]'1.23.0' }
)) {
    $installed = Get-Module -ListAvailable -Name $module.Name |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $installed -or $installed.Version -lt $module.MinimumVersion) {
        Install-Module -Name $module.Name -Scope CurrentUser -Force -AllowClobber -MinimumVersion $module.MinimumVersion
    }
}

$virtualEnvironment = Join-Path $repositoryRoot '.venv'
$virtualEnvironmentPython = Join-Path $virtualEnvironment 'Scripts/python.exe'

if (-not (Test-Path -LiteralPath $virtualEnvironmentPython -PathType Leaf)) {
    & python -m venv $virtualEnvironment
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the Python virtual environment (exit code $LASTEXITCODE)."
    }
}

& $virtualEnvironmentPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upgrade pip (exit code $LASTEXITCODE)."
}

& $virtualEnvironmentPython -m pip install -r (Join-Path $repositoryRoot 'requirements-dev.txt')
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install Python development dependencies (exit code $LASTEXITCODE)."
}
