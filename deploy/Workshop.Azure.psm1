Set-StrictMode -Version Latest

$script:RequiredAzModules = [ordered]@{
    'Az.Accounts' = [version]'4.0.0'
    'Az.Resources' = [version]'7.0.0'
    'Az.Compute' = [version]'10.0.0'
    'Az.Network' = [version]'7.0.0'
    'Az.PrivateDns' = [version]'1.0.0'
    'Az.SqlVirtualMachine' = [version]'2.3.0'
}
$script:RequiredProviders = @(
    'Microsoft.Compute'
    'Microsoft.Network'
    'Microsoft.Resources'
    'Microsoft.SqlVirtualMachine'
)
$script:KnownVmFamilies = @{
    'Standard_D4s_v5' = 'standardDSv5Family'
    'Standard_E8s_v5' = 'standardESv5Family'
}

function ConvertTo-WorkshopIpv4Value {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Address)

    $parsed = $null
    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [System.Net.IPAddress]::TryParse($Address, [ref] $parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.IPAddressToString -cne $Address) {
        throw "'$Address' is not a canonical IPv4 address."
    }
    $bytes = $parsed.GetAddressBytes()
    return [uint64] $bytes[0] * 16777216 + [uint64] $bytes[1] * 65536 +
        [uint64] $bytes[2] * 256 + [uint64] $bytes[3]
}

function ConvertTo-WorkshopIpv4Network {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Cidr)

    if ($Cidr -notmatch '^([^/]+)/(\d{1,2})$') {
        throw "'$Cidr' is not an IPv4 CIDR."
    }
    $addressText = $Matches[1]
    $prefix = [int] $Matches[2]
    if ($prefix -lt 0 -or $prefix -gt 32) {
        throw "'$Cidr' has an invalid IPv4 prefix length."
    }
    $address = ConvertTo-WorkshopIpv4Value -Address $addressText
    $hostCount = [uint64] [math]::Pow(2, 32 - $prefix)
    $network = $address - ($address % $hostCount)
    if ($address -ne $network) {
        throw "'$Cidr' is not a canonical IPv4 network CIDR."
    }
    [pscustomobject]@{
        Address = $address
        Prefix = $prefix
        Network = $network
        Broadcast = $network + $hostCount - 1
    }
}

function Test-WorkshopIpv4InNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uint64] $Address,
        [Parameter(Mandatory)][psobject] $Network
    )

    return $Address -ge $Network.Network -and $Address -le $Network.Broadcast
}

function Assert-WorkshopConfigShape {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config)

    $requiredTopLevel = @(
        'Location', 'ResourceGroupName', 'VNet', 'AdminSubnet', 'SqlSubnet',
        'AdminAsg', 'SqlAsg', 'PrivateDnsZone', 'SqlPrivateIp', 'AdminVm',
        'SqlVm', 'AutoShutdownTime', 'Tags'
    )
    foreach ($key in $requiredTopLevel) {
        if (-not $Config.ContainsKey($key) -or $null -eq $Config[$key]) {
            throw "Workshop configuration is missing required key '$key'."
        }
    }

    foreach ($key in @('Name', 'AddressPrefix')) {
        if (-not $Config.VNet.ContainsKey($key)) {
            throw "Workshop configuration VNet is missing required key '$key'."
        }
    }
    foreach ($subnetName in @('AdminSubnet', 'SqlSubnet')) {
        foreach ($key in @('Name', 'Prefix', 'DefaultOutboundAccess')) {
            if (-not $Config[$subnetName].ContainsKey($key)) {
                throw "Workshop configuration $subnetName is missing required key '$key'."
            }
        }
    }
    foreach ($key in @('Name', 'Size', 'Publisher', 'Offer', 'Sku', 'OsDiskGiB')) {
        if (-not $Config.AdminVm.ContainsKey($key)) {
            throw "Workshop configuration AdminVm is missing required key '$key'."
        }
    }
    foreach ($key in @('Name', 'Size', 'Publisher', 'Offer', 'Sku', 'OsDiskGiB', 'DataDiskGiB', 'LogDiskGiB', 'LicenseType')) {
        if (-not $Config.SqlVm.ContainsKey($key)) {
            throw "Workshop configuration SqlVm is missing required key '$key'."
        }
    }
    foreach ($key in @('environment', 'workload', 'managedBy')) {
        if (-not $Config.Tags.ContainsKey($key)) {
            throw "Workshop configuration Tags is missing required key '$key'."
        }
    }

    $requiredStrings = @(
        @{ Label = 'Location'; Value = $Config.Location }
        @{ Label = 'ResourceGroupName'; Value = $Config.ResourceGroupName }
        @{ Label = 'VNet.Name'; Value = $Config.VNet.Name }
        @{ Label = 'AdminSubnet.Name'; Value = $Config.AdminSubnet.Name }
        @{ Label = 'SqlSubnet.Name'; Value = $Config.SqlSubnet.Name }
        @{ Label = 'AdminAsg'; Value = $Config.AdminAsg }
        @{ Label = 'SqlAsg'; Value = $Config.SqlAsg }
        @{ Label = 'PrivateDnsZone'; Value = $Config.PrivateDnsZone }
        @{ Label = 'AdminVm.Name'; Value = $Config.AdminVm.Name }
        @{ Label = 'AdminVm.Size'; Value = $Config.AdminVm.Size }
        @{ Label = 'AdminVm.Publisher'; Value = $Config.AdminVm.Publisher }
        @{ Label = 'AdminVm.Offer'; Value = $Config.AdminVm.Offer }
        @{ Label = 'AdminVm.Sku'; Value = $Config.AdminVm.Sku }
        @{ Label = 'SqlVm.Name'; Value = $Config.SqlVm.Name }
        @{ Label = 'SqlVm.Size'; Value = $Config.SqlVm.Size }
        @{ Label = 'SqlVm.Publisher'; Value = $Config.SqlVm.Publisher }
        @{ Label = 'SqlVm.Offer'; Value = $Config.SqlVm.Offer }
        @{ Label = 'SqlVm.Sku'; Value = $Config.SqlVm.Sku }
        @{ Label = 'SqlVm.LicenseType'; Value = $Config.SqlVm.LicenseType }
    )
    foreach ($item in $requiredStrings) {
        if ($item.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($item.Value)) {
            throw "Workshop configuration $($item.Label) must be a nonempty string."
        }
    }

    foreach ($identityPair in @(
        @{ Label = 'AdminSubnet.Name and SqlSubnet.Name'; Admin = $Config.AdminSubnet.Name; Sql = $Config.SqlSubnet.Name }
        @{ Label = 'AdminAsg and SqlAsg'; Admin = $Config.AdminAsg; Sql = $Config.SqlAsg }
        @{ Label = 'AdminVm.Name and SqlVm.Name'; Admin = $Config.AdminVm.Name; Sql = $Config.SqlVm.Name }
    )) {
        if ([string]::Equals(
                [string] $identityPair.Admin,
                [string] $identityPair.Sql,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Workshop configuration $($identityPair.Label) must be distinct (case-insensitive)."
        }
    }

    foreach ($subnetName in @('AdminSubnet', 'SqlSubnet')) {
        if ($Config[$subnetName].DefaultOutboundAccess -isnot [bool] -or
            $Config[$subnetName].DefaultOutboundAccess -ne $false) {
            throw "Workshop configuration $subnetName.DefaultOutboundAccess must be exactly Boolean false."
        }
    }
    foreach ($disk in @(
        @{ Label = 'AdminVm.OsDiskGiB'; Value = $Config.AdminVm.OsDiskGiB }
        @{ Label = 'SqlVm.OsDiskGiB'; Value = $Config.SqlVm.OsDiskGiB }
        @{ Label = 'SqlVm.DataDiskGiB'; Value = $Config.SqlVm.DataDiskGiB }
        @{ Label = 'SqlVm.LogDiskGiB'; Value = $Config.SqlVm.LogDiskGiB }
    )) {
        if ($disk.Value -isnot [ValueType] -or [decimal] $disk.Value -le 0) {
            throw "Workshop configuration $($disk.Label) must be positive."
        }
    }

    $vnet = ConvertTo-WorkshopIpv4Network -Cidr ([string] $Config.VNet.AddressPrefix)
    $adminSubnet = ConvertTo-WorkshopIpv4Network -Cidr ([string] $Config.AdminSubnet.Prefix)
    $sqlSubnet = ConvertTo-WorkshopIpv4Network -Cidr ([string] $Config.SqlSubnet.Prefix)
    foreach ($subnetItem in @(
        @{ Label = 'AdminSubnet'; Network = $adminSubnet }
        @{ Label = 'SqlSubnet'; Network = $sqlSubnet }
    )) {
        $subnet = $subnetItem.Network
        if ($subnet.Prefix -lt 16 -or $subnet.Prefix -gt 29) {
            throw "Workshop configuration $($subnetItem.Label).Prefix must have a prefix length between /16 and /29."
        }
        if ($subnet.Network -lt $vnet.Network -or $subnet.Broadcast -gt $vnet.Broadcast -or
            $subnet.Prefix -le $vnet.Prefix) {
            throw 'Workshop configuration subnets must be fully contained in the VNet.'
        }
    }
    if ($adminSubnet.Network -le $sqlSubnet.Broadcast -and $sqlSubnet.Network -le $adminSubnet.Broadcast) {
        throw 'Workshop configuration subnets must not overlap.'
    }
    $sqlIp = ConvertTo-WorkshopIpv4Value -Address ([string] $Config.SqlPrivateIp)
    if (-not (Test-WorkshopIpv4InNetwork -Address $sqlIp -Network $sqlSubnet)) {
        throw 'Workshop configuration SqlPrivateIp must be contained in the SQL subnet.'
    }
    if ($sqlIp -lt ($sqlSubnet.Network + 4) -or $sqlIp -ge $sqlSubnet.Broadcast) {
        throw 'Workshop configuration SqlPrivateIp must not use network, broadcast, or Azure-reserved addresses.'
    }
}

function Assert-WorkshopHostCidr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Cidr
    )

    if ($Cidr -notmatch '^([^/]+)/32$') {
        throw 'Facilitator CIDR must be exactly one canonical IPv4 host with a /32 prefix.'
    }

    $addressText = $Matches[1]
    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($addressText, [ref] $address) -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'Facilitator CIDR must contain a valid IPv4 address.'
    }

    $normalized = "$($address.IPAddressToString)/32"
    if ($Cidr -cne $normalized) {
        throw "Facilitator CIDR is not canonical; use '$normalized'."
    }

    $addressValue = ConvertTo-WorkshopIpv4Value -Address $addressText
    $nonGlobalNetworks = @(
        '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
        '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
        '192.88.99.0/24', '192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24',
        '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'
    )
    $isNonGlobal = $false
    foreach ($networkText in $nonGlobalNetworks) {
        $network = ConvertTo-WorkshopIpv4Network -Cidr $networkText
        if (Test-WorkshopIpv4InNetwork -Address $addressValue -Network $network) {
            $isNonGlobal = $true
            break
        }
    }
    if ($isNonGlobal) {
        throw 'Facilitator CIDR must identify a public unicast IPv4 host.'
    }

    return $normalized
}

${function:New-WorkshopNetworkModel} = {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $FacilitatorCidr
    )

    Assert-WorkshopConfigShape -Config $Config
    $hostCidr = Assert-WorkshopHostCidr -Cidr $FacilitatorCidr

    [pscustomobject][ordered]@{
        VNet = [pscustomobject][ordered]@{
            Name = [string] $Config.VNet.Name
            AddressPrefix = [string] $Config.VNet.AddressPrefix
        }
        NatGateway = [pscustomobject][ordered]@{
            Name = 'nat-mcpsql-workshop'
            Required = $true
            PublicIpName = 'pip-mcpsql-nat'
            PublicIpEnabled = $true
            InboundEnabled = $false
            Purpose = 'Explicit outbound-only connectivity for both private subnets'
        }
        Admin = [pscustomobject][ordered]@{
            SubnetName = [string] $Config.AdminSubnet.Name
            AddressPrefix = [string] $Config.AdminSubnet.Prefix
            PrivateSubnet = $true
            DefaultOutboundAccess = [bool] $Config.AdminSubnet.DefaultOutboundAccess
            NatGatewayRequired = $true
            Asg = [string] $Config.AdminAsg
            PublicIpEnabled = $true
            Rules = @(
                [pscustomobject][ordered]@{
                    Name = 'Allow-Facilitator-Rdp'
                    Priority = 100
                    Direction = 'Inbound'
                    Access = 'Allow'
                    Protocol = 'Tcp'
                    SourcePrefix = $hostCidr
                    SourceAsg = $null
                    DestinationAsg = [string] $Config.AdminAsg
                    DestinationPort = 3389
                }
            )
        }
        Sql = [pscustomobject][ordered]@{
            SubnetName = [string] $Config.SqlSubnet.Name
            AddressPrefix = [string] $Config.SqlSubnet.Prefix
            PrivateSubnet = $true
            DefaultOutboundAccess = [bool] $Config.SqlSubnet.DefaultOutboundAccess
            NatGatewayRequired = $true
            Asg = [string] $Config.SqlAsg
            PublicIpEnabled = $false
            PrivateIp = [string] $Config.SqlPrivateIp
            Rules = @(
                [pscustomobject][ordered]@{
                    Name = 'Allow-Admin-To-Sql'
                    Priority = 100
                    Direction = 'Inbound'
                    Access = 'Allow'
                    Protocol = 'Tcp'
                    SourcePrefix = $null
                    SourceAsg = [string] $Config.AdminAsg
                    DestinationAsg = [string] $Config.SqlAsg
                    DestinationPort = 1433
                }
                [pscustomobject][ordered]@{
                    Name = 'Allow-Admin-To-Sql-Rdp'
                    Priority = 110
                    Direction = 'Inbound'
                    Access = 'Allow'
                    Protocol = 'Tcp'
                    SourcePrefix = $null
                    SourceAsg = [string] $Config.AdminAsg
                    DestinationAsg = [string] $Config.SqlAsg
                    DestinationPort = 3389
                }
                [pscustomobject][ordered]@{
                    Name = 'Deny-Other-VNet-To-Sql'
                    Priority = 4000
                    Direction = 'Inbound'
                    Access = 'Deny'
                    Protocol = '*'
                    SourcePrefix = 'VirtualNetwork'
                    SourceAsg = $null
                    DestinationAsg = [string] $Config.SqlAsg
                    DestinationPort = '*'
                }
                [pscustomobject][ordered]@{
                    Name = 'AzureDefault-AllowVNetInBound'
                    Priority = 65000
                    Direction = 'Inbound'
                    Access = 'Allow'
                    Protocol = '*'
                    SourcePrefix = 'VirtualNetwork'
                    SourceAsg = $null
                    DestinationAsg = $null
                    DestinationPort = '*'
                    ManagedByAzure = $true
                }
            )
        }
        PrivateDnsZone = [string] $Config.PrivateDnsZone
    }
}

