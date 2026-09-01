Set-StrictMode -Version Latest

BeforeAll {
    $script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:InstallerPath = Join-Path $script:RepositoryRoot 'build/Install-DevDependencies.ps1'
    $script:InstallerText = Get-Content -LiteralPath $script:InstallerPath -Raw

    if ($script:InstallerText -notmatch "InvocationName\s+-ne\s+'\.'") {
        throw 'Installer is not safe to dot-source for isolated unit tests.'
    }
    . $script:InstallerPath
}

Describe 'Offline development dependency installer contract' {
    It 'has explicit package and PowerShell repository opt-ins' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:InstallerPath,
            [ref] $tokens,
            [ref] $errors
        )

        $errors | Should -HaveCount 0
        $parameterNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        $parameterNames | Should -Contain 'WheelhousePath'
        $parameterNames | Should -Contain 'AllowPublicPackageIndex'
        $parameterNames | Should -Contain 'AllowConfiguredPackageIndex'
        $parameterNames | Should -Contain 'AllowPowerShellGallery'
        $parameterNames | Should -Contain 'PowerShellRepositoryName'
    }

    It 'contains no pip self-upgrade or unconditional public install' {
        $script:InstallerText | Should -Not -Match '(?i)pip\s+install\s+--upgrade\s+pip'
        $script:InstallerText | Should -Match 'Test-PythonDependencies\.py'
        $script:InstallerText | Should -Match '--no-index'
        $script:InstallerText | Should -Match '--find-links'
    }
}

