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
                    [pscustomobject]@{ Name = 'Az.Network'; Version = [version]'8.0.0' }
                    [pscustomobject]@{ Name = 'Az.PrivateDns'; Version = [version]'1.0.0' }
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
                    [pscustomobject]@{
                        Name = 'Standard_D4s_v5'; ResourceType = 'virtualMachines'; Family = 'standardDSv5Family'
                        Locations = @('indonesiacentral'); Restrictions = @()
                        Capabilities = @(
                            [pscustomobject]@{ Name = 'TrustedLaunchDisabled'; Value = 'False' }
                            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }
                        )
                    }
                    [pscustomobject]@{
                        Name = 'Standard_E8s_v5'; ResourceType = 'virtualMachines'; Family = 'standardESv5Family'
                        Locations = @('indonesiacentral'); Restrictions = @()
                        Capabilities = @(
                            [pscustomobject]@{ Name = 'TrustedLaunchDisabled'; Value = 'False' }
                            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }
                        )
                    }
                    [pscustomobject]@{ Name = 'Premium_LRS'; ResourceType = 'disks'; Locations = @('indonesiacentral'); Restrictions = @() }
                )
            }
            GetImages = {
                param($Publisher, $Offer, $Sku, $Location)
                $null = $Offer, $Sku, $Location
                if ($Publisher -eq 'MicrosoftWindowsDesktop') {
                    return @(
                        [pscustomobject]@{ Version = '26100.2000.1'; HyperVGeneration = 'V2' }
                        [pscustomobject]@{ Version = '26100.2033.1'; HyperVGeneration = 'V2' }
                    )
                }
                return @(
                    [pscustomobject]@{ Version = '16.0.1000.1'; HyperVGeneration = 'V2' }
                    [pscustomobject]@{ Version = '16.0.1135.2'; HyperVGeneration = 'V2' }
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

    function Get-TestCredential {
        $secureValue = [System.Security.SecureString]::new()
        foreach ($codePoint in @(117, 110, 105, 116, 45, 116, 101, 115, 116, 45, 111, 110, 108, 121)) {
            $secureValue.AppendChar([char] $codePoint)
        }
        $secureValue.MakeReadOnly()

        return [System.Management.Automation.PSCredential]::new('workshop-admin', $secureValue)
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
        $Config.AutoShutdownLocation | Should -Be 'southeastasia'
        $Config.Tags.environment | Should -Be 'workshop'
        $Config.Tags.workload | Should -Be 'mcp-sql'
        $Config.Tags.managedBy | Should -Be 'PowerShell'
        $Config.Tags.costconstraint | Should -Be 'ignore'
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

    It 'accepts contained nonoverlapping /29 subnets with an Azure-usable SQL host address' {
        $config = Import-PowerShellDataFile $script:ConfigPath
        $config.AdminSubnet.Prefix = '10.20.1.0/29'
        $config.SqlSubnet.Prefix = '10.20.2.0/29'
        $config.SqlPrivateIp = '10.20.2.4'

        { New-WorkshopNetworkModel -Config $config -FacilitatorCidr '8.8.8.8/32' } |
            Should -Not -Throw
    }

    It 'rejects subnets without at least three Azure-usable host addresses' -ForEach @(
        @{ Case = 'admin /30'; Change = { param($c) $c.AdminSubnet.Prefix = '10.20.1.0/30' } }
        @{ Case = 'admin /31'; Change = { param($c) $c.AdminSubnet.Prefix = '10.20.1.0/31' } }
        @{ Case = 'SQL /30'; Change = { param($c) $c.SqlSubnet.Prefix = '10.20.2.0/30'; $c.SqlPrivateIp = '10.20.2.1' } }
        @{ Case = 'SQL /31'; Change = { param($c) $c.SqlSubnet.Prefix = '10.20.2.0/31'; $c.SqlPrivateIp = '10.20.2.1' } }
    ) {
        $config = Import-PowerShellDataFile $script:ConfigPath
        & $Change $config

        { New-WorkshopNetworkModel -Config $config -FacilitatorCidr '8.8.8.8/32' } |
            Should -Throw -ExpectedMessage '*prefix length between /16 and /29*' -Because $Case
    }

    It 'rejects subnet prefixes broader than /16 even when contained in a broader VNet' {
        $config = Import-PowerShellDataFile $script:ConfigPath
        $config.VNet.AddressPrefix = '10.0.0.0/8'
        $config.AdminSubnet.Prefix = '10.20.0.0/15'
        $config.SqlSubnet.Prefix = '10.22.0.0/24'
        $config.SqlPrivateIp = '10.22.0.10'

        { New-WorkshopNetworkModel -Config $config -FacilitatorCidr '8.8.8.8/32' } |
            Should -Throw -ExpectedMessage '*prefix length between /16 and /29*'
    }

    It 'rejects case-insensitive duplicate network and compute identities' -ForEach @(
        @{ Case = 'subnet names'; Change = { param($c) $c.SqlSubnet.Name = $c.AdminSubnet.Name.ToUpperInvariant() } }
        @{ Case = 'application security groups'; Change = { param($c) $c.SqlAsg = $c.AdminAsg.ToUpperInvariant() } }
        @{ Case = 'virtual machines'; Change = { param($c) $c.SqlVm.Name = $c.AdminVm.Name.ToUpperInvariant() } }
    ) {
        $config = Import-PowerShellDataFile $script:ConfigPath
        & $Change $config

        { New-WorkshopNetworkModel -Config $config -FacilitatorCidr '8.8.8.8/32' } |
            Should -Throw -ExpectedMessage '*must be distinct*' -Because $Case
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
        $rdpRule = $Network.Sql.Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql-Rdp'
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
        $deny.Priority | Should -Be 4000
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
        $first | Should -Match 'Tags: environment=workshop; workload=mcp-sql; managedBy=PowerShell; costconstraint=ignore; expiresOn=2026-09-02'
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
    It 'requires PowerShell 7.4 consistently' -ForEach @(
        @{ Version = '7.3.99'; Expected = 'Failed' }
        @{ Version = '7.4.0'; Expected = 'Passed' }
    ) {
        $ops = Get-PassingOperationSet
        $candidate = [version] $Version
        $ops.GetPowerShellVersion = { $candidate }.GetNewClosure()

        $result = Invoke-PassingPreflight -Operations $ops
        $check = $result.Checks | Where-Object Name -EQ 'PowerShell version'

        $check.Status | Should -Be $Expected
        $check.Detail | Should -Match '7\.4 or later'
        $check.Remediation | Should -Match 'PowerShell 7\.4 or later|^$'
    }

    It 'records unsupported cross-region auto-shutdown with the documented local emergency-stop fallback' {
        $result = Invoke-PassingPreflight
        $capability = $result.AutoShutdownCapability
        $check = $result.Checks | Where-Object Name -EQ 'DevTestLab auto-shutdown capability'

        $result.Passed | Should -BeTrue
        $check.Status | Should -Be 'Passed'
        $capability.ScheduleSupported | Should -BeFalse
        $capability.VmLocation | Should -BeExactly 'indonesiacentral'
        $capability.ScheduleLocation | Should -BeExactly 'southeastasia'
        $capability.RequiredFallback | Should -BeExactly 'LocalEmergencyStop'
        $check.Detail | Should -Match 'unsupported.*local emergency stop|required.*local emergency stop'
    }

    It 'fails an unrecognized schedule-location mismatch instead of treating it as documented fallback' {
        $config = Import-PowerShellDataFile $script:ConfigPath
        $config.AutoShutdownLocation = 'eastus'

        $result = Invoke-PassingPreflight -Config $config
        $check = $result.Checks | Where-Object Name -EQ 'DevTestLab auto-shutdown capability'

        $result.Passed | Should -BeFalse
        $check.Status | Should -Be 'Failed'
        $result.AutoShutdownCapability.RequiredFallback | Should -BeNullOrEmpty
    }

    It 'requires the Private DNS module before deployment can pass preflight' {
        $result = Invoke-PassingPreflight

        ($result.Checks | Where-Object Name -EQ 'Module Az.PrivateDns').Status | Should -Be 'Passed'
    }

    It 'requires Az.Network 8.0.0 or later' -ForEach @(
        @{ Version = '7.0.0'; ExpectedStatus = 'Failed' }
        @{ Version = '7.27.0'; ExpectedStatus = 'Failed' }
        @{ Version = '8.0.0'; ExpectedStatus = 'Passed' }
    ) {
        $ops = Get-PassingOperationSet
        $testedVersion = $Version
        $baseGetModules = $ops.GetModules
        $ops.GetModules = {
            @(& $baseGetModules | ForEach-Object {
                if ($_.Name -eq 'Az.Network') {
                    [pscustomobject]@{ Name = $_.Name; Version = [version] $testedVersion }
                }
                else {
                    $_
                }
            })
        }

        $result = Invoke-PassingPreflight -Operations $ops
        $check = $result.Checks | Where-Object Name -EQ 'Module Az.Network'

        $check.Status | Should -Be $ExpectedStatus
        $check.Detail | Should -Match 'minimum version is 8\.0\.0'
    }

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
        @($script:Result.Checks | Where-Object { $_.Name -like 'Module Az.*' -and $_.Status -eq 'Failed' }).Count | Should -Be 6
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

    It 'rejects image versions outside the immutable numeric three-or-four-part shape without throwing' -ForEach @(
        '1.2', 'latest', '1.2.3-preview', '1.2.3.4.5'
    ) {
        $invalidVersion = $_
        $ops = Get-PassingOperationSet
        $ops.GetImages = {
            [pscustomobject]@{ Version = $invalidVersion }
        }.GetNewClosure()

        { $script:Result = Invoke-PassingPreflight -Operations $ops } | Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
        ($script:Result.Checks | Where-Object Name -EQ 'Admin VM image').Status | Should -Be 'Failed'
        ($script:Result.Checks | Where-Object Name -EQ 'SQL VM image').Status | Should -Be 'Failed'
    }

    It 'selects the highest version from only immutable numeric three-or-four-part image records' {
        $ops = Get-PassingOperationSet
        $ops.GetImages = {
            @(
                [pscustomobject]@{ Version = '999.0' }
                [pscustomobject]@{ Version = '3.9.9.9' }
                [pscustomobject]@{ Version = '3.10.0' }
                [pscustomobject]@{ Version = '999.0.0-preview' }
            )
        }

        $result = Invoke-PassingPreflight -Operations $ops

        $result.Passed | Should -BeTrue
        $result.ResolvedImages.Admin.Version | Should -Be '3.10.0'
        $result.ResolvedImages.Sql.Version | Should -Be '3.10.0'
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

    It 'rejects VM SKU metadata that disables Trusted Launch or omits generation V2' -ForEach @(
        @{ Size = 'Standard_D4s_v5'; Capability = 'TrustedLaunchDisabled'; Value = 'True' }
        @{ Size = 'Standard_E8s_v5'; Capability = 'TrustedLaunchDisabled'; Value = 'true' }
        @{ Size = 'Standard_D4s_v5'; Capability = 'HyperVGenerations'; Value = 'V1' }
        @{ Size = 'Standard_E8s_v5'; Capability = 'HyperVGenerations'; Value = 'V1' }
    ) {
        $ops = Get-PassingOperationSet
        $passingSkus = @(& $ops.GetComputeSkus)
        $targetSku = $passingSkus | Where-Object Name -EQ $Size
        ($targetSku.Capabilities | Where-Object Name -EQ $Capability).Value = $Value
        $ops.GetComputeSkus = { $passingSkus }.GetNewClosure()

        $result = Invoke-PassingPreflight -Operations $ops

        $result.Passed | Should -BeFalse
        ($result.Checks | Where-Object Name -EQ "VM SKU $Size").Status | Should -Be 'Failed'
    }

    It 'rejects selected VM image metadata that is not generation V2' -ForEach @(
        @{ Publisher = 'MicrosoftWindowsDesktop'; Check = 'Admin VM image' }
        @{ Publisher = 'MicrosoftSQLServer'; Check = 'SQL VM image' }
    ) {
        $rejectedPublisher = $Publisher
        $ops = Get-PassingOperationSet
        $ops.GetImages = {
            param($ImagePublisher)
            $generation = if ($ImagePublisher -eq $rejectedPublisher) { 'V1' } else { 'V2' }
            [pscustomobject]@{ Version = '1.2.3'; HyperVGeneration = $generation }
        }.GetNewClosure()

        $result = Invoke-PassingPreflight -Operations $ops

        $result.Passed | Should -BeFalse
        ($result.Checks | Where-Object Name -EQ $Check).Status | Should -Be 'Failed'
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

    It 'handles an Azure error record whose exception has no Response property' {
        InModuleScope Workshop.Azure {
            $exception = [System.Exception]::new('unexpected read failure')
            $record = [System.Management.Automation.ErrorRecord]::new(
                $exception,
                'UnexpectedAzureFailure',
                [System.Management.Automation.ErrorCategory]::NotSpecified,
                'rg-test'
            )

            { $script:notFound = Test-WorkshopAzureNotFound -ErrorRecord $record } | Should -Not -Throw
            $script:notFound | Should -BeFalse
        }
    }

    It 'recognizes the exact untyped absent-group record emitted by Get-AzResourceGroup' {
        InModuleScope Workshop.Azure {
            $exception = [System.Exception]::new('05:17:54 - Provided resource group does not exist.')
            $record = [System.Management.Automation.ErrorRecord]::new(
                $exception,
                'Microsoft.Azure.Commands.ResourceManager.Cmdlets.Implementation.GetAzureResourceGroupCmdlet',
                [System.Management.Automation.ErrorCategory]::NotSpecified,
                'rg-test'
            )

            (Test-WorkshopAzureNotFound -ErrorRecord $record) | Should -BeTrue
        }
    }

    It 'recognizes ResourceNotFound in an Az NetworkCloudException inner body' {
        InModuleScope Workshop.Azure {
            $inner = [System.Exception]::new('network resource absent')
            $inner | Add-Member -NotePropertyName Body -NotePropertyValue ([pscustomobject]@{
                Code = 'ResourceNotFound'
                Message = 'The requested network resource was not found.'
            })
            $outer = [System.Exception]::new('network operation failed', $inner)
            $record = [System.Management.Automation.ErrorRecord]::new(
                $outer,
                'Microsoft.Azure.Commands.Network.GetAzureRmApplicationSecurityGroup',
                [System.Management.Automation.ErrorCategory]::NotSpecified,
                'asg-test'
            )

            (Test-WorkshopAzureNotFound -ErrorRecord $record) | Should -BeTrue
        }
    }

    It 'exports only the intended functions and requires PowerShell 7.4' {
        $manifest = Test-ModuleManifest $script:ModulePath
        $manifest.PowerShellVersion | Should -Be ([version]'7.4')
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'Assert-WorkshopHostCidr', 'Export-WorkshopDeploymentEvidence', 'Format-WorkshopPlanCard', 'Get-WorkshopPlan',
            'Initialize-WorkshopAdminVm', 'Initialize-WorkshopSqlVm',
            'New-WorkshopAdminVm', 'New-WorkshopNetwork', 'New-WorkshopNetworkModel',
            'New-WorkshopSqlVm', 'Register-WorkshopSqlIaas', 'Remove-WorkshopEnvironment',
            'Resolve-WorkshopImageVersion', 'Set-WorkshopAutoShutdown', 'Start-WorkshopEnvironment',
            'Stop-WorkshopEnvironment',
            'Test-WorkshopNetworkBoundary', 'Test-WorkshopPrerequisites', 'Test-WorkshopReadiness',
            'Test-WorkshopVmBoundary'
        )
    }

    It 'contains no mutating Az command in the preflight entry point' {
        $files = @((Join-Path $PSScriptRoot '../../deploy/Test-WorkshopPrerequisites.ps1'))
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

Describe 'Private workshop network deployment' {
    BeforeEach {
        $script:NetworkState = @{}
        $script:NetworkCreates = [System.Collections.Generic.List[object]]::new()
        $script:SkipReadBackKind = $null
        $script:NetworkOperations = @{
            SupportsDefaultOutboundAccess = { $true }
            GetSubscriptionId = { 'mock' }
            GetResource = {
                param($Kind, $Name, $ResourceGroupName)
                $null = $ResourceGroupName
                $key = "$Kind/$Name"
                if ($script:NetworkState.ContainsKey($key)) { return $script:NetworkState[$key] }
                return $null
            }
            CreateResource = {
                param($Spec, $ResourceGroupName)
                $null = $ResourceGroupName
                $script:NetworkCreates.Add($Spec)
                if ($script:SkipReadBackKind -ne $Spec.Kind) {
                    $script:NetworkState["$($Spec.Kind)/$($Spec.Name)"] = $Spec
                }
                return $Spec
            }
            GetPublicIpInventory = {
                param($ResourceGroupName)
                $null = $ResourceGroupName
                @($script:NetworkState.Values | Where-Object Kind -EQ 'PublicIpAddress')
            }
        }
    }

    It 'fails before any mutation when private-subnet command capability is unsupported' {
        $script:NetworkOperations.SupportsDefaultOutboundAccess = { $false }

        { New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations } |
            Should -Throw -ExpectedMessage '*DefaultOutboundAccess*Az.Network 8.0.0*'
        $script:NetworkCreates | Should -HaveCount 0
        $script:NetworkState.Count | Should -Be 0
    }

    It 'creates the approved resources in dependency order with exactly two public IPs' {
        $result = New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations

        $result.Completed | Should -BeTrue
        @($script:NetworkCreates.Kind) | Should -Be @(
            'ResourceGroup', 'ApplicationSecurityGroup', 'ApplicationSecurityGroup',
            'PublicIpAddress', 'PublicIpAddress', 'NatGateway',
            'NetworkSecurityGroup', 'NetworkSecurityGroup', 'VirtualNetwork',
            'PrivateDnsZone', 'PrivateDnsVirtualNetworkLink', 'PrivateDnsARecord',
            'NetworkInterface', 'NetworkInterface'
        )
        @($script:NetworkCreates | Where-Object Kind -EQ 'PublicIpAddress').Name |
            Should -Be @('pip-mcpsql-admin', 'pip-mcpsql-nat')
        @($script:NetworkCreates | Where-Object { $_.Kind -eq 'PublicIpAddress' -and $_.Name -eq 'pip-mcpsql-sql' }).Count |
            Should -Be 0
    }

    It 'uses exact NSG ASG boundaries, source CIDR, protocols, ports, and priorities' {
        $null = New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations
        $adminNsg = $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-admin']
        $sqlNsg = $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql']

        $adminNsg.Rules | Should -HaveCount 1
        $adminNsg.Rules[0].Name | Should -Be 'Allow-Facilitator-Rdp'
        $adminNsg.Rules[0].Priority | Should -Be 100
        $adminNsg.Rules[0].Protocol | Should -Be 'Tcp'
        $adminNsg.Rules[0].SourcePortRange | Should -Be '*'
        $adminNsg.Rules[0].SourceAddressPrefix | Should -Be '8.8.8.8/32'
        $adminNsg.Rules[0].DestinationApplicationSecurityGroupId | Should -BeLike '*/asg-mcpsql-admin'
        $adminNsg.Rules[0].DestinationPortRange | Should -Be '3389'

        ($sqlNsg.Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql').Priority | Should -Be 100
        ($sqlNsg.Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql').DestinationPortRange | Should -Be '1433'
        ($sqlNsg.Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql-Rdp').Priority | Should -Be 110
        ($sqlNsg.Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql-Rdp').DestinationPortRange | Should -Be '3389'
        foreach ($rule in @($sqlNsg.Rules | Where-Object Access -EQ 'Allow')) {
            $rule.SourceApplicationSecurityGroupId | Should -BeLike '*/asg-mcpsql-admin'
            $rule.DestinationApplicationSecurityGroupId | Should -BeLike '*/asg-mcpsql-sql'
        }
        $deny = $sqlNsg.Rules | Where-Object Name -EQ 'Deny-Other-VNet-To-Sql'
        $deny.Priority | Should -Be 4000
        $deny.Protocol | Should -Be '*'
        $deny.SourceAddressPrefix | Should -Be 'VirtualNetwork'
        $deny.DestinationApplicationSecurityGroupId | Should -BeLike '*/asg-mcpsql-sql'
        $deny.DestinationPortRange | Should -Be '*'
        $deny.Access | Should -Be 'Deny'
    }

    It 'creates private NAT and subnet NSG associations and the approved NIC boundaries' {
        $null = New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations
        $vnet = $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop']
        foreach ($subnet in $vnet.Subnets) {
            $subnet.PrivateEndpointNetworkPolicies | Should -Be 'Disabled'
            $subnet.DefaultOutboundAccess | Should -BeFalse
            $subnet.NatGatewayId | Should -BeLike '*/nat-mcpsql-workshop'
            $subnet.NetworkSecurityGroupId | Should -Match '/nsg-mcpsql-(admin|sql)$'
        }
        $adminNic = $script:NetworkState['NetworkInterface/nic-mcpsql-admin']
        $sqlNic = $script:NetworkState['NetworkInterface/nic-mcpsql-sql']
        $adminNic.PublicIpAddressId | Should -BeLike '*/pip-mcpsql-admin'
        $adminNic.ApplicationSecurityGroupIds | Should -Be @('/subscriptions/mock/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/applicationSecurityGroups/asg-mcpsql-admin')
        $adminNic.NetworkSecurityGroupId | Should -BeNullOrEmpty
        $sqlNic.PublicIpAddressId | Should -BeNullOrEmpty
        $sqlNic.PrivateIpAllocationMethod | Should -Be 'Static'
        $sqlNic.PrivateIpAddress | Should -Be '10.20.2.10'
        $sqlNic.ApplicationSecurityGroupIds | Should -Be @('/subscriptions/mock/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/applicationSecurityGroups/asg-mcpsql-sql')
        $sqlNic.NetworkSecurityGroupId | Should -BeNullOrEmpty
    }

    It 'creates the exact private DNS zone, registration-disabled VNet link, and SQL A record' {
        $null = New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations

        $zone = $script:NetworkState['PrivateDnsZone/mcpworkshop.internal']
        $link = $script:NetworkState['PrivateDnsVirtualNetworkLink/mcpworkshop.internal/vnet-mcpsql-workshop-link']
        $record = $script:NetworkState['PrivateDnsARecord/mcpworkshop.internal/sql01']
        $zone.Id | Should -Be '/subscriptions/mock/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/privateDnsZones/mcpworkshop.internal'
        $link.VirtualNetworkId | Should -Be '/subscriptions/mock/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/virtualNetworks/vnet-mcpsql-workshop'
        $link.RegistrationEnabled | Should -BeFalse
        $record.RecordType | Should -Be 'A'
        $record.Ipv4Addresses | Should -Be @('10.20.2.10')
    }

    It 'is idempotent when every existing resource exactly matches' {
        $first = New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations
        $script:NetworkCreates.Clear()
        $second = New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations

        $first.Completed | Should -BeTrue
        $second.Completed | Should -BeTrue
        $script:NetworkCreates | Should -HaveCount 0
    }

    It 'refuses a conflicting existing resource without updating it' {
        $null = New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations
        $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop'].AddressPrefix = '10.99.0.0/16'
        $script:NetworkCreates.Clear()

        { New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations } |
            Should -Throw -ExpectedMessage '*conflicts with the approved shape*'
        $script:NetworkCreates | Should -HaveCount 0
    }

    It 'throws with a resumable checkpoint when positive read-back is missing' {
        $script:SkipReadBackKind = 'NatGateway'
        { New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations } |
            Should -Throw -ExpectedMessage '*NatGateway*native read-back*Checkpoint*'
        @($script:NetworkState.Keys | Where-Object { $_ -like 'PublicIpAddress/*' }).Count | Should -Be 2
    }
}

Describe 'Workshop network boundary verification' {
    BeforeEach {
        $script:NetworkState = @{}
        $script:NetworkOperations = @{
            SupportsDefaultOutboundAccess = { $true }
            GetSubscriptionId = { 'mock' }
            GetResource = {
                param($Kind, $Name, $ResourceGroupName)
                $null = $ResourceGroupName
                $key = "$Kind/$Name"
                if ($script:NetworkState.ContainsKey($key)) { return $script:NetworkState[$key] }
                return $null
            }
            CreateResource = {
                param($Spec, $ResourceGroupName)
                $null = $ResourceGroupName
                $script:NetworkState["$($Spec.Kind)/$($Spec.Name)"] = $Spec
                return $Spec
            }
            GetPublicIpInventory = {
                param($ResourceGroupName)
                $null = $ResourceGroupName
                @($script:NetworkState.Values | Where-Object Kind -EQ 'PublicIpAddress')
            }
        }
        $null = New-WorkshopNetwork -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations
    }

    It 'passes the exact approved deployed boundary without mutation' {
        $script:NetworkOperations.Remove('CreateResource')
        $result = Test-WorkshopNetworkBoundary -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations
        $result.Passed | Should -BeTrue
        @($result.Checks | Where-Object Status -EQ 'Failed') | Should -HaveCount 0
    }

    It 'fails every critical boundary violation' -ForEach @(
        @{ Case = 'SQL public IP'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-sql'].PublicIpAddressId = '/public/sql' } }
        @{ Case = 'SQL secondary public IP'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-sql'] | Add-Member -NotePropertyName PublicIpAddressIds -NotePropertyValue @($null, '/public/sql') -Force } }
        @{ Case = 'admin missing expected public IP'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-admin'].PublicIpAddressId = $null } }
        @{ Case = 'public SQL TCP'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules += [pscustomobject]@{ Name='Bad'; Priority=200; Direction='Inbound'; Access='Allow'; Protocol='Tcp'; SourceAddressPrefix='Internet'; DestinationPortRange='1433' } } }
        @{ Case = 'public SQL CIDR'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules += [pscustomobject]@{ Name='Bad'; Priority=200; Direction='Inbound'; Access='Allow'; Protocol='Tcp'; SourceAddressPrefix='8.8.8.0/24'; DestinationPortRange='1433' } } }
        @{ Case = 'public SQL plural port'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules += [pscustomobject]@{ Name='Bad'; Priority=200; Direction='Inbound'; Access='Allow'; Protocol='Tcp'; SourceAddressPrefixes=@('Internet'); DestinationPortRanges=@('1433') } } }
        @{ Case = 'public SQL Browser UDP'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules += [pscustomobject]@{ Name='Bad'; Priority=200; Direction='Inbound'; Access='Allow'; Protocol='Udp'; SourceAddressPrefix='*'; DestinationPortRange='1434' } } }
        @{ Case = 'admin RDP broad'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-admin'].Rules[0].SourceAddressPrefix = 'Internet' } }
        @{ Case = 'competing admin RDP broad'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-admin'].Rules += [pscustomobject]@{ Name='Bad-Rdp'; Priority=90; Direction='Inbound'; Access='Allow'; Protocol='Tcp'; SourceAddressPrefix='Internet'; DestinationPortRange='3389' } } }
        @{ Case = 'extra admin deny'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-admin'].Rules += [pscustomobject]@{ Name='Unapproved-Deny'; Priority=90; Direction='Inbound'; Access='Deny'; Protocol='*'; SourcePortRange='*'; SourceAddressPrefix='*'; DestinationPortRange='*'; DestinationAddressPrefix='*' } } }
        @{ Case = 'high-priority SQL VNet bypass'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules += [pscustomobject]@{ Name='Allow-All-VNet-Sql'; Priority=90; Direction='Inbound'; Access='Allow'; Protocol='Tcp'; SourcePortRange='*'; SourceAddressPrefix='VirtualNetwork'; DestinationPortRange='1433'; DestinationApplicationSecurityGroupId=$script:NetworkState['ApplicationSecurityGroup/asg-mcpsql-sql'].Id } } }
        @{ Case = 'extra SQL deny'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules += [pscustomobject]@{ Name='Unapproved-Sql-Deny'; Priority=120; Direction='Inbound'; Access='Deny'; Protocol='Tcp'; SourcePortRange='*'; SourceAddressPrefix='VirtualNetwork'; DestinationPortRange='1433'; DestinationApplicationSecurityGroupId=$script:NetworkState['ApplicationSecurityGroup/asg-mcpsql-sql'].Id } } }
        @{ Case = 'SQL ASG rule wrong'; Change = { ($script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql').SourceApplicationSecurityGroupId = '/wrong' } }
        @{ Case = 'deny absent'; Change = { $script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules = @($script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules | Where-Object Name -NE 'Deny-Other-VNet-To-Sql') } }
        @{ Case = 'deny priority wrong'; Change = { ($script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules | Where-Object Name -EQ 'Deny-Other-VNet-To-Sql').Priority = 3999 } }
        @{ Case = 'subnet prefix wrong'; Change = { $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop'].Subnets[1].AddressPrefix = '10.20.3.0/24' } }
        @{ Case = 'subnet NAT missing'; Change = { $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop'].Subnets[0].NatGatewayId = $null } }
        @{ Case = 'subnet NSG missing'; Change = { $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop'].Subnets[1].NetworkSecurityGroupId = $null } }
        @{ Case = 'subnet NAT lookalike resource group'; Change = { $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop'].Subnets[0].NatGatewayId = '/subscriptions/mock/resourceGroups/other/providers/Microsoft.Network/natGateways/nat-mcpsql-workshop' } }
        @{ Case = 'subnet NSG lookalike subscription'; Change = { $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop'].Subnets[1].NetworkSecurityGroupId = '/subscriptions/other/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/networkSecurityGroups/nsg-mcpsql-sql' } }
        @{ Case = 'default outbound enabled'; Change = { $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop'].Subnets[1].DefaultOutboundAccess = $true } }
        @{ Case = 'default outbound unverifiable'; Change = { $script:NetworkState['VirtualNetwork/vnet-mcpsql-workshop'].Subnets[1].PSObject.Properties.Remove('DefaultOutboundAccess') } }
        @{ Case = 'SQL private IP wrong'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-sql'].PrivateIpAddress = '10.20.2.11' } }
        @{ Case = 'admin subnet wrong'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-admin'].SubnetId = '/vnet/wrong/subnets/snet-sql' } }
        @{ Case = 'SQL subnet wrong'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-sql'].SubnetId = '/vnet/wrong/subnets/snet-admin' } }
        @{ Case = 'admin allocation static'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-admin'].PrivateIpAllocationMethod = 'Static' } }
        @{ Case = 'SQL allow outbound'; Change = { ($script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql').Direction = 'Outbound' } }
        @{ Case = 'SQL allow source port narrowed'; Change = { ($script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql').SourcePortRange = '1433' } }
        @{ Case = 'SQL allow mixed public source'; Change = { ($script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules | Where-Object Name -EQ 'Allow-Admin-To-Sql').SourceAddressPrefix = 'Internet' } }
        @{ Case = 'deny outbound'; Change = { ($script:NetworkState['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules | Where-Object Name -EQ 'Deny-Other-VNet-To-Sql').Direction = 'Outbound' } }
        @{ Case = 'NIC NSG attached'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-admin'].NetworkSecurityGroupId = '/nsg/forbidden' } }
        @{ Case = 'admin NIC PIP lookalike subscription'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-admin'].PublicIpAddressId = '/subscriptions/other/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/publicIPAddresses/pip-mcpsql-admin'; $script:NetworkState['NetworkInterface/nic-mcpsql-admin'].PublicIpAddressIds = @($script:NetworkState['NetworkInterface/nic-mcpsql-admin'].PublicIpAddressId) } }
        @{ Case = 'admin NIC ASG lookalike resource group'; Change = { $script:NetworkState['NetworkInterface/nic-mcpsql-admin'].ApplicationSecurityGroupIds = @('/subscriptions/mock/resourceGroups/other/providers/Microsoft.Network/applicationSecurityGroups/asg-mcpsql-admin') } }
        @{ Case = 'admin PIP wrong SKU'; Change = { $script:NetworkState['PublicIpAddress/pip-mcpsql-admin'].Sku = 'Basic' } }
        @{ Case = 'NAT PIP dynamic'; Change = { $script:NetworkState['PublicIpAddress/pip-mcpsql-nat'].AllocationMethod = 'Dynamic' } }
        @{ Case = 'NAT PIP IPv6'; Change = { $script:NetworkState['PublicIpAddress/pip-mcpsql-nat'].IpAddressVersion = 'IPv6' } }
        @{ Case = 'NAT wrong SKU'; Change = { $script:NetworkState['NatGateway/nat-mcpsql-workshop'].Sku = 'Basic' } }
        @{ Case = 'NAT lookalike identity'; Change = { $script:NetworkState['NatGateway/nat-mcpsql-workshop'].Id = '/subscriptions/other/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/natGateways/nat-mcpsql-workshop' } }
        @{ Case = 'DNS zone wrong identity'; Change = { $script:NetworkState['PrivateDnsZone/mcpworkshop.internal'].Id = '/subscriptions/mock/resourceGroups/other/providers/Microsoft.Network/privateDnsZones/mcpworkshop.internal' } }
        @{ Case = 'DNS registration enabled'; Change = { $script:NetworkState['PrivateDnsVirtualNetworkLink/mcpworkshop.internal/vnet-mcpsql-workshop-link'].RegistrationEnabled = $true } }
        @{ Case = 'DNS VNet lookalike'; Change = { $script:NetworkState['PrivateDnsVirtualNetworkLink/mcpworkshop.internal/vnet-mcpsql-workshop-link'].VirtualNetworkId = '/subscriptions/other/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/virtualNetworks/vnet-mcpsql-workshop' } }
        @{ Case = 'DNS record extra address'; Change = { $script:NetworkState['PrivateDnsARecord/mcpworkshop.internal/sql01'].Ipv4Addresses += '10.20.2.11' } }
        @{ Case = 'DNS record wrong address'; Change = { $script:NetworkState['PrivateDnsARecord/mcpworkshop.internal/sql01'].Ipv4Addresses = @('10.20.2.11') } }
    ) {
        & $Change
        $script:NetworkOperations.Remove('CreateResource')
        $result = Test-WorkshopNetworkBoundary -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations
        $result.Passed | Should -BeFalse -Because $Case
        @($result.Checks | Where-Object Status -EQ 'Failed').Count | Should -BeGreaterThan 0
    }

    It 'rejects any extra public IP in the target resource group regardless of attachment' {
        $script:NetworkState['PublicIpAddress/unattached-extra'] = [pscustomobject]@{
            Kind = 'PublicIpAddress'; Name = 'unattached-extra'; Location = 'indonesiacentral'
            Id = '/subscriptions/mock/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/publicIPAddresses/unattached-extra'
            Sku = 'Standard'; AllocationMethod = 'Static'; IpAddressVersion = 'IPv4'; Tags = @{}
        }
        $script:NetworkOperations.Remove('CreateResource')

        $result = Test-WorkshopNetworkBoundary -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations

        $result.Passed | Should -BeFalse
        ($result.Checks | Where-Object Name -EQ 'Standard static public IP inventory').Status | Should -Be 'Failed'
    }

    It 'fails closed and sanitizes an unverifiable read without mutating anything' {
        $script:NetworkOperations.GetResource = { throw "read failed`nwith detail" }
        $result = Test-WorkshopNetworkBoundary -Config $script:Config -FacilitatorCidr '8.8.8.8/32' -Operations $script:NetworkOperations
        $result.Passed | Should -BeFalse
        @($result.Checks | Where-Object Status -EQ 'Failed').Count | Should -BeGreaterThan 0
        foreach ($check in $result.Checks) {
            $check.Detail | Should -Not -Match "[`r`n]"
        }
    }
}

Describe 'Default workshop network operation shape' {
    It 'normalizes native network resources that expose Tag instead of Tags' {
        InModuleScope Workshop.Azure {
            $native = [pscustomobject]@{
                Name = 'asg-test'
                Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/applicationSecurityGroups/asg-test'
                Location = 'indonesiacentral'
                Tag = @{ environment = 'workshop'; workload = 'mcp-sql' }
            }

            { $script:normalizedAsg = ConvertFrom-WorkshopAzNetworkResource `
                    -Kind 'ApplicationSecurityGroup' -Resource $native } | Should -Not -Throw
            $script:normalizedAsg.Tags.environment | Should -BeExactly 'workshop'
            $script:normalizedAsg.Tags.workload | Should -BeExactly 'mcp-sql'
        }
    }

    It 'normalizes singular-only NSG rules with an empty source ASG collection' {
        InModuleScope Workshop.Azure {
            $destinationAsg = [pscustomobject]@{ Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/applicationSecurityGroups/asg-admin' }
            $native = [pscustomobject]@{
                Name = 'nsg-test'
                Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg-test'
                Location = 'indonesiacentral'
                Tags = @{ environment = 'workshop'; workload = 'mcp-sql' }
                SecurityRules = @(
                    [pscustomobject]@{
                        Name = 'Allow-Rdp'; Priority = 100; Direction = 'Inbound'; Access = 'Allow'; Protocol = 'Tcp'
                        SourcePortRange = '*'; SourceAddressPrefix = '203.0.113.10/32'
                        SourceApplicationSecurityGroups = @()
                        DestinationPortRange = '3389'; DestinationAddressPrefix = $null
                        DestinationApplicationSecurityGroups = @($destinationAsg)
                    }
                )
            }

            { $script:normalizedNsg = ConvertFrom-WorkshopAzNetworkResource `
                    -Kind 'NetworkSecurityGroup' -Resource $native } | Should -Not -Throw
            $script:normalizedNsg.Rules | Should -HaveCount 1
            $script:normalizedNsg.Rules[0].SourceApplicationSecurityGroupId | Should -BeNullOrEmpty
            $script:normalizedNsg.Rules[0].DestinationApplicationSecurityGroupId | Should -BeExactly $destinationAsg.Id
            $script:normalizedNsg.Rules[0].SourcePortRanges | Should -HaveCount 0
            $script:normalizedNsg.Rules[0].DestinationAddressPrefixes | Should -HaveCount 0
        }
    }

    It 'normalizes private DNS records that do not expose a Location property' {
        InModuleScope Workshop.Azure {
            $native = [pscustomobject]@{
                Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/example.internal/A/sql01'
                Name = 'sql01'
                ZoneName = 'example.internal'
                RecordType = 'A'
                Ttl = 300
                Records = @([pscustomobject]@{ Ipv4Address = '10.20.2.10' })
            }

            { $script:normalizedRecord = ConvertFrom-WorkshopAzNetworkResource `
                    -Kind 'PrivateDnsARecord' -Resource $native } | Should -Not -Throw
            $script:normalizedRecord.Location | Should -BeExactly 'global'
            $script:normalizedRecord.Ipv4Addresses | Should -Be @('10.20.2.10')
        }
    }

    It 'normalizes absent NIC references to null instead of an empty string' {
        InModuleScope Workshop.Azure {
            $native = [pscustomobject]@{
                Name = 'nic-test'
                Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic-test'
                Location = 'indonesiacentral'
                Tags = @{ environment = 'workshop'; workload = 'mcp-sql' }
                NetworkSecurityGroup = $null
                IpConfigurations = @(
                    [pscustomobject]@{
                        Name = 'ipconfig1'
                        PrivateIpAllocationMethod = 'Dynamic'
                        PrivateIpAddress = '10.20.1.4'
                        Subnet = [pscustomobject]@{ Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/admin' }
                        PublicIpAddress = [pscustomobject]@{ Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip-admin' }
                        ApplicationSecurityGroups = @([pscustomobject]@{ Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/applicationSecurityGroups/asg-admin' })
                    }
                )
            }

            $normalized = ConvertFrom-WorkshopAzNetworkResource -Kind 'NetworkInterface' -Resource $native
            $normalized.NetworkSecurityGroupId | Should -BeNullOrEmpty
            $normalized.NetworkSecurityGroupId | Should -Be $null
        }
    }

    It 'derives private-subnet support from command parameter metadata' {
        InModuleScope Workshop.Azure {
            Mock Get-Command {
                [pscustomobject]@{ Parameters = @{ DefaultOutboundAccess = $null } }
            } -ParameterFilter { $Name -eq 'New-AzVirtualNetworkSubnetConfig' }
            $operations = Get-DefaultWorkshopNetworkOperationSet

            (& $operations.SupportsDefaultOutboundAccess) | Should -BeTrue
            Should -Invoke Get-Command -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'New-AzVirtualNetworkSubnetConfig' -and $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'matches native NSG rule shapes by canonical custom tuples rather than object property layout' {
        InModuleScope Workshop.Azure -Parameters @{ Config = $script:Config } {
            param($Config)
            $expected = Get-WorkshopNetworkResourceSpecification -Config $Config `
                -FacilitatorCidr '8.8.8.8/32' -SubscriptionId 'mock' |
                Where-Object { $_.Kind -eq 'NetworkSecurityGroup' -and $_.Name -eq 'nsg-mcpsql-admin' }
            $nativeRules = @($expected.Rules | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name; Priority = $_.Priority; Direction = $_.Direction; Access = $_.Access; Protocol = $_.Protocol
                    SourcePortRange = $_.SourcePortRange; SourcePortRanges = @()
                    SourceAddressPrefix = $_.SourceAddressPrefix; SourceAddressPrefixes = @()
                    SourceApplicationSecurityGroupId = $_.SourceApplicationSecurityGroupId; SourceApplicationSecurityGroupIds = @()
                    DestinationPortRange = $_.DestinationPortRange; DestinationPortRanges = @()
                    DestinationAddressPrefix = $_.DestinationAddressPrefix; DestinationAddressPrefixes = @()
                    DestinationApplicationSecurityGroupId = $_.DestinationApplicationSecurityGroupId
                    DestinationApplicationSecurityGroupIds = @()
                }
            })
            $nativeShape = [pscustomobject]@{
                Kind = $expected.Kind; Name = $expected.Name; Location = $expected.Location
                Id = $expected.Id; Tags = $expected.Tags; Rules = $nativeRules
            }

            Test-WorkshopNetworkResourceMatch -Expected $expected -Actual $nativeShape | Should -BeTrue
        }
    }

    It 'uses native Az mutation commands with ErrorAction Stop and exactly two Standard static public IP calls' {
        InModuleScope Workshop.Azure -Parameters @{ Config = $script:Config } {
            param($Config)
            Set-Item -Path Function:New-AzPrivateDnsZone -Value {
                [CmdletBinding()]
                param($ResourceGroupName, $Name, $Tag)
                $null = $ResourceGroupName, $Name, $Tag
            }
            Set-Item -Path Function:New-AzPrivateDnsVirtualNetworkLink -Value {
                [CmdletBinding()]
                param($ResourceGroupName, $ZoneName, $Name, $VirtualNetworkId, $EnableRegistration, $Tag)
                $null = $ResourceGroupName, $ZoneName, $Name, $VirtualNetworkId, $EnableRegistration, $Tag
            }
            Set-Item -Path Function:New-AzPrivateDnsRecordConfig -Value {
                param($IPv4Address)
                $null = $IPv4Address
            }
            Set-Item -Path Function:New-AzPrivateDnsRecordSet -Value {
                [CmdletBinding()]
                param($ResourceGroupName, $ZoneName, $Name, $RecordType, $Ttl, $PrivateDnsRecords)
                $null = $ResourceGroupName, $ZoneName, $Name, $RecordType, $Ttl, $PrivateDnsRecords
            }
            Mock New-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = $Name; Location = $Location } }
            Mock New-AzApplicationSecurityGroup { [pscustomobject]@{ Name = $Name; Id = "/asg/$Name" } }
            Mock Get-AzApplicationSecurityGroup {
                [Microsoft.Azure.Commands.Network.Models.PSApplicationSecurityGroup]@{ Name = $Name; Id = "/asg/$Name" }
            }
            Mock New-AzPublicIpAddress { [pscustomobject]@{ Name = $Name; Id = "/pip/$Name" } }
            Mock Get-AzPublicIpAddress {
                [Microsoft.Azure.Commands.Network.Models.PSPublicIpAddress]@{ Name = $Name; Id = "/pip/$Name" }
            }
            Mock New-AzNatGateway { [pscustomobject]@{ Name = $Name; Id = "/nat/$Name" } }
            Mock Get-AzNatGateway {
                [Microsoft.Azure.Commands.Network.Models.PSNatGateway]@{ Name = $Name; Id = "/nat/$Name" }
            }
            Mock Get-AzNetworkSecurityGroup {
                [Microsoft.Azure.Commands.Network.Models.PSNetworkSecurityGroup]@{ Name = $Name; Id = "/nsg/$Name" }
            }
            Mock New-AzNetworkSecurityRuleConfig {
                [Microsoft.Azure.Commands.Network.Models.PSSecurityRule]@{ Name = $Name }
            }
            Mock New-AzNetworkSecurityGroup { [pscustomobject]@{ Name = $Name; Id = "/nsg/$Name" } }
            Mock New-AzVirtualNetworkSubnetConfig {
                [Microsoft.Azure.Commands.Network.Models.PSSubnet]@{ Name = $Name }
            }
            Mock New-AzVirtualNetwork { [pscustomobject]@{ Name = $Name; Id = "/vnet/$Name" } }
            Mock Get-AzVirtualNetwork {
                [Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork]@{
                    Name = $Name
                    Id = "/vnet/$Name"
                    Subnets = @(
                        [Microsoft.Azure.Commands.Network.Models.PSSubnet]@{ Name = 'snet-admin'; Id = '/subnet/snet-admin' }
                        [Microsoft.Azure.Commands.Network.Models.PSSubnet]@{ Name = 'snet-sql'; Id = '/subnet/snet-sql' }
                    )
                }
            }
            Mock New-AzNetworkInterfaceIpConfig {
                [Microsoft.Azure.Commands.Network.Models.PSNetworkInterfaceIPConfiguration]@{ Name = $Name }
            }
            Mock New-AzNetworkInterface { [pscustomobject]@{ Name = $Name; Id = "/nic/$Name" } }
            Mock New-AzPrivateDnsZone { [pscustomobject]@{ Name = $Name; ResourceId = "/privateDnsZones/$Name" } }
            Mock New-AzPrivateDnsVirtualNetworkLink { [pscustomobject]@{ Name = $Name; ResourceId = "/privateDnsLinks/$Name" } }
            Mock New-AzPrivateDnsRecordConfig { [pscustomobject]@{ Ipv4Address = $IPv4Address } }
            Mock New-AzPrivateDnsRecordSet { [pscustomobject]@{ Name = $Name; RecordType = $RecordType } }

            $operations = Get-DefaultWorkshopNetworkOperationSet
            $specs = Get-WorkshopNetworkResourceSpecification -Config $Config `
                -FacilitatorCidr '8.8.8.8/32' -SubscriptionId 'mock'
            foreach ($spec in $specs) { $null = & $operations.CreateResource $spec $Config.ResourceGroupName }

            Should -Invoke New-AzPublicIpAddress -Times 2 -Exactly -ParameterFilter {
                $Name -in @('pip-mcpsql-admin', 'pip-mcpsql-nat') -and $Sku -eq 'Standard' -and
                $AllocationMethod -eq 'Static' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke New-AzNatGateway -Times 1 -Exactly -ParameterFilter { $Sku -eq 'Standard' -and $ErrorAction -eq 'Stop' }
            Should -Invoke New-AzPrivateDnsZone -Times 1 -Exactly -ParameterFilter { $Name -eq 'mcpworkshop.internal' -and $ErrorAction -eq 'Stop' }
            Should -Invoke New-AzPrivateDnsVirtualNetworkLink -Times 1 -Exactly -ParameterFilter { $ZoneName -eq 'mcpworkshop.internal' -and -not $EnableRegistration -and $ErrorAction -eq 'Stop' }
            Should -Invoke New-AzPrivateDnsRecordSet -Times 1 -Exactly -ParameterFilter { $ZoneName -eq 'mcpworkshop.internal' -and $Name -eq 'sql01' -and $RecordType -eq 'A' -and $ErrorAction -eq 'Stop' }
            Should -Invoke New-AzNetworkInterface -Times 2 -Exactly -ParameterFilter { $null -eq $NetworkSecurityGroup -and $ErrorAction -eq 'Stop' }
            Should -Invoke New-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $ErrorAction -eq 'Stop' }
        }
    }

    It 'enumerates every public IP in the target resource group with terminating errors' {
        InModuleScope Workshop.Azure {
            Mock Get-AzPublicIpAddress { @() }
            Mock Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-id' } } }
            $operations = Get-DefaultWorkshopNetworkOperationSet

            $null = & $operations.GetPublicIpInventory 'rg-mcp-sql-workshop'

            Should -Invoke Get-AzPublicIpAddress -Times 1 -Exactly -ParameterFilter {
                $ResourceGroupName -eq 'rg-mcp-sql-workshop' -and
                -not $PSBoundParameters.ContainsKey('Name') -and $ErrorAction -eq 'Stop'
            }
        }
    }
}

Describe 'Immutable workshop image resolution' {
    It 'queries exact coordinates and selects the highest valid immutable version' {
        $script:ImageQuery = $null
        $operations = @{
            GetImages = {
                param($Publisher, $Offer, $Sku, $Location)
                $script:ImageQuery = @($Publisher, $Offer, $Sku, $Location)
                @(
                    [pscustomobject]@{ Version = '26100.9.1' }
                    [pscustomobject]@{ Version = 'latest' }
                    [pscustomobject]@{ Version = 'bad' }
                    [pscustomobject]@{ Version = '26100.10.2' }
                )
            }
        }

        $result = Resolve-WorkshopImageVersion -Publisher 'MicrosoftWindowsDesktop' -Offer 'windows-11' `
            -Sku 'win11-24h2-ent' -Location 'indonesiacentral' -Operations $operations

        $result.Version | Should -Be '26100.10.2'
        $script:ImageQuery | Should -Be @(
            'MicrosoftWindowsDesktop', 'windows-11', 'win11-24h2-ent', 'indonesiacentral'
        )
    }

    It 'rejects empty, latest-only, and malformed results' -ForEach @(
        @{ Images = @() }
        @{ Images = @([pscustomobject]@{ Version = 'latest' }) }
        @{ Images = @([pscustomobject]@{ Version = '1.2' }, [pscustomobject]@{ Version = 'not-valid' }) }
        @{ Images = @($null, [pscustomobject]@{ Other = '1.2.3' }) }
    ) {
        $returnedImages = $Images
        $operations = @{ GetImages = { $returnedImages }.GetNewClosure() }
        { Resolve-WorkshopImageVersion -Publisher 'p' -Offer 'o' -Sku 's' -Location 'l' -Operations $operations } |
            Should -Throw '*immutable image version*'
    }
}

Describe 'Exact workshop VM creation' {
    BeforeEach {
        $script:VmState = @{}
        $script:DiskState = @{}
        $script:VmCreates = [System.Collections.Generic.List[object]]::new()
        $script:DiskCreates = [System.Collections.Generic.List[object]]::new()
        $script:SkipVmReadBack = $false
        $script:VmOperations = @{
            GetSubscriptionId = { '11111111-1111-1111-1111-111111111111' }
            GetVm = {
                param($Name, $ResourceGroupName)
                $null = $ResourceGroupName
                if ($script:VmState.ContainsKey($Name)) { return $script:VmState[$Name] }
                $null
            }
            GetDisk = {
                param($Name, $ResourceGroupName)
                $null = $ResourceGroupName
                if ($script:DiskState.ContainsKey($Name)) { return $script:DiskState[$Name] }
                $null
            }
            CreateVm = {
                param($Spec, [System.Management.Automation.PSCredential] $Credential, $ResourceGroupName)
                $null = $Credential, $ResourceGroupName
                $script:VmCreates.Add($Spec)
                if (-not $script:SkipVmReadBack) { $script:VmState[$Spec.Name] = $Spec }
            }
            CreateDisk = {
                param($Spec, $ResourceGroupName)
                $null = $ResourceGroupName
                $script:DiskCreates.Add($Spec)
                $script:DiskState[$Spec.Name] = $Spec
            }
        }
        $script:VmCredential = Get-TestCredential
    }

    It 'creates the attested Windows client VM with exact Trusted Launch, OS disk, image, and admin NIC' {
        $result = New-WorkshopAdminVm -Config $script:Config -ImageVersion '26100.2033.1' `
            -Credential $script:VmCredential -WindowsClientLicenseAttested $true -Operations $script:VmOperations

        $result.Completed | Should -BeTrue
        $script:VmCreates | Should -HaveCount 1
        $vm = $script:VmCreates[0]
        $vm.Name | Should -Be 'vm-mcpsql-admin'
        $vm.VmSize | Should -Be 'Standard_D4s_v5'
        $vm.Image.Publisher | Should -Be 'MicrosoftWindowsDesktop'
        $vm.Image.Offer | Should -Be 'windows-11'
        $vm.Image.Sku | Should -Be 'win11-24h2-ent'
        $vm.Image.Version | Should -Be '26100.2033.1'
        $vm.LicenseType | Should -Be 'Windows_Client'
        $vm.SecurityType | Should -Be 'TrustedLaunch'
        $vm.SecureBoot | Should -BeTrue
        $vm.VTpm | Should -BeTrue
        $vm.OsDisk.Name | Should -Be 'osdisk-mcpsql-admin'
        $vm.OsDisk.SizeGiB | Should -Be 128
        $vm.OsDisk.Sku | Should -Be 'Premium_LRS'
        $vm.OsDisk.Caching | Should -Be 'ReadWrite'
        $vm.NetworkInterfaceIds | Should -Be @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/networkInterfaces/nic-mcpsql-admin')
    }

    It 'refuses the Windows client VM before any read or mutation without licensing attestation' {
        $script:Reads = 0
        $script:VmOperations.GetVm = { $script:Reads++; $null }
        { New-WorkshopAdminVm -Config $script:Config -ImageVersion '26100.2033.1' `
                -Credential $script:VmCredential -WindowsClientLicenseAttested $false -Operations $script:VmOperations } |
            Should -Throw '*attestation*'
        $script:Reads | Should -Be 0
        $script:VmCreates | Should -HaveCount 0
    }

    It 'creates exact SQL data and log disks then the private SQL VM' {
        $result = New-WorkshopSqlVm -Config $script:Config -ImageVersion '16.0.1135.2' `
            -Credential $script:VmCredential -Operations $script:VmOperations

        $result.Completed | Should -BeTrue
        @($script:DiskCreates.Name) | Should -Be @('disk-mcpsql-sql-data', 'disk-mcpsql-sql-log')
        $script:DiskCreates[0].SizeGiB | Should -Be 256
        $script:DiskCreates[0].Lun | Should -Be 0
        $script:DiskCreates[0].Caching | Should -Be 'ReadOnly'
        $script:DiskCreates[1].SizeGiB | Should -Be 128
        $script:DiskCreates[1].Lun | Should -Be 1
        $script:DiskCreates[1].Caching | Should -Be 'None'
        @($script:DiskCreates.Sku | Select-Object -Unique) | Should -Be @('Premium_LRS')
        $vm = $script:VmCreates[0]
        $vm.Name | Should -Be 'vm-mcpsql-sql'
        $vm.VmSize | Should -Be 'Standard_E8s_v5'
        $vm.OsType | Should -Be 'Windows'
        $vm.Image.Publisher | Should -Be 'MicrosoftSQLServer'
        $vm.Image.Offer | Should -Be 'SQL2022-WS2022'
        $vm.Image.Sku | Should -Be 'enterprise-gen2'
        $vm.Image.Version | Should -Be '16.0.1135.2'
        $vm.LicenseType | Should -BeNullOrEmpty
        $vm.SecurityType | Should -Be 'TrustedLaunch'
        $vm.SecureBoot | Should -BeTrue
        $vm.VTpm | Should -BeTrue
        $vm.OsDisk.SizeGiB | Should -Be 128
        $vm.OsDisk.Sku | Should -Be 'Premium_LRS'
        $vm.NetworkInterfaceIds | Should -Be @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/networkInterfaces/nic-mcpsql-sql')
        @($vm.NetworkInterfaceIds | Where-Object { $_ -match 'publicIPAddresses' }) | Should -HaveCount 0
        @($vm.DataDisks) | Should -HaveCount 2
    }

    It 'reuses exact existing VM and disks without mutation' {
        $null = New-WorkshopSqlVm -Config $script:Config -ImageVersion '16.0.1135.2' `
            -Credential $script:VmCredential -Operations $script:VmOperations
        $script:DiskCreates.Clear()
        $script:VmCreates.Clear()

        $result = New-WorkshopSqlVm -Config $script:Config -ImageVersion '16.0.1135.2' `
            -Credential $script:VmCredential -Operations $script:VmOperations

        $result.Completed | Should -BeTrue
        $script:DiskCreates | Should -HaveCount 0
        $script:VmCreates | Should -HaveCount 0
    }

    It 'fails all known shape conflicts before any later mutation' -ForEach @(
        @{ Target = 'VM'; Property = 'VmSize'; Value = 'Standard_E2s_v5' }
        @{ Target = 'VM'; Property = 'SecurityType'; Value = $null }
        @{ Target = 'VM'; Property = 'SecureBoot'; Value = $false }
        @{ Target = 'VM'; Property = 'VTpm'; Value = $false }
        @{ Target = 'VM'; Property = 'NetworkInterfaceIds'; Value = @('/wrong/nic') }
        @{ Target = 'VM'; Property = 'Image'; Value = [pscustomobject]@{ Publisher='MicrosoftSQLServer'; Offer='SQL2022-WS2022'; Sku='enterprise-gen2'; Version='latest' } }
        @{ Target = 'Data'; Property = 'SizeGiB'; Value = 512 }
        @{ Target = 'Log'; Property = 'Caching'; Value = 'ReadOnly' }
    ) {
        $null = New-WorkshopSqlVm -Config $script:Config -ImageVersion '16.0.1135.2' `
            -Credential $script:VmCredential -Operations $script:VmOperations
        $script:VmCreates.Clear(); $script:DiskCreates.Clear()
        if ($Target -eq 'VM') { $script:VmState['vm-mcpsql-sql'].$Property = $Value }
        elseif ($Target -eq 'Data') { $script:DiskState['disk-mcpsql-sql-data'].$Property = $Value }
        else { $script:DiskState['disk-mcpsql-sql-log'].$Property = $Value }

        { New-WorkshopSqlVm -Config $script:Config -ImageVersion '16.0.1135.2' `
                -Credential $script:VmCredential -Operations $script:VmOperations } |
            Should -Throw '*conflicts with the approved shape*'
        $script:VmCreates | Should -HaveCount 0
        $script:DiskCreates | Should -HaveCount 0
    }

    It 'requires positive exact VM readback after create' {
        $script:SkipVmReadBack = $true
        { New-WorkshopAdminVm -Config $script:Config -ImageVersion '26100.2033.1' `
                -Credential $script:VmCredential -WindowsClientLicenseAttested $true -Operations $script:VmOperations } |
            Should -Throw '*positive read-back*'
    }

    It 'rejects SQL Trusted Launch mismatch during positive readback' -ForEach @(
        @{ Property = 'SecurityType'; Value = $null }
        @{ Property = 'SecureBoot'; Value = $false }
        @{ Property = 'VTpm'; Value = $false }
    ) {
        $mismatchProperty = $Property
        $mismatchValue = $Value
        $vmState = $script:VmState
        $script:VmOperations.CreateVm = {
            param($Spec, [System.Management.Automation.PSCredential] $Credential, $ResourceGroupName)
            $null = $Credential, $ResourceGroupName
            $readBack = $Spec | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $readBack.$mismatchProperty = $mismatchValue
            $vmState[$Spec.Name] = $readBack
        }.GetNewClosure()

        { New-WorkshopSqlVm -Config $script:Config -ImageVersion '16.0.1135.2' `
                -Credential $script:VmCredential -Operations $script:VmOperations } |
            Should -Throw '*positive read-back*'
    }

    It 'positively verifies both approved VM boundaries' {
        $null = New-WorkshopAdminVm -Config $script:Config -ImageVersion '26100.2033.1' `
            -Credential $script:VmCredential -WindowsClientLicenseAttested $true -Operations $script:VmOperations
        $null = New-WorkshopSqlVm -Config $script:Config -ImageVersion '16.0.1135.2' `
            -Credential $script:VmCredential -Operations $script:VmOperations

        $result = Test-WorkshopVmBoundary -Config $script:Config -ResolvedImages @{
            Admin = [pscustomobject]@{ Version = '26100.2033.1' }
            Sql = [pscustomobject]@{ Version = '16.0.1135.2' }
        } -Operations $script:VmOperations

        $result.Passed | Should -BeTrue
        @($result.Checks | Where-Object Status -EQ 'Failed') | Should -HaveCount 0
    }

    It 'fails the SQL VM boundary for Trusted Launch drift' -ForEach @(
        @{ Property = 'SecurityType'; Value = $null }
        @{ Property = 'SecureBoot'; Value = $false }
        @{ Property = 'VTpm'; Value = $false }
    ) {
        $null = New-WorkshopAdminVm -Config $script:Config -ImageVersion '26100.2033.1' `
            -Credential $script:VmCredential -WindowsClientLicenseAttested $true -Operations $script:VmOperations
        $null = New-WorkshopSqlVm -Config $script:Config -ImageVersion '16.0.1135.2' `
            -Credential $script:VmCredential -Operations $script:VmOperations
        $script:VmState['vm-mcpsql-sql'].$Property = $Value

        $result = Test-WorkshopVmBoundary -Config $script:Config -ResolvedImages @{
            Admin = [pscustomobject]@{ Version = '26100.2033.1' }
            Sql = [pscustomobject]@{ Version = '16.0.1135.2' }
        } -Operations $script:VmOperations

        $result.Passed | Should -BeFalse
        ($result.Checks | Where-Object Name -EQ 'Sql VM exact shape').Status | Should -Be 'Failed'
    }
}

Describe 'SQL IaaS and auto-shutdown exact resources' {
    BeforeEach {
        $script:Iaas = $null
        $script:IaasCreates = 0
        $script:Schedules = @{}
        $script:ScheduleCreates = [System.Collections.Generic.List[object]]::new()
        $script:EmergencyStopCalls = 0
        $script:EmergencyStopResult = [pscustomobject]@{ Status = 'installed-and-verified' }
        $script:ServiceOperations = @{
            GetSubscriptionId = { '11111111-1111-1111-1111-111111111111' }
            GetTenantId = { '22222222-2222-2222-2222-222222222222' }
            GetSqlIaas = { $script:Iaas }
            CreateSqlIaas = { param($Spec) $script:IaasCreates++; $script:Iaas = $Spec }
            GetSchedule = { param($Name) if ($script:Schedules.ContainsKey($Name)) { $script:Schedules[$Name] } }
            CreateSchedule = { param($Spec) $script:ScheduleCreates.Add($Spec); $script:Schedules[$Spec.Name] = $Spec }
            EnsureEmergencyStop = {
                param($Config, $SubscriptionId, $TenantId)
                $null = $Config, $SubscriptionId, $TenantId
                $script:EmergencyStopCalls++
                $script:EmergencyStopResult
            }
        }
    }

    It 'registers SQL IaaS as PAYG only when absent and verifies exact readback' {
        $first = Register-WorkshopSqlIaas -Config $script:Config -Operations $script:ServiceOperations
        $second = Register-WorkshopSqlIaas -Config $script:Config -Operations $script:ServiceOperations

        $first.Completed | Should -BeTrue
        $second.Completed | Should -BeTrue
        $script:IaasCreates | Should -Be 1
        $script:Iaas.LicenseType | Should -Be 'PAYG'
        $script:Iaas.VirtualMachineId | Should -Be '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Compute/virtualMachines/vm-mcpsql-sql'
    }

    It 'refuses a conflicting SQL IaaS registration without mutation' {
        $script:Iaas = [pscustomobject]@{ Name='vm-mcpsql-sql'; Id='/wrong'; LicenseType='AHUB'; VirtualMachineId='/wrong' }
        { Register-WorkshopSqlIaas -Config $script:Config -Operations $script:ServiceOperations } |
            Should -Throw '*conflicts with the approved shape*'
        $script:IaasCreates | Should -Be 0
    }

    It 'completes unsupported cross-region fallback only after emergency stop is installed and verified' {
        $result = Set-WorkshopAutoShutdown -Config $script:Config -TimeZoneId 'SE Asia Standard Time' `
            -Operations $script:ServiceOperations

        $result.Completed | Should -BeTrue
        $result.ScheduleCreationSkipped | Should -BeTrue
        $result.FallbackRequired | Should -BeTrue
        $result.Fallback | Should -BeExactly 'LocalEmergencyStop'
        $result.FallbackStatus | Should -BeExactly 'installed-and-verified'
        $result.Checkpoint | Should -Contain 'LocalEmergencyStop:installed-and-verified'
        $result.Reason | Should -Match 'southeastasia.*indonesiacentral|cross-region'
        $script:EmergencyStopCalls | Should -Be 1
        $script:ScheduleCreates | Should -HaveCount 0
    }

    It 'reports a positively verified exact existing emergency stop as matched' {
        $script:EmergencyStopResult = [pscustomobject]@{ Status = 'matched-and-verified' }

        $result = Set-WorkshopAutoShutdown -Config $script:Config -Operations $script:ServiceOperations

        $result.Completed | Should -BeTrue
        $result.FallbackStatus | Should -BeExactly 'matched-and-verified'
        $result.Checkpoint | Should -Contain 'LocalEmergencyStop:matched-and-verified'
    }

    It 'blocks deployment when emergency-stop verification is not positive' -ForEach @($null, 'required', 'verification-failed') {
        $status = $_
        $script:EmergencyStopResult = if ($null -eq $status) { $null } else { [pscustomobject]@{ Status = $status } }

        { Set-WorkshopAutoShutdown -Config $script:Config -Operations $script:ServiceOperations } |
            Should -Throw '*emergency-stop*verified*'
    }

    It 'rejects an unrecognized cross-region schedule configuration without Azure mutation' {
        $config = Import-PowerShellDataFile $script:ConfigPath
        $config.AutoShutdownLocation = 'eastus'

        { Set-WorkshopAutoShutdown -Config $config -Operations $script:ServiceOperations } |
            Should -Throw '*not an approved fallback*'
        $script:ScheduleCreates | Should -HaveCount 0
    }

    It 'creates exact daily 1900 shutdown schedules when the schedule and VM locations match and is idempotent' {
        $config = Import-PowerShellDataFile $script:ConfigPath
        $config.AutoShutdownLocation = $config.Location
        $first = Set-WorkshopAutoShutdown -Config $config -TimeZoneId 'SE Asia Standard Time' `
            -Operations $script:ServiceOperations
        $second = Set-WorkshopAutoShutdown -Config $config -TimeZoneId 'SE Asia Standard Time' `
            -Operations $script:ServiceOperations

        $first.Completed | Should -BeTrue
        $second.Completed | Should -BeTrue
        $script:ScheduleCreates | Should -HaveCount 2
        $script:EmergencyStopCalls | Should -Be 0
        @($script:ScheduleCreates.Name) | Should -Be @('shutdown-computevm-vm-mcpsql-admin', 'shutdown-computevm-vm-mcpsql-sql')
        foreach ($schedule in $script:ScheduleCreates) {
            $schedule.Location | Should -Be 'indonesiacentral'
            $schedule.Status | Should -Be 'Enabled'
            $schedule.TaskType | Should -Be 'ComputeVmShutdownTask'
            $schedule.DailyRecurrenceTime | Should -Be '1900'
            $schedule.TimeZoneId | Should -Be 'SE Asia Standard Time'
            $schedule.TargetResourceId | Should -Match '/Microsoft\.Compute/virtualMachines/vm-mcpsql-(admin|sql)$'
            $schedule.NotificationStatus | Should -Be 'Disabled'
            $schedule.NotificationTimeInMinutes | Should -Be 30
        }
    }

    It 'creates or exactly matches a secret-free current-user emergency-stop task through fake task operations' {
        InModuleScope Workshop.Azure -Parameters @{ Config = $script:Config } {
            param($Config)
            $script:task = $null
            $script:createdSpecs = [System.Collections.Generic.List[object]]::new()
            $taskOperations = @{
                GetCurrentUser = { 'CONTOSO\facilitator' }
                GetPwshPath = { 'C:\Program Files\PowerShell\7\pwsh.exe' }
                GetTask = { param($Name) $null = $Name; $script:task }
                CreateTask = { param($Spec) $script:createdSpecs.Add($Spec); $script:task = $Spec }
            }

            $first = Initialize-WorkshopEmergencyStopScheduledTask -Config $Config `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -TenantId '22222222-2222-2222-2222-222222222222' -TaskOperations $taskOperations
            $second = Initialize-WorkshopEmergencyStopScheduledTask -Config $Config `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -TenantId '22222222-2222-2222-2222-222222222222' -TaskOperations $taskOperations

            $first.Status | Should -BeExactly 'installed-and-verified'
            $second.Status | Should -BeExactly 'matched-and-verified'
            $script:createdSpecs | Should -HaveCount 1
            $spec = $script:createdSpecs[0]
            $spec.Name | Should -BeExactly 'McpSqlWorkshop-EmergencyStop'
            $spec.UserId | Should -BeExactly 'CONTOSO\facilitator'
            $spec.UserId | Should -Not -Be 'SYSTEM'
            $spec.LogonType | Should -BeExactly 'Interactive'
            $spec.DailyTime | Should -BeExactly '1900'
            $spec.StartWhenAvailable | Should -BeTrue
            $spec.Execute | Should -BeExactly 'C:\Program Files\PowerShell\7\pwsh.exe'
            $spec.Arguments | Should -Match ([regex]::Escape('-SubscriptionId 11111111-1111-1111-1111-111111111111'))
            $spec.Arguments | Should -Match ([regex]::Escape('-TenantId 22222222-2222-2222-2222-222222222222'))
            $spec.Arguments | Should -Match ([regex]::Escape('-Confirm:$false'))
            $spec.Arguments | Should -Match 'Stop-WorkshopEnvironment\.ps1'
            $spec.Arguments | Should -Not -Match '(?i)password|secret|token'
        }
    }

    It 'produces emergency-stop arguments that pwsh.exe actually accepts and binds' {
        # Task Scheduler passes Arguments to the process command line verbatim, so the only
        # trustworthy assertion is running the generated string. The real script path is
        # swapped for a stub while leaving the generated quoting untouched.
        $probeRoot = Join-Path $TestDrive 'mcpsql stop probe'
        $null = New-Item -ItemType Directory -Path $probeRoot -Force
        try {
            $stub = Join-Path $probeRoot 'Stop-WorkshopEnvironment.ps1'
            Set-Content -LiteralPath $stub -Encoding utf8 -Value @(
                'param([string] $SubscriptionId, [string] $TenantId, [switch] $Confirm)'
                '"BOUND|$SubscriptionId|$TenantId|$($Confirm.IsPresent)"'
            )
            $spec = InModuleScope Workshop.Azure -Parameters @{ Config = $script:Config } {
                param($Config)
                $probe = @{ Task = $null; Captured = $null }
                $taskOperations = @{
                    GetCurrentUser = { 'CONTOSO\facilitator' }
                    GetPwshPath = { (Get-Process -Id $PID).Path }
                    GetTask = { param($Name) $null = $Name; $probe.Task }.GetNewClosure()
                    CreateTask = { param($Spec) $probe.Captured = $Spec; $probe.Task = $Spec }.GetNewClosure()
                }
                $null = Initialize-WorkshopEmergencyStopScheduledTask -Config $Config `
                    -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                    -TenantId '22222222-2222-2222-2222-222222222222' -TaskOperations $taskOperations
                $probe.Captured
            }

            $realScript = (Resolve-Path (Join-Path $PSScriptRoot '../../deploy/Stop-WorkshopEnvironment.ps1')).Path
            $spec.Arguments | Should -Match ([regex]::Escape($realScript))
            $arguments = $spec.Arguments.Replace($realScript, $stub)
            $stdout = Join-Path $probeRoot 'out.txt'
            $stderr = Join-Path $probeRoot 'err.txt'
            $process = Start-Process -FilePath $spec.Execute -ArgumentList $arguments `
                -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            ((Get-Content -LiteralPath $stderr -Raw) + '').Trim() | Should -BeNullOrEmpty
            $process.ExitCode | Should -Be 0
            ((Get-Content -LiteralPath $stdout -Raw) + '').Trim() |
                Should -BeExactly 'BOUND|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222|False'
        }
        finally {
            Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects conflicting or unverifiable emergency-stop task state through fakes' -ForEach @(
        @{ Case = 'conflict'; Expected = '*conflicts with the approved secret-free current-user shape*' },
        @{ Case = 'missing-readback'; Expected = '*was not positively verified after installation*' }
    ) {
        InModuleScope Workshop.Azure -Parameters @{ Config = $script:Config; Case = $Case; Expected = $Expected } {
            param($Config, $Case, $Expected)
            $configuration = $Config
            $script:task = if ($Case -eq 'conflict') {
                [pscustomobject]@{ Name = 'McpSqlWorkshop-EmergencyStop'; UserId = 'SYSTEM' }
            } else { $null }
            $taskOperations = @{
                GetCurrentUser = { 'CONTOSO\facilitator' }
                GetPwshPath = { 'C:\Program Files\PowerShell\7\pwsh.exe' }
                GetTask = { param($Name) $null = $Name; $script:task }
                CreateTask = { param($Spec) $null = $Spec }
            }

            { Initialize-WorkshopEmergencyStopScheduledTask -Config $configuration `
                    -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                    -TenantId '22222222-2222-2222-2222-222222222222' -TaskOperations $taskOperations } |
                Should -Throw $Expected
        }
    }

    It 'refuses a conflicting shutdown schedule before creating the other schedule' {
        $config = Import-PowerShellDataFile $script:ConfigPath
        $config.AutoShutdownLocation = $config.Location
        $script:Schedules['shutdown-computevm-vm-mcpsql-sql'] = [pscustomobject]@{
            Name='shutdown-computevm-vm-mcpsql-sql'; Id='/wrong'; Status='Enabled'; TaskType='ComputeVmShutdownTask'
            DailyRecurrenceTime='2000'; TimeZoneId='SE Asia Standard Time'; TargetResourceId='/wrong'
        }
        { Set-WorkshopAutoShutdown -Config $config -TimeZoneId 'SE Asia Standard Time' `
                -Operations $script:ServiceOperations } | Should -Throw '*conflicts with the approved shape*'
        $script:ScheduleCreates | Should -HaveCount 0
    }

    It 'refuses notification drift in an otherwise matching shutdown schedule' {
        $config = Import-PowerShellDataFile $script:ConfigPath
        $config.AutoShutdownLocation = $config.Location
        $null = Set-WorkshopAutoShutdown -Config $config -TimeZoneId 'UTC' `
            -Operations $script:ServiceOperations
        $script:ScheduleCreates.Clear()
        $script:Schedules['shutdown-computevm-vm-mcpsql-admin'].NotificationStatus = 'Enabled'

        { Set-WorkshopAutoShutdown -Config $config -TimeZoneId 'UTC' `
                -Operations $script:ServiceOperations } | Should -Throw '*conflicts with the approved shape*'
        $script:ScheduleCreates | Should -HaveCount 0
    }
}

Describe 'Scheduled task principal normalization' {
    It 'compares the task principal by security identifier, not by string form' {
        # Task Scheduler reports 'user' for a principal registered as 'DOMAIN\user', so an
        # exact string comparison rejected a correctly installed task.
        InModuleScope Workshop.Azure {
            $current = [Security.Principal.WindowsIdentity]::GetCurrent()
            $qualified = ConvertTo-WorkshopEmergencyStopComparableTask -Task ([pscustomobject]@{
                Name = 'McpSqlWorkshop-EmergencyStop'; UserId = $current.Name })
            $bare = ConvertTo-WorkshopEmergencyStopComparableTask -Task ([pscustomobject]@{
                Name = 'McpSqlWorkshop-EmergencyStop'; UserId = ($current.Name -split '\\')[-1] })

            $qualified.UserId | Should -BeExactly $bare.UserId
            $qualified.UserId | Should -BeExactly $current.User.Value
        }
    }

    It 'leaves an unresolvable principal untouched instead of throwing' {
        InModuleScope Workshop.Azure {
            ConvertTo-WorkshopUserIdentity -UserId 'NO SUCH PRINCIPAL 9f3a' |
                Should -BeExactly 'NO SUCH PRINCIPAL 9f3a'
            ConvertTo-WorkshopUserIdentity -UserId '' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Scheduled task absence detection' {
    It 'treats every documented not-found shape as absence, and nothing else' -ForEach @(
        @{ Case = 'error id'; Id = 'NoMatchingMSFT_ScheduledTaskObjectsFound'; Category = 'ObjectNotFound'; Message = 'anything'; Expected = $true }
        @{ Case = 'category only'; Id = 'SomeOtherId'; Category = 'ObjectNotFound'; Message = 'anything'; Expected = $true }
        @{ Case = 'message only'; Id = 'SomeOtherId'; Category = 'InvalidOperation'; Message = "No MSFT_ScheduledTask objects found with property 'TaskName' equal to 'x'."; Expected = $true }
        @{ Case = 'access denied'; Id = 'AccessDenied'; Category = 'PermissionDenied'; Message = 'Access is denied.'; Expected = $false }
    ) {
        # A prior deployment always left the task behind, so this branch was never exercised
        # until teardown began removing it, and a real deployment then aborted here.
        InModuleScope Workshop.Azure -Parameters @{ Id = $Id; Category = $Category; Message = $Message; Expected = $Expected } {
            param($Id, $Category, $Message, $Expected)
            $record = [System.Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new($Message),
                $Id,
                [System.Management.Automation.ErrorCategory]::$Category,
                $null)
            Test-WorkshopScheduledTaskAbsent -ErrorRecord $record | Should -Be $Expected
        }
    }
}

Describe 'Exact custom rule set comparison' {
    BeforeAll {
        $script:ExpectedRule = [pscustomobject]@{
            Name = 'Temporary-Facilitator-Rdp'; Priority = 100; Direction = 'Inbound'; Access = 'Allow'
            Protocol = 'Tcp'; SourceAddressPrefix = '111.95.209.140/32'; DestinationPortRange = @('3389')
        }
    }

    It 'reports a mismatch instead of failing when the group holds no custom rules' {
        # A governance policy can strip every rule from an existing group; resume must be
        # able to detect that rather than crash on parameter binding.
        InModuleScope Workshop.Azure -Parameters @{ Expected = $script:ExpectedRule } {
            param($Expected)
            $expectedRules = @($Expected)
            { $null = Test-WorkshopExactCustomRuleSet -ExpectedRules $expectedRules -ActualRules @() } |
                Should -Not -Throw
            Test-WorkshopExactCustomRuleSet -ExpectedRules $expectedRules -ActualRules @() | Should -BeFalse
        }
    }

    It 'treats an empty expectation against an empty group as a match' {
        InModuleScope Workshop.Azure {
            Test-WorkshopExactCustomRuleSet -ExpectedRules @() -ActualRules @() | Should -BeTrue
        }
    }
}

Describe 'Workshop stop and guarded removal' {
    BeforeEach {
        $script:ContextCalls = 0
        $script:Stopped = [System.Collections.Generic.List[string]]::new()
        $script:Started = [System.Collections.Generic.List[string]]::new()
        $script:Power = @{
            'vm-mcpsql-admin' = 'PowerState/running'
            'vm-mcpsql-sql' = 'PowerState/running'
        }
        $script:LifecycleOperations = @{
            SetContext = { $script:ContextCalls++ }
            GetVm = {
                param($Name)
                [pscustomobject]@{
                    Name=$Name
                    Id="/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Compute/virtualMachines/$Name"
                }
            }
            StopVm = { param($Name) $script:Stopped.Add($Name); $script:Power[$Name] = 'PowerState/deallocated' }
            StartVm = { param($Name) $script:Started.Add($Name); $script:Power[$Name] = 'PowerState/running' }
            GetPowerState = { param($Name) $script:Power[$Name] }
        }
        $script:RemoveCalls = 0
        $script:GroupRemoved = $false
        $script:RemoveOperations = @{
            SetContext = { $script:ContextCalls++ }
            GetResourceGroup = {
                if ($script:GroupRemoved) { return [pscustomobject]@{ Status='NotFound'; ResourceGroup=$null } }
                [pscustomobject]@{ Status='Found'; ResourceGroup=[pscustomobject]@{
                    ResourceGroupName='rg-mcp-sql-workshop'
                    ResourceId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-mcp-sql-workshop'
                    Tags=@{ environment='workshop'; workload='mcp-sql'; managedBy='PowerShell' }
                } }
            }
            RemoveResourceGroup = { $script:RemoveCalls++; $script:GroupRemoved = $true }
            WaitForRemoval = { $true }
            GetTaggedResources = { @() }
            RemoveEmergencyStopTask = { $script:EmergencyStopRemovals++; 'removed' }
        }
        $script:EmergencyStopRemovals = 0
    }

    It 'deallocates and verifies exactly both approved VMs' {
        $result = Stop-WorkshopEnvironment -Config $script:Config `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -TenantId '22222222-2222-2222-2222-222222222222' -Operations $script:LifecycleOperations -Confirm:$false

        $result.Completed | Should -BeTrue
        $script:Stopped | Should -Be @('vm-mcpsql-admin', 'vm-mcpsql-sql')
        $script:Power.Values | Should -Be @('PowerState/deallocated', 'PowerState/deallocated')
        $result.Checkpoint | Should -Be @(
            'VirtualMachine/vm-mcpsql-admin:deallocated-and-verified',
            'VirtualMachine/vm-mcpsql-sql:deallocated-and-verified'
        )
    }

    It 'aggregates stop failures while still attempting exactly both approved VMs' {
        $script:LifecycleOperations.StopVm = {
            param($Name)
            $script:Stopped.Add($Name)
            if ($Name -eq 'vm-mcpsql-admin') { throw 'admin failed' }
            $script:Power[$Name] = 'PowerState/deallocated'
        }
        { Stop-WorkshopEnvironment -Config $script:Config `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -Operations $script:LifecycleOperations -Confirm:$false } | Should -Throw '*admin failed*'
        $script:Stopped | Should -Be @('vm-mcpsql-admin', 'vm-mcpsql-sql')
    }

    It 'starts and verifies every approved VM that is not running' {
        $script:Power['vm-mcpsql-admin'] = 'PowerState/deallocated'
        $script:Power['vm-mcpsql-sql'] = 'PowerState/stopped'

        $result = Start-WorkshopEnvironment -Config $script:Config `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -TenantId '22222222-2222-2222-2222-222222222222' -Operations $script:LifecycleOperations -Confirm:$false

        $result.Completed | Should -BeTrue
        $script:Started | Should -Be @('vm-mcpsql-admin', 'vm-mcpsql-sql')
        $result.Checkpoint | Should -Be @(
            'VirtualMachine/vm-mcpsql-admin:started-and-verified',
            'VirtualMachine/vm-mcpsql-sql:started-and-verified'
        )
    }

    It 'leaves an already running VM untouched and starts only the stopped one' {
        $script:Power['vm-mcpsql-sql'] = 'PowerState/deallocated'

        $result = Start-WorkshopEnvironment -Config $script:Config `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -Operations $script:LifecycleOperations -Confirm:$false

        $script:Started | Should -Be @('vm-mcpsql-sql')
        $result.Checkpoint | Should -Be @(
            'VirtualMachine/vm-mcpsql-admin:already-running',
            'VirtualMachine/vm-mcpsql-sql:started-and-verified'
        )
    }

    It 'fails when a started VM does not reach the running power state' {
        $script:Power['vm-mcpsql-admin'] = 'PowerState/deallocated'
        $script:LifecycleOperations.StartVm = { param($Name) $script:Started.Add($Name) }

        { Start-WorkshopEnvironment -Config $script:Config `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -Operations $script:LifecycleOperations -Confirm:$false } |
            Should -Throw '*was not PowerState/running*'
    }

    It 'requires exact removal confirmation, tags, ID, and subscription context before deletion' -ForEach @(
        @{ Case='phrase'; Phrase='delete rg-mcp-sql-workshop' }
        @{ Case='environment tag'; Phrase='DELETE rg-mcp-sql-workshop' }
        @{ Case='workload tag'; Phrase='DELETE rg-mcp-sql-workshop' }
        @{ Case='managedBy tag'; Phrase='DELETE rg-mcp-sql-workshop' }
        @{ Case='ID'; Phrase='DELETE rg-mcp-sql-workshop' }
    ) {
        if ($Case -ne 'phrase') {
            $environment = if ($Case -eq 'environment tag') { 'prod' } else { 'workshop' }
            $workload = if ($Case -eq 'workload tag') { 'other' } else { 'mcp-sql' }
            $managedBy = if ($Case -eq 'managedBy tag') { 'other' } else { 'PowerShell' }
            $resourceId = if ($Case -eq 'ID') {
                '/subscriptions/other/resourceGroups/rg-mcp-sql-workshop'
            }
            else {
                '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-mcp-sql-workshop'
            }
            $script:RemoveOperations.GetResourceGroup = {
                [pscustomobject]@{
                    Status = 'Found'
                    ResourceGroup = [pscustomobject]@{
                        ResourceGroupName = 'rg-mcp-sql-workshop'
                        ResourceId = $resourceId
                        Tags = @{ environment = $environment; workload = $workload; managedBy = $managedBy }
                    }
                }
            }.GetNewClosure()
        }
        { Remove-WorkshopEnvironment -Config $script:Config `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ConfirmationPhrase $Phrase -Operations $script:RemoveOperations -Confirm:$false } |
            Should -Throw -Because $Case
        $script:RemoveCalls | Should -Be 0
    }

    It 'removes, waits boundedly, verifies typed NotFound, and verifies no tagged resources remain' {
        $script:TaggedAbsenceArguments = $null
        $script:RemoveOperations.GetTaggedResources = {
            param($Environment, $Workload, $ManagedBy, $SubscriptionId, $ResourceGroupName)
            $script:TaggedAbsenceArguments = @($Environment, $Workload, $ManagedBy, $SubscriptionId, $ResourceGroupName)
            @()
        }
        $result = Remove-WorkshopEnvironment -Config $script:Config `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -ConfirmationPhrase 'DELETE rg-mcp-sql-workshop' -Operations $script:RemoveOperations -Confirm:$false

        $result.Completed | Should -BeTrue
        $script:RemoveCalls | Should -Be 1
        $script:EmergencyStopRemovals | Should -Be 1
        $result.Checkpoint | Should -Contain 'Local emergency-stop task removed'
        $script:TaggedAbsenceArguments | Should -Be @(
            'workshop', 'mcp-sql', 'PowerShell',
            '11111111-1111-1111-1111-111111111111', 'rg-mcp-sql-workshop'
        )
    }

    It 'fails closed when the local emergency-stop task cannot be proven removed' {
        $script:RemoveOperations.RemoveEmergencyStopTask = { 'still-present' }

        { Remove-WorkshopEnvironment -Config $script:Config `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ConfirmationPhrase 'DELETE rg-mcp-sql-workshop' -Operations $script:RemoveOperations -Confirm:$false } |
            Should -Throw '*emergency-stop task removal returned unexpected state*'
    }

    It 'fails closed for auth/network reads and for remaining tagged resources' -ForEach @('read-error', 'remaining') {
        if ($_ -eq 'read-error') { $script:RemoveOperations.GetResourceGroup = { throw 'AuthorizationFailed' } }
        else {
            $script:RemoveOperations.GetTaggedResources = { @([pscustomobject]@{ Id='/remaining' }) }
        }
        { Remove-WorkshopEnvironment -Config $script:Config `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ConfirmationPhrase 'DELETE rg-mcp-sql-workshop' -Operations $script:RemoveOperations -Confirm:$false } |
            Should -Throw
    }

    It 'searches the whole subscription for tagged survivors instead of the deleted group' {
        InModuleScope Workshop.Azure {
            $operations = Get-DefaultWorkshopRemoveOperationSet
            # Pester injects mock parameters through its own scope, so the capture has to be
            # script-scoped; it is removed again below.
            $script:TagQueryProbe = $null
            Mock Get-AzResource {
                $script:TagQueryProbe = @{ TagName = $TagName; TagValue = $TagValue; Group = $ResourceGroupName }
                @(
                    [pscustomobject]@{
                        ResourceId = '/subscriptions/sub/resourceGroups/rg-elsewhere/providers/Microsoft.Storage/storageAccounts/leaked'
                        Tags = @{ environment = 'workshop'; workload = 'mcp-sql'; managedBy = 'PowerShell' }
                    },
                    [pscustomobject]@{
                        ResourceId = '/subscriptions/sub/resourceGroups/rg-other/providers/Microsoft.Storage/storageAccounts/unrelated'
                        Tags = @{ environment = 'other'; workload = 'mcp-sql'; managedBy = 'PowerShell' }
                    }
                )
            }

            try {
                $remaining = @(& $operations.GetTaggedResources 'workshop' 'mcp-sql' 'PowerShell' `
                    'sub' 'rg-mcp-sql-workshop')

                # Scoping the query to the already-deleted group would make this unfalsifiable.
                $script:TagQueryProbe.Group | Should -BeNullOrEmpty
                $script:TagQueryProbe.TagName | Should -BeExactly 'managedBy'
                $remaining | Should -HaveCount 1
                $remaining[0].ResourceId | Should -Match 'rg-elsewhere'
            }
            finally {
                Remove-Variable -Name TagQueryProbe -Scope Script -ErrorAction SilentlyContinue
            }
        }
    }

    It 'polls removal to typed NotFound with an injected non-sleeping waiter' {
        InModuleScope Workshop.Azure {
            $script:Reads = 0
            $script:Waits = 0
            $result = Wait-WorkshopResourceGroupRemoval -Name 'rg-mcp-sql-workshop' -MaximumAttempts 3 `
                -ReadOperation {
                    $script:Reads++
                    if ($script:Reads -lt 3) { return 'Found' }
                    'NotFound'
                } -WaitOperation { $script:Waits++ }

            $result | Should -BeTrue
            $script:Reads | Should -Be 3
            $script:Waits | Should -Be 2
        }
    }

    It 'times out boundedly and does not treat authorization failure as absence' {
        InModuleScope Workshop.Azure {
            $script:Waits = 0
            (Wait-WorkshopResourceGroupRemoval -Name 'rg' -MaximumAttempts 2 `
                -ReadOperation { 'Found' } -WaitOperation { $script:Waits++ }) | Should -BeFalse
            $script:Waits | Should -Be 1
            { Wait-WorkshopResourceGroupRemoval -Name 'rg' -MaximumAttempts 2 `
                    -ReadOperation { throw 'AuthorizationFailed' } -WaitOperation { throw 'must not wait' } } |
                Should -Throw '*AuthorizationFailed*'
        }
    }
}

Describe 'Bootstrap deployment serialization and staging isolation' {
    BeforeEach {
        $script:BootstrapOrder = [System.Collections.Generic.List[string]]::new()
        $script:LockReleased = $false
        $script:BootstrapOps = @{
            GetRecipientCertificate = { $script:BootstrapOrder.Add('certificate'); 'certificate' }
            ProtectPayload = { $script:BootstrapOrder.Add('protect'); 'envelope' }
            GetSubscriptionId = { $script:BootstrapOrder.Add('subscription'); '11111111-1111-1111-1111-111111111111' }
            AcquireDeploymentLock = {
                param($SubscriptionId, $ResourceGroupName, $VmName)
                $script:BootstrapOrder.Add("lock:$SubscriptionId/$ResourceGroupName/$VmName")
                [pscustomobject]@{ Acquired = $true }
            }
            ReleaseDeploymentLock = { param($Lease) $null = $Lease; $script:LockReleased = $true; $script:BootstrapOrder.Add('unlock') }
            StageBootstrapFiles = {
                param($VmName, $ResourceGroupName, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit, $DeploymentId)
                $null = $VmName, $ResourceGroupName, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit
                $script:BootstrapOrder.Add("stage:$DeploymentId")
            }
            SetExtension = {
                param($VmName, $ResourceGroupName, $Location, $ArchiveUri, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit, $DeploymentId)
                $null = $VmName, $ResourceGroupName, $Location, $ArchiveUri, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit
                $script:BootstrapOrder.Add("set:$DeploymentId")
            }
            GetExtension = {
                $script:BootstrapOrder.Add('status')
                [pscustomobject]@{ ProvisioningState = 'Succeeded'; Statuses = @([pscustomobject]@{ Code = 'ProvisioningState/succeeded' }) }
            }
            ReadReadiness = {
                $script:BootstrapOrder.Add('readiness')
                [pscustomobject]@{ Completed = $true; DeploymentId = '11111111-2222-3333-4444-555555555555'; Certificate = [pscustomobject]@{ PublicCertificatePath='C:\public.cer'; PublicCertificateSha256=('A' * 64) } }
            }
        }
    }

    It 'excludes a concurrent holder of the same deployment key, isolates other keys, and reacquires after release' {
        $modulePath = (Get-Module Workshop.Azure).Path
        # Mutex ownership is per thread, so the competing probe must run on its own runspace.
        $probeOnOtherThread = {
            param($ModulePath, $SubscriptionId, $ResourceGroupName, $VmName)
            $shell = [powershell]::Create()
            try {
                $null = $shell.AddScript({
                    param($ModulePath, $SubscriptionId, $ResourceGroupName, $VmName)
                    Import-Module $ModulePath -Force
                    & (Get-Module Workshop.Azure) {
                        param($SubscriptionId, $ResourceGroupName, $VmName)
                        try {
                            $lease = Enter-WorkshopBootstrapLock -SubscriptionId $SubscriptionId `
                                -ResourceGroupName $ResourceGroupName -VmName $VmName -TimeoutMilliseconds 250
                            Exit-WorkshopBootstrapLock -Lease $lease
                            'acquired'
                        }
                        catch { 'blocked' }
                    } $SubscriptionId $ResourceGroupName $VmName
                }).AddArgument($ModulePath).AddArgument($SubscriptionId).
                    AddArgument($ResourceGroupName).AddArgument($VmName)
                [string] @($shell.Invoke())[-1]
            }
            finally { $shell.Dispose() }
        }

        $lease = InModuleScope Workshop.Azure {
            Enter-WorkshopBootstrapLock -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-mcp-sql-workshop' -VmName 'vm-mcpsql-sql' -TimeoutMilliseconds 1000
        }
        try {
            $lease.Acquired | Should -BeTrue
            & $probeOnOtherThread $modulePath '11111111-1111-1111-1111-111111111111' `
                'rg-mcp-sql-workshop' 'vm-mcpsql-sql' | Should -BeExactly 'blocked'
            & $probeOnOtherThread $modulePath '11111111-1111-1111-1111-111111111111' `
                'rg-mcp-sql-workshop' 'vm-mcpsql-admin' | Should -BeExactly 'acquired'
        }
        finally {
            InModuleScope Workshop.Azure -Parameters @{ Lease = $lease } {
                param($Lease)
                Exit-WorkshopBootstrapLock -Lease $Lease
            }
        }
        $lease.Acquired | Should -BeFalse
        & $probeOnOtherThread $modulePath '11111111-1111-1111-1111-111111111111' `
            'rg-mcp-sql-workshop' 'vm-mcpsql-sql' | Should -BeExactly 'acquired'
    }

    It 'holds one deployment-keyed local lock around staging, extension mutation, status, and readiness readback' {
        $result = Initialize-WorkshopSqlVm -Config $script:Config -AdministratorCredential (Get-TestCredential) `
            -DatabaseMasterKeyPassword (Get-TestCredential).Password -McpReaderPassword (Get-TestCredential).Password `
            -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
            -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
            -DeploymentId '11111111-2222-3333-4444-555555555555' -Operations $script:BootstrapOps

        $result.Completed | Should -BeTrue
        $script:LockReleased | Should -BeTrue
        $script:BootstrapOrder.IndexOf('lock:11111111-1111-1111-1111-111111111111/rg-mcp-sql-workshop/vm-mcpsql-sql') |
            Should -BeLessThan $script:BootstrapOrder.IndexOf('status')
        $script:BootstrapOrder.IndexOf('lock:11111111-1111-1111-1111-111111111111/rg-mcp-sql-workshop/vm-mcpsql-sql') |
            Should -BeLessThan $script:BootstrapOrder.IndexOf('certificate')
        $script:BootstrapOrder.IndexOf('subscription') |
            Should -BeLessThan $script:BootstrapOrder.IndexOf('lock:11111111-1111-1111-1111-111111111111/rg-mcp-sql-workshop/vm-mcpsql-sql')
        $script:BootstrapOrder.IndexOf('certificate') |
            Should -BeLessThan $script:BootstrapOrder.IndexOf('protect')
        $script:BootstrapOrder.IndexOf('protect') |
            Should -BeLessThan $script:BootstrapOrder.IndexOf('stage:11111111-2222-3333-4444-555555555555')
        $script:BootstrapOrder.IndexOf('stage:11111111-2222-3333-4444-555555555555') |
            Should -BeLessThan $script:BootstrapOrder.IndexOf('set:11111111-2222-3333-4444-555555555555')
        $script:BootstrapOrder.IndexOf('set:11111111-2222-3333-4444-555555555555') |
            Should -BeLessThan $script:BootstrapOrder.LastIndexOf('status')
        $script:BootstrapOrder[-1] | Should -Be 'unlock'
    }

    It 'releases the local lock when extension mutation fails' {
        $script:BootstrapOps.SetExtension = { throw 'extension failed' }
        { Initialize-WorkshopSqlVm -Config $script:Config -AdministratorCredential (Get-TestCredential) `
                -DatabaseMasterKeyPassword (Get-TestCredential).Password -McpReaderPassword (Get-TestCredential).Password `
                -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
                -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
                -DeploymentId '11111111-2222-3333-4444-555555555555' -Operations $script:BootstrapOps } |
            Should -Throw '*extension failed*'
        $script:LockReleased | Should -BeTrue
    }

    It 'rejects a non-canonical deployment identifier before any host or guest mutation' -ForEach @(
        '11111111-2222-3333-4444-55555555555F',
        '{11111111-2222-3333-4444-555555555555}',
        '11111111222233334444555555555555'
    ) {
        $candidate = $_
        { Initialize-WorkshopSqlVm -Config $script:Config -AdministratorCredential (Get-TestCredential) `
                -DatabaseMasterKeyPassword (Get-TestCredential).Password -McpReaderPassword (Get-TestCredential).Password `
                -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
                -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
                -DeploymentId $candidate -Operations $script:BootstrapOps } |
            Should -Throw '*DeploymentId*'
        $script:BootstrapOrder | Should -BeNullOrEmpty
    }

    It 'rejects a transitioning existing custom extension under the lock before certificate or staging' -ForEach @('Creating','Updating','Deleting','Transitioning') {
        $state = $_
        $script:BootstrapOps.GetExtension = {
            [pscustomobject]@{ ProvisioningState = $state; Statuses = @([pscustomobject]@{ Code = "ProvisioningState/$($state.ToLowerInvariant())" }) }
        }.GetNewClosure()
        { Initialize-WorkshopSqlVm -Config $script:Config -AdministratorCredential (Get-TestCredential) `
                -DatabaseMasterKeyPassword (Get-TestCredential).Password -McpReaderPassword (Get-TestCredential).Password `
                -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
                -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
                -DeploymentId '11111111-2222-3333-4444-555555555555' -Operations $script:BootstrapOps } |
            Should -Throw '*active*operation*'
        @($script:BootstrapOrder | Where-Object { $_ -like 'lock:*' }) | Should -HaveCount 1
        @($script:BootstrapOrder | Where-Object { $_ -in @('certificate','protect') -or $_ -like 'stage:*' -or $_ -like 'set:*' }) |
            Should -HaveCount 0
        $script:BootstrapOrder[-1] | Should -Be 'unlock'
    }

    It 'normalizes only agreeing extension-state signals and fails closed otherwise' -ForEach @(
        @{ Case='absent'; Extension=$null; Expected='Absent' }
        @{ Case='succeeded'; Extension=[pscustomobject]@{ ProvisioningState='Succeeded'; Statuses=@([pscustomobject]@{ Code='ProvisioningState/succeeded' }); InstanceView=[pscustomobject]@{ Statuses=@([pscustomobject]@{ Code='ProvisioningState/Succeeded' }) } }; Expected='Succeeded' }
        @{ Case='failed nested'; Extension=[pscustomobject]@{ Resource=[pscustomobject]@{ Value=[pscustomobject]@{ ProvisioningState='Failed'; Statuses=@([pscustomobject]@{ Code='ProvisioningState/failed' }) } } }; Expected='Failed' }
        @{ Case='transitioning'; Extension=[pscustomobject]@{ Statuses=@([pscustomobject]@{ Code='ProvisioningState/updating' }) }; Expected='Updating' }
        @{ Case='empty'; Extension=[pscustomobject]@{}; Expected='Unknown' }
        @{ Case='malformed'; Extension=[pscustomobject]@{ ProvisioningState=@{ Bad='shape' } }; Expected='Unknown' }
        @{ Case='unknown'; Extension=[pscustomobject]@{ Statuses=@([pscustomobject]@{ Code='ProvisioningState/banana' }) }; Expected='Unknown' }
        @{ Case='contradictory'; Extension=[pscustomobject]@{ ProvisioningState='Succeeded'; Statuses=@([pscustomobject]@{ Code='ProvisioningState/failed' }) }; Expected='Unknown' }
        @{ Case='failed with exit code'; Extension=[pscustomobject]@{ ProvisioningState='Failed'; Statuses=@([pscustomobject]@{ Code='ProvisioningState/failed/-196608' }) }; Expected='Failed' }
        @{ Case='succeeded with trailing segment'; Extension=[pscustomobject]@{ Statuses=@([pscustomobject]@{ Code='ProvisioningState/succeeded/0' }) }; Expected='Succeeded' }
        @{ Case='unknown with exit code'; Extension=[pscustomobject]@{ Statuses=@([pscustomobject]@{ Code='ProvisioningState/banana/-1' }) }; Expected='Unknown' }
    ) {
        InModuleScope Workshop.Azure -Parameters @{ Value = $Extension; ExpectedState = $Expected } {
            param($Value, $ExpectedState)
            Get-WorkshopBootstrapExtensionState -Extension $Value | Should -BeExactly $ExpectedState
        }
    }

    It 'fails closed when the extension graph is too deep to traverse completely' {
        InModuleScope Workshop.Azure {
            $node = [pscustomobject]@{ ProvisioningState = 'Succeeded' }
            foreach ($depth in 1..20) { $node = [pscustomobject]@{ Resource = $node } }
            Get-WorkshopBootstrapExtensionState -Extension $node | Should -BeExactly 'Unknown'
        }
    }

    It 'rejects unknown extension state under the lock before certificate or mutation' {
        $script:BootstrapOps.GetExtension = { [pscustomobject]@{} }

        { Initialize-WorkshopSqlVm -Config $script:Config -AdministratorCredential (Get-TestCredential) `
                -DatabaseMasterKeyPassword (Get-TestCredential).Password -McpReaderPassword (Get-TestCredential).Password `
                -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
                -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
                -DeploymentId '11111111-2222-3333-4444-555555555555' -Operations $script:BootstrapOps } |
            Should -Throw '*Unknown*'
        @($script:BootstrapOrder | Where-Object { $_ -like 'lock:*' }) | Should -HaveCount 1
        @($script:BootstrapOrder | Where-Object { $_ -in @('certificate','protect') -or $_ -like 'stage:*' -or $_ -like 'set:*' }) |
            Should -HaveCount 0
        $script:BootstrapOrder[-1] | Should -Be 'unlock'
    }

    It 'allows redeploy over an extension that previously failed with an Azure exit code' {
        $script:PriorExtension = [pscustomobject]@{
            ProvisioningState = 'Failed'
            Statuses = @([pscustomobject]@{ Code = 'ProvisioningState/failed/-196608' })
        }
        $script:BootstrapOps.GetExtension = {
            param($VmName, $ResourceGroupName, $Name)
            $null = $VmName, $ResourceGroupName, $Name
            $script:BootstrapOrder.Add('status')
            $prior = $script:PriorExtension
            $script:PriorExtension = [pscustomobject]@{ ProvisioningState = 'Succeeded' }
            $prior
        }

        $result = Initialize-WorkshopSqlVm -Config $script:Config -AdministratorCredential (Get-TestCredential) `
            -DatabaseMasterKeyPassword (Get-TestCredential).Password -McpReaderPassword (Get-TestCredential).Password `
            -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
            -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
            -DeploymentId '11111111-2222-3333-4444-555555555555' -Operations $script:BootstrapOps

        $result.Completed | Should -BeTrue
        @($script:BootstrapOrder | Where-Object { $_ -like 'set:*' }) | Should -HaveCount 1
    }

    It 'rejects readiness that carries no deployment identifier' {
        $script:BootstrapOps.ReadReadiness = { [pscustomobject]@{ Completed = $true } }

        { Initialize-WorkshopSqlVm -Config $script:Config -AdministratorCredential (Get-TestCredential) `
                -DatabaseMasterKeyPassword (Get-TestCredential).Password -McpReaderPassword (Get-TestCredential).Password `
                -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
                -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
                -DeploymentId '11111111-2222-3333-4444-555555555555' -Operations $script:BootstrapOps } |
            Should -Throw '*did not report Completed=true for the expected deployment*'
        $script:BootstrapOrder[-1] | Should -Be 'unlock'
    }

    It 'uses deployment-specific guest paths and a short secret-free extension command' {
        InModuleScope Workshop.Azure {
            $deploymentId = '11111111-2222-3333-4444-555555555555'
            $operations = Get-DefaultWorkshopBootstrapOperationSet
            $probe = @{ Staged = $null; Extension = $null }
            # Pester injects mock parameters through its own scope, so the capture has to be
            # script-scoped; it is removed again below.
            $script:StagingProbe = $probe
            Mock Invoke-AzVMRunCommand {
                $script:StagingProbe.Staged = $ScriptString
                [pscustomobject]@{ Value = @([pscustomobject]@{ Message = 'placeholder' }) }
            }
            Mock Set-AzVMExtension {
                $script:StagingProbe.Extension = @{ Protected = $ProtectedSettingString; Public = $SettingString }
                [pscustomobject]@{ ProvisioningState = 'Succeeded' }
            }

            try {
                # Staging verifies its own hash, so the placeholder response is expected to fail.
                { & $operations.StageBootstrapFiles 'vm-mcpsql-admin' 'rg-mcp-sql-workshop' `
                    'encrypted-cms-envelope' 'Initialize-AdminVm.ps1' `
                    '0123456789abcdef0123456789abcdef01234567' $deploymentId } |
                    Should -Throw '*was not positively verified*'

                $probe.Staged | Should -Match ([regex]::Escape("C:\McpSqlWorkshop\deployments\$deploymentId"))
                $probe.Staged | Should -Match 'bootstrap-launcher\.ps1'
                $probe.Staged | Should -Match 'protected-bootstrap\.cms'
                $probe.Staged | Should -Match 'Staged bootstrap file hash verification failed'
                # Earlier attempts must be pruned so retries cannot accumulate repository copies.
                $probe.Staged | Should -Match ([regex]::Escape("-cne '$deploymentId'"))

                $null = & $operations.SetExtension 'vm-mcpsql-admin' 'rg-mcp-sql-workshop' 'indonesiacentral' `
                    'https://example.invalid/archive.zip' 'encrypted-cms-envelope' 'Initialize-AdminVm.ps1' `
                    '0123456789abcdef0123456789abcdef01234567' $deploymentId
                $command = [string] ($probe.Extension.Protected | ConvertFrom-Json).commandToExecute
                $command | Should -Match ([regex]::Escape("C:\McpSqlWorkshop\deployments\$deploymentId\bootstrap-launcher.ps1"))
                $command | Should -Not -Match '(?i)encrypted-cms-envelope|secret|password'
                [string] $probe.Extension.Public |
                    Should -Not -Match '(?i)encrypted-cms-envelope|secret|password'
            }
            finally {
                Remove-Variable -Name StagingProbe -Scope Script -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Default Task 6 Az command contracts' {
    It 'builds the administration VM with an immutable image, Windows client license, Trusted Launch, UEFI, OS disk, and exact NIC' {
        InModuleScope Workshop.Azure -Parameters @{
            Config = $script:Config
            TestCredential = (Get-TestCredential)
        } {
            param($Config, [System.Management.Automation.PSCredential] $TestCredential)
            $credential = $TestCredential
            $spec = Get-WorkshopVmSpecification -Role Admin -Config $Config `
                -ImageVersion '26100.2033.1' -SubscriptionId 'sub'
            Mock New-AzVMConfig { [pscustomobject]@{ Name=$VMName } }
            Mock Set-AzVMOperatingSystem { $VM }
            Mock Set-AzVMSourceImage { $VM }
            Mock Set-AzVMOSDisk { $VM }
            Mock Set-AzVMSecurityProfile { $VM }
            Mock Set-AzVmUefi { $VM }
            Mock Add-AzVMNetworkInterface { $VM }
            Mock Add-AzVMDataDisk { $VM }
            Mock New-AzVM { [pscustomobject]@{ Name=$VM.Name } }

            $operations = Get-DefaultWorkshopVmOperationSet
            $null = & $operations.CreateVm $spec $credential $Config.ResourceGroupName

            Should -Invoke New-AzVMConfig -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'vm-mcpsql-admin' -and $VMSize -eq 'Standard_D4s_v5' -and
                $LicenseType -eq 'Windows_Client' -and $null -ne $Tags -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Set-AzVMOperatingSystem -Times 1 -Exactly -ParameterFilter {
                $Windows -and $Credential -is [PSCredential] -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Set-AzVMSourceImage -Times 1 -Exactly -ParameterFilter {
                $PublisherName -eq 'MicrosoftWindowsDesktop' -and $Offer -eq 'windows-11' -and
                $Skus -eq 'win11-24h2-ent' -and $Version -eq '26100.2033.1' -and
                $Version -ne 'latest' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Set-AzVMSecurityProfile -Times 1 -Exactly -ParameterFilter {
                $SecurityType -eq 'TrustedLaunch' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Set-AzVmUefi -Times 1 -Exactly -ParameterFilter {
                $EnableVtpm -and $EnableSecureBoot -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Set-AzVMOSDisk -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'osdisk-mcpsql-admin' -and $DiskSizeInGB -eq 128 -and
                $StorageAccountType -eq 'Premium_LRS' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Add-AzVMNetworkInterface -Times 1 -Exactly -ParameterFilter {
                $Id -eq '/subscriptions/sub/resourceGroups/rg-mcp-sql-workshop/providers/Microsoft.Network/networkInterfaces/nic-mcpsql-admin' -and
                $Primary -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke New-AzVM -Times 1 -Exactly -ParameterFilter { $ErrorAction -eq 'Stop' }
        }
    }

    It 'creates Premium SQL disks and attaches LUN zero ReadOnly and LUN one None without any public IP command' {
        InModuleScope Workshop.Azure -Parameters @{
            Config = $script:Config
            TestCredential = (Get-TestCredential)
        } {
            param($Config, [System.Management.Automation.PSCredential] $TestCredential)
            $credential = $TestCredential
            $spec = Get-WorkshopVmSpecification -Role Sql -Config $Config `
                -ImageVersion '16.0.1135.2' -SubscriptionId 'sub'
            $diskSpecs = @(Get-WorkshopDiskSpecification -VmSpecification $spec)
            Mock New-AzDiskConfig { [pscustomobject]@{} }
            Mock New-AzDisk { [pscustomobject]@{ Name=$DiskName } }
            Mock New-AzVMConfig { [pscustomobject]@{ Name=$VMName } }
            Mock Set-AzVMOperatingSystem { $VM }
            Mock Set-AzVMSourceImage { $VM }
            Mock Set-AzVMOSDisk { $VM }
            Mock Set-AzVMSecurityProfile { $VM }
            Mock Set-AzVmUefi { $VM }
            Mock Add-AzVMNetworkInterface { $VM }
            Mock Add-AzVMDataDisk { $VM }
            Mock New-AzVM { [pscustomobject]@{ Name=$VM.Name } }
            Mock New-AzPublicIpAddress { throw 'Public IP must not be created by VM operations.' }

            $operations = Get-DefaultWorkshopVmOperationSet
            foreach ($disk in $diskSpecs) { $null = & $operations.CreateDisk $disk $Config.ResourceGroupName }
            $null = & $operations.CreateVm $spec $credential $Config.ResourceGroupName

            Should -Invoke New-AzDiskConfig -Times 2 -Exactly -ParameterFilter {
                $SkuName -eq 'Premium_LRS' -and $CreateOption -eq 'Empty' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Add-AzVMDataDisk -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'disk-mcpsql-sql-data' -and $Lun -eq 0 -and $Caching -eq 'ReadOnly' -and
                $CreateOption -eq 'Attach' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Add-AzVMDataDisk -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'disk-mcpsql-sql-log' -and $Lun -eq 1 -and $Caching -eq 'None' -and
                $CreateOption -eq 'Attach' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke New-AzVMConfig -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'vm-mcpsql-sql' -and $VMSize -eq 'Standard_E8s_v5' -and
                [string]::IsNullOrWhiteSpace([string] $LicenseType) -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Set-AzVMSecurityProfile -Times 1 -Exactly -ParameterFilter {
                $SecurityType -eq 'TrustedLaunch' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Set-AzVmUefi -Times 1 -Exactly -ParameterFilter {
                $EnableVtpm -and $EnableSecureBoot -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
        }
    }

    It 'fails closed before SQL VM creation when Trusted Launch commands reject required parameters' -ForEach @(
        @{ FailedCommand = 'SecurityProfile'; Message = 'SecurityType'; ExpectedUefiCalls = 0 }
        @{ FailedCommand = 'Uefi'; Message = 'EnableVtpm'; ExpectedUefiCalls = 1 }
    ) {
        InModuleScope Workshop.Azure -Parameters @{
            Config = $script:Config
            TestCredential = (Get-TestCredential)
            RejectedCommand = $FailedCommand
            RejectionMessage = $Message
            UefiCalls = $ExpectedUefiCalls
        } {
            param(
                $Config,
                [System.Management.Automation.PSCredential] $TestCredential,
                $RejectedCommand,
                $RejectionMessage,
                $UefiCalls
            )
            $credential = $TestCredential
            $rejected = $RejectedCommand
            $rejection = $RejectionMessage
            $expectedUefiCalls = $UefiCalls
            $spec = Get-WorkshopVmSpecification -Role Sql -Config $Config `
                -ImageVersion '16.0.1135.2' -SubscriptionId 'sub'
            Mock New-AzVMConfig { [pscustomobject]@{ Name=$VMName } }
            Mock Set-AzVMOperatingSystem { $VM }
            Mock Set-AzVMSourceImage { $VM }
            Mock Set-AzVMOSDisk { $VM }
            Mock Set-AzVMSecurityProfile {
                if ($rejected -eq 'SecurityProfile') {
                    throw "A parameter cannot be found that matches parameter name $rejection."
                }
                $VM
            }
            Mock Set-AzVmUefi {
                if ($rejected -eq 'Uefi') {
                    throw "A parameter cannot be found that matches parameter name $rejection."
                }
                $VM
            }
            Mock Add-AzVMNetworkInterface { $VM }
            Mock Add-AzVMDataDisk { $VM }
            Mock New-AzVM { [pscustomobject]@{ Name=$VM.Name } }

            $operations = Get-DefaultWorkshopVmOperationSet
            { & $operations.CreateVm $spec $credential $Config.ResourceGroupName } |
                Should -Throw "*$rejection*"

            Should -Invoke Set-AzVMSecurityProfile -Times 1 -Exactly
            Should -Invoke Set-AzVmUefi -Times $expectedUefiCalls -Exactly
            Should -Invoke New-AzVM -Times 0 -Exactly
        }
    }

    It 'uses terminating PAYG SQL IaaS and generic DevTest Labs schedule mutations' {
        InModuleScope Workshop.Azure {
            Set-Item -Path Function:New-AzSqlVM -Value {
                [CmdletBinding()]
                param($ResourceGroupName, $Name, $Location, $LicenseType)
                $null = $ResourceGroupName, $Name, $Location, $LicenseType
            }
            Mock New-AzSqlVM { [pscustomobject]@{ Name=$Name } }
            Mock New-AzResource { [pscustomobject]@{ ResourceId=$ResourceId } }
            $operations = Get-DefaultWorkshopServiceOperationSet
            $iaas = [pscustomobject]@{ Name='vm-mcpsql-sql'; Location='indonesiacentral' }
            $schedule = [pscustomobject]@{
                Id='/subscriptions/sub/resourceGroups/rg/providers/microsoft.devtestlab/schedules/shutdown-computevm-vm'
                Location='southeastasia'
                Status='Enabled'; TaskType='ComputeVmShutdownTask'; TimeZoneId='UTC'
                DailyRecurrenceTime='1900'; TargetResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
                NotificationStatus='Disabled'; NotificationTimeInMinutes=30
            }

            $null = & $operations.CreateSqlIaas $iaas 'rg-mcp-sql-workshop'
            $null = & $operations.CreateSchedule $schedule 'rg-mcp-sql-workshop'

            Should -Invoke New-AzSqlVM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'vm-mcpsql-sql' -and $LicenseType -eq 'PAYG' -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke New-AzResource -Times 1 -Exactly -ParameterFilter {
                $ResourceId -match '/microsoft\.devtestlab/schedules/' -and $ApiVersion -eq '2018-09-15' -and
                $Location -eq 'southeastasia' -and
                $Properties.status -eq 'Enabled' -and $Properties.dailyRecurrence.time -eq '1900' -and
                $Force -and $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'normalizes the Az SqlVirtualMachine 3 license property on readback' {
        InModuleScope Workshop.Azure {
            Mock Get-AzSqlVM {
                [pscustomobject]@{
                    Name = $Name
                    Id = "/subscriptions/sub/resourceGroups/$ResourceGroupName/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/$Name"
                    Location = 'indonesiacentral'
                    SqlServerLicenseType = 'PAYG'
                    VirtualMachineResourceId = "/subscriptions/sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$Name"
                }
            }
            $operations = Get-DefaultWorkshopServiceOperationSet
            $spec = [pscustomobject]@{ Name = 'vm-mcpsql-sql' }

            { $script:sqlIaasReadback = & $operations.GetSqlIaas $spec 'rg-mcp-sql-workshop' } |
                Should -Not -Throw
            $script:sqlIaasReadback.LicenseType | Should -BeExactly 'PAYG'
            Should -Invoke Get-AzSqlVM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'vm-mcpsql-sql' -and $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'expands and exactly normalizes native shutdown schedule properties on readback' {
        InModuleScope Workshop.Azure {
            Mock Get-AzResource {
                [pscustomobject]@{
                    ResourceId = $ResourceId
                    Location = 'indonesiacentral'
                    Properties = [pscustomobject]@{
                        status='Enabled'; taskType='ComputeVmShutdownTask'; timeZoneId='UTC'
                        targetResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
                        dailyRecurrence=[pscustomobject]@{ time='1900' }
                        notificationSettings=[pscustomobject]@{ status='Disabled'; timeInMinutes=30 }
                    }
                }
            }
            $spec = [pscustomobject]@{ Id='/subscriptions/sub/resourceGroups/rg/providers/microsoft.devtestlab/schedules/shutdown-computevm-vm' }
            $operations = Get-DefaultWorkshopServiceOperationSet

            $result = & $operations.GetSchedule 'shutdown-computevm-vm' 'rg' $spec

            $result.NotificationStatus | Should -Be 'Disabled'
            $result.NotificationTimeInMinutes | Should -Be 30
            Should -Invoke Get-AzResource -Times 1 -Exactly -ParameterFilter {
                $ResourceId -eq $spec.Id -and $ExpandProperties -and $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'uses Force and terminating errors for exact VM deallocation and resource-group removal' {
        InModuleScope Workshop.Azure {
            Mock Stop-AzVM { [pscustomobject]@{ Status='Succeeded' } }
            Mock Remove-AzResourceGroup { $true }
            $stop = Get-DefaultWorkshopStopOperationSet
            $remove = Get-DefaultWorkshopRemoveOperationSet

            $null = & $stop.StopVm 'vm-mcpsql-admin' 'rg-mcp-sql-workshop'
            $null = & $remove.RemoveResourceGroup 'rg-mcp-sql-workshop'

            Should -Invoke Stop-AzVM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'vm-mcpsql-admin' -and $Force -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Remove-AzResourceGroup -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'rg-mcp-sql-workshop' -and $Force -and $ErrorAction -eq 'Stop'
            }
        }
    }
}

Describe 'Bootstrap repository supply-chain boundary' {
    BeforeAll {
        $script:RepositoryCommit = '0123456789abcdef0123456789abcdef01234567'

        function Write-BootstrapTestArchive {
            param(
                [Parameter(Mandatory)][string] $Path,
                [Parameter(Mandatory)][object[]] $Entries
            )
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($definition in $Entries) {
                    $entry = $archive.CreateEntry([string]$definition.Name)
                    if ($definition.PSObject.Properties.Name -contains 'ExternalAttributes') {
                        $entry.ExternalAttributes = [int]$definition.ExternalAttributes
                    }
                    if ($definition.PSObject.Properties.Name -contains 'Content') {
                        $writer = [IO.StreamWriter]::new($entry.Open())
                        try { $writer.Write([string]$definition.Content) }
                        finally { $writer.Dispose() }
                    }
                }
            }
            finally {
                $archive.Dispose()
                $stream.Dispose()
            }
        }
    }

    It 'normalizes only the optional git suffix for the exact approved repository' {
        InModuleScope Workshop.Azure -Parameters @{ Commit = $script:RepositoryCommit } {
            param($Commit)
            Get-WorkshopBootstrapArchiveUri `
                -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
                -RepositoryCommit $Commit |
                Should -Be "https://github.com/ibranibeny/mcp-sql-query-store-workshop/archive/$Commit.zip"
        }
    }

    It 'rejects every repository other than the exact approved public repository' -ForEach @(
        'https://github.com/example/mcp-sql-query-store-workshop'
        'https://github.com/ibranibeny/another-repository'
        'https://github.com/IBRANIBENY/mcp-sql-query-store-workshop'
    ) {
        $unapprovedRepository = $_
        InModuleScope Workshop.Azure -Parameters @{
            Repository = $unapprovedRepository
            Commit = $script:RepositoryCommit
        } {
            param($Repository, $Commit)
            $null = $Repository, $Commit
            { Get-WorkshopBootstrapArchiveUri -RepositoryUrl $Repository -RepositoryCommit $Commit } |
                Should -Throw '*approved repository*'
        }
    }

    It 'rejects traversal, multiple roots, and reparse entries before extracting repository content' -ForEach @(
        @{
            Case = 'path traversal'
            Entries = @([pscustomobject]@{ Name = 'mcp-sql-query-store-workshop-0123456789abcdef0123456789abcdef01234567/../escape.ps1'; Content = 'bad' })
        }
        @{
            Case = 'multiple top-level roots'
            Entries = @(
                [pscustomobject]@{ Name = 'mcp-sql-query-store-workshop-0123456789abcdef0123456789abcdef01234567/deploy/Initialize-SqlVm.ps1'; Content = 'good' }
                [pscustomobject]@{ Name = 'other-root/payload.ps1'; Content = 'bad' }
            )
        }
        @{
            Case = 'reparse entry'
            Entries = @([pscustomobject]@{ Name = 'mcp-sql-query-store-workshop-0123456789abcdef0123456789abcdef01234567/link'; Content = 'target'; ExternalAttributes = [int](0xA000 -shl 16) })
        }
    ) {
        $archivePath = Join-Path $TestDrive "$($Case -replace ' ', '-').zip"
        $destination = Join-Path $TestDrive "$($Case -replace ' ', '-')-destination"
        Write-BootstrapTestArchive -Path $archivePath -Entries $Entries

        InModuleScope Workshop.Azure -Parameters @{
            ArchivePath = $archivePath
            Destination = $destination
            Commit = $script:RepositoryCommit
        } {
            param($ArchivePath, $Destination, $Commit)
            $null = $ArchivePath, $Destination, $Commit
            { Expand-WorkshopBootstrapArchive -ArchivePath $ArchivePath -DestinationPath $Destination `
                    -RepositoryCommit $Commit -ApprovedBootstrapEntryPoint 'Initialize-SqlVm.ps1' } |
                Should -Throw '*repository archive rejected*'
        }
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It 'rejects an entry whose staged path would exceed the Windows path limit' {
        # The guest stages under a deployment-scoped path, so a long entry silently blew
        # past MAX_PATH and surfaced as "Could not find a part of the path".
        $archivePath = Join-Path $TestDrive 'too-long.zip'
        $root = 'mcp-sql-query-store-workshop-0123456789abcdef0123456789abcdef01234567'
        $deepName = "$root/docs/" + ('d' * 200) + '.md'
        Write-BootstrapTestArchive -Path $archivePath -Entries @(
            [pscustomobject]@{ Name = "$root/deploy/Initialize-SqlVm.ps1"; Content = '# approved' }
            [pscustomobject]@{ Name = $deepName; Content = 'too long' }
        )
        $destination = Join-Path $TestDrive 'too-long-destination'

        InModuleScope Workshop.Azure -Parameters @{
            ArchivePath = $archivePath
            Destination = $destination
            Commit = $script:RepositoryCommit
        } {
            param($ArchivePath, $Destination, $Commit)
            $null = $ArchivePath, $Destination, $Commit
            { Expand-WorkshopBootstrapArchive -ArchivePath $ArchivePath -DestinationPath $Destination `
                    -RepositoryCommit $Commit -ApprovedBootstrapEntryPoint 'Initialize-SqlVm.ps1' } |
                Should -Throw '*character Windows path limit*'
        }
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It 'keeps every real repository path inside the limit for a deployment-scoped guest root' {
        # Reproduces the guest layout: deployment GUID folder, staging folder, and the
        # 69-character root folder GitHub puts inside the archive.
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $guestParent = 'C:\McpSqlWorkshop\deployments\' + [guid]::NewGuid().ToString('D')
        $stagingLength = $guestParent.Length + 1 + 14
        $archiveRootLength = ('mcp-sql-query-store-workshop-' + ('0' * 40)).Length

        Push-Location $repositoryRoot
        try { $tracked = @(git ls-files) } finally { Pop-Location }
        $tracked.Count | Should -BeGreaterThan 0

        $worst = $tracked | Sort-Object Length -Descending | Select-Object -First 1
        ($stagingLength + 1 + $archiveRootLength + 1 + $worst.Length) | Should -BeLessOrEqual 259
    }

    It 'extracts one exact repository root containing the approved bootstrap entry point' {
        $archivePath = Join-Path $TestDrive 'approved.zip'
        $destination = Join-Path $TestDrive 'approved-repository'
        Write-BootstrapTestArchive -Path $archivePath -Entries @(
            [pscustomobject]@{ Name = 'mcp-sql-query-store-workshop-0123456789abcdef0123456789abcdef01234567/deploy/Initialize-SqlVm.ps1'; Content = '# approved' }
            [pscustomobject]@{ Name = 'mcp-sql-query-store-workshop-0123456789abcdef0123456789abcdef01234567/sql/00-Preflight.sql'; Content = 'SELECT 1;' }
        )

        InModuleScope Workshop.Azure -Parameters @{
            ArchivePath = $archivePath
            Destination = $destination
            Commit = $script:RepositoryCommit
        } {
            param($ArchivePath, $Destination, $Commit)
            $null = $ArchivePath, $Destination, $Commit
            Expand-WorkshopBootstrapArchive -ArchivePath $ArchivePath -DestinationPath $Destination `
                -RepositoryCommit $Commit -ApprovedBootstrapEntryPoint 'Initialize-SqlVm.ps1' |
                Should -Be $Destination
        }
        Test-Path -LiteralPath (Join-Path $destination 'deploy/Initialize-SqlVm.ps1') -PathType Leaf |
            Should -BeTrue
    }

    It 'retries validated archive promotion boundedly when the first move is temporarily denied' {
        $archivePath = Join-Path $TestDrive 'promotion-retry.zip'
        $destination = Join-Path $TestDrive 'promotion-retry-repository'
        Write-BootstrapTestArchive -Path $archivePath -Entries @(
            [pscustomobject]@{ Name = 'mcp-sql-query-store-workshop-0123456789abcdef0123456789abcdef01234567/deploy/Initialize-SqlVm.ps1'; Content = '# approved' }
        )

        InModuleScope Workshop.Azure -Parameters @{
            ArchivePath = $archivePath
            Destination = $destination
            Commit = $script:RepositoryCommit
        } {
            param($ArchivePath, $Destination, $Commit)
            $script:promotionAttempts = 0
            $script:promotionWaits = 0
            $promote = {
                param($Source, $Target)
                $script:promotionAttempts++
                if ($script:promotionAttempts -eq 1) {
                    throw [System.UnauthorizedAccessException]::new('temporarily locked')
                }
                Move-Item -LiteralPath $Source -Destination $Target -ErrorAction Stop
            }
            $wait = { $script:promotionWaits++ }

            Expand-WorkshopBootstrapArchive -ArchivePath $ArchivePath -DestinationPath $Destination `
                -RepositoryCommit $Commit -ApprovedBootstrapEntryPoint 'Initialize-SqlVm.ps1' `
                -PromoteOperation $promote -WaitOperation $wait -MaximumPromotionAttempts 3 |
                Should -Be $Destination
            $script:promotionAttempts | Should -Be 2
            $script:promotionWaits | Should -Be 1
        }
    }

    It 'validates and extracts the archive before invoking the approved bootstrap entry point' {
        $moduleText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../deploy/Workshop.Azure.psm1') -Raw
        $stageAt = $moduleText.IndexOf('StageBootstrapFiles = {')
        $validationAt = $moduleText.IndexOf('$null = Expand-WorkshopBootstrapArchive', $stageAt)
        $executionAt = $moduleText.IndexOf("& (Join-Path `$repo 'deploy\__BOOTSTRAP_ENTRY_POINT__')", $stageAt)
        $extensionAt = $moduleText.IndexOf('SetExtension = {', $stageAt)
        $validationAt | Should -BeGreaterThan $stageAt
        $executionAt | Should -BeGreaterThan $validationAt
        $extensionAt | Should -BeGreaterThan $executionAt
    }
}