function Get-WorkshopPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $FacilitatorCidr,
        [Parameter(Mandatory)][datetime] $ExpiresOn,
        [Parameter(Mandatory)][bool] $WindowsClientLicenseAttested,
        [Parameter(Mandatory)][bool] $SqlEnterpriseCostAcknowledged,
        [Parameter(Mandatory)][bool] $BillableResourcesAcknowledged,
        [hashtable] $ResolvedImages
    )

    Assert-WorkshopConfigShape -Config $Config
    $network = New-WorkshopNetworkModel -Config $Config -FacilitatorCidr $FacilitatorCidr
    $adminVersion = 'unresolved (latest requested)'
    $sqlVersion = 'unresolved (latest requested)'
    if ($null -ne $ResolvedImages) {
        if ($ResolvedImages.ContainsKey('Admin') -and $null -ne $ResolvedImages.Admin) {
            $adminVersion = ConvertTo-WorkshopSafeDetail -Value $ResolvedImages.Admin.Version
        }
        if ($ResolvedImages.ContainsKey('Sql') -and $null -ne $ResolvedImages.Sql) {
            $sqlVersion = ConvertTo-WorkshopSafeDetail -Value $ResolvedImages.Sql.Version
        }
    }

    [pscustomobject][ordered]@{
        Location = [string] $Config.Location
        ResourceGroupName = [string] $Config.ResourceGroupName
        Network = $network
        AdminVm = [pscustomobject][ordered]@{
            Name = [string] $Config.AdminVm.Name
            Size = [string] $Config.AdminVm.Size
            Vcpu = 4
            PublicIpEnabled = $true
            Image = [pscustomobject][ordered]@{
                Publisher = [string] $Config.AdminVm.Publisher
                Offer = [string] $Config.AdminVm.Offer
                Sku = [string] $Config.AdminVm.Sku
                Version = $adminVersion
            }
            Disks = [pscustomobject][ordered]@{ OsGiB = [int] $Config.AdminVm.OsDiskGiB }
            WindowsClientLicenseAttested = $WindowsClientLicenseAttested
        }
        SqlVm = [pscustomobject][ordered]@{
            Name = [string] $Config.SqlVm.Name
            Size = [string] $Config.SqlVm.Size
            Vcpu = 8
            PublicIpEnabled = $false
            PrivateIp = [string] $Config.SqlPrivateIp
            Image = [pscustomobject][ordered]@{
                Publisher = [string] $Config.SqlVm.Publisher
                Offer = [string] $Config.SqlVm.Offer
                Sku = [string] $Config.SqlVm.Sku
                Version = $sqlVersion
            }
            Disks = [pscustomobject][ordered]@{
                OsGiB = [int] $Config.SqlVm.OsDiskGiB
                DataGiB = [int] $Config.SqlVm.DataDiskGiB
                LogGiB = [int] $Config.SqlVm.LogDiskGiB
            }
            LicenseType = [string] $Config.SqlVm.LicenseType
            SqlEnterpriseCostAcknowledged = $SqlEnterpriseCostAcknowledged
        }
        AutoShutdownTime = [string] $Config.AutoShutdownTime
        PublicBoundary = [pscustomobject][ordered]@{
            PublicIngress = "Windows 11 RDP from $FacilitatorCidr only"
            SqlPublicIp = 'none'
            SqlIngress = 'Admin ASG to SQL ASG TCP 1433'
            Outbound = 'Explicit NAT Gateway on both private subnets'
        }
        Pricing = [pscustomobject][ordered]@{
            Queried = $false
            Status = 'Pricing was not queried'
            BillableResourcesAcknowledged = $BillableResourcesAcknowledged
            BillableCategories = @(
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
        }
        Tags = [pscustomobject][ordered]@{
            environment = [string] $Config.Tags.environment
            workload = [string] $Config.Tags.workload
            managedBy = [string] $Config.Tags.managedBy
            expiresOn = $ExpiresOn.Date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
}

function Format-WorkshopPlanCard {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)] [psobject] $Plan)

    process {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('MCP SQL Query Store Workshop - deployment plan')
        $lines.Add("Location: $($Plan.Location)")
        $lines.Add("Resource group: $($Plan.ResourceGroupName)")
        $lines.Add("Administration VM: $($Plan.AdminVm.Name) / $($Plan.AdminVm.Size) / $($Plan.AdminVm.Image.Publisher):$($Plan.AdminVm.Image.Offer):$($Plan.AdminVm.Image.Sku):$($Plan.AdminVm.Image.Version)")
        $lines.Add("SQL VM: $($Plan.SqlVm.Name) / $($Plan.SqlVm.Size) / $($Plan.SqlVm.Image.Publisher):$($Plan.SqlVm.Image.Offer):$($Plan.SqlVm.Image.Sku):$($Plan.SqlVm.Image.Version)")
        $lines.Add("VNet: $($Plan.Network.VNet.Name) $($Plan.Network.VNet.AddressPrefix)")
        $lines.Add("Admin subnet: $($Plan.Network.Admin.SubnetName) $($Plan.Network.Admin.AddressPrefix); private: $($Plan.Network.Admin.PrivateSubnet); default outbound: $($Plan.Network.Admin.DefaultOutboundAccess); NAT required: $($Plan.Network.Admin.NatGatewayRequired)")
        $lines.Add("SQL subnet: $($Plan.Network.Sql.SubnetName) $($Plan.Network.Sql.AddressPrefix); private: $($Plan.Network.Sql.PrivateSubnet); default outbound: $($Plan.Network.Sql.DefaultOutboundAccess); NAT required: $($Plan.Network.Sql.NatGatewayRequired)")
        $lines.Add("ASGs: $($Plan.Network.Admin.Asg) -> $($Plan.Network.Sql.Asg)")
        $lines.Add("SQL private IP: $($Plan.SqlVm.PrivateIp)")
        $lines.Add("NAT gateway: $($Plan.Network.NatGateway.Name); outbound public IP: $($Plan.Network.NatGateway.PublicIpName); inbound: $($Plan.Network.NatGateway.InboundEnabled)")
        $lines.Add("Administration disks: OS $($Plan.AdminVm.Disks.OsGiB) GiB")
        $lines.Add("SQL disks: OS $($Plan.SqlVm.Disks.OsGiB) GiB; data $($Plan.SqlVm.Disks.DataGiB) GiB; log $($Plan.SqlVm.Disks.LogGiB) GiB")
        $lines.Add('SQL public IP: none')
        $lines.Add("Public ingress: $($Plan.PublicBoundary.PublicIngress)")
        $lines.Add("SQL ingress: $($Plan.PublicBoundary.SqlIngress)")
        $lines.Add("Windows client license attested: $($Plan.AdminVm.WindowsClientLicenseAttested)")
        $lines.Add("SQL Enterprise PAYG acknowledged: $($Plan.SqlVm.SqlEnterpriseCostAcknowledged)")
        $lines.Add("All billable categories acknowledged: $($Plan.Pricing.BillableResourcesAcknowledged)")
        $lines.Add("Pricing queried: $($Plan.Pricing.Queried) - $($Plan.Pricing.Status)")
        $lines.Add('Billable categories:')
        foreach ($category in $Plan.Pricing.BillableCategories) {
            $lines.Add("  - $category")
        }
        $lines.Add("Auto-shutdown: $($Plan.AutoShutdownTime)")
        $lines.Add("Tags: environment=$($Plan.Tags.environment); workload=$($Plan.Tags.workload); managedBy=$($Plan.Tags.managedBy); expiresOn=$($Plan.Tags.expiresOn)")
        return @($lines | ForEach-Object {
            ConvertTo-WorkshopSafeDetail -Value $_
        }) -join [Environment]::NewLine
    }
}

function Add-WorkshopCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Checks,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Passed,
        [Parameter(Mandatory)][string] $Detail,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Remediation
    )

    $Checks.Add([pscustomobject][ordered]@{
        Name = ConvertTo-WorkshopSafeDetail -Value $Name
        Status = if ($Passed) { 'Passed' } else { 'Failed' }
        Detail = ConvertTo-WorkshopSafeDetail -Value $Detail
        Remediation = if ($Passed) { '' } else { ConvertTo-WorkshopSafeDetail -Value $Remediation }
    })
}

function Invoke-WorkshopReadOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Operation,
        [object[]] $Arguments = @()
    )

    try {
        $ErrorActionPreference = 'Stop'
        $operationOutput = @(& $Operation @Arguments 2>&1)
        $operationErrors = @($operationOutput | Where-Object {
            $_ -is [System.Management.Automation.ErrorRecord]
        })
        if ($operationErrors.Count -gt 0) {
            throw ($operationErrors | ForEach-Object Exception | ForEach-Object Message) -join '; '
        }
        [pscustomobject]@{
            Succeeded = $true
            Value = @($operationOutput)
            Error = $null
        }
    }
    catch {
        [pscustomobject]@{
            Succeeded = $false
            Value = @()
            Error = ConvertTo-WorkshopSafeDetail -Value $_.Exception.Message
        }
    }
}

function Get-WorkshopNestedIdentifier {
    [CmdletBinding()]
    param(
        [object] $InputObject,
        [Parameter(Mandatory)][string] $PropertyName
    )

    if ($null -eq $InputObject -or $InputObject.PSObject.Properties.Name -notcontains $PropertyName) {
        return ''
    }
    $value = $InputObject.$PropertyName
    if ($null -eq $value) {
        return ''
    }
    if ($value.PSObject.Properties.Name -contains 'Id') {
        return [string] $value.Id
    }
    return [string] $value
}

function Test-WorkshopLocationMatch {
    [CmdletBinding()]
    param(
        [object[]] $Locations,
        [Parameter(Mandatory)][string] $RequiredLocation
    )

    $normalizedRequired = $RequiredLocation.ToLowerInvariant() -replace '[^a-z0-9]', ''
    return $null -ne ($Locations | Where-Object {
        $normalizedLocation = ([string] $_).ToLowerInvariant() -replace '[^a-z0-9]', ''
        $normalizedLocation -eq $normalizedRequired
    } | Select-Object -First 1)
}

function Get-WorkshopQuotaAvailability {
    [CmdletBinding()]
    param([AllowNull()][object] $Usage)

    $current = 0L
    $limit = 0L
    $shapeValid = $null -ne $Usage -and
        $Usage.PSObject.Properties.Name -contains 'CurrentValue' -and
        $Usage.PSObject.Properties.Name -contains 'Limit'
    $valuesValid = $shapeValid -and
        [long]::TryParse([string] $Usage.CurrentValue, [ref] $current) -and
        [long]::TryParse([string] $Usage.Limit, [ref] $limit) -and
        $current -ge 0 -and $limit -ge 0
    if (-not $valuesValid) {
        return [pscustomobject]@{ Verified = $false; Available = $null }
    }
    return [pscustomobject]@{
        Verified = $true
        Available = [Math]::Max(0L, $limit - $current)
    }
}

function ConvertTo-WorkshopSafeDetail {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value,

        [string] $Fallback = 'Validation could not be verified.'
    )

    if ($null -eq $Value) {
        return $Fallback
    }
    $text = [string] $Value
    $text = [regex]::Replace($text, '[\x00-\x1F\x7F]+', ' ')
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Fallback
    }
    if ($text.Length -gt 512) {
        return $text.Substring(0, 509) + '...'
    }
    return $text
}

function Test-WorkshopAzureNotFound {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord)

    $codes = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.FullyQualifiedErrorId)) {
        $codes.Add($ErrorRecord.FullyQualifiedErrorId)
    }
    $exception = $ErrorRecord.Exception
    foreach ($propertyName in @('Code', 'ErrorCode')) {
        if ($null -ne $exception -and $exception.PSObject.Properties.Name -contains $propertyName) {
            $codes.Add([string] $exception.$propertyName)
        }
    }
    if ($null -ne $exception -and $exception.PSObject.Properties.Name -contains 'Error' -and
        $null -ne $exception.Error -and $exception.Error.PSObject.Properties.Name -contains 'Code') {
        $codes.Add([string] $exception.Error.Code)
    }
    foreach ($code in $codes) {
        if ($code -match '(^|,|\.)Resource(Group)?NotFound($|,|\.)') {
            return $true
        }
    }
    foreach ($candidate in @($exception, $exception.Response)) {
        if ($null -ne $candidate -and $candidate.PSObject.Properties.Name -contains 'StatusCode' -and
            [int] $candidate.StatusCode -eq 404) {
            return $true
        }
    }
    return $false
}

function Get-WorkshopNetworkSkuValidationTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Location,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{12}$')][string] $Suffix
    )

    $resourceGroupName = "rg-mcpsql-sku-$Suffix"
    $nestedTemplate = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        resources = @(
            [ordered]@{
                type = 'Microsoft.Network/publicIPAddresses'
                apiVersion = '2024-05-01'
                name = "pip-sku-$Suffix"
                location = $Location
                sku = [ordered]@{ name = 'Standard' }
                properties = [ordered]@{
                    publicIPAllocationMethod = 'Static'
                    publicIPAddressVersion = 'IPv4'
                }
            }
            [ordered]@{
                type = 'Microsoft.Network/natGateways'
                apiVersion = '2024-05-01'
                name = "nat-sku-$Suffix"
                location = $Location
                sku = [ordered]@{ name = 'Standard' }
                properties = [ordered]@{ idleTimeoutInMinutes = 10 }
            }
        )
    }

    [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        resources = @(
            [ordered]@{
                type = 'Microsoft.Resources/resourceGroups'
                apiVersion = '2022-09-01'
                name = $resourceGroupName
                location = $Location
            }
            [ordered]@{
                type = 'Microsoft.Resources/deployments'
                apiVersion = '2022-09-01'
                name = "network-sku-$Suffix"
                resourceGroup = $resourceGroupName
                dependsOn = @("[subscriptionResourceId('Microsoft.Resources/resourceGroups', '$resourceGroupName')]")
                properties = [ordered]@{
                    mode = 'Incremental'
                    expressionEvaluationOptions = [ordered]@{ scope = 'inner' }
                    template = $nestedTemplate
                }
            }
        )
    }
}

