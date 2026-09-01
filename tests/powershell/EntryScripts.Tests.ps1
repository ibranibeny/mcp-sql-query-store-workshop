Set-StrictMode -Version Latest

BeforeAll {
    $script:DeployPath = Join-Path $PSScriptRoot '../../deploy/Deploy-WorkshopEnvironment.ps1'
    $script:StopPath = Join-Path $PSScriptRoot '../../deploy/Stop-WorkshopEnvironment.ps1'
    $script:RemovePath = Join-Path $PSScriptRoot '../../deploy/Remove-WorkshopEnvironment.ps1'
}

Describe 'Workshop deployment entry script contract' {
    BeforeAll {
        $script:Tokens = $null
        $script:Errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:DeployPath,
            [ref] $script:Tokens,
            [ref] $script:Errors
        )
    }

    It 'parses and uses strict advanced-function semantics' {
        $script:Errors | Should -HaveCount 0
        $script:Ast.ParamBlock.Attributes.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
        (Get-Content -LiteralPath $script:DeployPath -Raw) | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
    }

    It 'requires the three acknowledgements and explicit billable deployment approval' -ForEach @(
        'WindowsClientLicenseAttested', 'SqlEnterpriseCostAcknowledged',
        'BillableResourcesAcknowledged', 'ApproveBillableDeployment'
    ) {
        $parameterName = $_
        $parameter = $script:Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq $parameterName }
        $parameter | Should -Not -BeNullOrEmpty
        @($parameter.Attributes.TypeName.FullName) | Should -Contain 'switch'
        @($parameter.Attributes.TypeName.FullName) | Should -Contain 'Parameter'
        @($parameter.Attributes | Where-Object { $_.Extent.Text -match '^\[Parameter\(Mandatory\)\]$' }) |
            Should -HaveCount 1
    }

    It 'requires an explicit target and a mandatory secure credential without prompting' {
        $subscription = $script:Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SubscriptionId' }
        @($subscription.Attributes | Where-Object { $_.Extent.Text -match '^\[Parameter\(Mandatory\)\]$' }) |
            Should -HaveCount 1
        foreach ($name in @('TenantId', 'FacilitatorCidr', 'ExpiresOn')) {
            $parameter = $script:Ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            @($parameter.Attributes | Where-Object { $_.Extent.Text -match 'Mandatory' }) |
                Should -HaveCount 0
        }
        $credential = $script:Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Credential' }
        $credential.StaticType.FullName | Should -Be 'System.Management.Automation.PSCredential'
        @($credential.Attributes | Where-Object { $_.Extent.Text -match '^\[Parameter\(Mandatory\)\]$' }) |
            Should -HaveCount 1
        (Get-Content -LiteralPath $script:DeployPath -Raw) | Should -Not -Match 'Get-Credential'
    }

    It 'uses the exact phrase, has no default phrase, and orders context, preflight, phrase, ShouldProcess, network' {
        $phrase = $script:Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ConfirmationPhrase' }
        $phrase.DefaultValue | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $script:DeployPath -Raw
        $text | Should -Match "DEPLOY rg-mcp-sql-workshop"
        $contextAt = $text.IndexOf('SetContext')
        $preflightAt = $text.IndexOf('TestPrerequisites')
        $phraseAt = $text.LastIndexOf("DEPLOY rg-mcp-sql-workshop")
        $shouldProcessAt = $text.IndexOf('$PSCmdlet.ShouldProcess')
        $networkAt = $text.LastIndexOf('NewNetwork')
        $contextAt | Should -BeGreaterThan -1
        $contextAt | Should -BeLessThan $preflightAt
        $preflightAt | Should -BeLessThan $phraseAt
        $phraseAt | Should -BeLessThan $shouldProcessAt
        $shouldProcessAt | Should -BeLessThan $networkAt
    }

    It 'does not contain any direct resource creation command' {
        $commands = $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object GetCommandName
        @($commands | Where-Object { $_ -match '^New-Az' }).Count | Should -Be 0
    }
}

