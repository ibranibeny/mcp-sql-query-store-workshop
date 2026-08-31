Set-StrictMode -Version Latest

BeforeAll {
    $script:DeployPath = Join-Path $PSScriptRoot '../../deploy/Deploy-WorkshopEnvironment.ps1'
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
            PreflightPassed = $true
        }
        $counters = $script:Counters
        $script:EntryOperations = @{
            SetContext = ({
                param($SubscriptionId, $TenantId)
                $null = $SubscriptionId, $TenantId
                $counters.SetContext++
            }).GetNewClosure()
            TestPrerequisites = ({
                param($Parameters)
                $null = $Parameters
                $counters.Preflight++
                [pscustomobject]@{
                    Passed = $counters.PreflightPassed
                    Checks = @()
                    Plan = $null
                }
            }).GetNewClosure()
            NewNetwork = ({
                param($Parameters)
                $null = $Parameters
                $counters.Network++
                [pscustomobject]@{ Completed = $true; Checkpoint = @('network complete') }
            }).GetNewClosure()
            TestBoundary = ({
                param($Parameters)
                $null = $Parameters
                $counters.Boundary++
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
    }

    It 'creates nothing when preflight fails' {
        $script:Counters.PreflightPassed = $false
        { & $script:DeployPath @script:EntryParameters } | Should -Throw '*prerequisite validation failed*'
        $script:Counters.Network | Should -Be 0
        $script:Counters.Boundary | Should -Be 0
    }

    It 'creates nothing when the exact phrase does not match' {
        $script:EntryParameters.ConfirmationPhrase = 'deploy rg-mcp-sql-workshop'
        { & $script:DeployPath @script:EntryParameters } | Should -Throw '*did not match exactly*'
        $script:Counters.Network | Should -Be 0
        $script:Counters.Boundary | Should -Be 0
    }

    It 'creates nothing when ShouldProcess is declined through WhatIf' {
        $script:EntryParameters.Remove('Confirm')
        $script:EntryParameters.WhatIf = $true
        $result = @(& $script:DeployPath @script:EntryParameters)
        $result[-1].Completed | Should -BeFalse
        $script:Counters.Network | Should -Be 0
        $script:Counters.Boundary | Should -Be 0
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
}