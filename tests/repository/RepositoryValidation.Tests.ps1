BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepositoryRoot 'build/RepositoryValidation.psm1'
    Import-Module $script:ModulePath -Force
}

Describe 'Get-RepositoryJsonFile' {
    It 'returns tracked and unignored JSON while excluding ignored generated JSON' {
        $repository = Join-Path $TestDrive 'json-repository'
        New-Item -ItemType Directory -Path $repository | Out-Null
        git -C $repository init --quiet
        Set-Content -LiteralPath (Join-Path $repository '.gitignore') -Value "ignored.json`nnode_modules/"
        Set-Content -LiteralPath (Join-Path $repository 'tracked.json') -Value '{}'
        git -C $repository add .gitignore tracked.json
        git -C $repository -c user.name=Test -c user.email=test@example.invalid commit --quiet -m initial
        Set-Content -LiteralPath (Join-Path $repository 'untracked.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $repository 'ignored.json') -Value 'not json'
        New-Item -ItemType Directory -Path (Join-Path $repository 'node_modules') | Out-Null
        Set-Content -LiteralPath (Join-Path $repository 'node_modules/generated.json') -Value 'not json'

        $files = @(Get-RepositoryJsonFile -RepositoryRoot $repository)

        $files | Should -Be @('tracked.json', 'untracked.json')
    }

    It 'throws when git cannot enumerate files' {
        $missingRepository = Join-Path $TestDrive 'missing-repository'

        { Get-RepositoryJsonFile -RepositoryRoot $missingRepository } |
            Should -Throw '*git ls-files failed*'
    }
}

Describe 'Find-RepositorySecret' {
    It 'detects each supported private-key header' -ForEach @(
        '-----BEGIN PRIVATE KEY-----', # repository-secret-scan: allow-test-fixture
        '-----BEGIN RSA PRIVATE KEY-----', # repository-secret-scan: allow-test-fixture
        '-----BEGIN EC PRIVATE KEY-----', # repository-secret-scan: allow-test-fixture
        '-----BEGIN OPENSSH PRIVATE KEY-----', # repository-secret-scan: allow-test-fixture
        '-----BEGIN DSA PRIVATE KEY-----', # repository-secret-scan: allow-test-fixture
        '-----BEGIN ENCRYPTED PRIVATE KEY-----' # repository-secret-scan: allow-test-fixture
    ) {
        $findings = @(Find-RepositorySecret -Path 'fixture.pem' -Content $_)

        $findings.Count | Should -Be 1
        $findings[0].Type | Should -Be 'Private key'
        $findings[0].Line | Should -Be 1
        ($findings | Out-String) | Should -Not -Match ([regex]::Escape($_))
    }

    It 'detects format-aware password assignments without returning values' -ForEach @(
        @{ Name = 'JSON'; Content = '{"password": "actual-secret-123"}' }, # repository-secret-scan: allow-test-fixture
        @{ Name = 'dotenv'; Content = 'Server=db;Password=actual-secret-123;Encrypt=True' }, # repository-secret-scan: allow-test-fixture
        @{ Name = 'dotenv-pwd'; Content = 'Pwd=actual-secret-123' }, # repository-secret-scan: allow-test-fixture
        @{ Name = 'YAML'; Content = 'password: actual-secret-123' }, # repository-secret-scan: allow-test-fixture
        @{ Name = 'PowerShell parameter'; Content = "Connect-Thing -Password 'actual-secret-123'" }, # repository-secret-scan: allow-test-fixture
        @{ Name = 'PowerShell hashtable'; Content = "@{ Password = 'actual-secret-123' }" }, # repository-secret-scan: allow-test-fixture
        @{ Name = 'PowerShell variable'; Content = "`$Password = 'actual-secret-123'" }, # repository-secret-scan: allow-test-fixture
        @{ Name = 'Insecure SecureString conversion'; Content = "ConvertTo-SecureString 'actual-secret-123' -AsPlainText -Force" } # repository-secret-scan: allow-test-fixture
    ) {
        $findings = @(Find-RepositorySecret -Path "fixture.$($Name)" -Content $Content)

        $findings.Count | Should -Be 1
        $findings[0].Type | Should -Be 'Password assignment'
        $findings[0].Line | Should -Be 1
        ($findings | Out-String) | Should -Not -Match 'actual-secret-123'
    }

    It 'detects multiline JSON password assignments without returning the value' {
        $content = @'
{
  "password":
    "multiline-secret-456"
}
'@ # repository-secret-scan: allow-test-fixture

        $findings = @(Find-RepositorySecret -Path 'fixture.json' -Content $content)

        $findings.Count | Should -Be 1
        $findings[0].Type | Should -Be 'Password assignment'
        $findings[0].Line | Should -Be 2
        $findings[0].PSObject.Properties.Name | Should -Be @('Path', 'Type', 'Line')
        ($findings | Out-String) | Should -Not -Match 'multiline-secret-456'
    }

    It 'detects password literals in inline YAML mappings without returning the value' {
        $content = 'database: { user: workshop, password: inline-secret-789 }' # repository-secret-scan: allow-test-fixture

        $findings = @(Find-RepositorySecret -Path 'fixture.yaml' -Content $content)

        $findings.Count | Should -Be 1
        $findings[0].Type | Should -Be 'Password assignment'
        $findings[0].Line | Should -Be 1
        $findings[0].PSObject.Properties.Name | Should -Be @('Path', 'Type', 'Line')
        ($findings | Out-String) | Should -Not -Match 'inline-secret-789'
    }

    It 'detects a later literal after a safe password assignment without returning values' -ForEach @(
        @{
            Name = 'JSON-ish'
            Content = '{"password":"${FIRST_PASSWORD}","password":"second-json-secret"}' # repository-secret-scan: allow-test-fixture
            Secret = 'second-json-secret'
        },
        @{
            Name = 'inline YAML'
            Content = '{ password: @env(FIRST_PASSWORD), password: second-yaml-secret }' # repository-secret-scan: allow-test-fixture
            Secret = 'second-yaml-secret'
        }
    ) {
        $findings = @(Find-RepositorySecret -Path "fixture-$Name.txt" -Content $Content)

        $findings.Count | Should -Be 1
        $findings[0].Path | Should -Be "fixture-$Name.txt"
        $findings[0].Type | Should -Be 'Password assignment'
        $findings[0].Line | Should -Be 1
        $findings[0].PSObject.Properties.Name | Should -Be @('Path', 'Type', 'Line')
        ($findings | Out-String) | Should -Not -Match ([regex]::Escape($Secret))
    }

    It 'allows approved placeholders and non-literal PowerShell password handling' -ForEach @(
        '{"password": "SET_LOCALLY_ON_ADMIN_VM"}', # repository-secret-scan: allow-test-fixture
        'Password=<password>', # repository-secret-scan: allow-test-fixture
        'password: ${DATABASE_PASSWORD}', # repository-secret-scan: allow-test-fixture
        'password: @env(DATABASE_PASSWORD)', # repository-secret-scan: allow-test-fixture
        '$Password = Read-Host -AsSecureString', # repository-secret-scan: allow-test-fixture
        'param([SecureString] $Password)', # repository-secret-scan: allow-test-fixture
        "-Password `$env:DATABASE_PASSWORD", # repository-secret-scan: allow-test-fixture
        '-Password $SecurePassword', # repository-secret-scan: allow-test-fixture
        'ConvertTo-SecureString $env:DATABASE_PASSWORD -AsPlainText -Force' # repository-secret-scan: allow-test-fixture
    ) {
        @(Find-RepositorySecret -Path 'fixture.txt' -Content $_) | Should -BeNullOrEmpty
    }

    It 'allows supported generated, SQLCMD, environment, and variable references' -ForEach @(
        '-Password @GeneratedPassword',
        'password: $(DatabasePassword)',
        'Password=$(DatabasePassword);Encrypt=True',
        '{ password: @env(DATABASE_PASSWORD) }',
        "Password = [Environment]::GetEnvironmentVariable('DATABASE_PASSWORD')",
        'Password = [System.Environment]::GetEnvironmentVariable("DATABASE_PASSWORD")',
        '-Password $DatabasePassword'
    ) {
        @(Find-RepositorySecret -Path 'fixture.txt' -Content $_) | Should -BeNullOrEmpty
    }

    It 'does not honor the fixture bypass outside designated test paths' {
        $content = 'password: bypassed-literal # repository-secret-scan: allow-test-fixture'

        $findings = @(Find-RepositorySecret -Path 'src/config.yaml' -Content $content)

        $findings.Count | Should -Be 1
        $findings[0].Type | Should -Be 'Password assignment'
    }

    It 'honors the fixture bypass in designated test paths' {
        $content = 'password: intentional-fixture # repository-secret-scan: allow-test-fixture'

        @(Find-RepositorySecret -Path 'tests/fixtures/config.yaml' -Content $content) |
            Should -BeNullOrEmpty
    }

    It 'does not flag the scanner implementation itself' {
        @(Find-RepositorySecret -Path 'build/RepositoryValidation.psm1' -Content (
            Get-Content -LiteralPath $script:ModulePath -Raw
        )) |
            Should -BeNullOrEmpty
    }

    It 'scans a nested file with the same basename as the scanner implementation' {
        $content = 'password: nested-file-secret' # repository-secret-scan: allow-test-fixture

        $findings = @(
            Find-RepositorySecret -Path 'samples/nested/RepositoryValidation.psm1' -Content $content
        )

        $findings.Count | Should -Be 1
        $findings[0].Type | Should -Be 'Password assignment'
    }
}

Describe 'Resolve-RepositoryDiffBase' {
    It 'uses an explicit base ref before environment or branch fallbacks' {
        $previousBefore = $env:GITHUB_EVENT_BEFORE
        try {
            $env:GITHUB_EVENT_BEFORE = '0000000000000000000000000000000000000000'
            Resolve-RepositoryDiffBase -RepositoryRoot $script:RepositoryRoot -BaseRef 'HEAD' |
                Should -Be 'HEAD'
        }
        finally {
            $env:GITHUB_EVENT_BEFORE = $previousBefore
        }
    }

    It 'uses a valid GITHUB_EVENT_BEFORE when no explicit ref is supplied' {
        $previousBefore = $env:GITHUB_EVENT_BEFORE
        try {
            $env:GITHUB_EVENT_BEFORE = (git -C $script:RepositoryRoot rev-parse HEAD^).Trim()
            Resolve-RepositoryDiffBase -RepositoryRoot $script:RepositoryRoot |
                Should -Be $env:GITHUB_EVENT_BEFORE
        }
        finally {
            $env:GITHUB_EVENT_BEFORE = $previousBefore
        }
    }
}

Describe 'Test-RepositoryWhitespace' {
    It 'checks committed changes from the selected base through HEAD' {
        $repository = Join-Path $TestDrive 'whitespace-repository'
        New-Item -ItemType Directory -Path $repository | Out-Null
        git -C $repository init --quiet
        Set-Content -LiteralPath (Join-Path $repository 'sample.txt') -Value 'clean'
        git -C $repository add sample.txt
        git -C $repository -c user.name=Test -c user.email=test@example.invalid commit --quiet -m initial
        $base = (git -C $repository rev-parse HEAD).Trim()
        Set-Content -LiteralPath (Join-Path $repository 'sample.txt') -Value "trailing-space "
        git -C $repository add sample.txt
        git -C $repository -c user.name=Test -c user.email=test@example.invalid commit --quiet -m whitespace

        { Test-RepositoryWhitespace -RepositoryRoot $repository -BaseRef $base } |
            Should -Throw '*base-to-HEAD*'
    }
}

Describe 'Get-PSScriptAnalyzerGateResult' {
    It 'reports a non-failing optional skip when the analyzer is absent' {
        $result = Get-PSScriptAnalyzerGateResult -AnalyzerAvailable:$false

        $result.Failed | Should -BeFalse
        $result.Skipped | Should -BeTrue
        $result.Message | Should -Be 'SKIP: PSScriptAnalyzer (not installed; run build/Install-DevDependencies.ps1)'
    }

    It 'fails a strict gate when the analyzer is absent' {
        $result = Get-PSScriptAnalyzerGateResult -AnalyzerAvailable:$false -Required

        $result.Failed | Should -BeTrue
        $result.Skipped | Should -BeFalse
    }
}