Describe 'Workshop deployment entry script gates' {
    BeforeEach {
        $script:Counters = [pscustomobject]@{
            SetContext = 0
            Preflight = 0
            Network = 0
            Boundary = 0
            AdminVm = 0
            SqlVm = 0
            SqlIaas = 0
            Shutdown = 0
            VmBoundary = 0
            SqlBootstrap = 0
            AdminBootstrap = 0
            Readiness = 0
            PreflightPassed = $true
        }
        $script:Sequence = [System.Collections.Generic.List[string]]::new()
        $counters = $script:Counters
        $sequence = $script:Sequence
        $script:PreflightResult = [pscustomobject]@{
            Passed = $true
            Checks = @()
            Plan = $null
            ResolvedImages = [pscustomobject]@{
                Admin = [pscustomobject]@{
                    Publisher = 'MicrosoftWindowsDesktop'
                    Offer = 'windows-11'
                    Sku = 'win11-24h2-ent'
                    Version = '26100.2033.1'
                }
                Sql = [pscustomobject]@{
                    Publisher = 'MicrosoftSQLServer'
                    Offer = 'SQL2022-WS2022'
                    Sku = 'enterprise-gen2'
                    Version = '16.0.1135.2'
                }
            }
        }
        $preflightResult = $script:PreflightResult
        $script:EntryOperations = @{
            SetContext = ({
                param($SubscriptionId, $TenantId)
                $null = $SubscriptionId, $TenantId
                $counters.SetContext++
                $sequence.Add('context')
            }).GetNewClosure()
            TestPrerequisites = ({
                param($Parameters)
                $null = $Parameters
                $counters.Preflight++
                $sequence.Add('preflight')
                $preflightResult.Passed = $counters.PreflightPassed
                $preflightResult
            }).GetNewClosure()
            NewNetwork = ({
                param($Parameters)
                $null = $Parameters
                $counters.Network++
                $sequence.Add('network')
                [pscustomobject]@{ Completed = $true; Checkpoint = @('network complete') }
            }).GetNewClosure()
            TestBoundary = ({
                param($Parameters)
                $null = $Parameters
                $counters.Boundary++
                $sequence.Add('network-boundary')
                [pscustomobject]@{ Passed = $true; Checks = @() }
            }).GetNewClosure()
            NewAdminVm = ({
                param($Parameters)
                $null = $Parameters
                $counters.AdminVm++
                $sequence.Add('admin-vm')
                [pscustomobject]@{ Completed = $true; Checkpoint = @('admin VM complete') }
            }).GetNewClosure()
            NewSqlVm = ({
                param($Parameters)
                $null = $Parameters
                $counters.SqlVm++
                $sequence.Add('sql-vm')
                [pscustomobject]@{ Completed = $true; Checkpoint = @('SQL VM complete') }
            }).GetNewClosure()
            RegisterSqlIaas = ({
                param($Parameters)
                $null = $Parameters
                $counters.SqlIaas++
                $sequence.Add('sql-iaas')
                [pscustomobject]@{ Completed = $true; Checkpoint = @('SQL IaaS complete') }
            }).GetNewClosure()
            SetAutoShutdown = ({
                param($Parameters)
                $null = $Parameters
                $counters.Shutdown++
                $sequence.Add('shutdown')
                [pscustomobject]@{ Completed = $true; Checkpoint = @('shutdown complete') }
            }).GetNewClosure()
            TestVmBoundary = ({
                param($Parameters)
                $null = $Parameters
                $counters.VmBoundary++
                $sequence.Add('vm-boundary')
                [pscustomobject]@{ Passed = $true; Checks = @() }
            }).GetNewClosure()
            InitializeSqlVm = ({
                param($Parameters)
                $null = $Parameters
                $counters.SqlBootstrap++
                $sequence.Add('sql-bootstrap')
                [pscustomobject]@{
                    Completed = $true
                    Checkpoint = @('SQL bootstrap complete')
                    Readiness = [pscustomobject]@{ Completed = $true; Certificate = [pscustomobject]@{ PublicCertificatePath = 'C:\public.cer'; PublicCertificateSha256 = ('A' * 64) } }
                }
            }).GetNewClosure()
            InitializeAdminVm = ({
                param($Parameters)
                $null = $Parameters
                $counters.AdminBootstrap++
                $sequence.Add('admin-bootstrap')
                [pscustomobject]@{ Completed = $true; Checkpoint = @('admin bootstrap complete'); Readiness = [pscustomobject]@{ Completed = $true } }
            }).GetNewClosure()
            TestReadiness = ({
                param($Parameters)
                $null = $Parameters
                $counters.Readiness++
                $sequence.Add('readiness')
                [pscustomobject]@{ Passed = $true; Checks = @() }
            }).GetNewClosure()
        }
        $securePassword = [Security.SecureString]::new()
        foreach ($character in 'unit-test-only'.ToCharArray()) {
            $securePassword.AppendChar($character)
        }
        $securePassword.MakeReadOnly()
        $script:Credential = [PSCredential]::new('workshop-admin', $securePassword)
        $script:EntryParameters = @{
            SubscriptionId = '11111111-1111-1111-1111-111111111111'
            TenantId = '22222222-2222-2222-2222-222222222222'
            FacilitatorCidr = '8.8.8.8/32'
            ExpiresOn = (Get-Date).Date.AddDays(2)
            Credential = $script:Credential
            DatabaseMasterKeyPassword = $script:Credential.Password
            McpReaderPassword = $script:Credential.Password
            RepositoryUrl = 'https://github.com/example/mcp-sql-workshop.git'
            RepositoryCommit = '0123456789abcdef0123456789abcdef01234567'
            WindowsClientLicenseAttested = $true
            SqlEnterpriseCostAcknowledged = $true
            BillableResourcesAcknowledged = $true
            ApproveBillableDeployment = $true
            ConfirmationPhrase = 'DEPLOY rg-mcp-sql-workshop'
            Operations = $script:EntryOperations
            Confirm = $false
        }
    }

    It 'invokes network creation only after every gate passes' {
        $result = @(& $script:DeployPath @script:EntryParameters)
        $result[-1].Completed | Should -BeTrue
        $script:Counters.SetContext | Should -Be 1
        $script:Counters.Preflight | Should -Be 1
        $script:Counters.Network | Should -Be 1
        $script:Counters.Boundary | Should -Be 1
        $script:Counters.AdminVm | Should -Be 1
        $script:Counters.SqlVm | Should -Be 1
        $script:Counters.SqlIaas | Should -Be 1
        $script:Counters.Shutdown | Should -Be 1
        $script:Counters.VmBoundary | Should -Be 1
        $script:Counters.SqlBootstrap | Should -Be 1
        $script:Counters.AdminBootstrap | Should -Be 1
        $script:Counters.Readiness | Should -Be 1
        $script:Sequence | Should -Be @(
            'context', 'preflight', 'network', 'network-boundary', 'admin-vm', 'sql-vm',
            'sql-iaas', 'shutdown', 'vm-boundary', 'sql-bootstrap', 'admin-bootstrap', 'readiness'
        )
        $result[-1].Checkpoint | Should -Contain 'network complete'
        $result[-1].Checkpoint | Should -Contain 'shutdown complete'
        $result[-1].Checkpoint | Should -Contain 'admin bootstrap complete'
        ($result | Out-String) | Should -Not -Match 'unit-test-only'
    }

    It 'requires secure bootstrap inputs and an immutable repository commit' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:DeployPath, [ref] $tokens, [ref] $errors
        )
        foreach ($name in @('DatabaseMasterKeyPassword', 'McpReaderPassword')) {
            $parameter = $ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            $parameter.StaticType.FullName | Should -Be 'System.Security.SecureString'
            @($parameter.Attributes | Where-Object { $_.Extent.Text -match 'Mandatory' }) | Should -HaveCount 1
        }
        $commit = $ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'RepositoryCommit' }
        $commit.Extent.Text | Should -Match "ValidatePattern\('\^\[0-9a-f\]\{40\}\$'\)"
    }

    It 'creates nothing when preflight fails' {
        $script:Counters.PreflightPassed = $false
        { & $script:DeployPath @script:EntryParameters } | Should -Throw '*prerequisite validation failed*'
        $script:Counters.Network | Should -Be 0
        $script:Counters.Boundary | Should -Be 0
        $script:Counters.AdminVm | Should -Be 0
        $script:Counters.SqlVm | Should -Be 0
    }

    It 'rejects malformed or mismatched resolved image records before any resource mutation' -ForEach @(
        @{ Case = 'missing image collection'; Change = { param($p) $p.ResolvedImages = $null } }
        @{ Case = 'missing admin record'; Change = { param($p) $p.ResolvedImages.Admin = $null } }
        @{ Case = 'missing SQL record'; Change = { param($p) $p.ResolvedImages.Sql = $null } }
        @{ Case = 'admin publisher mismatch'; Change = { param($p) $p.ResolvedImages.Admin.Publisher = 'OtherPublisher' } }
        @{ Case = 'admin offer mismatch'; Change = { param($p) $p.ResolvedImages.Admin.Offer = 'other-offer' } }
        @{ Case = 'admin SKU mismatch'; Change = { param($p) $p.ResolvedImages.Admin.Sku = 'other-sku' } }
        @{ Case = 'admin mutable version'; Change = { param($p) $p.ResolvedImages.Admin.Version = 'latest' } }
        @{ Case = 'admin two-part version'; Change = { param($p) $p.ResolvedImages.Admin.Version = '1.2' } }
        @{ Case = 'SQL publisher mismatch'; Change = { param($p) $p.ResolvedImages.Sql.Publisher = 'OtherPublisher' } }
        @{ Case = 'SQL offer mismatch'; Change = { param($p) $p.ResolvedImages.Sql.Offer = 'other-offer' } }
        @{ Case = 'SQL SKU mismatch'; Change = { param($p) $p.ResolvedImages.Sql.Sku = 'other-sku' } }
        @{ Case = 'SQL suffixed version'; Change = { param($p) $p.ResolvedImages.Sql.Version = '16.0.1135-preview' } }
        @{ Case = 'shapeless admin record'; Change = { param($p) $p.ResolvedImages.Admin = [pscustomobject]@{ Unexpected = 'value' } } }
    ) {
        & $Change $script:PreflightResult

        { & $script:DeployPath @script:EntryParameters } |
            Should -Throw '*approved immutable image*' -Because $Case
        $script:Counters.Network | Should -Be 0
        $script:Counters.AdminVm | Should -Be 0
        $script:Counters.SqlVm | Should -Be 0
        $script:Counters.SqlIaas | Should -Be 0
        $script:Counters.Shutdown | Should -Be 0
    }

    It 'creates nothing when the exact phrase does not match' {
        $script:EntryParameters.ConfirmationPhrase = 'deploy rg-mcp-sql-workshop'
        { & $script:DeployPath @script:EntryParameters } | Should -Throw '*did not match exactly*'
        $script:Counters.Network | Should -Be 0
        $script:Counters.Boundary | Should -Be 0
        $script:Counters.AdminVm | Should -Be 0
        $script:Counters.SqlVm | Should -Be 0
    }

    It 'creates nothing when ShouldProcess is declined through WhatIf' {
        $script:EntryParameters.Remove('Confirm')
        $script:EntryParameters.WhatIf = $true
        $result = @(& $script:DeployPath @script:EntryParameters)
        $result[-1].Completed | Should -BeFalse
        $script:Counters.Network | Should -Be 0
        $script:Counters.Boundary | Should -Be 0
        $script:Counters.AdminVm | Should -Be 0
        $script:Counters.SqlVm | Should -Be 0
    }

    It 'rejects an empty credential username before context, preflight, approval, or output' {
        $script:EntryParameters.Credential = [PSCredential]::new(' ', $script:Credential.Password)

        { & $script:DeployPath @script:EntryParameters } | Should -Throw '*nonempty administrator credential*'
        $script:Counters.SetContext | Should -Be 0
        $script:Counters.Preflight | Should -Be 0
        $script:Counters.Network | Should -Be 0
    }

    It 'rejects an empty SecureString password before context, preflight, approval, or output' {
        $script:EntryParameters.Credential = [PSCredential]::new('workshop-admin', [Security.SecureString]::new())

        { & $script:DeployPath @script:EntryParameters } | Should -Throw '*nonempty SecureString password*'
        $script:Counters.SetContext | Should -Be 0
        $script:Counters.Preflight | Should -Be 0
        $script:Counters.Network | Should -Be 0
    }

    It 'does not invoke any VM operation when network creation fails' {
        $script:EntryOperations.NewNetwork = { throw 'network failed' }
        { & $script:DeployPath @script:EntryParameters } | Should -Throw '*network failed*No automatic rollback*'
        $script:Counters.AdminVm | Should -Be 0
        $script:Counters.SqlVm | Should -Be 0
        $script:Counters.SqlIaas | Should -Be 0
        $script:Counters.Shutdown | Should -Be 0
        $script:Counters.VmBoundary | Should -Be 0
    }

    It 'stops before later mutations when any completed stage declines or returns incomplete' -ForEach @(
        @{ Stage='NewNetwork'; Later=@('AdminVm','SqlVm','SqlIaas','Shutdown','VmBoundary') }
        @{ Stage='NewAdminVm'; Later=@('SqlVm','SqlIaas','Shutdown','VmBoundary') }
        @{ Stage='NewSqlVm'; Later=@('SqlIaas','Shutdown','VmBoundary') }
        @{ Stage='RegisterSqlIaas'; Later=@('Shutdown','VmBoundary') }
        @{ Stage='SetAutoShutdown'; Later=@('VmBoundary') }
    ) {
        $stageName = $Stage
        $script:EntryOperations[$stageName] = {
            param($Parameters)
            $null = $Parameters
            [pscustomobject]@{ Completed = $false; Checkpoint = @("$stageName incomplete") }
        }.GetNewClosure()

        { & $script:DeployPath @script:EntryParameters } | Should -Throw '*did not complete*No automatic rollback*'
        foreach ($counterName in $Later) {
            $script:Counters.$counterName | Should -Be 0
        }
    }
}