function Get-DefaultWorkshopOperationSet {
    [CmdletBinding()]
    param()

    @{
        GetPowerShellVersion = { $PSVersionTable.PSVersion }
        GetModules = { Get-Module -ListAvailable -Name $script:RequiredAzModules.Keys -ErrorAction Stop }
        GetContext = { Get-AzContext -ErrorAction Stop }
        GetProviders = { Get-AzResourceProvider -ErrorAction Stop }
        GetLocations = { Get-AzLocation -ErrorAction Stop }
        GetComputeSkus = { Get-AzComputeResourceSku -ErrorAction Stop }
        GetImages = {
            param($Publisher, $Offer, $Sku, $Location)
            Get-AzVMImage -PublisherName $Publisher -Offer $Offer -Skus $Sku -Location $Location -ErrorAction Stop
        }
        GetVmUsages = { param($Location) Get-AzVMUsage -Location $Location -ErrorAction Stop }
        TestNetworkSkuDeployment = {
            param($Location)
            $suffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
            $template = Get-WorkshopNetworkSkuValidationTemplate -Location $Location -Suffix $suffix
            $validationCommand = 'Test-Az' + 'SubscriptionDeployment'
            $validationOutput = @(
                & $validationCommand -Name "mcpsql-sku-$Suffix" -Location $Location `
                    -TemplateObject $template -ErrorAction Stop
            )
            $validationErrors = @(
                foreach ($item in $validationOutput) {
                    if ($null -eq $item) {
                        continue
                    }
                    if ($item.PSObject.Properties.Name -contains 'Message') {
                        ConvertTo-WorkshopSafeDetail -Value $item.Message
                    }
                    elseif ($item.PSObject.Properties.Name -contains 'Error') {
                        ConvertTo-WorkshopSafeDetail -Value $item.Error
                    }
                    else {
                        ConvertTo-WorkshopSafeDetail -Value $item
                    }
                }
            )
            $validated = $validationErrors.Count -eq 0
            [pscustomobject][ordered]@{
                PublicIpStandardAvailable = $validated
                NatGatewayStandardAvailable = $validated
                Errors = $validationErrors
            }
        }
        FindResourceGroup = {
            param($Name)
            try {
                [pscustomobject]@{
                    VerifiedAbsent = $false
                    ResourceGroup = Get-AzResourceGroup -Name $Name -ErrorAction Stop
                }
            }
            catch {
                if (-not (Test-WorkshopAzureNotFound -ErrorRecord $_)) {
                    throw
                }
                [pscustomobject]@{ VerifiedAbsent = $true; ResourceGroup = $null }
            }
        }
        FindResources = {
            param($Names, $ResourceGroupName)
            Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop |
                Where-Object { $_.Name -in $Names }
        }
    }
}

${function:Test-WorkshopPrerequisites} = {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SubscriptionId,
        [ValidateNotNullOrEmpty()][string] $TenantId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $FacilitatorCidr,
        [Parameter(Mandatory)][bool] $WindowsClientLicenseAttested,
        [Parameter(Mandatory)][bool] $SqlEnterpriseCostAcknowledged,
        [Parameter(Mandatory)][bool] $BillableResourcesAcknowledged,
        [Parameter(Mandatory)][datetime] $ExpiresOn,
        [hashtable] $Operations
    )

    Assert-WorkshopConfigShape -Config $Config
    if ($null -eq $Operations) {
        $Operations = Get-DefaultWorkshopOperationSet
    }
    $requiredOperations = @(
        'GetPowerShellVersion', 'GetModules', 'GetContext', 'GetProviders',
        'GetLocations', 'GetComputeSkus', 'GetImages', 'GetVmUsages',
        'TestNetworkSkuDeployment', 'FindResourceGroup', 'FindResources'
    )
    foreach ($operationName in $requiredOperations) {
        if (-not $Operations.ContainsKey($operationName) -or $Operations[$operationName] -isnot [scriptblock]) {
            throw "Operations must provide scriptblock '$operationName'."
        }
    }

    $checks = [System.Collections.Generic.List[object]]::new()
    $resolvedImages = @{ Admin = $null; Sql = $null }
    $plan = $null

    $versionResult = Invoke-WorkshopReadOperation -Operation $Operations.GetPowerShellVersion
    $powerShellVersion = if ($versionResult.Succeeded -and $versionResult.Value.Count -gt 0) { [version] $versionResult.Value[0] } else { [version]'0.0' }
    Add-WorkshopCheck -Checks $checks -Name 'PowerShell version' -Passed ($powerShellVersion -ge [version]'7.0') `
        -Detail "Detected PowerShell $powerShellVersion; version 7 or later is required." `
        -Remediation 'Run the preflight with PowerShell 7 or later.'

    $moduleResult = Invoke-WorkshopReadOperation -Operation $Operations.GetModules
    $installedModules = @($moduleResult.Value)
    foreach ($requiredModule in $script:RequiredAzModules.GetEnumerator()) {
        $installed = $installedModules | Where-Object Name -EQ $requiredModule.Key | Sort-Object Version -Descending | Select-Object -First 1
        $modulePassed = $moduleResult.Succeeded -and $null -ne $installed -and [version] $installed.Version -ge $requiredModule.Value
        $detected = if ($null -eq $installed) { 'not installed' } else { [string] $installed.Version }
        Add-WorkshopCheck -Checks $checks -Name "Module $($requiredModule.Key)" -Passed $modulePassed `
            -Detail "Detected $detected; minimum version is $($requiredModule.Value)." `
            -Remediation "Install or update $($requiredModule.Key) to version $($requiredModule.Value) or later."
    }

    $contextResult = Invoke-WorkshopReadOperation -Operation $Operations.GetContext
    $context = if ($contextResult.Value.Count -gt 0) { $contextResult.Value[0] } else { $null }
    $actualAccount = Get-WorkshopNestedIdentifier -InputObject $context -PropertyName 'Account'
    $actualTenant = Get-WorkshopNestedIdentifier -InputObject $context -PropertyName 'Tenant'
    $actualSubscription = Get-WorkshopNestedIdentifier -InputObject $context -PropertyName 'Subscription'
    $accountPassed = $contextResult.Succeeded -and -not [string]::IsNullOrWhiteSpace($actualAccount)
    Add-WorkshopCheck -Checks $checks -Name 'Azure context account' -Passed $accountPassed `
        -Detail "Authenticated account '$actualAccount'." `
        -Remediation 'Authenticate to Azure with a nonempty account before running preflight again.'
    Add-WorkshopCheck -Checks $checks -Name 'Azure context subscription' -Passed ($contextResult.Succeeded -and $actualSubscription -eq $SubscriptionId) `
        -Detail "Expected subscription '$SubscriptionId'; current subscription '$actualSubscription'." `
        -Remediation 'Select the explicit subscription before running preflight again.'
    $tenantSupplied = $PSBoundParameters.ContainsKey('TenantId')
    $tenantPassed = $contextResult.Succeeded -and -not [string]::IsNullOrWhiteSpace($actualTenant) -and
        (-not $tenantSupplied -or $actualTenant -eq $TenantId)
    $expectedTenant = if ($tenantSupplied) { "'$TenantId'" } else { 'any nonempty authenticated tenant' }
    Add-WorkshopCheck -Checks $checks -Name 'Azure context tenant' -Passed $tenantPassed `
        -Detail "Expected $expectedTenant; current tenant '$actualTenant'." `
        -Remediation 'Authenticate to and select the required tenant before running preflight again.'

    $providerResult = Invoke-WorkshopReadOperation -Operation $Operations.GetProviders
    foreach ($providerName in $script:RequiredProviders) {
        $provider = $providerResult.Value | Where-Object ProviderNamespace -EQ $providerName | Select-Object -First 1
        $providerPassed = $providerResult.Succeeded -and $null -ne $provider -and $provider.RegistrationState -eq 'Registered'
        $state = if ($null -eq $provider) { 'not returned' } else { [string] $provider.RegistrationState }
        Add-WorkshopCheck -Checks $checks -Name "Provider $providerName" -Passed $providerPassed `
            -Detail "Registration state is '$state'; preflight does not register providers." `
            -Remediation "Register $providerName outside this preflight, then rerun it."
    }

    $locationResult = Invoke-WorkshopReadOperation -Operation $Operations.GetLocations
    $locationExists = $locationResult.Succeeded -and $null -ne ($locationResult.Value | Where-Object Location -EQ $Config.Location | Select-Object -First 1)
    Add-WorkshopCheck -Checks $checks -Name 'Location' -Passed $locationExists `
        -Detail "Required location is '$($Config.Location)'." `
        -Remediation 'Confirm the subscription exposes the approved Indonesia Central location.'

    $skuResult = Invoke-WorkshopReadOperation -Operation $Operations.GetComputeSkus
    $skuRecords = @{}
    foreach ($vm in @($Config.AdminVm, $Config.SqlVm)) {
        $sku = $skuResult.Value | Where-Object {
            $_.Name -eq $vm.Size -and $_.ResourceType -eq 'virtualMachines' -and
            @($_.Locations) -contains $Config.Location
        } | Select-Object -First 1
        $skuRecords[$vm.Size] = $sku
        if ($null -eq $sku) {
            $restrictions = @()
        }
        else {
            $restrictions = @($sku.Restrictions)
        }
        $skuPassed = $skuResult.Succeeded -and $null -ne $sku -and $restrictions.Count -eq 0
        $restrictionDetail = if ($restrictions.Count -eq 0) { 'none' } else { ($restrictions.ReasonCode -join ', ') }
        Add-WorkshopCheck -Checks $checks -Name "VM SKU $($vm.Size)" -Passed $skuPassed `
            -Detail "Exact SKU in $($Config.Location); restrictions: $restrictionDetail. Availability is not claimed until this check passes." `
            -Remediation "Resolve subscription restrictions or choose an approved capacity path for $($vm.Size)."
    }

    $diskSku = $skuResult.Value | Where-Object {
        $_.Name -eq 'Premium_LRS' -and $_.ResourceType -eq 'disks' -and
        (Test-WorkshopLocationMatch -Locations @($_.Locations) -RequiredLocation $Config.Location)
    } | Select-Object -First 1
    $diskRestrictions = @()
    if ($null -ne $diskSku) {
        $diskRestrictions = @($diskSku.Restrictions)
    }
    $diskSkuPassed = $skuResult.Succeeded -and $null -ne $diskSku -and $diskRestrictions.Count -eq 0
    $diskRestrictionDetail = if ($diskRestrictions.Count -eq 0) { 'none' } else { ($diskRestrictions.ReasonCode -join ', ') }
    $diskSkuDetail = if (-not $skuResult.Succeeded) {
        "Managed disk SKU query failed: $($skuResult.Error)"
    }
    elseif ($null -eq $diskSku) {
        "Premium_LRS was not returned for managed disks in $($Config.Location)."
    }
    elseif ($diskRestrictions.Count -gt 0) {
        "Premium_LRS managed disks in $($Config.Location) have restrictions: $diskRestrictionDetail."
    }
    else {
        "Exact managed disk SKU in $($Config.Location); restrictions: none."
    }
    Add-WorkshopCheck -Checks $checks -Name 'Managed disk SKU Premium_LRS' -Passed $diskSkuPassed `
        -Detail $diskSkuDetail `
        -Remediation "Confirm Premium_LRS managed disks are available without subscription restrictions in $($Config.Location)."

    $requiredResourceTypes = @(
        @{ Provider = 'Microsoft.Compute'; Type = 'disks'; RequiredSku = 'Premium_LRS'; ExactSkuValidated = $true }
        @{ Provider = 'Microsoft.Network'; Type = 'publicIPAddresses'; RequiredSku = 'Standard'; ExactSkuValidated = $false }
        @{ Provider = 'Microsoft.Network'; Type = 'natGateways'; RequiredSku = 'Standard'; ExactSkuValidated = $false }
        @{ Provider = 'Microsoft.Network'; Type = 'virtualNetworks'; RequiredSku = ''; ExactSkuValidated = $false }
        @{ Provider = 'Microsoft.Network'; Type = 'networkSecurityGroups'; RequiredSku = ''; ExactSkuValidated = $false }
        @{ Provider = 'Microsoft.Network'; Type = 'applicationSecurityGroups'; RequiredSku = ''; ExactSkuValidated = $false }
        @{ Provider = 'Microsoft.Network'; Type = 'privateDnsZones'; RequiredSku = ''; ExactSkuValidated = $false; RequiredLocation = 'global' }
    )
    foreach ($requirement in $requiredResourceTypes) {
        $provider = $providerResult.Value | Where-Object ProviderNamespace -EQ $requirement.Provider | Select-Object -First 1
        $resourceTypes = if ($null -ne $provider -and $provider.PSObject.Properties.Name -contains 'ResourceTypes') {
            @($provider.ResourceTypes)
        }
        else {
            @()
        }
        $resourceType = $resourceTypes | Where-Object {
            $_.PSObject.Properties.Name -contains 'ResourceTypeName' -and $_.ResourceTypeName -eq $requirement.Type
        } | Select-Object -First 1
        $locations = if ($null -ne $resourceType -and $resourceType.PSObject.Properties.Name -contains 'Locations') {
            @($resourceType.Locations)
        }
        else {
            @()
        }
        $requiredLocation = if ($requirement.ContainsKey('RequiredLocation')) {
            [string] $requirement.RequiredLocation
        }
        else {
            [string] $Config.Location
        }
        $resourceTypePassed = $providerResult.Succeeded -and $null -ne $resourceType -and
            (Test-WorkshopLocationMatch -Locations $locations -RequiredLocation $requiredLocation)
        if (-not $resourceTypePassed) {
            $detail = "Provider metadata does not confirm resource-type support in location '$requiredLocation'."
            if (-not [string]::IsNullOrWhiteSpace([string] $requirement.RequiredSku) -and -not $requirement.ExactSkuValidated) {
                $detail += " Deployment still requires SKU '$($requirement.RequiredSku)', whose exact regional listing is not asserted by this metadata."
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string] $requirement.RequiredSku) -and -not $requirement.ExactSkuValidated) {
            $detail = "Provider metadata confirms location '$requiredLocation'; deployment requires SKU '$($requirement.RequiredSku)', whose exact regional listing is not asserted by this metadata."
        }
        elseif ($requirement.ExactSkuValidated) {
            $detail = "Provider metadata confirms location '$requiredLocation'; exact deployment SKU '$($requirement.RequiredSku)' is validated separately by the managed disk SKU check."
        }
        else {
            $detail = "Provider metadata confirms resource-type support in location '$requiredLocation'."
        }
        Add-WorkshopCheck -Checks $checks -Name "Resource type $($requirement.Provider)/$($requirement.Type)" -Passed $resourceTypePassed `
            -Detail $detail `
            -Remediation "Confirm $($requirement.Provider)/$($requirement.Type) supports $requiredLocation, then rerun preflight."
    }

    $networkSkuResult = Invoke-WorkshopReadOperation -Operation $Operations.TestNetworkSkuDeployment -Arguments @($Config.Location)
    $networkSkuValidation = if ($networkSkuResult.Succeeded -and $networkSkuResult.Value.Count -eq 1) {
        $networkSkuResult.Value[0]
    }
    else {
        $null
    }
    $networkSkuShapeValid = $null -ne $networkSkuValidation -and
        $networkSkuValidation.PSObject.Properties.Name -contains 'PublicIpStandardAvailable' -and
        $networkSkuValidation.PublicIpStandardAvailable -is [bool] -and
        $networkSkuValidation.PSObject.Properties.Name -contains 'NatGatewayStandardAvailable' -and
        $networkSkuValidation.NatGatewayStandardAvailable -is [bool]
    $networkSkuErrors = @()
    if (-not $networkSkuResult.Succeeded) {
        $networkSkuErrors = @(ConvertTo-WorkshopSafeDetail -Value $networkSkuResult.Error)
    }
    elseif (-not $networkSkuShapeValid) {
        $networkSkuErrors = @('Validation returned no verifiable exact-SKU result.')
    }
    elseif ($networkSkuValidation.PSObject.Properties.Name -contains 'Errors') {
        $networkSkuErrors = @($networkSkuValidation.Errors | ForEach-Object { ConvertTo-WorkshopSafeDetail -Value $_ })
    }
    $networkSkuErrorDetail = if ($networkSkuErrors.Count -gt 0) {
        $networkSkuErrors -join '; '
    }
    else {
        'No validation errors were returned.'
    }
    $publicIpStandardPassed = $networkSkuShapeValid -and $networkSkuValidation.PublicIpStandardAvailable -and
        $networkSkuErrors.Count -eq 0
    $natGatewayStandardPassed = $networkSkuShapeValid -and $networkSkuValidation.NatGatewayStandardAvailable -and
        $networkSkuErrors.Count -eq 0
    Add-WorkshopCheck -Checks $checks -Name 'Network SKU Standard public IP' -Passed $publicIpStandardPassed `
        -Detail "Subscription deployment validation for Standard, Static IPv4 public IP in $($Config.Location). $networkSkuErrorDetail This validates schema, SKU, and location, not capacity." `
        -Remediation 'Confirm the Standard public IP SKU validates in the approved subscription and region.'
    Add-WorkshopCheck -Checks $checks -Name 'Network SKU Standard NAT Gateway' -Passed $natGatewayStandardPassed `
        -Detail "Subscription deployment validation for Standard NAT Gateway in $($Config.Location). $networkSkuErrorDetail This validates schema, SKU, and location, not capacity." `
        -Remediation 'Confirm the Standard NAT Gateway SKU validates in the approved subscription and region.'

    foreach ($role in @('Admin', 'Sql')) {
        $vm = if ($role -eq 'Admin') { $Config.AdminVm } else { $Config.SqlVm }
        $imageResult = Invoke-WorkshopReadOperation -Operation $Operations.GetImages -Arguments @($vm.Publisher, $vm.Offer, $vm.Sku, $Config.Location)
        $versions = foreach ($image in $imageResult.Value) {
            $parsedVersion = $null
            if ($null -ne $image -and $image.PSObject.Properties.Name -contains 'Version' -and
                $image.Version -ne 'latest' -and [version]::TryParse([string] $image.Version, [ref] $parsedVersion)) {
                [pscustomobject]@{ Image = $image; ParsedVersion = $parsedVersion }
            }
        }
        $latestRecord = $versions | Sort-Object ParsedVersion -Descending | Select-Object -First 1
        $latest = if ($null -eq $latestRecord) { $null } else { $latestRecord.Image }
        $imagePassed = $imageResult.Succeeded -and $null -ne $latest
        if ($imagePassed) {
            $resolvedImages[$role] = [pscustomobject][ordered]@{
                Publisher = [string] $vm.Publisher
                Offer = [string] $vm.Offer
                Sku = [string] $vm.Sku
                Version = [string] $latest.Version
            }
        }
        $resolvedVersion = if ($null -eq $latest) { 'not resolved' } else { [string] $latest.Version }
        Add-WorkshopCheck -Checks $checks -Name "$role VM image" -Passed $imagePassed `
            -Detail "Exact image $($vm.Publisher):$($vm.Offer):$($vm.Sku); immutable version: $resolvedVersion." `
            -Remediation 'Confirm the exact Marketplace image coordinates are visible in Indonesia Central.'
    }

    $usageResult = Invoke-WorkshopReadOperation -Operation $Operations.GetVmUsages -Arguments @($Config.Location)
    $familyRequirements = @{}
    foreach ($requirement in @(
        @{ Vm = $Config.AdminVm; Vcpu = 4 },
        @{ Vm = $Config.SqlVm; Vcpu = 8 }
    )) {
        $sku = $skuRecords[$requirement.Vm.Size]
        $family = if ($null -ne $sku -and -not [string]::IsNullOrWhiteSpace([string] $sku.Family)) {
            [string] $sku.Family
        }
        elseif ($script:KnownVmFamilies.ContainsKey([string] $requirement.Vm.Size)) {
            [string] $script:KnownVmFamilies[[string] $requirement.Vm.Size]
        }
        else {
            $null
        }
        if (-not [string]::IsNullOrWhiteSpace($family)) {
            if (-not $familyRequirements.ContainsKey($family)) {
                $familyRequirements[$family] = 0
            }
            $familyRequirements[$family] += $requirement.Vcpu
        }
    }
    foreach ($family in @($familyRequirements.Keys | Sort-Object)) {
        $usage = $usageResult.Value | Where-Object { $_.Name.Value -eq $family } | Select-Object -First 1
        $required = [int] $familyRequirements[$family]
        $availability = Get-WorkshopQuotaAvailability -Usage $usage
        $usageAvailable = $usageResult.Succeeded -and $availability.Verified
        $available = if ($usageAvailable) { $availability.Available } else { $null }
        $missing = if ($usageAvailable) { [Math]::Max(0, $required - $available) } else { $null }
        $quotaPassed = $usageAvailable -and $available -ge $required
        $quotaDetail = if ($usageAvailable) {
            "Required vCPUs: $required; available vCPUs: $available; missing vCPUs: $missing."
        }
        else {
            "Required vCPUs: $required; available vCPUs: unknown; missing vCPUs: unknown."
        }
        Add-WorkshopCheck -Checks $checks -Name "Quota $family" -Passed $quotaPassed `
            -Detail $quotaDetail `
            -Remediation "Request at least $required available vCPUs for $family in $($Config.Location)."
    }

    $totalRequired = 12
    $totalUsage = $usageResult.Value | Where-Object {
        $_.Name.Value -eq 'cores' -or
        ($_.Name.PSObject.Properties.Name -contains 'LocalizedValue' -and
            $_.Name.LocalizedValue -eq 'Total Regional vCPUs')
    } | Select-Object -First 1
    $totalAvailability = Get-WorkshopQuotaAvailability -Usage $totalUsage
    $totalUsageAvailable = $usageResult.Succeeded -and $totalAvailability.Verified
    $totalAvailable = if ($totalUsageAvailable) { $totalAvailability.Available } else { $null }
    $totalMissing = if ($totalUsageAvailable) {
        [Math]::Max(0, $totalRequired - $totalAvailable)
    }
    else {
        $null
    }
    $totalDetail = if ($totalUsageAvailable) {
        "Required vCPUs: $totalRequired; available vCPUs: $totalAvailable; missing vCPUs: $totalMissing."
    }
    else {
        "Required vCPUs: $totalRequired; available vCPUs: unknown; missing vCPUs: unknown."
    }
    Add-WorkshopCheck -Checks $checks -Name 'Quota Total Regional vCPUs' `
        -Passed ($totalUsageAvailable -and $totalAvailable -ge $totalRequired) `
        -Detail $totalDetail `
        -Remediation "Request at least $totalRequired available Total Regional vCPUs in $($Config.Location)."

    $resourceGroupResult = Invoke-WorkshopReadOperation -Operation $Operations.FindResourceGroup -Arguments @($Config.ResourceGroupName)
    $resourceGroupValue = if ($resourceGroupResult.Value.Count -eq 1) { $resourceGroupResult.Value[0] } else { $null }
    $verifiedAbsent = $resourceGroupResult.Succeeded -and $null -ne $resourceGroupValue -and
        $resourceGroupValue.PSObject.Properties.Name -contains 'VerifiedAbsent' -and
        $resourceGroupValue.VerifiedAbsent -is [bool] -and $resourceGroupValue.VerifiedAbsent
    $resourceGroup = if ($null -ne $resourceGroupValue -and
        $resourceGroupValue.PSObject.Properties.Name -contains 'ResourceGroup') {
        $resourceGroupValue.ResourceGroup
    }
    elseif ($null -ne $resourceGroupValue -and
        $resourceGroupValue.PSObject.Properties.Name -notcontains 'VerifiedAbsent') {
        $resourceGroupValue
    }
    else {
        $null
    }
    $resourceGroupExists = $resourceGroupResult.Succeeded -and $null -ne $resourceGroup
    $resourceGroupDetail = if (-not $resourceGroupResult.Succeeded) {
        "Resource group collision read failed: $($resourceGroupResult.Error)"
    }
    elseif ($verifiedAbsent) {
        "Resource group '$($Config.ResourceGroupName)' is verified absent."
    }
    elseif ($resourceGroupExists) {
        "Resource group '$($Config.ResourceGroupName)' already exists."
    }
    else {
        "Resource group '$($Config.ResourceGroupName)' absence was not explicitly verified."
    }
    Add-WorkshopCheck -Checks $checks -Name 'Resource group collision' -Passed $verifiedAbsent `
        -Detail $resourceGroupDetail `
        -Remediation 'Choose a clean subscription scope or remove the old workshop through its verified teardown process.'

    $plannedNames = @(
        $Config.VNet.Name, $Config.AdminAsg, $Config.SqlAsg, $Config.AdminVm.Name,
        $Config.SqlVm.Name, $Config.PrivateDnsZone, 'pip-mcpsql-admin',
        'pip-mcpsql-nat', 'nat-mcpsql-workshop', 'nsg-mcpsql-admin', 'nsg-mcpsql-sql'
    )
    if ($verifiedAbsent) {
        $resourceNamesPassed = $true
        $resourceNameDetail = 'Scoped resource collision set is verified empty because the resource group is verified absent.'
    }
    elseif ($resourceGroupExists) {
        $resourceResult = Invoke-WorkshopReadOperation -Operation $Operations.FindResources -Arguments @(, $plannedNames, $Config.ResourceGroupName)
        $collisions = @($resourceResult.Value | Where-Object { $null -ne $_ })
        $resourceNamesPassed = $resourceResult.Succeeded -and $collisions.Count -eq 0
        $resourceNameDetail = if ($resourceResult.Succeeded) {
            "Found $($collisions.Count) existing resource(s) with planned names."
        }
        else {
            "Scoped resource collision read failed: $($resourceResult.Error)"
        }
    }
    else {
        $resourceNamesPassed = $false
        $resourceNameDetail = 'Scoped resource collisions cannot be verified until the resource-group read succeeds.'
    }
    Add-WorkshopCheck -Checks $checks -Name 'Resource name collisions' -Passed $resourceNamesPassed `
        -Detail $resourceNameDetail `
        -Remediation 'Remove or rename colliding workshop resources before deployment.'

    $validCidr = $false
    try {
        $normalizedCidr = Assert-WorkshopHostCidr -Cidr $FacilitatorCidr
        $validCidr = $true
        Add-WorkshopCheck -Checks $checks -Name 'Facilitator CIDR' -Passed $true `
            -Detail "Validated public IPv4 host CIDR '$normalizedCidr'." -Remediation ''
    }
    catch {
        Add-WorkshopCheck -Checks $checks -Name 'Facilitator CIDR' -Passed $false `
            -Detail $_.Exception.Message -Remediation 'Supply the facilitator public IPv4 address as a canonical /32.'
    }

    Add-WorkshopCheck -Checks $checks -Name 'Windows client license attestation' -Passed $WindowsClientLicenseAttested `
        -Detail 'Marketplace visibility does not prove Windows 11 Enterprise licensing eligibility.' `
        -Remediation 'Confirm eligibility and explicitly attest the Windows client license requirement.'
    Add-WorkshopCheck -Checks $checks -Name 'SQL Enterprise PAYG acknowledgement' -Passed $SqlEnterpriseCostAcknowledged `
        -Detail 'The approved SQL Server 2022 Enterprise image uses PAYG licensing.' `
        -Remediation 'Acknowledge SQL Server Enterprise PAYG cost before deployment.'
    $billableCategoryDetail = 'Windows client compute and license entitlement responsibility; Administration VM compute; SQL VM compute; SQL Server Enterprise PAYG; managed OS, data, and log disks; two Standard public IP resources for administration ingress and NAT egress; NAT Gateway hourly usage and data processing; outbound data transfer; Private DNS zone and query charges. Pricing was not queried.'
    Add-WorkshopCheck -Checks $checks -Name 'All billable resource categories acknowledged' -Passed $BillableResourcesAcknowledged `
        -Detail $billableCategoryDetail `
        -Remediation 'Review and acknowledge every listed billable resource category before deployment.'

    $today = (Get-Date).Date
    $expirationDate = $ExpiresOn.Date
    $expirationPassed = $expirationDate -gt $today -and $expirationDate -le $today.AddDays(7)
    Add-WorkshopCheck -Checks $checks -Name 'Expiration date' -Passed $expirationPassed `
        -Detail "Expiration date '$($expirationDate.ToString('yyyy-MM-dd'))' must be in the future and no more than seven days away." `
        -Remediation 'Choose an expiration date from tomorrow through seven days from today.'

    if ($validCidr) {
        $plan = Get-WorkshopPlan -Config $Config -FacilitatorCidr $FacilitatorCidr -ExpiresOn $ExpiresOn `
            -WindowsClientLicenseAttested $WindowsClientLicenseAttested `
            -SqlEnterpriseCostAcknowledged $SqlEnterpriseCostAcknowledged `
            -BillableResourcesAcknowledged $BillableResourcesAcknowledged -ResolvedImages $resolvedImages
    }

    [pscustomobject][ordered]@{
        Passed = @($checks | Where-Object Status -EQ 'Failed').Count -eq 0
        Checks = $checks.ToArray()
        ResolvedImages = [pscustomobject][ordered]@{
            Admin = $resolvedImages.Admin
            Sql = $resolvedImages.Sql
        }
        Plan = $plan
    }
}

function Get-WorkshopNetworkResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $ResourceType,
        [Parameter(Mandatory)][string] $Name
    )

    return "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/$ResourceType/$Name"
}

function Get-WorkshopNetworkResourceSpecification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $FacilitatorCidr,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SubscriptionId
    )

    Assert-WorkshopConfigShape -Config $Config
    $hostCidr = Assert-WorkshopHostCidr -Cidr $FacilitatorCidr
    $resourceGroupName = [string] $Config.ResourceGroupName
    $idParameters = @{ SubscriptionId = $SubscriptionId; ResourceGroupName = $resourceGroupName }
    $adminAsgId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'applicationSecurityGroups' -Name $Config.AdminAsg
    $sqlAsgId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'applicationSecurityGroups' -Name $Config.SqlAsg
    $adminPipId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'publicIPAddresses' -Name 'pip-mcpsql-admin'
    $natPipId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'publicIPAddresses' -Name 'pip-mcpsql-nat'
    $natId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'natGateways' -Name 'nat-mcpsql-workshop'
    $adminNsgId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'networkSecurityGroups' -Name 'nsg-mcpsql-admin'
    $sqlNsgId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'networkSecurityGroups' -Name 'nsg-mcpsql-sql'
    $vnetId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'virtualNetworks' -Name $Config.VNet.Name
    $privateDnsZoneId = Get-WorkshopNetworkResourceId @idParameters -ResourceType 'privateDnsZones' -Name $Config.PrivateDnsZone
    $privateDnsLinkName = "$($Config.VNet.Name)-link"
    $privateDnsLinkId = "$privateDnsZoneId/virtualNetworkLinks/$privateDnsLinkName"
    $privateDnsRecordId = "$privateDnsZoneId/A/sql01"
    $adminSubnetId = "$vnetId/subnets/$($Config.AdminSubnet.Name)"
    $sqlSubnetId = "$vnetId/subnets/$($Config.SqlSubnet.Name)"
    $tags = [ordered]@{}
    foreach ($key in @($Config.Tags.Keys | Sort-Object)) {
        $tags[$key] = [string] $Config.Tags[$key]
    }

    @(
        [pscustomobject][ordered]@{
            Kind = 'ResourceGroup'; Name = $resourceGroupName; Location = [string] $Config.Location
            Id = "/subscriptions/$SubscriptionId/resourceGroups/$resourceGroupName"; Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'ApplicationSecurityGroup'; Name = [string] $Config.AdminAsg; Location = [string] $Config.Location
            Id = $adminAsgId; Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'ApplicationSecurityGroup'; Name = [string] $Config.SqlAsg; Location = [string] $Config.Location
            Id = $sqlAsgId; Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'PublicIpAddress'; Name = 'pip-mcpsql-admin'; Location = [string] $Config.Location
            Id = $adminPipId; Sku = 'Standard'; AllocationMethod = 'Static'; IpAddressVersion = 'IPv4'; Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'PublicIpAddress'; Name = 'pip-mcpsql-nat'; Location = [string] $Config.Location
            Id = $natPipId; Sku = 'Standard'; AllocationMethod = 'Static'; IpAddressVersion = 'IPv4'; Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'NatGateway'; Name = 'nat-mcpsql-workshop'; Location = [string] $Config.Location
            Id = $natId; Sku = 'Standard'; PublicIpAddressIds = @($natPipId); Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'NetworkSecurityGroup'; Name = 'nsg-mcpsql-admin'; Location = [string] $Config.Location
            Id = $adminNsgId; Tags = $tags
            Rules = @(
                [pscustomobject][ordered]@{
                    Name = 'Allow-Facilitator-Rdp'; Priority = 100; Direction = 'Inbound'; Access = 'Allow'; Protocol = 'Tcp'
                    SourcePortRange = '*'; SourceAddressPrefix = $hostCidr; SourceApplicationSecurityGroupId = $null
                    DestinationPortRange = '3389'; DestinationAddressPrefix = $null
                    DestinationApplicationSecurityGroupId = $adminAsgId
                }
            )
        }
        [pscustomobject][ordered]@{
            Kind = 'NetworkSecurityGroup'; Name = 'nsg-mcpsql-sql'; Location = [string] $Config.Location
            Id = $sqlNsgId; Tags = $tags
            Rules = @(
                [pscustomobject][ordered]@{
                    Name = 'Allow-Admin-To-Sql'; Priority = 100; Direction = 'Inbound'; Access = 'Allow'; Protocol = 'Tcp'
                    SourcePortRange = '*'; SourceAddressPrefix = $null; SourceApplicationSecurityGroupId = $adminAsgId
                    DestinationPortRange = '1433'; DestinationAddressPrefix = $null
                    DestinationApplicationSecurityGroupId = $sqlAsgId
                }
                [pscustomobject][ordered]@{
                    Name = 'Allow-Admin-To-Sql-Rdp'; Priority = 110; Direction = 'Inbound'; Access = 'Allow'; Protocol = 'Tcp'
                    SourcePortRange = '*'; SourceAddressPrefix = $null; SourceApplicationSecurityGroupId = $adminAsgId
                    DestinationPortRange = '3389'; DestinationAddressPrefix = $null
                    DestinationApplicationSecurityGroupId = $sqlAsgId
                }
                [pscustomobject][ordered]@{
                    Name = 'Deny-Other-VNet-To-Sql'; Priority = 4000; Direction = 'Inbound'; Access = 'Deny'; Protocol = '*'
                    SourcePortRange = '*'; SourceAddressPrefix = 'VirtualNetwork'; SourceApplicationSecurityGroupId = $null
                    DestinationPortRange = '*'; DestinationAddressPrefix = $null
                    DestinationApplicationSecurityGroupId = $sqlAsgId
                }
            )
        }
        [pscustomobject][ordered]@{
            Kind = 'VirtualNetwork'; Name = [string] $Config.VNet.Name; Location = [string] $Config.Location
            Id = $vnetId; AddressPrefix = [string] $Config.VNet.AddressPrefix; Tags = $tags
            Subnets = @(
                [pscustomobject][ordered]@{
                    Name = [string] $Config.AdminSubnet.Name; AddressPrefix = [string] $Config.AdminSubnet.Prefix
                    PrivateEndpointNetworkPolicies = 'Disabled'; DefaultOutboundAccess = $false
                    NatGatewayId = $natId; NetworkSecurityGroupId = $adminNsgId
                }
                [pscustomobject][ordered]@{
                    Name = [string] $Config.SqlSubnet.Name; AddressPrefix = [string] $Config.SqlSubnet.Prefix
                    PrivateEndpointNetworkPolicies = 'Disabled'; DefaultOutboundAccess = $false
                    NatGatewayId = $natId; NetworkSecurityGroupId = $sqlNsgId
                }
            )
        }
        [pscustomobject][ordered]@{
            Kind = 'PrivateDnsZone'; Name = [string] $Config.PrivateDnsZone; Location = 'global'
            Id = $privateDnsZoneId; Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'PrivateDnsVirtualNetworkLink'; Name = "$($Config.PrivateDnsZone)/$privateDnsLinkName"; Location = 'global'
            Id = $privateDnsLinkId; ZoneName = [string] $Config.PrivateDnsZone; LinkName = $privateDnsLinkName
            VirtualNetworkId = $vnetId; RegistrationEnabled = $false; Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'PrivateDnsARecord'; Name = "$($Config.PrivateDnsZone)/sql01"; Location = 'global'
            Id = $privateDnsRecordId; ZoneName = [string] $Config.PrivateDnsZone; RecordName = 'sql01'
            RecordType = 'A'; Ttl = 300; Ipv4Addresses = @([string] $Config.SqlPrivateIp)
        }
        [pscustomobject][ordered]@{
            Kind = 'NetworkInterface'; Name = 'nic-mcpsql-admin'; Location = [string] $Config.Location
            Id = (Get-WorkshopNetworkResourceId @idParameters -ResourceType 'networkInterfaces' -Name 'nic-mcpsql-admin')
            SubnetId = $adminSubnetId; PrivateIpAllocationMethod = 'Dynamic'; PrivateIpAddress = $null
            PublicIpAddressId = $adminPipId; PublicIpAddressIds = @($adminPipId); IpConfigurationCount = 1
            ApplicationSecurityGroupIds = @($adminAsgId)
            NetworkSecurityGroupId = $null; Tags = $tags
        }
        [pscustomobject][ordered]@{
            Kind = 'NetworkInterface'; Name = 'nic-mcpsql-sql'; Location = [string] $Config.Location
            Id = (Get-WorkshopNetworkResourceId @idParameters -ResourceType 'networkInterfaces' -Name 'nic-mcpsql-sql')
            SubnetId = $sqlSubnetId; PrivateIpAllocationMethod = 'Static'; PrivateIpAddress = [string] $Config.SqlPrivateIp
            PublicIpAddressId = $null; PublicIpAddressIds = @(); IpConfigurationCount = 1
            ApplicationSecurityGroupIds = @($sqlAsgId)
            NetworkSecurityGroupId = $null; Tags = $tags
        }
    )
}

function ConvertTo-WorkshopComparableValue {
    [CmdletBinding()]
    param([AllowNull()][object] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Value -match '(?i)^/?subscriptions/') {
            return ('/' + $Value.Trim('/')).ToLowerInvariant()
        }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $result[[string] $key] = ConvertTo-WorkshopComparableValue -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-WorkshopComparableValue -Value $_ })
    }
    if ($Value -is [psobject] -and @($Value.PSObject.Properties).Count -gt 0 -and $Value -isnot [ValueType]) {
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
            $result[$property.Name] = ConvertTo-WorkshopComparableValue -Value $property.Value
        }
        return $result
    }
    return $Value
}

function Test-WorkshopNetworkResourceMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $Expected,
        [Parameter(Mandatory)][psobject] $Actual
    )

    if ($Expected.Kind -eq 'NetworkSecurityGroup' -and $Actual.Kind -eq 'NetworkSecurityGroup') {
        $expectedBase = [pscustomobject][ordered]@{
            Kind = $Expected.Kind; Name = $Expected.Name; Location = $Expected.Location
            Id = $Expected.Id; Tags = $Expected.Tags
        }
        $actualBase = [pscustomobject][ordered]@{
            Kind = $Actual.Kind; Name = $Actual.Name; Location = $Actual.Location
            Id = $Actual.Id; Tags = $Actual.Tags
        }
        $expectedComparable = ConvertTo-WorkshopComparableValue -Value $expectedBase
        $actualComparable = ConvertTo-WorkshopComparableValue -Value $actualBase
        $baseMatches = ($expectedComparable | ConvertTo-Json -Depth 20 -Compress) -ceq
            ($actualComparable | ConvertTo-Json -Depth 20 -Compress)
        return $baseMatches -and (Test-WorkshopExactCustomRuleSet `
            -ExpectedRules @($Expected.Rules) -ActualRules @($Actual.Rules))
    }

    $expectedComparable = ConvertTo-WorkshopComparableValue -Value $Expected
    $actualComparable = ConvertTo-WorkshopComparableValue -Value $Actual
    return ($expectedComparable | ConvertTo-Json -Depth 20 -Compress) -ceq
        ($actualComparable | ConvertTo-Json -Depth 20 -Compress)
}

function Get-WorkshopReferenceId {
    [CmdletBinding()]
    param([AllowNull()][object] $Reference)

    if ($null -eq $Reference) { return '' }
    if ($Reference -is [string]) { return [string] $Reference }
    if ($Reference.PSObject.Properties.Name -contains 'Id' -and $null -ne $Reference.Id) {
        return [string] $Reference.Id
    }
    return ''
}

function ConvertFrom-WorkshopAzNetworkResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][psobject] $Resource
    )

    if ($Resource.PSObject.Properties.Name -contains 'Kind') {
        return $Resource
    }
    $name = if ($Kind -eq 'ResourceGroup') { [string] $Resource.ResourceGroupName } else { [string] $Resource.Name }
    $location = [string] $Resource.Location
    $tags = if ($null -eq $Resource.Tags) { [ordered]@{} } else { $Resource.Tags }
    switch ($Kind) {
        'ResourceGroup' {
            return [pscustomobject][ordered]@{ Kind = $Kind; Name = $name; Location = $location; Id = [string] $Resource.ResourceId; Tags = $tags }
        }
        'ApplicationSecurityGroup' {
            return [pscustomobject][ordered]@{ Kind = $Kind; Name = $name; Location = $location; Id = [string] $Resource.Id; Tags = $tags }
        }
        'PublicIpAddress' {
            return [pscustomobject][ordered]@{
                Kind = $Kind; Name = $name; Location = $location; Id = [string] $Resource.Id
                Sku = [string] $Resource.Sku.Name; AllocationMethod = [string] $Resource.PublicIpAllocationMethod
                IpAddressVersion = [string] $Resource.PublicIpAddressVersion; Tags = $tags
            }
        }
        'NatGateway' {
            return [pscustomobject][ordered]@{
                Kind = $Kind; Name = $name; Location = $location; Id = [string] $Resource.Id; Sku = [string] $Resource.Sku.Name
                PublicIpAddressIds = @($Resource.PublicIpAddresses | ForEach-Object { [string] $_.Id }); Tags = $tags
            }
        }
        'NetworkSecurityGroup' {
            $rules = @($Resource.SecurityRules | ForEach-Object {
                [pscustomobject][ordered]@{
                    Name = [string] $_.Name; Priority = [int] $_.Priority; Direction = [string] $_.Direction
                    Access = [string] $_.Access; Protocol = [string] $_.Protocol
                    SourcePortRange = [string] $_.SourcePortRange; SourceAddressPrefix = [string] $_.SourceAddressPrefix
                    SourceApplicationSecurityGroupId = Get-WorkshopReferenceId -Reference @($_.SourceApplicationSecurityGroups)[0]
                    SourcePortRanges = @($_.SourcePortRanges); SourceAddressPrefixes = @($_.SourceAddressPrefixes)
                    SourceApplicationSecurityGroupIds = @($_.SourceApplicationSecurityGroups | ForEach-Object { Get-WorkshopReferenceId -Reference $_ })
                    DestinationPortRange = [string] $_.DestinationPortRange; DestinationAddressPrefix = [string] $_.DestinationAddressPrefix
                    DestinationApplicationSecurityGroupId = Get-WorkshopReferenceId -Reference @($_.DestinationApplicationSecurityGroups)[0]
                    DestinationPortRanges = @($_.DestinationPortRanges); DestinationAddressPrefixes = @($_.DestinationAddressPrefixes)
                    DestinationApplicationSecurityGroupIds = @($_.DestinationApplicationSecurityGroups | ForEach-Object { Get-WorkshopReferenceId -Reference $_ })
                }
            })
            return [pscustomobject][ordered]@{ Kind = $Kind; Name = $name; Location = $location; Id = [string] $Resource.Id; Tags = $tags; Rules = $rules }
        }
        'VirtualNetwork' {
            $subnets = @($Resource.Subnets | ForEach-Object {
                $defaultOutboundAccess = if ($_.PSObject.Properties.Name -contains 'DefaultOutboundAccess' -and
                    $_.DefaultOutboundAccess -is [bool]) {
                    $_.DefaultOutboundAccess
                }
                else {
                    $null
                }
                [pscustomobject][ordered]@{
                    Name = [string] $_.Name; AddressPrefix = [string] $_.AddressPrefix
                    PrivateEndpointNetworkPolicies = [string] $_.PrivateEndpointNetworkPolicies
                    DefaultOutboundAccess = $defaultOutboundAccess
                    NatGatewayId = Get-WorkshopReferenceId -Reference $_.NatGateway
                    NetworkSecurityGroupId = Get-WorkshopReferenceId -Reference $_.NetworkSecurityGroup
                }
            })
            return [pscustomobject][ordered]@{
                Kind = $Kind; Name = $name; Location = $location; Id = [string] $Resource.Id
                AddressPrefix = [string] @($Resource.AddressSpace.AddressPrefixes)[0]; Tags = $tags; Subnets = $subnets
            }
        }
        'NetworkInterface' {
            $ipConfigurations = @($Resource.IpConfigurations)
            $ipConfiguration = $ipConfigurations[0]
            $privateIpAddress = if ([string] $ipConfiguration.PrivateIpAllocationMethod -eq 'Static') {
                [string] $ipConfiguration.PrivateIpAddress
            }
            else {
                $null
            }
            return [pscustomobject][ordered]@{
                Kind = $Kind; Name = $name; Location = $location; Id = [string] $Resource.Id
                SubnetId = Get-WorkshopReferenceId -Reference $ipConfiguration.Subnet
                PrivateIpAllocationMethod = [string] $ipConfiguration.PrivateIpAllocationMethod
                PrivateIpAddress = $privateIpAddress
                PublicIpAddressId = Get-WorkshopReferenceId -Reference $ipConfiguration.PublicIpAddress
                PublicIpAddressIds = @($ipConfigurations | ForEach-Object { Get-WorkshopReferenceId -Reference $_.PublicIpAddress } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                IpConfigurationCount = $ipConfigurations.Count
                ApplicationSecurityGroupIds = @($ipConfiguration.ApplicationSecurityGroups | ForEach-Object { [string] $_.Id })
                NetworkSecurityGroupId = Get-WorkshopReferenceId -Reference $Resource.NetworkSecurityGroup
                Tags = $tags
            }
        }
        'PrivateDnsZone' {
            $resourceId = if ($Resource.PSObject.Properties.Name -contains 'ResourceId') {
                [string] $Resource.ResourceId
            }
            else {
                [string] $Resource.Id
            }
            return [pscustomobject][ordered]@{
                Kind = $Kind; Name = $name; Location = 'global'; Id = $resourceId; Tags = $tags
            }
        }
        'PrivateDnsVirtualNetworkLink' {
            $resourceId = if ($Resource.PSObject.Properties.Name -contains 'ResourceId') {
                [string] $Resource.ResourceId
            }
            else {
                [string] $Resource.Id
            }
            $registrationEnabled = if ($Resource.PSObject.Properties.Name -contains 'RegistrationEnabled') {
                [bool] $Resource.RegistrationEnabled
            }
            else {
                [bool] $Resource.EnableRegistration
            }
            $virtualNetworkId = if ($Resource.PSObject.Properties.Name -contains 'VirtualNetworkId') {
                [string] $Resource.VirtualNetworkId
            }
            elseif ($Resource.PSObject.Properties.Name -contains 'VirtualNetwork') {
                Get-WorkshopReferenceId -Reference $Resource.VirtualNetwork
            }
            else {
                ''
            }
            return [pscustomobject][ordered]@{
                Kind = $Kind; Name = "$($Resource.ZoneName)/$name"; Location = 'global'; Id = $resourceId
                ZoneName = [string] $Resource.ZoneName; LinkName = $name
                VirtualNetworkId = $virtualNetworkId
                RegistrationEnabled = $registrationEnabled; Tags = $tags
            }
        }
        'PrivateDnsARecord' {
            $resourceId = if ($Resource.PSObject.Properties.Name -contains 'ResourceId') {
                [string] $Resource.ResourceId
            }
            else {
                [string] $Resource.Id
            }
            $ipv4Addresses = @($Resource.Records | ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'Ipv4Address') { [string] $_.Ipv4Address }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            return [pscustomobject][ordered]@{
                Kind = $Kind; Name = "$($Resource.ZoneName)/$name"; Location = 'global'; Id = $resourceId
                ZoneName = [string] $Resource.ZoneName; RecordName = $name; RecordType = [string] $Resource.RecordType
                Ttl = [int] $Resource.Ttl; Ipv4Addresses = $ipv4Addresses
            }
        }
        default { throw "Unsupported workshop network resource kind '$Kind'." }
    }
}

