[CmdletBinding()]
param(
    [Parameter()]
    [string] $WheelhousePath,

    [Parameter()]
    [switch] $AllowPublicPackageIndex,

    [Parameter()]
    [switch] $AllowConfiguredPackageIndex,

    [Parameter()]
    [switch] $AllowPowerShellGallery,

    [Parameter()]
    [string] $PowerShellRepositoryName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-SanitizedProcessOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Output
    )

    foreach ($line in $Output) {
        $safeLine = $line.ToString() -replace '(?i)\b(?:https?|ftp)://[^\s''"]+', '[REDACTED-URL]'
        if (-not [string]::IsNullOrWhiteSpace($safeLine)) {
            Write-Host $safeLine
        }
    }
}

function Invoke-SanitizedNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter()]
        [string[]] $ArgumentList = @()
    )

    $commandOutput = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    Write-SanitizedProcessOutput -Output $commandOutput
    return $exitCode
}

function Resolve-SafeLocalDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'WheelhousePath must name an existing local directory.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path, (Get-Location).Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'WheelhousePath must name an existing local directory.'
    }

    $current = $root
    $relativePath = $fullPath.Substring($root.Length)
    foreach ($segment in $relativePath.Split(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.StringSplitOptions]::RemoveEmptyEntries
    )) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            throw 'WheelhousePath must name an existing local directory.'
        }

        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'WheelhousePath cannot traverse a symbolic link or reparse point.'
        }
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw 'WheelhousePath must name an existing local directory.'
    }

    return $fullPath
}

function Get-RepositoryPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $virtualEnvironment = Join-Path $RepositoryRoot '.venv'
    $virtualEnvironmentPython = Join-Path $virtualEnvironment 'Scripts/python.exe'
    if (Test-Path -LiteralPath $virtualEnvironmentPython -PathType Leaf) {
        return $virtualEnvironmentPython
    }

    $candidates = @(
        @{ Name = 'py'; Prefix = @('-3') },
        @{ Name = 'python'; Prefix = @() },
        @{ Name = 'python3'; Prefix = @() }
    )
    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate.Name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $command) {
            continue
        }

        $arguments = @($candidate.Prefix) + @('-m', 'venv', $virtualEnvironment)
        $exitCode = Invoke-SanitizedNativeCommand -FilePath $command.Source -ArgumentList $arguments
        if ($exitCode -eq 0 -and
            (Test-Path -LiteralPath $virtualEnvironmentPython -PathType Leaf)) {
            return $virtualEnvironmentPython
        }
    }

    throw 'Unable to create .venv using an available local Python installation. No network access was attempted.'
}

function Test-PythonDependencyRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PythonPath,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $verifier = Join-Path $RepositoryRoot 'build/Test-PythonDependencies.py'
    $requirements = Join-Path $RepositoryRoot 'requirements-dev.txt'
    $exitCode = Invoke-SanitizedNativeCommand -FilePath $PythonPath -ArgumentList @(
        $verifier, '--requirements', $requirements
    )
    if ($exitCode -eq 0) {
        return $true
    }
    if ($exitCode -eq 1) {
        return $false
    }

    throw "Python dependency verification failed (exit code $exitCode)."
}

function Invoke-PipInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PythonPath,

        [Parameter(Mandatory)]
        [string] $RequirementsPath,

        [Parameter()]
        [switch] $NoIndex,

        [Parameter()]
        [string] $FindLinks,

        [Parameter()]
        [switch] $UseConfiguredIndex
    )

    $arguments = @('-m', 'pip', 'install')
    if ($NoIndex) {
        $arguments += @('--no-index', '--find-links', $FindLinks)
    }
    $arguments += @('-r', $RequirementsPath)

    $configuredIndexUrl = if ($UseConfiguredIndex) { $env:PIP_INDEX_URL } else { $null }
    $environmentNames = @(
        'PIP_CONFIG_FILE',
        'PIP_DISABLE_PIP_VERSION_CHECK',
        'PIP_INDEX_URL',
        'PIP_EXTRA_INDEX_URL',
        'PIP_TRUSTED_HOST',
        'PIP_PROXY',
        'PIP_FIND_LINKS',
        'PIP_NO_INDEX'
    )
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        $nullDevice = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
            'NUL'
        }
        else {
            '/dev/null'
        }
        [Environment]::SetEnvironmentVariable('PIP_CONFIG_FILE', $nullDevice, 'Process')
        [Environment]::SetEnvironmentVariable('PIP_DISABLE_PIP_VERSION_CHECK', '1', 'Process')
        foreach ($name in @(
            'PIP_EXTRA_INDEX_URL',
            'PIP_TRUSTED_HOST',
            'PIP_PROXY',
            'PIP_FIND_LINKS'
        )) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }

        if ($UseConfiguredIndex) {
            [Environment]::SetEnvironmentVariable('PIP_INDEX_URL', $configuredIndexUrl, 'Process')
            [Environment]::SetEnvironmentVariable('PIP_NO_INDEX', $null, 'Process')
        }
        elseif ($NoIndex) {
            [Environment]::SetEnvironmentVariable('PIP_INDEX_URL', $null, 'Process')
            [Environment]::SetEnvironmentVariable('PIP_NO_INDEX', '1', 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable('PIP_INDEX_URL', $null, 'Process')
            [Environment]::SetEnvironmentVariable('PIP_NO_INDEX', $null, 'Process')
        }

        $exitCode = Invoke-SanitizedNativeCommand -FilePath $PythonPath -ArgumentList $arguments
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $previousEnvironment[$name],
                'Process'
            )
        }
    }
    if ($exitCode -ne 0) {
        throw "pip failed to install development dependencies (exit code $exitCode)."
    }
}

