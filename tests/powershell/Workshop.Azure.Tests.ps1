Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '../../deploy/Workshop.Azure.psd1'
    $script:ConfigPath = Join-Path $PSScriptRoot '../../deploy/WorkshopConfig.psd1'
    if (Test-Path $script:ModulePath) {
        Import-Module $script:ModulePath -Force
    }
    $script:Config = if (Test-Path $script:ConfigPath) {
        Import-PowerShellDataFile $script:ConfigPath
    }
    else {
        @{}
    }

    function Get-PassingOperationSet {
        @{
            GetPowerShellVersion = { [version]'7.4.6' }
            GetModules = {
                @(
                    [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'4.0.2' }
                    [pscustomobject]@{ Name = 'Az.Resources'; Version = [version]'7.0.0' }
                    [pscustomobject]@{ Name = 'Az.Compute'; Version = [version]'10.0.0' }
                    [pscustomobject]@{ Name = 'Az.Network'; Version = [version]'7.0.0' }
                    [pscustomobject]@{ Name = 'Az.SqlVirtualMachine'; Version = [version]'2.3.0' }
                )
            }
            GetContext = {
                [pscustomobject]@{
                    Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
                    Tenant = [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222' }
                    Account = [pscustomobject]@{ Id = 'facilitator@example.test' }
                }
            }
            GetProviders = {
                @(
                    [pscustomobject]@{
                        ProviderNamespace = 'Microsoft.Compute'
                        RegistrationState = 'Registered'
                        ResourceTypes = @(
                            [pscustomobject]@{ ResourceTypeName = 'disks'; Locations = @('Indonesia Central') }
                        )
                    }
                    [pscustomobject]@{
                        ProviderNamespace = 'Microsoft.Network'
                        RegistrationState = 'Registered'
                        ResourceTypes = @(@(
                            'publicIPAddresses', 'natGateways', 'virtualNetworks',
                            'networkSecurityGroups', 'applicationSecurityGroups'
                        ) | ForEach-Object {
                            [pscustomobject]@{ ResourceTypeName = $_; Locations = @('Indonesia Central') }
                        }) + @([pscustomobject]@{
                            ResourceTypeName = 'privateDnsZones'
                            Locations = @('global')
                        })
                    }
                    [pscustomobject]@{ ProviderNamespace = 'Microsoft.Resources'; RegistrationState = 'Registered'; ResourceTypes = @() }
                    [pscustomobject]@{ ProviderNamespace = 'Microsoft.SqlVirtualMachine'; RegistrationState = 'Registered'; ResourceTypes = @() }
                )
            }
            GetLocations = { @([pscustomobject]@{ Location = 'indonesiacentral' }) }
            GetComputeSkus = {
                @(
                    [pscustomobject]@{ Name = 'Standard_D4s_v5'; ResourceType = 'virtualMachines'; Family = 'standardDSv5Family'; Locations = @('indonesiacentral'); Restrictions = @() }
                    [pscustomobject]@{ Name = 'Standard_E8s_v5'; ResourceType = 'virtualMachines'; Family = 'standardESv5Family'; Locations = @('indonesiacentral'); Restrictions = @() }
                    [pscustomobject]@{ Name = 'Premium_LRS'; ResourceType = 'disks'; Locations = @('indonesiacentral'); Restrictions = @() }
                )
            }
            GetImages = {
                param($Publisher, $Offer, $Sku, $Location)
                $null = $Offer, $Sku, $Location
                if ($Publisher -eq 'MicrosoftWindowsDesktop') {
                    return @(
                        [pscustomobject]@{ Version = '26100.2000.1' }
                        [pscustomobject]@{ Version = '26100.2033.1' }
                    )
                }
                return @(
                    [pscustomobject]@{ Version = '16.0.1000.1' }
                    [pscustomobject]@{ Version = '16.0.1135.2' }
                )
            }
            GetVmUsages = {
                @(
                    [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'cores'; LocalizedValue = 'Total Regional vCPUs' }; CurrentValue = 6; Limit = 100 }
                    [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardDSv5Family'; LocalizedValue = 'Standard DSv5 Family vCPUs' }; CurrentValue = 2; Limit = 20 }
                    [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardESv5Family'; LocalizedValue = 'Standard ESv5 Family vCPUs' }; CurrentValue = 4; Limit = 20 }
                )
            }
            TestNetworkSkuDeployment = {
                param($Location)
                $null = $Location
                [pscustomobject]@{
                    PublicIpStandardAvailable = $true
                    NatGatewayStandardAvailable = $true
                    Errors = @()
                }
            }
            FindResourceGroup = {
                param($Name)
                $null = $Name
                [pscustomobject]@{ VerifiedAbsent = $true; ResourceGroup = $null }
            }
            FindResources = { param($Names, $ResourceGroupName) $null = $Names, $ResourceGroupName; return @() }
        }
    }

    function Invoke-PassingPreflight {
        param(
            [hashtable]$Operations = (Get-PassingOperationSet),
            [hashtable]$Config = $script:Config
        )
        Test-WorkshopPrerequisites -Config $Config `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -TenantId '22222222-2222-2222-2222-222222222222' `
            -FacilitatorCidr '8.8.8.8/32' `
            -WindowsClientLicenseAttested $true `
            -SqlEnterpriseCostAcknowledged $true `
            -BillableResourcesAcknowledged $true `
            -ExpiresOn (Get-Date).Date.AddDays(2) `
            -Operations $Operations
    }
}

Describe 'Workshop configuration defaults' {
    It 'uses every approved concrete default' {
        $Config.Location | Should -Be 'indonesiacentral'
        $Config.ResourceGroupName | Should -Be 'rg-mcp-sql-workshop'
        $Config.VNet.Name | Should -Be 'vnet-mcpsql-workshop'
        $Config.VNet.AddressPrefix | Should -Be '10.20.0.0/16'
        $Config.AdminSubnet.Name | Should -Be 'snet-admin'
        $Config.AdminSubnet.Prefix | Should -Be '10.20.1.0/24'
        $Config.AdminSubnet.DefaultOutboundAccess | Should -BeFalse
        $Config.SqlSubnet.Name | Should -Be 'snet-sql'
        $Config.SqlSubnet.Prefix | Should -Be '10.20.2.0/24'
        $Config.SqlSubnet.DefaultOutboundAccess | Should -BeFalse
        $Config.AdminAsg | Should -Be 'asg-mcpsql-admin'
        $Config.SqlAsg | Should -Be 'asg-mcpsql-sql'
        $Config.PrivateDnsZone | Should -Be 'mcpworkshop.internal'
        $Config.SqlPrivateIp | Should -Be '10.20.2.10'
        $Config.AdminVm.Name | Should -Be 'vm-mcpsql-admin'
        $Config.AdminVm.Size | Should -Be 'Standard_D4s_v5'
        $Config.AdminVm.Publisher | Should -Be 'MicrosoftWindowsDesktop'
        $Config.AdminVm.Offer | Should -Be 'windows-11'
        $Config.AdminVm.Sku | Should -Be 'win11-24h2-ent'
        $Config.AdminVm.OsDiskGiB | Should -Be 128
        $Config.SqlVm.Name | Should -Be 'vm-mcpsql-sql'
        $Config.SqlVm.Size | Should -Be 'Standard_E8s_v5'
        $Config.SqlVm.Publisher | Should -Be 'MicrosoftSQLServer'
        $Config.SqlVm.Offer | Should -Be 'SQL2022-WS2022'
        $Config.SqlVm.Sku | Should -Be 'enterprise-gen2'
        $Config.SqlVm.OsDiskGiB | Should -Be 128
        $Config.SqlVm.DataDiskGiB | Should -Be 256
        $Config.SqlVm.LogDiskGiB | Should -Be 128
        $Config.SqlVm.LicenseType | Should -Be 'PAYG'
        $Config.AutoShutdownTime | Should -Be '1900'
        $Config.Tags.environment | Should -Be 'workshop'
        $Config.Tags.workload | Should -Be 'mcp-sql'
        $Config.Tags.managedBy | Should -Be 'PowerShell'
    }
}

Describe 'Assert-WorkshopHostCidr' {
    It 'returns a canonical public IPv4 host CIDR' {
        Assert-WorkshopHostCidr '8.8.8.8/32' | Should -Be '8.8.8.8/32'
    }

    It 'rejects non-global, special-use, noncanonical, IPv6, and broad values' -ForEach @(
        '0.0.0.0/32', '127.0.0.1/32', '169.254.10.1/32', '224.0.0.1/32',
        '10.1.2.3/32', '172.16.2.3/32', '192.168.2.3/32', '8.8.8.8/31',
        '100.64.0.1/32', '192.0.0.1/32', '192.0.2.8/32', '198.18.0.1/32',
        '198.51.100.22/32', '203.0.113.8/32', '192.88.99.1/32', '240.0.0.1/32',
        '255.255.255.255/32', '8.8.8.8/0', '008.8.8.8/32', '2001:db8::1/128',
        'not-a-cidr'
    ) {
        { Assert-WorkshopHostCidr $_ } | Should -Throw
    }
}

Describe 'Workshop configuration shape validation' {
    It 'rejects invalid network, address, outbound, sizing, and naming configuration before reads' -ForEach @(
        @{ Case = 'noncanonical VNet'; Change = { param($c) $c.VNet.AddressPrefix = '10.20.1.1/16' } }
        @{ Case = 'non-IPv4 VNet'; Change = { param($c) $c.VNet.AddressPrefix = '2001:db8::/64' } }
        @{ Case = 'admin subnet outside VNet'; Change = { param($c) $c.AdminSubnet.Prefix = '10.21.1.0/24' } }
        @{ Case = 'overlapping subnets'; Change = { param($c) $c.SqlSubnet.Prefix = '10.20.1.128/25' } }
        @{ Case = 'SQL IP outside subnet'; Change = { param($c) $c.SqlPrivateIp = '10.20.3.10' } }
        @{ Case = 'SQL IP is network'; Change = { param($c) $c.SqlPrivateIp = '10.20.2.0' } }
        @{ Case = 'SQL IP is reserved gateway'; Change = { param($c) $c.SqlPrivateIp = '10.20.2.1' } }
        @{ Case = 'SQL IP is reserved DNS'; Change = { param($c) $c.SqlPrivateIp = '10.20.2.3' } }
        @{ Case = 'SQL IP is broadcast'; Change = { param($c) $c.SqlPrivateIp = '10.20.2.255' } }
        @{ Case = 'admin outbound is true'; Change = { param($c) $c.AdminSubnet.DefaultOutboundAccess = $true } }
        @{ Case = 'SQL outbound is not Boolean false'; Change = { param($c) $c.SqlSubnet.DefaultOutboundAccess = 'false' } }
        @{ Case = 'empty required name'; Change = { param($c) $c.AdminVm.Name = ' ' } }
        @{ Case = 'empty VM size'; Change = { param($c) $c.SqlVm.Size = '' } }
        @{ Case = 'zero disk'; Change = { param($c) $c.SqlVm.DataDiskGiB = 0 } }
        @{ Case = 'negative disk'; Change = { param($c) $c.AdminVm.OsDiskGiB = -1 } }
    ) {
        $config = Import-PowerShellDataFile $script:ConfigPath
        & $Change $config
        { New-WorkshopNetworkModel -Config $config -FacilitatorCidr '8.8.8.8/32' } |
            Should -Throw -Because $Case
    }

    It 'throws for invalid configuration before invoking any external read' {
        $config = Import-PowerShellDataFile $script:ConfigPath
        $config.SqlSubnet.Prefix = '10.99.0.0/24'
        $script:ReadInvoked = $false
        $ops = Get-PassingOperationSet
        $ops.GetPowerShellVersion = { $script:ReadInvoked = $true; [version]'7.4' }

        { Invoke-PassingPreflight -Operations $ops -Config $config } | Should -Throw
        $script:ReadInvoked | Should -BeFalse
    }
}

Describe 'Workshop network model' {
    BeforeAll {
        $script:Network = New-WorkshopNetworkModel -Config $script:Config -FacilitatorCidr '8.8.8.8/32'
    }

    It 'assigns a public IP only to the administration VM' {
        $Network.Admin.PublicIpEnabled | Should -BeTrue
        $Network.Sql.PublicIpEnabled | Should -BeFalse
    }

    It 'requires explicit NAT and private outbound settings on both subnets' {
        $Network.NatGateway.Name | Should -Be 'nat-mcpsql-workshop'
        $Network.NatGateway.PublicIpName | Should -Be 'pip-mcpsql-nat'
        $Network.NatGateway.PublicIpEnabled | Should -BeTrue
        $Network.NatGateway.InboundEnabled | Should -BeFalse
        $Network.Admin.NatGatewayRequired | Should -BeTrue
        $Network.Sql.NatGatewayRequired | Should -BeTrue
        $Network.Admin.DefaultOutboundAccess | Should -BeFalse
        $Network.Sql.DefaultOutboundAccess | Should -BeFalse
        $Network.Admin.PrivateSubnet | Should -BeTrue
        $Network.Sql.PrivateSubnet | Should -BeTrue
    }

    It 'allows public RDP only from the facilitator host CIDR' {
        $rule = $Network.Admin.Rules | Where-Object Name -EQ 'Allow-Facilitator-Rdp'
        $rule.SourcePrefix | Should -Be '8.8.8.8/32'
        $rule.DestinationPort | Should -Be 3389
        $rule.Protocol | Should -Be 'Tcp'
        $rule.Access | Should -Be 'Allow'
    }

    It 'uses ASG-only SQL rules for 1433 and private RDP' {
        $sqlRule = $Network.Sql.Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql'
        $rdpRule = $Network.Sql.Rules | Where-Object Name -EQ 'Allow-Admin-Rdp-To-Sql'
        $sqlRule.SourceAsg | Should -Be 'asg-mcpsql-admin'
        $sqlRule.DestinationAsg | Should -Be 'asg-mcpsql-sql'
        $sqlRule.DestinationPort | Should -Be 1433
        $sqlRule.SourcePrefix | Should -BeNullOrEmpty
        $rdpRule.SourceAsg | Should -Be 'asg-mcpsql-admin'
        $rdpRule.DestinationPort | Should -Be 3389
        $rdpRule.SourcePrefix | Should -BeNullOrEmpty
    }

    It 'denies other VNet ingress to SQL before the Azure default allow' {
        $deny = $Network.Sql.Rules | Where-Object Name -EQ 'Deny-Other-VNet-To-Sql'
        $deny.SourcePrefix | Should -Be 'VirtualNetwork'
        $deny.Access | Should -Be 'Deny'
        $deny.Priority | Should -BeLessThan 65000
        ($Network.Sql.Rules | Sort-Object Priority | Select-Object -Last 1).Name | Should -Be 'AzureDefault-AllowVNetInBound'
    }
}

Describe 'Workshop plan and card' {
    It 'is deterministic, complete, and does not mutate configuration' {
        $before = $script:Config | ConvertTo-Json -Depth 20 -Compress
        $parameters = @{
            Config = $script:Config
            FacilitatorCidr = '8.8.8.8/32'
            ExpiresOn = [datetime]'2026-09-02T00:00:00Z'
            WindowsClientLicenseAttested = $true
            SqlEnterpriseCostAcknowledged = $true
            BillableResourcesAcknowledged = $true
        }
        $first = Get-WorkshopPlan @parameters
        $second = Get-WorkshopPlan @parameters
        ($first | ConvertTo-Json -Depth 20 -Compress) | Should -Be ($second | ConvertTo-Json -Depth 20 -Compress)
        ($script:Config | ConvertTo-Json -Depth 20 -Compress) | Should -Be $before
        $first.Network.Sql.PublicIpEnabled | Should -BeFalse
        $first.AdminVm.Image.Offer | Should -Be 'windows-11'
        $first.AdminVm.Disks.OsGiB | Should -Be 128
        $first.SqlVm.Disks.DataGiB | Should -Be 256
        $first.SqlVm.Disks.LogGiB | Should -Be 128
        $first.SqlVm.LicenseType | Should -Be 'PAYG'
        $first.Pricing.Queried | Should -BeFalse
        $first.Tags.expiresOn | Should -Be '2026-09-02'
    }

    It 'returns a deep copy independent of configuration' {
        $plan = Get-WorkshopPlan -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -ExpiresOn ([datetime]'2026-09-02') -WindowsClientLicenseAttested $true -SqlEnterpriseCostAcknowledged $true -BillableResourcesAcknowledged $true
        $plan.Tags.environment = 'changed'
        $plan.AdminVm.Image.Sku = 'changed'
        $script:Config.Tags.environment | Should -Be 'workshop'
        $script:Config.AdminVm.Sku | Should -Be 'win11-24h2-ent'
    }

    It 'preserves date-only expiration semantics regardless of local time zone' {
        $plan = Get-WorkshopPlan -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -ExpiresOn ([datetime]'2026-09-02') -WindowsClientLicenseAttested $true -SqlEnterpriseCostAcknowledged $true -BillableResourcesAcknowledged $true
        $plan.Tags.expiresOn | Should -Be '2026-09-02'
    }

    It 'formats a deterministic plan card with boundaries, costs, and attestations' {
        $plan = Get-WorkshopPlan -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -ExpiresOn ([datetime]'2026-09-02') -WindowsClientLicenseAttested $true -SqlEnterpriseCostAcknowledged $true -BillableResourcesAcknowledged $true
        $first = Format-WorkshopPlanCard -Plan $plan
        $second = Format-WorkshopPlanCard -Plan $plan
        $first | Should -BeExactly $second
        $first | Should -Match 'SQL public IP: none'
        $first | Should -Match 'Public ingress: Windows 11 RDP from 8\.8\.8\.8/32 only'
        $first | Should -Match 'SQL ingress: Admin ASG to SQL ASG TCP 1433'
        $first | Should -Match 'Windows client license attested: True'
        $first | Should -Match 'SQL Enterprise PAYG acknowledged: True'
        $first | Should -Match 'All billable categories acknowledged: True'
        $first | Should -Match 'VNet: vnet-mcpsql-workshop 10\.20\.0\.0/16'
        $first | Should -Match 'Admin subnet: snet-admin 10\.20\.1\.0/24; private: True; default outbound: False; NAT required: True'
        $first | Should -Match 'SQL subnet: snet-sql 10\.20\.2\.0/24; private: True; default outbound: False; NAT required: True'
        $first | Should -Match 'ASGs: asg-mcpsql-admin -> asg-mcpsql-sql'
        $first | Should -Match 'SQL private IP: 10\.20\.2\.10'
        $first | Should -Match 'NAT gateway: nat-mcpsql-workshop; outbound public IP: pip-mcpsql-nat; inbound: False'
        $first | Should -Match 'Administration disks: OS 128 GiB'
        $first | Should -Match 'SQL disks: OS 128 GiB; data 256 GiB; log 128 GiB'
        $first | Should -Match 'Tags: environment=workshop; workload=mcp-sql; managedBy=PowerShell; expiresOn=2026-09-02'
        foreach ($category in $plan.Pricing.BillableCategories) {
            $first | Should -Match ([regex]::Escape($category))
        }
        $first | Should -Match 'Pricing queried: False'
        $plan.Pricing.BillableResourcesAcknowledged | Should -BeTrue
        $plan.Pricing.BillableCategories | Should -Be @(
            'Windows client compute and license entitlement responsibility'
            'Administration VM compute'
            'SQL VM compute'
            'SQL Server Enterprise PAYG'
            'Managed OS, data, and log disks'
            'Standard public IP for administration ingress'
            'Standard public IP for NAT egress'
            'NAT Gateway hourly usage'
            'NAT Gateway data processing'
            'Outbound data transfer'
            'Private DNS zone and query charges'
        )
        $first | Should -Match 'Pricing was not queried'
    }
}

Describe 'Non-destructive workshop preflight' {
    It 'aggregates an all-pass result and resolves immutable latest images' {
        $result = Invoke-PassingPreflight
        $failedChecks = @($result.Checks | Where-Object Status -NE 'Passed')
        $failedChecks.Count | Should -Be 0
        $result.Passed | Should -BeTrue
        $result.ResolvedImages.Admin.Version | Should -Be '26100.2033.1'
        $result.ResolvedImages.Sql.Version | Should -Be '16.0.1135.2'
        $result.ResolvedImages.Admin.Version | Should -Not -Be 'latest'
        $result.Plan.AdminVm.Image.Version | Should -Be '26100.2033.1'
        $result.Plan.SqlVm.Image.Version | Should -Be '16.0.1135.2'
    }

    It 'fails an unregistered provider without attempting registration' {
        $script:RegisterCalls = 0
        $ops = Get-PassingOperationSet
        $ops.GetProviders = {
            @(
                [pscustomobject]@{ ProviderNamespace = 'Microsoft.Compute'; RegistrationState = 'NotRegistered' }
                [pscustomobject]@{ ProviderNamespace = 'Microsoft.Network'; RegistrationState = 'Registered' }
                [pscustomobject]@{ ProviderNamespace = 'Microsoft.Resources'; RegistrationState = 'Registered' }
                [pscustomobject]@{ ProviderNamespace = 'Microsoft.SqlVirtualMachine'; RegistrationState = 'Registered' }
            )
        }
        $ops.RegisterProvider = { $script:RegisterCalls++ }
        $result = Invoke-PassingPreflight -Operations $ops
        $result.Passed | Should -BeFalse
        ($result.Checks | Where-Object Name -EQ 'Provider Microsoft.Compute').Status | Should -Be 'Failed'
        $script:RegisterCalls | Should -Be 0
    }

    It 'accepts an authenticated context when the optional tenant parameter is omitted' {
        $ops = Get-PassingOperationSet
        $result = Test-WorkshopPrerequisites -Config $script:Config `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -FacilitatorCidr '8.8.8.8/32' `
            -WindowsClientLicenseAttested $true `
            -SqlEnterpriseCostAcknowledged $true `
            -BillableResourcesAcknowledged $true `
            -ExpiresOn (Get-Date).Date.AddDays(2) `
            -Operations $ops

        $result.Passed | Should -BeTrue
        ($result.Checks | Where-Object Name -EQ 'Azure context tenant').Status | Should -Be 'Passed'
    }

    It 'aggregates a missing authenticated account without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetContext = {
            [pscustomobject]@{
                Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
                Tenant = [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222' }
                Account = $null
            }
        }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        ($script:Result.Checks | Where-Object Name -EQ 'Azure context account').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'Azure context subscription').Status | Should -Be 'Passed'
    }

    It 'aggregates a missing authenticated tenant without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetContext = {
            [pscustomobject]@{
                Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
                Tenant = $null
                Account = [pscustomobject]@{ Id = 'facilitator@example.test' }
            }
        }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        ($script:Result.Checks | Where-Object Name -EQ 'Azure context tenant').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'Azure context subscription').Status | Should -Be 'Passed'
    }

    It 'aggregates a subscription mismatch without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetContext = {
            [pscustomobject]@{
                Subscription = [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' }
                Tenant = [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222' }
                Account = [pscustomobject]@{ Id = 'facilitator@example.test' }
            }
        }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        ($script:Result.Checks | Where-Object Name -EQ 'Azure context subscription').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'Azure context account').Status | Should -Be 'Passed'
    }

    It 'aggregates an optional supplied-tenant mismatch without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetContext = {
            [pscustomobject]@{
                Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
                Tenant = [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' }
                Account = [pscustomobject]@{ Id = 'facilitator@example.test' }
            }
        }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        ($script:Result.Checks | Where-Object Name -EQ 'Azure context tenant').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'Azure context subscription').Status | Should -Be 'Passed'
    }

    It 'validates the approved managed disk SKU and required resource types in the region' {
        $result = Invoke-PassingPreflight
        ($result.Checks | Where-Object Name -EQ 'Managed disk SKU Premium_LRS').Status | Should -Be 'Passed'
        foreach ($resourceType in @(
            'Microsoft.Compute/disks', 'Microsoft.Network/publicIPAddresses',
            'Microsoft.Network/natGateways', 'Microsoft.Network/virtualNetworks',
            'Microsoft.Network/networkSecurityGroups', 'Microsoft.Network/applicationSecurityGroups',
            'Microsoft.Network/privateDnsZones'
        )) {
            ($result.Checks | Where-Object Name -EQ "Resource type $resourceType").Status | Should -Be 'Passed'
        }
        ($result.Checks | Where-Object Name -EQ 'Resource type Microsoft.Network/publicIPAddresses').Detail |
            Should -Be "Provider metadata confirms location 'indonesiacentral'; deployment requires SKU 'Standard', whose exact regional listing is not asserted by this metadata."
        ($result.Checks | Where-Object Name -EQ 'Resource type Microsoft.Network/natGateways').Detail |
            Should -Be "Provider metadata confirms location 'indonesiacentral'; deployment requires SKU 'Standard', whose exact regional listing is not asserted by this metadata."
        ($result.Checks | Where-Object Name -EQ 'Resource type Microsoft.Network/privateDnsZones').Detail |
            Should -Be "Provider metadata confirms resource-type support in location 'global'."
    }

    It 'requires exact Standard network SKU validation separately from provider location metadata' {
        $result = Invoke-PassingPreflight
        ($result.Checks | Where-Object Name -EQ 'Network SKU Standard public IP').Status | Should -Be 'Passed'
        ($result.Checks | Where-Object Name -EQ 'Network SKU Standard NAT Gateway').Status | Should -Be 'Passed'

        $ops = Get-PassingOperationSet
        $ops.TestNetworkSkuDeployment = {
            [pscustomobject]@{
                PublicIpStandardAvailable = $false
                NatGatewayStandardAvailable = $true
                Errors = @()
            }
        }
        $failed = Invoke-PassingPreflight -Operations $ops
        ($failed.Checks | Where-Object Name -EQ 'Resource type Microsoft.Network/publicIPAddresses').Status | Should -Be 'Passed'
        ($failed.Checks | Where-Object Name -EQ 'Resource type Microsoft.Network/natGateways').Status | Should -Be 'Passed'
        ($failed.Checks | Where-Object Name -EQ 'Network SKU Standard public IP').Status | Should -Be 'Failed'
        ($failed.Checks | Where-Object Name -EQ 'Network SKU Standard NAT Gateway').Status | Should -Be 'Passed'

        $ops.TestNetworkSkuDeployment = {
            [pscustomobject]@{
                PublicIpStandardAvailable = $true
                NatGatewayStandardAvailable = $false
                Errors = @()
            }
        }
        $failed = Invoke-PassingPreflight -Operations $ops
        ($failed.Checks | Where-Object Name -EQ 'Network SKU Standard public IP').Status | Should -Be 'Passed'
        ($failed.Checks | Where-Object Name -EQ 'Network SKU Standard NAT Gateway').Status | Should -Be 'Failed'
    }

    It 'fails both exact network SKU checks when validation exposes errors despite true flags' {
        $ops = Get-PassingOperationSet
        $ops.TestNetworkSkuDeployment = {
            [pscustomobject]@{
                PublicIpStandardAvailable = $true
                NatGatewayStandardAvailable = $true
                Errors = @("invalid SKU`ndetail")
            }
        }

        $result = Invoke-PassingPreflight -Operations $ops
        $result.Passed | Should -BeFalse
        foreach ($name in @('Network SKU Standard public IP', 'Network SKU Standard NAT Gateway')) {
            $check = $result.Checks | Where-Object Name -EQ $name
            $check.Status | Should -Be 'Failed'
            $check.Detail | Should -Match 'invalid SKU detail'
            $check.Detail | Should -Not -Match "[`r`n]"
        }
    }

    It 'fails both exact network SKU checks when validation throws or is unverifiable' -ForEach @('throws', 'null') {
        $ops = Get-PassingOperationSet
        if ($_ -eq 'throws') {
            $ops.TestNetworkSkuDeployment = { throw "validation failed`nwith unsafe formatting" }
        }
        else {
            $ops.TestNetworkSkuDeployment = { return $null }
        }

        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        foreach ($name in @('Network SKU Standard public IP', 'Network SKU Standard NAT Gateway')) {
            $check = $script:Result.Checks | Where-Object Name -EQ $name
            $check.Status | Should -Be 'Failed'
            $check.Detail | Should -Not -Match "[`r`n]"
        }
    }

    It 'builds the exact in-memory subscription validation template and uses validation only' {
        InModuleScope Workshop.Azure {
            $script:CapturedTemplate = $null
            $script:CapturedLocation = $null
            $script:CapturedName = $null
            Mock Test-AzSubscriptionDeployment {
                $script:CapturedTemplate = $TemplateObject
                $script:CapturedLocation = $Location
                $script:CapturedName = $Name
                return $null
            }

            $operations = Get-DefaultWorkshopOperationSet
            $result = & $operations.TestNetworkSkuDeployment 'indonesiacentral'

            $result.PublicIpStandardAvailable | Should -BeTrue
            $result.NatGatewayStandardAvailable | Should -BeTrue
            $script:CapturedLocation | Should -Be 'indonesiacentral'
            $script:CapturedName | Should -Match '^mcpsql-sku-[a-f0-9]{12}$'
            $script:CapturedTemplate.'$schema' | Should -Be 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
            $script:CapturedTemplate.resources.Count | Should -Be 2
            ($script:CapturedTemplate.resources | Where-Object type -EQ 'Microsoft.Resources/resourceGroups').location | Should -Be 'indonesiacentral'
            $nestedDeployment = $script:CapturedTemplate.resources | Where-Object type -EQ 'Microsoft.Resources/deployments'
            $nestedDeployment.resourceGroup | Should -Match '^rg-mcpsql-sku-[a-f0-9]{12}$'
            $nestedDeployment.properties.mode | Should -Be 'Incremental'
            $nestedDeployment.properties.template.'$schema' | Should -Be 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
            $publicIp = $nestedDeployment.properties.template.resources | Where-Object type -EQ 'Microsoft.Network/publicIPAddresses'
            $publicIp.location | Should -Be 'indonesiacentral'
            $publicIp.sku.name | Should -Be 'Standard'
            $publicIp.properties.publicIPAllocationMethod | Should -Be 'Static'
            $publicIp.properties.publicIPAddressVersion | Should -Be 'IPv4'
            $natGateway = $nestedDeployment.properties.template.resources | Where-Object type -EQ 'Microsoft.Network/natGateways'
            $natGateway.location | Should -Be 'indonesiacentral'
            $natGateway.sku.name | Should -Be 'Standard'
            Should -Invoke Test-AzSubscriptionDeployment -Times 1 -Exactly
        }
    }

    It 'aggregates a false all-billable-categories acknowledgement without hiding other failures' {
        $result = Test-WorkshopPrerequisites -Config $script:Config `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -FacilitatorCidr '8.8.8.8/32' `
            -WindowsClientLicenseAttested $false `
            -SqlEnterpriseCostAcknowledged $false `
            -BillableResourcesAcknowledged $false `
            -ExpiresOn (Get-Date).Date.AddDays(2) `
            -Operations (Get-PassingOperationSet)

        $result.Passed | Should -BeFalse
        $failedNames = @($result.Checks | Where-Object Status -EQ 'Failed' | ForEach-Object Name)
        $failedNames | Should -Contain 'Windows client license attestation'
        $failedNames | Should -Contain 'SQL Enterprise PAYG acknowledgement'
        $failedNames | Should -Contain 'All billable resource categories acknowledged'
        ($result.Checks | Where-Object Name -EQ 'All billable resource categories acknowledged').Detail |
            Should -Match 'Windows client compute and license entitlement responsibility.*Administration VM compute.*SQL VM compute.*SQL Server Enterprise PAYG.*managed OS, data, and log disks.*two Standard public IP resources.*NAT Gateway hourly usage and data processing.*outbound data transfer.*Private DNS zone and query charges.*Pricing was not queried'
    }

    It 'fails a restricted managed disk SKU and missing resource-type locations without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetComputeSkus = {
            @(
                [pscustomobject]@{ Name = 'Standard_D4s_v5'; ResourceType = 'virtualMachines'; Family = 'standardDSv5Family'; Locations = @('indonesiacentral'); Restrictions = @() }
                [pscustomobject]@{ Name = 'Standard_E8s_v5'; ResourceType = 'virtualMachines'; Family = 'standardESv5Family'; Locations = @('indonesiacentral'); Restrictions = @() }
                [pscustomobject]@{ Name = 'Premium_LRS'; ResourceType = 'disks'; Locations = @('indonesiacentral'); Restrictions = @([pscustomobject]@{ ReasonCode = 'NotAvailableForSubscription' }) }
            )
        }
        $ops.GetProviders = {
            @(
                [pscustomobject]@{ ProviderNamespace = 'Microsoft.Compute'; RegistrationState = 'Registered'; ResourceTypes = @([pscustomobject]@{ ResourceTypeName = 'disks'; Locations = @('East US') }) }
                [pscustomobject]@{ ProviderNamespace = 'Microsoft.Network'; RegistrationState = 'Registered'; ResourceTypes = @() }
                [pscustomobject]@{ ProviderNamespace = 'Microsoft.Resources'; RegistrationState = 'Registered'; ResourceTypes = @() }
                [pscustomobject]@{ ProviderNamespace = 'Microsoft.SqlVirtualMachine'; RegistrationState = 'Registered'; ResourceTypes = @() }
            )
        }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        ($script:Result.Checks | Where-Object Name -EQ 'Managed disk SKU Premium_LRS').Status | Should -Be 'Failed'
        @($script:Result.Checks | Where-Object { $_.Name -like 'Resource type *' -and $_.Status -eq 'Failed' }).Count | Should -Be 7
        ($script:Result.Checks | Where-Object Name -EQ 'Resource type Microsoft.Compute/disks').Detail |
            Should -Be "Provider metadata does not confirm resource-type support in location 'indonesiacentral'."
    }

    It 'aggregates context, location, restriction, image, quota, attestation, date, and collision failures' {
        $ops = Get-PassingOperationSet
        $ops.GetContext = { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'wrong' }; Tenant = [pscustomobject]@{ Id = 'wrong' } } }
        $ops.GetLocations = { @([pscustomobject]@{ Location = 'eastus' }) }
        $ops.GetComputeSkus = {
            @(
                [pscustomobject]@{ Name = 'Standard_D4s_v5'; ResourceType = 'virtualMachines'; Family = 'standardDSv5Family'; Locations = @('indonesiacentral'); Restrictions = @([pscustomobject]@{ ReasonCode = 'NotAvailableForSubscription' }) }
                [pscustomobject]@{ Name = 'Standard_E8s_v5'; ResourceType = 'virtualMachines'; Family = 'standardESv5Family'; Locations = @('indonesiacentral'); Restrictions = @() }
            )
        }
        $ops.GetImages = { param($Publisher, $Offer, $Sku, $Location) $null = $Publisher, $Offer, $Sku, $Location; return @() }
        $ops.GetVmUsages = {
            @(
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardDSv5Family'; LocalizedValue = 'DSv5' }; CurrentValue = 18; Limit = 20 }
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardESv5Family'; LocalizedValue = 'ESv5' }; CurrentValue = 18; Limit = 20 }
            )
        }
        $ops.FindResourceGroup = { param($Name) [pscustomobject]@{ ResourceGroupName = $Name } }
        $ops.FindResources = { param($Names, $ResourceGroupName) $null = $Names, $ResourceGroupName; return @([pscustomobject]@{ Name = 'vm-mcpsql-admin' }) }

        $result = Test-WorkshopPrerequisites -Config $script:Config `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -TenantId '22222222-2222-2222-2222-222222222222' `
            -FacilitatorCidr '10.1.2.3/32' `
            -WindowsClientLicenseAttested $false `
            -SqlEnterpriseCostAcknowledged $false `
            -BillableResourcesAcknowledged $false `
            -ExpiresOn (Get-Date).Date.AddDays(8) `
            -Operations $ops

        $result.Passed | Should -BeFalse
        $failedNames = @($result.Checks | Where-Object Status -EQ 'Failed' | ForEach-Object Name)
        foreach ($name in @(
            'Azure context subscription', 'Azure context tenant', 'Location',
            'VM SKU Standard_D4s_v5', 'Admin VM image', 'SQL VM image',
            'Quota standardDSv5Family', 'Quota standardESv5Family',
            'Resource group collision', 'Resource name collisions', 'Facilitator CIDR',
            'Windows client license attestation', 'SQL Enterprise PAYG acknowledgement',
            'All billable resource categories acknowledged', 'Expiration date'
        )) {
            $failedNames | Should -Contain $name
        }
    }

    It 'sums required vCPUs when both VMs use the same quota family' {
        $ops = Get-PassingOperationSet
        $ops.GetComputeSkus = {
            @(
                [pscustomobject]@{ Name = 'Standard_D4s_v5'; ResourceType = 'virtualMachines'; Family = 'sameFamily'; Locations = @('indonesiacentral'); Restrictions = @() }
                [pscustomobject]@{ Name = 'Standard_E8s_v5'; ResourceType = 'virtualMachines'; Family = 'sameFamily'; Locations = @('indonesiacentral'); Restrictions = @() }
            )
        }
        $ops.GetVmUsages = { @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'sameFamily'; LocalizedValue = 'Same family' }; CurrentValue = 0; Limit = 11 }) }
        $result = Invoke-PassingPreflight -Operations $ops
        $result.Passed | Should -BeFalse
        ($result.Checks | Where-Object Name -EQ 'Quota sameFamily').Detail |
            Should -Be 'Required vCPUs: 12; available vCPUs: 11; missing vCPUs: 1.'
    }

    It 'fails total regional quota when both family quotas pass' {
        $ops = Get-PassingOperationSet
        $ops.GetVmUsages = {
            @(
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'cores'; LocalizedValue = 'Total Regional vCPUs' }; CurrentValue = 9; Limit = 20 }
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardDSv5Family'; LocalizedValue = 'DSv5' }; CurrentValue = 0; Limit = 20 }
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardESv5Family'; LocalizedValue = 'ESv5' }; CurrentValue = 0; Limit = 20 }
            )
        }

        $result = Invoke-PassingPreflight -Operations $ops
        ($result.Checks | Where-Object Name -EQ 'Quota standardDSv5Family').Status | Should -Be 'Passed'
        ($result.Checks | Where-Object Name -EQ 'Quota standardESv5Family').Status | Should -Be 'Passed'
        $total = $result.Checks | Where-Object Name -EQ 'Quota Total Regional vCPUs'
        $total.Status | Should -Be 'Failed'
        $total.Detail | Should -Be 'Required vCPUs: 12; available vCPUs: 11; missing vCPUs: 1.'
    }

    It 'fails total regional quota when its usage record is missing' {
        $ops = Get-PassingOperationSet
        $ops.GetVmUsages = {
            @(
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardDSv5Family' }; CurrentValue = 0; Limit = 20 }
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardESv5Family' }; CurrentValue = 0; Limit = 20 }
            )
        }
        $result = Invoke-PassingPreflight -Operations $ops
        ($result.Checks | Where-Object Name -EQ 'Quota Total Regional vCPUs').Status | Should -Be 'Failed'
        ($result.Checks | Where-Object Name -EQ 'Quota Total Regional vCPUs').Detail |
            Should -Be 'Required vCPUs: 12; available vCPUs: unknown; missing vCPUs: unknown.'
    }

    It 'fails malformed total regional quota as unverifiable without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetVmUsages = {
            @(
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'cores'; LocalizedValue = "Total`nRegional vCPUs" }; CurrentValue = 'not-a-count'; Limit = 'also-not-a-count' }
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardDSv5Family' }; CurrentValue = 0; Limit = 20 }
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardESv5Family' }; CurrentValue = 0; Limit = 20 }
            )
        }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $total = $script:Result.Checks | Where-Object Name -EQ 'Quota Total Regional vCPUs'
        $total.Status | Should -Be 'Failed'
        $total.Detail | Should -Be 'Required vCPUs: 12; available vCPUs: unknown; missing vCPUs: unknown.'
    }

    It 'reports missing and outdated required Az modules without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetModules = { @([pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'1.0.0' }) }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        @($script:Result.Checks | Where-Object { $_.Name -like 'Module Az.*' -and $_.Status -eq 'Failed' }).Count | Should -Be 5
    }

    It 'aggregates read-operation errors without throwing or omitting quota checks' {
        $ops = Get-PassingOperationSet
        foreach ($operationName in @(
            'GetPowerShellVersion', 'GetModules', 'GetContext', 'GetProviders',
            'GetLocations', 'GetComputeSkus', 'GetImages', 'GetVmUsages',
            'TestNetworkSkuDeployment', 'FindResourceGroup', 'FindResources'
        )) {
            $ops[$operationName] = { throw 'simulated read failure' }
        }

        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        ($script:Result.Checks.Name -join ',') | Should -Match 'Quota standardDSv5Family'
        ($script:Result.Checks.Name -join ',') | Should -Match 'Quota standardESv5Family'
        ($script:Result.Checks | Where-Object Name -EQ 'Quota standardDSv5Family').Detail |
            Should -Be 'Required vCPUs: 4; available vCPUs: unknown; missing vCPUs: unknown.'
        ($script:Result.Checks | Where-Object Name -EQ 'Managed disk SKU Premium_LRS').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'Managed disk SKU Premium_LRS').Detail |
            Should -Be 'Managed disk SKU query failed: simulated read failure'
        @($script:Result.Checks | Where-Object { $_.Name -like 'Resource type *' -and $_.Status -eq 'Failed' }).Count | Should -Be 7
        @($script:Result.Checks | Where-Object Status -EQ 'Failed').Count | Should -BeGreaterThan 10
    }

    It 'fails malformed image versions without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetImages = { param($Publisher, $Offer, $Sku, $Location) $null = $Publisher, $Offer, $Sku, $Location; return @([pscustomobject]@{ Version = 'not-a-version' }) }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        ($script:Result.Checks | Where-Object Name -EQ 'Admin VM image').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'SQL VM image').Status | Should -Be 'Failed'
    }

    It 'fails null or shapeless image records without throwing' {
        $ops = Get-PassingOperationSet
        $ops.GetImages = { @($null, [pscustomobject]@{ Unexpected = 'shape' }) }
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        ($script:Result.Checks | Where-Object Name -EQ 'Admin VM image').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'SQL VM image').Status | Should -Be 'Failed'
    }

    It 'requires exact location-qualified virtual-machine SKU records' {
        $ops = Get-PassingOperationSet
        $ops.GetComputeSkus = {
            @(
                [pscustomobject]@{ Name = 'Standard_D4s_v5'; ResourceType = 'disks'; Family = 'standardDSv5Family'; Locations = @('indonesiacentral'); Restrictions = @() }
                [pscustomobject]@{ Name = 'Standard_E8s_v5'; ResourceType = 'virtualMachines'; Family = 'standardESv5Family'; Locations = @(); Restrictions = @() }
            )
        }
        $result = Invoke-PassingPreflight -Operations $ops
        ($result.Checks | Where-Object Name -EQ 'VM SKU Standard_D4s_v5').Status | Should -Be 'Failed'
        ($result.Checks | Where-Object Name -EQ 'VM SKU Standard_E8s_v5').Status | Should -Be 'Failed'
    }

    It 'scopes resource-name collision reads to the target resource group' {
        $script:CollisionScope = $null
        $ops = Get-PassingOperationSet
        $ops.FindResourceGroup = { param($Name) [pscustomobject]@{ ResourceGroupName = $Name } }
        $ops.FindResources = {
            param($Names, $ResourceGroupName)
            $null = $Names
            $script:CollisionScope = $ResourceGroupName
            @()
        }
        $result = Invoke-PassingPreflight -Operations $ops
        $result.Passed | Should -BeFalse
        $script:CollisionScope | Should -Be 'rg-mcp-sql-workshop'
    }

    It 'does not read scoped resources when resource-group absence is verified' {
        $script:ScopedReadInvoked = $false
        $ops = Get-PassingOperationSet
        $ops.FindResources = { $script:ScopedReadInvoked = $true; @() }
        $result = Invoke-PassingPreflight -Operations $ops
        $result.Passed | Should -BeTrue
        $script:ScopedReadInvoked | Should -BeFalse
        ($result.Checks | Where-Object Name -EQ 'Resource name collisions').Detail |
            Should -Match 'verified absent'
    }

    It 'fails closed when resource-group absence is returned as an ambiguous null' {
        $ops = Get-PassingOperationSet
        $ops.FindResourceGroup = { return $null }
        $result = Invoke-PassingPreflight -Operations $ops
        ($result.Checks | Where-Object Name -EQ 'Resource group collision').Status | Should -Be 'Failed'
        ($result.Checks | Where-Object Name -EQ 'Resource name collisions').Status | Should -Be 'Failed'
    }

    It 'turns terminating and nonterminating collision-read errors into failures without swallowing auth' -ForEach @(
        @{ Kind = 'terminating'; Operation = { throw 'AuthorizationFailed: denied' } }
        @{ Kind = 'nonterminating'; Operation = { Write-Error 'network read failed'; return $null } }
    ) {
        $ops = Get-PassingOperationSet
        $ops.FindResourceGroup = $Operation
        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw -Because $Kind
        ($script:Result.Checks | Where-Object Name -EQ 'Resource group collision').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'Resource name collisions').Status | Should -Be 'Failed'
    }

    It 'fails scoped resource collisions when an existing group read errors' {
        $ops = Get-PassingOperationSet
        $ops.FindResourceGroup = { [pscustomobject]@{ ResourceGroupName = 'rg-mcp-sql-workshop' } }
        $ops.FindResources = { Write-Error 'AuthorizationFailed'; @() }
        $result = Invoke-PassingPreflight -Operations $ops
        ($result.Checks | Where-Object Name -EQ 'Resource name collisions').Status | Should -Be 'Failed'
    }

    It 'sanitizes and bounds all external-derived check details' {
        $ops = Get-PassingOperationSet
        $payload = "malicious`r`n`t$([char]0)$('x' * 2000)"
        $ops.GetContext = { throw $payload }
        $ops.GetProviders = { throw $payload }
        $ops.GetComputeSkus = { throw $payload }
        $ops.GetVmUsages = { throw $payload }
        $ops.FindResourceGroup = { throw $payload }
        $result = Invoke-PassingPreflight -Operations $ops

        foreach ($check in $result.Checks) {
            $check.Name | Should -Not -Match '[\x00-\x1F\x7F]'
            $check.Detail | Should -Not -Match '[\x00-\x1F\x7F]'
            $check.Remediation | Should -Not -Match '[\x00-\x1F\x7F]'
            $check.Name.Length | Should -BeLessOrEqual 512
            $check.Detail.Length | Should -BeLessOrEqual 512
            $check.Remediation.Length | Should -BeLessOrEqual 512
        }
    }
}