function Get-DefaultWorkshopNetworkOperationSet {
    [CmdletBinding()]
    param()

    @{
        GetSubscriptionId = {
            $context = Get-AzContext -ErrorAction Stop
            $subscriptionId = Get-WorkshopNestedIdentifier -InputObject $context -PropertyName 'Subscription'
            if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
                throw 'The active Azure context did not return a subscription ID.'
            }
            $subscriptionId
        }
        GetResource = {
            param($Kind, $Name, $ResourceGroupName)
            try {
                $resource = switch ($Kind) {
                    'ResourceGroup' { Get-AzResourceGroup -Name $Name -ErrorAction Stop }
                    'ApplicationSecurityGroup' { Get-AzApplicationSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
                    'PublicIpAddress' { Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
                    'NatGateway' { Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
                    'NetworkSecurityGroup' { Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
                    'VirtualNetwork' { Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
                    'NetworkInterface' { Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
                    'PrivateDnsZone' { Get-AzPrivateDnsZone -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
                    'PrivateDnsVirtualNetworkLink' {
                        $zoneName, $linkName = $Name -split '/', 2
                        $link = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $ResourceGroupName `
                            -ZoneName $zoneName -Name $linkName -ErrorAction Stop
                        $link | Add-Member -NotePropertyName ZoneName -NotePropertyValue $zoneName -Force
                        $link
                    }
                    'PrivateDnsARecord' {
                        $zoneName, $recordName = $Name -split '/', 2
                        $record = Get-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroupName `
                            -ZoneName $zoneName -Name $recordName -RecordType A -ErrorAction Stop
                        $record | Add-Member -NotePropertyName ZoneName -NotePropertyValue $zoneName -Force
                        $record
                    }
                    default { throw "Unsupported workshop network resource kind '$Kind'." }
                }
                ConvertFrom-WorkshopAzNetworkResource -Kind $Kind -Resource $resource
            }
            catch {
                if (Test-WorkshopAzureNotFound -ErrorRecord $_) { return $null }
                throw
            }
        }
        GetPublicIpInventory = {
            param($ResourceGroupName)
            @(Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -ErrorAction Stop | ForEach-Object {
                ConvertFrom-WorkshopAzNetworkResource -Kind 'PublicIpAddress' -Resource $_
            })
        }
        CreateResource = {
            param($Spec, $ResourceGroupName)
            switch ($Spec.Kind) {
                'ResourceGroup' {
                    New-AzResourceGroup -Name $Spec.Name -Location $Spec.Location -Tag $Spec.Tags -ErrorAction Stop
                }
                'ApplicationSecurityGroup' {
                    New-AzApplicationSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Spec.Name `
                        -Location $Spec.Location -Tag $Spec.Tags -ErrorAction Stop
                }
                'PublicIpAddress' {
                    New-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Spec.Name `
                        -Location $Spec.Location -Sku $Spec.Sku -AllocationMethod $Spec.AllocationMethod `
                        -IpAddressVersion $Spec.IpAddressVersion -Tag $Spec.Tags -ErrorAction Stop
                }
                'NatGateway' {
                    $publicIp = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName `
                        -Name (($Spec.PublicIpAddressIds[0] -split '/')[-1]) -ErrorAction Stop
                    New-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $Spec.Name `
                        -Location $Spec.Location -Sku $Spec.Sku -PublicIpAddress $publicIp `
                        -Tag $Spec.Tags -ErrorAction Stop
                }
                'NetworkSecurityGroup' {
                    $securityRules = foreach ($rule in $Spec.Rules) {
                        $parameters = @{
                            Name = $rule.Name; Priority = $rule.Priority; Direction = $rule.Direction
                            Access = $rule.Access; Protocol = $rule.Protocol; SourcePortRange = $rule.SourcePortRange
                            DestinationPortRange = $rule.DestinationPortRange; ErrorAction = 'Stop'
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string] $rule.SourceAddressPrefix)) {
                            $parameters.SourceAddressPrefix = $rule.SourceAddressPrefix
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string] $rule.SourceApplicationSecurityGroupId)) {
                            $parameters.SourceApplicationSecurityGroup = @(
                                Get-AzApplicationSecurityGroup -ResourceGroupName $ResourceGroupName `
                                    -Name (($rule.SourceApplicationSecurityGroupId -split '/')[-1]) -ErrorAction Stop
                            )
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string] $rule.DestinationAddressPrefix)) {
                            $parameters.DestinationAddressPrefix = $rule.DestinationAddressPrefix
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string] $rule.DestinationApplicationSecurityGroupId)) {
                            $parameters.DestinationApplicationSecurityGroup = @(
                                Get-AzApplicationSecurityGroup -ResourceGroupName $ResourceGroupName `
                                    -Name (($rule.DestinationApplicationSecurityGroupId -split '/')[-1]) -ErrorAction Stop
                            )
                        }
                        New-AzNetworkSecurityRuleConfig @parameters
                    }
                    New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Spec.Name `
                        -Location $Spec.Location -SecurityRules $securityRules -Tag $Spec.Tags -ErrorAction Stop
                }
                'VirtualNetwork' {
                    $natGateway = Get-AzNatGateway -ResourceGroupName $ResourceGroupName `
                        -Name (($Spec.Subnets[0].NatGatewayId -split '/')[-1]) -ErrorAction Stop
                    $subnets = foreach ($subnet in $Spec.Subnets) {
                        $networkSecurityGroup = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName `
                            -Name (($subnet.NetworkSecurityGroupId -split '/')[-1]) -ErrorAction Stop
                        New-AzVirtualNetworkSubnetConfig -Name $subnet.Name -AddressPrefix $subnet.AddressPrefix `
                            -NetworkSecurityGroup $networkSecurityGroup -InputObject $natGateway `
                            -PrivateEndpointNetworkPoliciesFlag $subnet.PrivateEndpointNetworkPolicies `
                            -DefaultOutboundAccess $subnet.DefaultOutboundAccess -ErrorAction Stop
                    }
                    New-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $Spec.Name `
                        -Location $Spec.Location -AddressPrefix $Spec.AddressPrefix -Subnet $subnets `
                        -Tag $Spec.Tags -ErrorAction Stop
                }
                'PrivateDnsZone' {
                    New-AzPrivateDnsZone -ResourceGroupName $ResourceGroupName -Name $Spec.Name `
                        -Tag $Spec.Tags -ErrorAction Stop
                }
                'PrivateDnsVirtualNetworkLink' {
                    New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $ResourceGroupName `
                        -ZoneName $Spec.ZoneName -Name $Spec.LinkName -VirtualNetworkId $Spec.VirtualNetworkId `
                        -EnableRegistration:$Spec.RegistrationEnabled -Tag $Spec.Tags -ErrorAction Stop
                }
                'PrivateDnsARecord' {
                    $record = New-AzPrivateDnsRecordConfig -IPv4Address $Spec.Ipv4Addresses[0]
                    New-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroupName -ZoneName $Spec.ZoneName `
                        -Name $Spec.RecordName -RecordType A -Ttl $Spec.Ttl -PrivateDnsRecords $record `
                        -ErrorAction Stop
                }
                'NetworkInterface' {
                    $virtualNetworkName = ($Spec.SubnetId -split '/virtualNetworks/')[1] -split '/subnets/' | Select-Object -First 1
                    $subnetName = ($Spec.SubnetId -split '/')[-1]
                    $virtualNetwork = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName `
                        -Name $virtualNetworkName -ErrorAction Stop
                    $subnet = @($virtualNetwork.Subnets | Where-Object Name -EQ $subnetName)[0]
                    if ($null -eq $subnet) { throw "Subnet '$subnetName' was not returned for NIC creation." }
                    $applicationSecurityGroups = @($Spec.ApplicationSecurityGroupIds | ForEach-Object {
                        Get-AzApplicationSecurityGroup -ResourceGroupName $ResourceGroupName `
                            -Name (($_ -split '/')[-1]) -ErrorAction Stop
                    })
                    $ipParameters = @{
                        Name = 'ipconfig1'; Subnet = $subnet
                        ApplicationSecurityGroup = $applicationSecurityGroups
                        ErrorAction = 'Stop'
                    }
                    if ($Spec.PrivateIpAllocationMethod -eq 'Static') {
                        $ipParameters.PrivateIpAddress = $Spec.PrivateIpAddress
                        $ipParameters.PrivateIpAddressVersion = 'IPv4'
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string] $Spec.PublicIpAddressId)) {
                        $ipParameters.PublicIpAddress = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName `
                            -Name (($Spec.PublicIpAddressId -split '/')[-1]) -ErrorAction Stop
                    }
                    $ipConfiguration = New-AzNetworkInterfaceIpConfig @ipParameters
                    New-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $Spec.Name `
                        -Location $Spec.Location -IpConfiguration $ipConfiguration -Tag $Spec.Tags `
                        -ErrorAction Stop
                }
                default { throw "Unsupported workshop network resource kind '$($Spec.Kind)'." }
            }
        }
    }
}

function Assert-WorkshopNetworkOperationSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Operations,
        [switch] $ReadOnly
    )

    $required = @('GetSubscriptionId', 'GetResource', 'GetPublicIpInventory')
    if (-not $ReadOnly) { $required += 'CreateResource' }
    foreach ($name in $required) {
        if (-not $Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]) {
            throw "Operations must provide scriptblock '$name'."
        }
    }
}

