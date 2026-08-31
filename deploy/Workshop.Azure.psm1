Set-StrictMode -Version Latest

$script:RequiredAzModules = [ordered]@{
    'Az.Accounts' = [version]'4.0.0'
    'Az.Resources' = [version]'7.0.0'
    'Az.Compute' = [version]'10.0.0'
    'Az.Network' = [version]'7.0.0'
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
                    Name = 'Allow-Admin-Rdp-To-Sql'
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
                    Priority = 120
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

Export-ModuleMember -Function @(
    'Assert-WorkshopHostCidr'
    'New-WorkshopNetworkModel'
    'Get-WorkshopPlan'
    'Test-WorkshopPrerequisites'
    'Format-WorkshopPlanCard'
)