Describe 'Workshop lifecycle entry script contracts' {
    It 'provides strict ShouldProcess stop and remove entry scripts' -ForEach @(
        @{ ScriptName = 'Stop-WorkshopEnvironment.ps1'; Required = @('SubscriptionId') }
        @{ ScriptName = 'Remove-WorkshopEnvironment.ps1'; Required = @('SubscriptionId', 'ConfirmationPhrase') }
    ) {
        $Path = Join-Path $PSScriptRoot "../../deploy/$ScriptName"
        Test-Path -LiteralPath $Path | Should -BeTrue
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
        $errors | Should -HaveCount 0
        $ast.ParamBlock.Attributes.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
        foreach ($name in $Required) {
            $parameter = $ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            @($parameter.Attributes | Where-Object { $_.Extent.Text -match 'Mandatory' }) | Should -HaveCount 1
        }
    }

    It 'keeps lifecycle entry scripts thin and forwards operation injection' -ForEach @(
        'Stop-WorkshopEnvironment.ps1', 'Remove-WorkshopEnvironment.ps1'
    ) {
        $path = Join-Path $PSScriptRoot "../../deploy/$_"
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match 'Operations\s*=\s*\$Operations'
        $text | Should -Not -Match '(?m)^\s*(Stop-AzVM|Remove-AzResourceGroup|Get-AzResourceGroup)\b'
    }

    It 'requires the exact destructive phrase in the remove entry script' {
        (Get-Content -LiteralPath $script:RemovePath -Raw) | Should -Match 'DELETE rg-mcp-sql-workshop'
    }
}