${function:New-WorkshopNetwork} = {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $FacilitatorCidr,
        [hashtable] $Operations
    )

    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopNetworkOperationSet }
    Assert-WorkshopNetworkOperationSet -Operations $Operations
    $subscriptionId = [string] (& $Operations.GetSubscriptionId)
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw 'Network operations returned an empty subscription ID.'
    }
    $specs = @(Get-WorkshopNetworkResourceSpecification -Config $Config `
        -FacilitatorCidr $FacilitatorCidr -SubscriptionId $subscriptionId)
    $checkpoint = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($spec in $specs) {
            $existing = & $Operations.GetResource $spec.Kind $spec.Name $Config.ResourceGroupName
            if ($null -ne $existing) {
                if (-not (Test-WorkshopNetworkResourceMatch -Expected $spec -Actual $existing)) {
                    throw "$($spec.Kind) '$($spec.Name)' conflicts with the approved shape."
                }
                $checkpoint.Add("$($spec.Kind)/$($spec.Name):matched")
                continue
            }

            $null = & $Operations.CreateResource $spec $Config.ResourceGroupName
            $readBack = & $Operations.GetResource $spec.Kind $spec.Name $Config.ResourceGroupName
            if ($null -eq $readBack) {
                throw "$($spec.Kind) '$($spec.Name)' was not returned by positive native read-back."
            }
            if (-not (Test-WorkshopNetworkResourceMatch -Expected $spec -Actual $readBack)) {
                throw "$($spec.Kind) '$($spec.Name)' positive native read-back conflicts with the approved shape."
            }
            $checkpoint.Add("$($spec.Kind)/$($spec.Name):created-and-verified")
        }
    }
    catch {
        $safeMessage = ConvertTo-WorkshopSafeDetail -Value $_.Exception.Message
        $safeCheckpoint = if ($checkpoint.Count -eq 0) { 'none' } else { $checkpoint -join ', ' }
        throw "$safeMessage Checkpoint: $safeCheckpoint. No automatic rollback was attempted; correct the mismatch or failure, then rerun to resume."
    }

    [pscustomobject][ordered]@{
        Completed = $true
        Checkpoint = $checkpoint.ToArray()
        Resources = $specs
    }
}

function Add-WorkshopBoundaryCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Checks,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Passed,
        [Parameter(Mandatory)][string] $Detail
    )

    Add-WorkshopCheck -Checks $Checks -Name $Name -Passed $Passed -Detail $Detail `
        -Remediation 'Restore the exact approved private two-tier network shape, then run boundary verification again.'
}