Describe 'Offline development dependency installer behavior' {
    It 'returns only the native exit code when the verifier emits status lines' {
        $python = Join-Path $script:RepositoryRoot '.venv/Scripts/python.exe'

        $result = Invoke-SanitizedNativeCommand -FilePath $python -ArgumentList @(
            '-c', "print('Demo | required: >=1,<2 | detected: 1.5 | status: satisfied')"
        )

        $result | Should -BeOfType ([int])
        $result | Should -Be 0
    }

    BeforeEach {
        if ($null -eq (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
            Set-Alias -Name Install-Module -Value Write-Output -Scope Script
        }
        Mock Get-Module {
            [pscustomobject]@{ Name = $Name; Version = [version]'99.0'; Path = 'test-only' }
        }
        Mock Install-Module { throw 'Install-Module must not be reached by default.' }
        Mock Get-RepositoryPython { 'C:\test\.venv\Scripts\python.exe' }
        Mock Invoke-PipInstall { throw 'pip must not be reached by default.' }
    }

    It 'does not invoke pip or Install-Module when everything is already satisfied' {
        Mock Test-PythonDependencyRequirement { $true }

        Invoke-DevDependencyInstallation -RepositoryRoot $script:RepositoryRoot

        Should -Invoke Invoke-PipInstall -Times 0 -Exactly
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'fails with corporate guidance when dependencies are missing and no source is opted in' {
        Mock Test-PythonDependencyRequirement { $false }

        { Invoke-DevDependencyInstallation -RepositoryRoot $script:RepositoryRoot } |
            Should -Throw '*preprovisioned*wheelhouse*AllowConfiguredPackageIndex*'
        Should -Invoke Invoke-PipInstall -Times 0 -Exactly
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'uses only no-index and find-links for an explicitly supplied wheelhouse' {
        $wheelhouse = Join-Path $TestDrive 'wheelhouse'
        [void] (New-Item -ItemType Directory -Path $wheelhouse)
        $script:VerificationCalls = 0
        Mock Test-PythonDependencyRequirement {
            $script:VerificationCalls++
            return $script:VerificationCalls -gt 1
        }
        Mock Invoke-PipInstall {}

        Invoke-DevDependencyInstallation -RepositoryRoot $script:RepositoryRoot `
            -WheelhousePath $wheelhouse

        Should -Invoke Invoke-PipInstall -Times 1 -Exactly -ParameterFilter {
            $NoIndex -and $FindLinks -eq [System.IO.Path]::GetFullPath($wheelhouse) -and
            -not $UsePublicIndex -and -not $UseConfiguredIndex
        }
    }

    It 'uses the public package index only after the explicit public opt-in' {
        $script:VerificationCalls = 0
        Mock Test-PythonDependencyRequirement {
            $script:VerificationCalls++
            return $script:VerificationCalls -gt 1
        }
        Mock Invoke-PipInstall {}

        Invoke-DevDependencyInstallation -RepositoryRoot $script:RepositoryRoot `
            -AllowPublicPackageIndex

        Should -Invoke Invoke-PipInstall -Times 1 -Exactly -ParameterFilter {
            $UsePublicIndex -and -not $UseConfiguredIndex -and -not $NoIndex
        }
    }

    It 'uses an environment-configured index only after its separate explicit opt-in' {
        $previousIndex = $env:PIP_INDEX_URL
        try {
            $env:PIP_INDEX_URL = 'https://internal.invalid/simple'
            $script:VerificationCalls = 0
            Mock Test-PythonDependencyRequirement {
                $script:VerificationCalls++
                return $script:VerificationCalls -gt 1
            }
            Mock Invoke-PipInstall {}

            Invoke-DevDependencyInstallation -RepositoryRoot $script:RepositoryRoot `
                -AllowConfiguredPackageIndex

            Should -Invoke Invoke-PipInstall -Times 1 -Exactly -ParameterFilter {
                $UseConfiguredIndex -and -not $UsePublicIndex -and -not $NoIndex
            }
        }
        finally {
            $env:PIP_INDEX_URL = $previousIndex
        }
    }

    It 'does not install a missing PowerShell module without an explicit repository route' {
        Mock Get-Module { $null }
        Mock Test-PythonDependencyRequirement { $true }

        { Invoke-DevDependencyInstallation -RepositoryRoot $script:RepositoryRoot } |
            Should -Throw '*AllowPowerShellGallery*PowerShellRepositoryName*'
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Invoke-PipInstall -Times 0 -Exactly
    }

    It 'uses an explicitly named internal PowerShell repository' {
        Mock Get-Module { $null }
        Mock Install-Module {}
        Mock Test-PythonDependencyRequirement { $true }

        Invoke-DevDependencyInstallation -RepositoryRoot $script:RepositoryRoot `
            -PowerShellRepositoryName 'CorporatePS'

        Should -Invoke Install-Module -Times 2 -Exactly -ParameterFilter {
            $Repository -eq 'CorporatePS'
        }
        Should -Invoke Invoke-PipInstall -Times 0 -Exactly
    }

    It 'uses PSGallery only after the explicit gallery opt-in' {
        Mock Get-Module { $null }
        Mock Install-Module {}
        Mock Test-PythonDependencyRequirement { $true }

        Invoke-DevDependencyInstallation -RepositoryRoot $script:RepositoryRoot `
            -AllowPowerShellGallery

        Should -Invoke Install-Module -Times 2 -Exactly -ParameterFilter {
            $Repository -eq 'PSGallery'
        }
        Should -Invoke Invoke-PipInstall -Times 0 -Exactly
    }
}

Describe 'Configured Python index process isolation' {
    It 'isolates the configured index from extra indexes and pip configuration' {
        $previousIndex = $env:PIP_INDEX_URL
        $previousExtraIndex = $env:PIP_EXTRA_INDEX_URL
        try {
            $env:PIP_INDEX_URL = 'https://internal.invalid/simple'
            $env:PIP_EXTRA_INDEX_URL = 'https://must-not-be-used.invalid/simple'
            $script:NativeArguments = @()
            Mock Invoke-SanitizedNativeCommand {
                $script:NativeArguments = @($ArgumentList)
                $script:NativePipConfig = $env:PIP_CONFIG_FILE
                return 0
            }

            Invoke-PipInstall -PythonPath 'python.exe' -RequirementsPath 'requirements-dev.txt' `
                -UseConfiguredIndex

            $script:NativeArguments | Should -Contain '--isolated'
            $script:NativeArguments | Should -Contain '--index-url'
            $script:NativeArguments | Should -Contain $env:PIP_INDEX_URL
            $script:NativeArguments | Should -Not -Contain $env:PIP_EXTRA_INDEX_URL
            $script:NativePipConfig | Should -Be 'NUL'
        }
        finally {
            $env:PIP_INDEX_URL = $previousIndex
            $env:PIP_EXTRA_INDEX_URL = $previousExtraIndex
        }
    }
}

Describe 'Local wheelhouse path safety' {
    It 'rejects a reparse-point ancestor before pip can run' {
        $ancestor = Join-Path $TestDrive 'linked-parent'
        $wheelhouse = Join-Path $ancestor 'wheelhouse'
        [void] (New-Item -ItemType Directory -Path $wheelhouse)
        $fullAncestor = [System.IO.Path]::GetFullPath($ancestor)
        Mock Get-Item {
            if ([System.IO.Path]::GetFullPath($LiteralPath) -eq $fullAncestor) {
                return [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::ReparsePoint }
            }
            return [System.IO.DirectoryInfo]::new($LiteralPath)
        }

        { Resolve-SafeLocalDirectory -Path $wheelhouse } |
            Should -Throw '*symbolic link or reparse point*'
    }
}