Describe 'Static safety and module contract' {
    It 'uses terminating errors for every default Azure collision read and recognizes only explicit not-found' {
        InModuleScope Workshop.Azure {
            Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = $Name } }
            Mock Get-AzResource { @() }
            $operations = Get-DefaultWorkshopOperationSet
            $null = & $operations.FindResourceGroup 'rg-test'
            $null = & $operations.FindResources @('one') 'rg-test'
            Should -Invoke Get-AzResourceGroup -Times 1 -ParameterFilter { $ErrorAction -eq 'Stop' }
            Should -Invoke Get-AzResource -Times 1 -ParameterFilter { $ErrorAction -eq 'Stop' }
        }
    }

    It 'returns VerifiedAbsent only for an explicit Azure resource-group not-found code' {
        InModuleScope Workshop.Azure {
            Mock Get-AzResourceGroup {
                $exception = [System.Exception]::new('resource group is absent')
                $record = [System.Management.Automation.ErrorRecord]::new(
                    $exception,
                    'ResourceGroupNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $Name
                )
                throw $record
            }
            $operations = Get-DefaultWorkshopOperationSet
            $result = & $operations.FindResourceGroup 'rg-test'
            $result.VerifiedAbsent | Should -BeTrue
            $result.ResourceGroup | Should -BeNullOrEmpty
        }
    }

    It 'does not convert Azure authorization failures into verified absence' {
        InModuleScope Workshop.Azure {
            Mock Get-AzResourceGroup {
                $exception = [System.Exception]::new('denied')
                $record = [System.Management.Automation.ErrorRecord]::new(
                    $exception,
                    'AuthorizationFailed',
                    [System.Management.Automation.ErrorCategory]::PermissionDenied,
                    $Name
                )
                throw $record
            }
            $operations = Get-DefaultWorkshopOperationSet
            { & $operations.FindResourceGroup 'rg-test' } | Should -Throw
        }
    }

    It 'exports only the intended functions and requires PowerShell 7.4' {
        $manifest = Test-ModuleManifest $script:ModulePath
        $manifest.PowerShellVersion | Should -Be ([version]'7.4')
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'Assert-WorkshopHostCidr', 'Format-WorkshopPlanCard', 'Get-WorkshopPlan',
            'New-WorkshopNetworkModel', 'Test-WorkshopPrerequisites'
        )
    }

    It 'contains no mutating Az command in the module or preflight entry point' {
        $files = @(
            (Join-Path $PSScriptRoot '../../deploy/Workshop.Azure.psm1'),
            (Join-Path $PSScriptRoot '../../deploy/Test-WorkshopPrerequisites.ps1')
        )
        $commands = foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object GetCommandName
        }
        @($commands | Where-Object { $_ -match '^(Register|New|Set|Remove|Update)-Az' }).Count | Should -Be 0
        @($commands | Where-Object { $_ -match '-Az' -and $_ -notmatch '^Get-Az' -and $_ -ne 'Test-AzSubscriptionDeployment' }).Count | Should -Be 0
        $commands | Should -Not -Contain 'New-AzDeployment'

        $modulePath = Join-Path $PSScriptRoot '../../deploy/Workshop.Azure.psm1'
        $tokens = $null
        $errors = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
        $dynamicCommands = @($moduleAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                [string]::IsNullOrWhiteSpace($node.GetCommandName())
        }, $true) | ForEach-Object { $_.Extent.Text })
        $dynamicCommands.Count | Should -Be 2
        $dynamicCommands | Should -Contain '& $Operation @Arguments 2>&1'
        @($dynamicCommands | Where-Object { $_ -match '^& \$validationCommand -Name' }).Count | Should -Be 1
        (Get-Content -LiteralPath $modulePath -Raw) | Should -Match "\`$validationCommand = 'Test-Az' \+ 'SubscriptionDeployment'"
    }

    It 'requires and forwards the billable acknowledgement in the entry script' {
        $entryPath = Join-Path $PSScriptRoot '../../deploy/Test-WorkshopPrerequisites.ps1'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BillableResourcesAcknowledged' }
        $parameter | Should -Not -BeNullOrEmpty
        @($parameter.Attributes.TypeName.FullName) | Should -Contain 'switch'
        @($parameter.Attributes.TypeName.FullName) | Should -Contain 'Parameter'
        $entryText = Get-Content -LiteralPath $entryPath -Raw
        $entryText | Should -Match 'BillableResourcesAcknowledged\s*=\s*\$BillableResourcesAcknowledged\.IsPresent'
    }
}