function Get-WorkshopRulePropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $Rule,
        [Parameter(Mandatory)][string] $SingularName,
        [Parameter(Mandatory)][string] $PluralName
    )

    $values = @()
    if ($Rule.PSObject.Properties.Name -contains $SingularName) {
        $values += @($Rule.$SingularName)
    }
    if ($Rule.PSObject.Properties.Name -contains $PluralName) {
        $values += @($Rule.$PluralName)
    }
    return @($values | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string] $_) })
}

function Test-WorkshopRuleCoversPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $Rule,
        [Parameter(Mandatory)][int] $Port
    )

    foreach ($range in @(Get-WorkshopRulePropertyValue -Rule $Rule `
            -SingularName 'DestinationPortRange' -PluralName 'DestinationPortRanges')) {
        if ($range -eq '*' -or $range -eq [string] $Port) { return $true }
        if ($range -match '^(\d+)-(\d+)$' -and $Port -ge [int] $Matches[1] -and $Port -le [int] $Matches[2]) {
            return $true
        }
    }
    return $false
}

function Test-WorkshopRuleProtocol {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $Rule,
        [Parameter(Mandatory)][string] $Protocol
    )

    return [string] $Rule.Protocol -in @('*', $Protocol)
}

function ConvertTo-WorkshopNormalizedRule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject] $Rule)

    function Get-NormalizedScalarValue {
        param([string] $SingularName, [string] $PluralName, [switch] $Reference)

        $values = Get-WorkshopRulePropertyValue -Rule $Rule -SingularName $SingularName -PluralName $PluralName
        @($values | ForEach-Object {
            $value = if ($Reference) { Get-WorkshopReferenceId -Reference $_ } else { [string] $_ }
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                if ($value -match '(?i)^/?subscriptions/') {
                    ConvertTo-WorkshopComparableValue -Value $value
                }
                else {
                    $value.ToLowerInvariant()
                }
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }

    [pscustomobject][ordered]@{
        Name = ([string] $Rule.Name).ToLowerInvariant()
        Priority = [int] $Rule.Priority
        Direction = ([string] $Rule.Direction).ToLowerInvariant()
        Access = ([string] $Rule.Access).ToLowerInvariant()
        Protocol = ([string] $Rule.Protocol).ToLowerInvariant()
        SourcePorts = @(Get-NormalizedScalarValue -SingularName 'SourcePortRange' -PluralName 'SourcePortRanges')
        SourceAddresses = @(Get-NormalizedScalarValue -SingularName 'SourceAddressPrefix' -PluralName 'SourceAddressPrefixes')
        SourceAsgs = @(Get-NormalizedScalarValue -SingularName 'SourceApplicationSecurityGroupId' `
            -PluralName 'SourceApplicationSecurityGroupIds' -Reference)
        DestinationPorts = @(Get-NormalizedScalarValue -SingularName 'DestinationPortRange' -PluralName 'DestinationPortRanges')
        DestinationAddresses = @(Get-NormalizedScalarValue -SingularName 'DestinationAddressPrefix' -PluralName 'DestinationAddressPrefixes')
        DestinationAsgs = @(Get-NormalizedScalarValue -SingularName 'DestinationApplicationSecurityGroupId' `
            -PluralName 'DestinationApplicationSecurityGroupIds' -Reference)
    }
}

function Test-WorkshopExactCustomRuleSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $ExpectedRules,
        [Parameter(Mandatory)][object[]] $ActualRules
    )

    $customRules = @($ActualRules | Where-Object {
        -not ($_.PSObject.Properties.Name -contains 'ManagedByAzure' -and $_.ManagedByAzure -eq $true)
    })
    $expected = @($ExpectedRules | ForEach-Object { ConvertTo-WorkshopNormalizedRule -Rule $_ } |
        Sort-Object Priority, Name)
    $actual = @($customRules | ForEach-Object { ConvertTo-WorkshopNormalizedRule -Rule $_ } |
        Sort-Object Priority, Name)
    return $expected.Count -eq $actual.Count -and
        (($expected | ConvertTo-Json -Depth 10 -Compress) -ceq ($actual | ConvertTo-Json -Depth 10 -Compress))
}

${function:Test-WorkshopNetworkBoundary} = {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $FacilitatorCidr,
        [hashtable] $Operations
    )

    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopNetworkOperationSet }
    Assert-WorkshopNetworkOperationSet -Operations $Operations -ReadOnly
    $checks = [System.Collections.Generic.List[object]]::new()
    try {
        $subscriptionId = [string] (& $Operations.GetSubscriptionId)
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
            throw 'Network operations returned an empty subscription ID.'
        }
    }
    catch {
        Add-WorkshopBoundaryCheck -Checks $checks -Name 'Read subscription identity' -Passed $false `
            -Detail (ConvertTo-WorkshopSafeDetail -Value $_.Exception.Message)
        return [pscustomobject][ordered]@{ Passed = $false; Checks = $checks.ToArray() }
    }
    $expectedSpecs = @(Get-WorkshopNetworkResourceSpecification -Config $Config `
        -FacilitatorCidr $FacilitatorCidr -SubscriptionId $subscriptionId)
    $actual = @{}
    foreach ($spec in $expectedSpecs) {
        try {
            $resource = & $Operations.GetResource $spec.Kind $spec.Name $Config.ResourceGroupName
            if ($null -eq $resource) { throw "$($spec.Kind) '$($spec.Name)' was not returned." }
            $actual["$($spec.Kind)/$($spec.Name)"] = $resource
            Add-WorkshopBoundaryCheck -Checks $checks -Name "Read $($spec.Kind) $($spec.Name)" -Passed $true `
                -Detail 'Deployed object was read successfully.'
        }
        catch {
            Add-WorkshopBoundaryCheck -Checks $checks -Name "Read $($spec.Kind) $($spec.Name)" -Passed $false `
                -Detail (ConvertTo-WorkshopSafeDetail -Value $_.Exception.Message)
        }
    }
    if ($actual.Count -ne $expectedSpecs.Count) {
        return [pscustomobject][ordered]@{ Passed = $false; Checks = $checks.ToArray() }
    }

    $adminPip = $actual['PublicIpAddress/pip-mcpsql-admin']
    $natPip = $actual['PublicIpAddress/pip-mcpsql-nat']
    $nat = $actual['NatGateway/nat-mcpsql-workshop']
    $adminNsg = $actual['NetworkSecurityGroup/nsg-mcpsql-admin']
    $sqlNsg = $actual['NetworkSecurityGroup/nsg-mcpsql-sql']
    $vnet = $actual["VirtualNetwork/$($Config.VNet.Name)"]
    $adminNic = $actual['NetworkInterface/nic-mcpsql-admin']
    $sqlNic = $actual['NetworkInterface/nic-mcpsql-sql']
    $expectedByKey = @{}
    foreach ($spec in $expectedSpecs) { $expectedByKey["$($spec.Kind)/$($spec.Name)"] = $spec }
    $adminAsgId = $expectedByKey["ApplicationSecurityGroup/$($Config.AdminAsg)"].Id
    $sqlAsgId = $expectedByKey["ApplicationSecurityGroup/$($Config.SqlAsg)"].Id

    $resourceIdentitiesPassed = $true
    foreach ($key in $expectedByKey.Keys) {
        $resourceIdentitiesPassed = $resourceIdentitiesPassed -and
            (ConvertTo-WorkshopComparableValue $actual[$key].Id) -ceq
                (ConvertTo-WorkshopComparableValue $expectedByKey[$key].Id)
    }
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'Exact network resource identities' `
        -Passed $resourceIdentitiesPassed `
        -Detail 'Every network and private DNS object must have its approved full subscription-qualified resource ID.'

    try {
        $publicIpInventory = @(& $Operations.GetPublicIpInventory $Config.ResourceGroupName)
        $expectedPublicIps = @(
            $expectedByKey['PublicIpAddress/pip-mcpsql-admin'],
            $expectedByKey['PublicIpAddress/pip-mcpsql-nat']
        )
        $actualPublicIps = @($publicIpInventory | Sort-Object Id)
        $expectedPublicIps = @($expectedPublicIps | Sort-Object Id)
        $publicIpInventoryPassed = $actualPublicIps.Count -eq 2 -and
            (Test-WorkshopNetworkResourceMatch -Expected $expectedPublicIps[0] -Actual $actualPublicIps[0]) -and
            (Test-WorkshopNetworkResourceMatch -Expected $expectedPublicIps[1] -Actual $actualPublicIps[1])
    }
    catch {
        $publicIpInventory = @()
        $publicIpInventoryPassed = $false
    }
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'Standard static public IP inventory' `
        -Passed $publicIpInventoryPassed `
        -Detail 'The target resource group must contain exactly the full-ID-matched Standard Static IPv4 administration and NAT public IP resources.'
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'NAT Gateway identity and SKU' `
        -Passed ((ConvertTo-WorkshopComparableValue $nat.Id) -ceq
            (ConvertTo-WorkshopComparableValue $expectedByKey['NatGateway/nat-mcpsql-workshop'].Id) -and
            $nat.Sku -ceq 'Standard') `
        -Detail 'NAT Gateway must have the exact subscription-qualified identity and Standard SKU.'
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'NAT public IP association' `
        -Passed (@($nat.PublicIpAddressIds).Count -eq 1 -and
            (ConvertTo-WorkshopComparableValue $nat.PublicIpAddressIds[0]) -eq (ConvertTo-WorkshopComparableValue $natPip.Id)) `
        -Detail 'NAT Gateway must use exactly the approved NAT-egress public IP.'

    $adminPublicIds = @(
        if ($adminNic.PSObject.Properties.Name -contains 'PublicIpAddressIds') {
            @($adminNic.PublicIpAddressIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
        }
        else {
            @($adminNic.PublicIpAddressId | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
        }
    )
    $sqlPublicIds = @(
        if ($sqlNic.PSObject.Properties.Name -contains 'PublicIpAddressIds') {
            @($sqlNic.PublicIpAddressIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
        }
        else {
            @($sqlNic.PublicIpAddressId | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
        }
    )
    $adminPublicPassed = $adminNic.IpConfigurationCount -eq 1 -and $adminPublicIds.Count -eq 1 -and
        (ConvertTo-WorkshopComparableValue $adminPublicIds[0]) -eq (ConvertTo-WorkshopComparableValue $adminPip.Id) -and
        (ConvertTo-WorkshopComparableValue $adminNic.PublicIpAddressId) -eq (ConvertTo-WorkshopComparableValue $adminPip.Id)
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'Administration NIC public IP' -Passed $adminPublicPassed `
        -Detail 'Administration NIC must have exactly the administration public IP.'
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'SQL NIC has no public IP' `
        -Passed ($sqlNic.IpConfigurationCount -eq 1 -and $sqlPublicIds.Count -eq 0 -and
            [string]::IsNullOrWhiteSpace([string] $sqlNic.PublicIpAddressId)) `
        -Detail 'SQL NIC public IP association must be empty.'
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'NIC NSGs are absent' `
        -Passed ([string]::IsNullOrWhiteSpace([string] $adminNic.NetworkSecurityGroupId) -and
            [string]::IsNullOrWhiteSpace([string] $sqlNic.NetworkSecurityGroupId)) `
        -Detail 'NSGs must be associated only at subnet level.'
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'NIC ASG membership' `
        -Passed (@($adminNic.ApplicationSecurityGroupIds).Count -eq 1 -and
            @($sqlNic.ApplicationSecurityGroupIds).Count -eq 1 -and
            (ConvertTo-WorkshopComparableValue $adminNic.ApplicationSecurityGroupIds[0]) -eq (ConvertTo-WorkshopComparableValue $adminAsgId) -and
            (ConvertTo-WorkshopComparableValue $sqlNic.ApplicationSecurityGroupIds[0]) -eq (ConvertTo-WorkshopComparableValue $sqlAsgId)) `
        -Detail 'Each NIC must belong only to its approved application security group.'
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'SQL static private IP' `
        -Passed ($sqlNic.PrivateIpAllocationMethod -eq 'Static' -and $sqlNic.PrivateIpAddress -eq $Config.SqlPrivateIp) `
        -Detail "SQL NIC must use static private IP '$($Config.SqlPrivateIp)'."
    $expectedAdminSubnetId = ($expectedSpecs | Where-Object { $_.Kind -eq 'NetworkInterface' -and $_.Name -eq 'nic-mcpsql-admin' }).SubnetId
    $expectedSqlSubnetId = ($expectedSpecs | Where-Object { $_.Kind -eq 'NetworkInterface' -and $_.Name -eq 'nic-mcpsql-sql' }).SubnetId
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'NIC subnet and allocation boundaries' `
        -Passed ($adminNic.PrivateIpAllocationMethod -eq 'Dynamic' -and
            (ConvertTo-WorkshopComparableValue $adminNic.SubnetId) -eq (ConvertTo-WorkshopComparableValue $expectedAdminSubnetId) -and
            (ConvertTo-WorkshopComparableValue $sqlNic.SubnetId) -eq (ConvertTo-WorkshopComparableValue $expectedSqlSubnetId)) `
        -Detail 'Administration and SQL NICs must use their approved subnets and allocation modes.'

    $adminRdp = @($adminNsg.Rules | Where-Object Name -EQ 'Allow-Facilitator-Rdp')
    $adminRdpPassed = $adminRdp.Count -eq 1 -and $adminRdp[0].Priority -eq 100 -and
        $adminRdp[0].Protocol -eq 'Tcp' -and $adminRdp[0].SourceAddressPrefix -ceq $FacilitatorCidr -and
        $adminRdp[0].SourcePortRange -eq '*' -and $adminRdp[0].DestinationPortRange -eq '3389' -and
        $adminRdp[0].Access -eq 'Allow' -and
        (ConvertTo-WorkshopComparableValue $adminRdp[0].DestinationApplicationSecurityGroupId) -eq
            (ConvertTo-WorkshopComparableValue $adminAsgId)
    $adminRdpAllows = @($adminNsg.Rules | Where-Object {
        $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' -and
        (Test-WorkshopRuleProtocol -Rule $_ -Protocol 'Tcp') -and
        (Test-WorkshopRuleCoversPort -Rule $_ -Port 3389)
    })
    $adminRdpPassed = $adminRdpPassed -and $adminRdpAllows.Count -eq 1 -and
        $adminRdpAllows[0].Name -eq 'Allow-Facilitator-Rdp'
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'Facilitator RDP rule' -Passed $adminRdpPassed `
        -Detail 'Administration RDP must be TCP 3389 from the exact validated facilitator /32 to the admin ASG.'

    $sqlRulesPassed = $true
    foreach ($ruleExpectation in @(
        @{ Name = 'Allow-Admin-To-Sql'; Priority = 100; Port = '1433' },
        @{ Name = 'Allow-Admin-To-Sql-Rdp'; Priority = 110; Port = '3389' }
    )) {
        $rule = @($sqlNsg.Rules | Where-Object Name -EQ $ruleExpectation.Name)
        $sourcePrefixes = @()
        $destinationPrefixes = @()
        if ($rule.Count -eq 1) {
            $sourcePrefixes = @(Get-WorkshopRulePropertyValue -Rule $rule[0] `
                -SingularName 'SourceAddressPrefix' -PluralName 'SourceAddressPrefixes')
            $destinationPrefixes = @(Get-WorkshopRulePropertyValue -Rule $rule[0] `
                -SingularName 'DestinationAddressPrefix' -PluralName 'DestinationAddressPrefixes')
        }
        $sqlRulesPassed = $sqlRulesPassed -and $rule.Count -eq 1 -and
            $rule[0].Priority -eq $ruleExpectation.Priority -and $rule[0].Direction -eq 'Inbound' -and
            $rule[0].Protocol -eq 'Tcp' -and $rule[0].SourcePortRange -eq '*' -and
            $rule[0].DestinationPortRange -eq $ruleExpectation.Port -and $rule[0].Access -eq 'Allow' -and
            $sourcePrefixes.Count -eq 0 -and $destinationPrefixes.Count -eq 0 -and
            (ConvertTo-WorkshopComparableValue $rule[0].SourceApplicationSecurityGroupId) -eq
                (ConvertTo-WorkshopComparableValue $adminAsgId) -and
            (ConvertTo-WorkshopComparableValue $rule[0].DestinationApplicationSecurityGroupId) -eq
                (ConvertTo-WorkshopComparableValue $sqlAsgId)
    }
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'SQL ASG allow rules' -Passed $sqlRulesPassed `
        -Detail 'SQL TCP 1433 and private RDP must originate at the admin ASG and target the SQL ASG.'

    $deny = @($sqlNsg.Rules | Where-Object Name -EQ 'Deny-Other-VNet-To-Sql')
    $denySourceAsgs = @()
    $denyDestinationPrefixes = @()
    if ($deny.Count -eq 1) {
        $denySourceAsgs = @(Get-WorkshopRulePropertyValue -Rule $deny[0] `
            -SingularName 'SourceApplicationSecurityGroupId' -PluralName 'SourceApplicationSecurityGroupIds')
        $denyDestinationPrefixes = @(Get-WorkshopRulePropertyValue -Rule $deny[0] `
            -SingularName 'DestinationAddressPrefix' -PluralName 'DestinationAddressPrefixes')
    }
    $denyPassed = $deny.Count -eq 1 -and $deny[0].Priority -eq 4000 -and
        $deny[0].Direction -eq 'Inbound' -and $deny[0].Protocol -eq '*' -and $deny[0].SourcePortRange -eq '*' -and
        $deny[0].SourceAddressPrefix -eq 'VirtualNetwork' -and $deny[0].DestinationPortRange -eq '*' -and
        $deny[0].Access -eq 'Deny' -and $denySourceAsgs.Count -eq 0 -and $denyDestinationPrefixes.Count -eq 0 -and
        (ConvertTo-WorkshopComparableValue $deny[0].DestinationApplicationSecurityGroupId) -eq
            (ConvertTo-WorkshopComparableValue $sqlAsgId)
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'SQL VNet deny rule' -Passed $denyPassed `
        -Detail 'Other VNet traffic must be denied to the SQL ASG at priority 4000.'

    Add-WorkshopBoundaryCheck -Checks $checks -Name 'Exact administration custom NSG rules' `
        -Passed (Test-WorkshopExactCustomRuleSet `
            -ExpectedRules @($expectedByKey['NetworkSecurityGroup/nsg-mcpsql-admin'].Rules) `
            -ActualRules @($adminNsg.Rules)) `
        -Detail 'Administration NSG custom rules must be exactly the approved canonical set; Azure-managed defaults are ignored.'
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'Exact SQL custom NSG rules' `
        -Passed (Test-WorkshopExactCustomRuleSet `
            -ExpectedRules @($expectedByKey['NetworkSecurityGroup/nsg-mcpsql-sql'].Rules) `
            -ActualRules @($sqlNsg.Rules)) `
        -Detail 'SQL NSG custom rules must be exactly the approved canonical set; every extra allow or deny rule is drift.'

    $publicSqlRule = @($sqlNsg.Rules + $adminNsg.Rules | Where-Object {
        $sourceAsgs = @(Get-WorkshopRulePropertyValue -Rule $_ `
            -SingularName 'SourceApplicationSecurityGroupId' -PluralName 'SourceApplicationSecurityGroupIds')
        $sourcePrefixes = @(Get-WorkshopRulePropertyValue -Rule $_ `
            -SingularName 'SourceAddressPrefix' -PluralName 'SourceAddressPrefixes')
        $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' -and $sourceAsgs.Count -eq 0 -and
        @($sourcePrefixes | Where-Object { $_ -ne 'VirtualNetwork' }).Count -gt 0 -and
        (((Test-WorkshopRuleProtocol -Rule $_ -Protocol 'Tcp') -and
            (Test-WorkshopRuleCoversPort -Rule $_ -Port 1433)) -or
            ((Test-WorkshopRuleProtocol -Rule $_ -Protocol 'Udp') -and
            (Test-WorkshopRuleCoversPort -Rule $_ -Port 1434)))
    })
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'No public SQL or Browser rule' -Passed ($publicSqlRule.Count -eq 0) `
        -Detail 'No custom rule may permit public TCP 1433 or UDP 1434.'

    $subnetsPassed = @($vnet.Subnets).Count -eq 2
    foreach ($expectedSubnet in @(
        @{ Name = $Config.AdminSubnet.Name; Prefix = $Config.AdminSubnet.Prefix; Nsg = $expectedByKey['NetworkSecurityGroup/nsg-mcpsql-admin'].Id },
        @{ Name = $Config.SqlSubnet.Name; Prefix = $Config.SqlSubnet.Prefix; Nsg = $expectedByKey['NetworkSecurityGroup/nsg-mcpsql-sql'].Id }
    )) {
        $subnet = @($vnet.Subnets | Where-Object Name -EQ $expectedSubnet.Name)
        $outboundVerified = $subnet.Count -eq 1 -and
            $subnet[0].PSObject.Properties.Name -contains 'DefaultOutboundAccess' -and
            $subnet[0].DefaultOutboundAccess -is [bool] -and -not $subnet[0].DefaultOutboundAccess
        $subnetsPassed = $subnetsPassed -and $subnet.Count -eq 1 -and $outboundVerified -and
            $subnet[0].AddressPrefix -eq $expectedSubnet.Prefix -and
            $subnet[0].PrivateEndpointNetworkPolicies -eq 'Disabled' -and
            (ConvertTo-WorkshopComparableValue $subnet[0].NatGatewayId) -ceq
                (ConvertTo-WorkshopComparableValue $expectedByKey['NatGateway/nat-mcpsql-workshop'].Id) -and
            (ConvertTo-WorkshopComparableValue $subnet[0].NetworkSecurityGroupId) -ceq
                (ConvertTo-WorkshopComparableValue $expectedSubnet.Nsg)
    }
    Add-WorkshopBoundaryCheck -Checks $checks -Name 'Private subnet NAT and NSG associations' -Passed $subnetsPassed `
        -Detail 'Both private subnets require default outbound disabled plus the approved NAT Gateway and subnet NSG.'

    foreach ($dnsKey in @(
        "PrivateDnsZone/$($Config.PrivateDnsZone)",
        "PrivateDnsVirtualNetworkLink/$($Config.PrivateDnsZone)/$($Config.VNet.Name)-link",
        "PrivateDnsARecord/$($Config.PrivateDnsZone)/sql01"
    )) {
        Add-WorkshopBoundaryCheck -Checks $checks -Name "Exact $dnsKey" `
            -Passed (Test-WorkshopNetworkResourceMatch -Expected $expectedByKey[$dnsKey] -Actual $actual[$dnsKey]) `
            -Detail 'Private DNS resource identity and values must exactly match the approved private-only SQL name.'
    }

    [pscustomobject][ordered]@{
        Passed = @($checks | Where-Object Status -EQ 'Failed').Count -eq 0
        Checks = $checks.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Assert-WorkshopHostCidr'
    'New-WorkshopNetworkModel'
    'New-WorkshopNetwork'
    'Get-WorkshopPlan'
    'Test-WorkshopPrerequisites'
    'Test-WorkshopNetworkBoundary'
    'Format-WorkshopPlanCard'
)