function Install-RequiredPowerShellModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [version] $MinimumVersion,

        [Parameter()]
        [switch] $AllowPowerShellGallery,

        [Parameter()]
        [string] $PowerShellRepositoryName
    )

    $installed = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -ne $installed -and $installed.Version -ge $MinimumVersion) {
        return
    }

    if ($PowerShellRepositoryName) {
        if ($PowerShellRepositoryName -ieq 'PSGallery') {
            throw 'Use -AllowPowerShellGallery to explicitly permit PSGallery.'
        }
        $repository = $PowerShellRepositoryName
        Write-Output "Installing $Name from explicitly selected PowerShell repository '$repository'."
    }
    elseif ($AllowPowerShellGallery) {
        $repository = 'PSGallery'
        Write-Output "Installing $Name from explicitly enabled PSGallery."
    }
    else {
        throw "PowerShell module '$Name' $MinimumVersion or newer is required. Preprovision it, explicitly use -AllowPowerShellGallery outside the corporate environment, or use -PowerShellRepositoryName for an internal repository."
    }

    Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber `
        -MinimumVersion $MinimumVersion -Repository $repository -ErrorAction Stop
}

function Invoke-DevDependencyInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter()]
        [string] $WheelhousePath,

        [Parameter()]
        [switch] $AllowPublicPackageIndex,

        [Parameter()]
        [switch] $AllowConfiguredPackageIndex,

        [Parameter()]
        [switch] $AllowPowerShellGallery,

        [Parameter()]
        [string] $PowerShellRepositoryName
    )

    $pythonSourceCount = @(
        [bool] $WheelhousePath,
        [bool] $AllowPublicPackageIndex,
        [bool] $AllowConfiguredPackageIndex
    ).Where({ $_ }).Count
    if ($pythonSourceCount -gt 1) {
        throw 'Choose only one Python dependency source: wheelhouse, public index, or configured index.'
    }
    if ($AllowPowerShellGallery -and $PowerShellRepositoryName) {
        throw 'Choose either -AllowPowerShellGallery or -PowerShellRepositoryName, not both.'
    }
    if ($AllowConfiguredPackageIndex -and [string]::IsNullOrWhiteSpace($env:PIP_INDEX_URL)) {
        throw '-AllowConfiguredPackageIndex requires PIP_INDEX_URL to be configured. The URL is intentionally not logged.'
    }

    $pythonPath = Get-RepositoryPython -RepositoryRoot $RepositoryRoot

    foreach ($module in @(
        @{ Name = 'Pester'; MinimumVersion = [version]'5.6.1' },
        @{ Name = 'PSScriptAnalyzer'; MinimumVersion = [version]'1.23.0' }
    )) {
        Install-RequiredPowerShellModule -Name $module.Name `
            -MinimumVersion $module.MinimumVersion `
            -AllowPowerShellGallery:$AllowPowerShellGallery `
            -PowerShellRepositoryName $PowerShellRepositoryName
    }

    if (Test-PythonDependencyRequirement -PythonPath $pythonPath -RepositoryRoot $RepositoryRoot) {
        Write-Output 'Python development dependencies already satisfy requirements-dev.txt; pip was not invoked.'
        return
    }

    $requirementsPath = Join-Path $RepositoryRoot 'requirements-dev.txt'
    if ($WheelhousePath) {
        $safeWheelhouse = Resolve-SafeLocalDirectory -Path $WheelhousePath
        Write-Output "Installing Python development dependencies from local wheelhouse '$safeWheelhouse'."
        Invoke-PipInstall -PythonPath $pythonPath -RequirementsPath $requirementsPath `
            -NoIndex -FindLinks $safeWheelhouse
    }
    elseif ($AllowPublicPackageIndex) {
        Write-Warning 'Public package network access was explicitly enabled for this run.'
        Invoke-PipInstall -PythonPath $pythonPath -RequirementsPath $requirementsPath
    }
    elseif ($AllowConfiguredPackageIndex) {
        Write-Output 'Installing from the explicitly enabled configured package index (URL redacted).'
        Invoke-PipInstall -PythonPath $pythonPath -RequirementsPath $requirementsPath `
            -UseConfiguredIndex
    }
    else {
        throw 'Python dependencies are missing or outside the required bounds. Use a preprovisioned environment, provide -WheelhousePath for a local/internal wheelhouse, or configure an internal PIP_INDEX_URL and explicitly use -AllowConfiguredPackageIndex. Public access requires the separate -AllowPublicPackageIndex opt-in outside the corporate environment.'
    }

    if (-not (Test-PythonDependencyRequirement -PythonPath $pythonPath -RepositoryRoot $RepositoryRoot)) {
        throw 'Python dependencies still do not satisfy requirements-dev.txt after installation.'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    Invoke-DevDependencyInstallation -RepositoryRoot $repositoryRoot @PSBoundParameters
}
