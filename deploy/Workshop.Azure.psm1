Set-StrictMode -Version Latest

$script:RequiredAzModules = [ordered]@{
    'Az.Accounts' = [version]'4.0.0'
    'Az.Resources' = [version]'7.0.0'
    'Az.Compute' = [version]'10.0.0'
    'Az.Network' = [version]'8.0.0'
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
        'SqlVm', 'AutoShutdownTime', 'AutoShutdownLocation', 'Tags'
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
        @{ Label = 'AutoShutdownLocation'; Value = $Config.AutoShutdownLocation }
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
            # Exempts the workshop VMs from the subscription cost-control shutdown policy
            # so a timed lab run is not interrupted mid-measurement.
            costconstraint = [string] $Config.Tags.costconstraint
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
        $lines.Add("Tags: environment=$($Plan.Tags.environment); workload=$($Plan.Tags.workload); managedBy=$($Plan.Tags.managedBy); costconstraint=$($Plan.Tags.costconstraint); expiresOn=$($Plan.Tags.expiresOn)")
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
    $exceptionCandidates = [System.Collections.Generic.List[object]]::new()
    $candidate = $exception
    while ($null -ne $candidate -and $exceptionCandidates.Count -lt 8) {
        $exceptionCandidates.Add($candidate)
        $candidate = if ($candidate.PSObject.Properties.Name -contains 'InnerException') {
            $candidate.InnerException
        }
        else {
            $null
        }
    }
    foreach ($exceptionCandidate in $exceptionCandidates) {
        foreach ($propertyName in @('Code', 'ErrorCode')) {
            if ($exceptionCandidate.PSObject.Properties.Name -contains $propertyName) {
                $codes.Add([string] $exceptionCandidate.$propertyName)
            }
        }
        foreach ($containerName in @('Error', 'Body')) {
            if ($exceptionCandidate.PSObject.Properties.Name -contains $containerName -and
                $null -ne $exceptionCandidate.$containerName -and
                $exceptionCandidate.$containerName.PSObject.Properties.Name -contains 'Code') {
                $codes.Add([string] $exceptionCandidate.$containerName.Code)
            }
        }
    }
    foreach ($code in $codes) {
        if ($code -match '(^|,|\.)Resource(Group)?NotFound($|,|\.)') {
            return $true
        }
    }
    if ($ErrorRecord.FullyQualifiedErrorId -ceq
            'Microsoft.Azure.Commands.ResourceManager.Cmdlets.Implementation.GetAzureResourceGroupCmdlet' -and
        $null -ne $exception -and
        $exception.Message -match '^\d{2}:\d{2}:\d{2} - Provided resource group does not exist\.$') {
        return $true
    }
    foreach ($exceptionCandidate in $exceptionCandidates) {
        $response = if ($exceptionCandidate.PSObject.Properties.Name -contains 'Response') {
            $exceptionCandidate.Response
        }
        else {
            $null
        }
        foreach ($responseCandidate in @($exceptionCandidate, $response)) {
            if ($null -ne $responseCandidate -and
                $responseCandidate.PSObject.Properties.Name -contains 'StatusCode' -and
                [string] $responseCandidate.StatusCode -in @('404', 'NotFound')) {
                return $true
            }
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
    Add-WorkshopCheck -Checks $checks -Name 'PowerShell version' -Passed ($powerShellVersion -ge [version]'7.4') `
        -Detail "Detected PowerShell $powerShellVersion; version 7.4 or later is required." `
        -Remediation 'Run the preflight with PowerShell 7.4 or later.'

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
        $capabilities = if ($null -ne $sku -and $sku.PSObject.Properties.Name -contains 'Capabilities') {
            @($sku.Capabilities)
        }
        else {
            @()
        }
        $trustedLaunchDisabled = $capabilities | Where-Object Name -EQ 'TrustedLaunchDisabled' |
            Select-Object -First 1
        $hyperVGenerations = $capabilities | Where-Object Name -EQ 'HyperVGenerations' |
            Select-Object -First 1
        $trustedLaunchAllowed = $null -eq $trustedLaunchDisabled -or
            -not [string]::Equals([string] $trustedLaunchDisabled.Value, 'true', [System.StringComparison]::OrdinalIgnoreCase)
        $generationV2Allowed = $null -eq $hyperVGenerations -or
            @(([string] $hyperVGenerations.Value) -split ',' | ForEach-Object { $_.Trim() }) -contains 'V2'
        $skuPassed = $skuResult.Succeeded -and $null -ne $sku -and $restrictions.Count -eq 0 -and
            $trustedLaunchAllowed -and $generationV2Allowed
        $restrictionDetail = if ($restrictions.Count -eq 0) { 'none' } else { ($restrictions.ReasonCode -join ', ') }
        $trustedLaunchDetail = if ($null -eq $trustedLaunchDisabled) { 'not returned' } else { [string] $trustedLaunchDisabled.Value }
        $generationDetail = if ($null -eq $hyperVGenerations) { 'not returned' } else { [string] $hyperVGenerations.Value }
        Add-WorkshopCheck -Checks $checks -Name "VM SKU $($vm.Size)" -Passed $skuPassed `
            -Detail "Exact SKU in $($Config.Location); restrictions: $restrictionDetail; TrustedLaunchDisabled: $trustedLaunchDetail; HyperVGenerations: $generationDetail. Availability is not claimed until this check passes." `
            -Remediation "Confirm $($vm.Size) supports Trusted Launch and Hyper-V generation V2 without subscription restrictions."
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
            $versionText = if ($null -ne $image -and $image.PSObject.Properties.Name -contains 'Version') {
                [string] $image.Version
            }
            else {
                ''
            }
            if ($versionText -match '^\d+(\.\d+){2,3}$' -and
                [version]::TryParse($versionText, [ref] $parsedVersion)) {
                [pscustomobject]@{ Image = $image; ParsedVersion = $parsedVersion }
            }
        }
        $latestRecord = $versions | Sort-Object ParsedVersion -Descending | Select-Object -First 1
        $latest = if ($null -eq $latestRecord) { $null } else { $latestRecord.Image }
        $hyperVGeneration = if ($null -ne $latest -and
            $latest.PSObject.Properties.Name -contains 'HyperVGeneration') {
            [string] $latest.HyperVGeneration
        }
        else {
            ''
        }
        $generationV2 = [string]::IsNullOrWhiteSpace($hyperVGeneration) -or
            @($hyperVGeneration -split ',' | ForEach-Object { $_.Trim() }) -contains 'V2'
        $imagePassed = $imageResult.Succeeded -and $null -ne $latest -and $generationV2
        if ($imagePassed) {
            $resolvedImages[$role] = [pscustomobject][ordered]@{
                Publisher = [string] $vm.Publisher
                Offer = [string] $vm.Offer
                Sku = [string] $vm.Sku
                Version = [string] $latest.Version
            }
        }
        $resolvedVersion = if ($null -eq $latest) { 'not resolved' } else { [string] $latest.Version }
        $generationDetail = if ([string]::IsNullOrWhiteSpace($hyperVGeneration)) { 'not returned' } else { $hyperVGeneration }
        Add-WorkshopCheck -Checks $checks -Name "$role VM image" -Passed $imagePassed `
            -Detail "Exact image $($vm.Publisher):$($vm.Offer):$($vm.Sku); immutable version: $resolvedVersion; HyperVGeneration: $generationDetail." `
            -Remediation 'Confirm the exact Marketplace image is visible in Indonesia Central and supports Hyper-V generation V2.'
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

    $autoShutdownCapability = Get-WorkshopAutoShutdownCapability -Config $Config
    $autoShutdownDetail = if ($autoShutdownCapability.ScheduleSupported) {
        "DevTestLab scheduling is supported because schedule and VM location are both '$($autoShutdownCapability.VmLocation)'."
    }
    elseif ($autoShutdownCapability.FallbackDocumented) {
        "DevTestLab cross-region scheduling from '$($autoShutdownCapability.ScheduleLocation)' to '$($autoShutdownCapability.VmLocation)' is unsupported; the documented local emergency stop is required. It runs as the current interactive user at $($Config.AutoShutdownTime) in this workstation's local time zone, so leave this workstation signed in with a valid Azure sign-in until then."
    }
    else {
        "DevTestLab schedule location '$($autoShutdownCapability.ScheduleLocation)' does not match VM location '$($autoShutdownCapability.VmLocation)' and has no approved fallback."
    }
    Add-WorkshopCheck -Checks $checks -Name 'DevTestLab auto-shutdown capability' `
        -Passed ($autoShutdownCapability.ScheduleSupported -or $autoShutdownCapability.FallbackDocumented) `
        -Detail $autoShutdownDetail `
        -Remediation "Set AutoShutdownLocation to '$($autoShutdownCapability.VmLocation)' in deploy/WorkshopConfig.psd1, or run deploy/Stop-WorkshopEnvironment.ps1 manually at the end of the workshop."

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
        AutoShutdownCapability = $autoShutdownCapability
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

    $expectedHasKind = $Expected.PSObject.Properties.Name -contains 'Kind'
    $actualHasKind = $Actual.PSObject.Properties.Name -contains 'Kind'
    if ($expectedHasKind -and $actualHasKind -and
        $Expected.Kind -eq 'NetworkSecurityGroup' -and $Actual.Kind -eq 'NetworkSecurityGroup') {
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

    if ($null -eq $Reference) { return $null }
    if ($Reference -is [string]) { return [string] $Reference }
    if ($Reference.PSObject.Properties.Name -contains 'Id' -and $null -ne $Reference.Id) {
        return [string] $Reference.Id
    }
    return $null
}

function Get-WorkshopOptionalCollectionProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $PropertyName
    )

    if ($InputObject.PSObject.Properties.Name -notcontains $PropertyName) {
        return @()
    }
    return @($InputObject.$PropertyName | Where-Object { $null -ne $_ })
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
    $location = if ($Resource.PSObject.Properties.Name -contains 'Location') {
        [string] $Resource.Location
    }
    elseif ($Kind -like 'PrivateDns*') {
        'global'
    }
    else {
        ''
    }
    $tags = if ($Resource.PSObject.Properties.Name -contains 'Tags' -and $null -ne $Resource.Tags) {
        $Resource.Tags
    }
    elseif ($Resource.PSObject.Properties.Name -contains 'Tag' -and $null -ne $Resource.Tag) {
        $Resource.Tag
    }
    elseif ($Resource.PSObject.Properties.Name -contains 'TagsTable' -and $null -ne $Resource.TagsTable) {
        $Resource.TagsTable
    }
    else {
        [ordered]@{}
    }
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
                $sourceApplicationSecurityGroups = @(
                    Get-WorkshopOptionalCollectionProperty -InputObject $_ `
                        -PropertyName 'SourceApplicationSecurityGroups'
                )
                $destinationApplicationSecurityGroups = @(
                    Get-WorkshopOptionalCollectionProperty -InputObject $_ `
                        -PropertyName 'DestinationApplicationSecurityGroups'
                )
                [pscustomobject][ordered]@{
                    Name = [string] $_.Name; Priority = [int] $_.Priority; Direction = [string] $_.Direction
                    Access = [string] $_.Access; Protocol = [string] $_.Protocol
                    SourcePortRange = [string] $_.SourcePortRange; SourceAddressPrefix = [string] $_.SourceAddressPrefix
                    SourceApplicationSecurityGroupId = Get-WorkshopReferenceId -Reference `
                        ($sourceApplicationSecurityGroups | Select-Object -First 1)
                    SourcePortRanges = @(Get-WorkshopOptionalCollectionProperty -InputObject $_ -PropertyName 'SourcePortRanges')
                    SourceAddressPrefixes = @(Get-WorkshopOptionalCollectionProperty -InputObject $_ -PropertyName 'SourceAddressPrefixes')
                    SourceApplicationSecurityGroupIds = @($sourceApplicationSecurityGroups | ForEach-Object { Get-WorkshopReferenceId -Reference $_ })
                    DestinationPortRange = [string] $_.DestinationPortRange; DestinationAddressPrefix = [string] $_.DestinationAddressPrefix
                    DestinationApplicationSecurityGroupId = Get-WorkshopReferenceId -Reference `
                        ($destinationApplicationSecurityGroups | Select-Object -First 1)
                    DestinationPortRanges = @(Get-WorkshopOptionalCollectionProperty -InputObject $_ -PropertyName 'DestinationPortRanges')
                    DestinationAddressPrefixes = @(Get-WorkshopOptionalCollectionProperty -InputObject $_ -PropertyName 'DestinationAddressPrefixes')
                    DestinationApplicationSecurityGroupIds = @($destinationApplicationSecurityGroups | ForEach-Object { Get-WorkshopReferenceId -Reference $_ })
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
        SupportsDefaultOutboundAccess = {
            $command = Get-Command -Name New-AzVirtualNetworkSubnetConfig -ErrorAction Stop
            $command.Parameters.ContainsKey('DefaultOutboundAccess')
        }
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
    if (-not $ReadOnly) { $required += @('SupportsDefaultOutboundAccess', 'CreateResource') }
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
    if (-not (& $Operations.SupportsDefaultOutboundAccess)) {
        throw "New-AzVirtualNetworkSubnetConfig does not support DefaultOutboundAccess. Install Az.Network 8.0.0 or later before deployment."
    }
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
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ExpectedRules,
        # An existing group can legitimately hold zero custom rules, for example after a
        # governance policy removed one. That must compare as a mismatch, not fail binding.
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ActualRules
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

function Get-WorkshopComputeResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $ResourceType,
        [Parameter(Mandatory)][string] $Name
    )

    "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/$ResourceType/$Name"
}

function Resolve-WorkshopImageVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Publisher,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Offer,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Sku,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Location,
        [hashtable] $Operations
    )

    if ($null -eq $Operations) {
        $Operations = @{
            GetImages = {
                param($ImagePublisher, $ImageOffer, $ImageSku, $ImageLocation)
                Get-AzVMImage -PublisherName $ImagePublisher -Offer $ImageOffer -Skus $ImageSku `
                    -Location $ImageLocation -ErrorAction Stop
            }
        }
    }
    if (-not $Operations.ContainsKey('GetImages') -or $Operations.GetImages -isnot [scriptblock]) {
        throw "Operations must provide scriptblock 'GetImages'."
    }

    $validVersions = @(& $Operations.GetImages $Publisher $Offer $Sku $Location | ForEach-Object {
        $parsed = $null
        $versionText = if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Version') {
            [string] $_.Version
        }
        else {
            ''
        }
        if ($versionText -match '^\d+(\.\d+){2,3}$' -and
            [version]::TryParse($versionText, [ref] $parsed)) {
            [pscustomobject]@{ Text = $versionText; Parsed = $parsed }
        }
    })
    $selected = $validVersions | Sort-Object Parsed -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        throw "The exact image $Publisher`:$Offer`:$Sku in '$Location' returned no valid immutable image version."
    }
    [pscustomobject][ordered]@{
        Publisher = $Publisher
        Offer = $Offer
        Sku = $Sku
        Version = $selected.Text
        Location = $Location
    }
}

function Get-WorkshopVmSpecification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Admin', 'Sql')][string] $Role,
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $ImageVersion,
        [Parameter(Mandatory)][string] $SubscriptionId
    )

    if ($ImageVersion -notmatch '^\d+(\.\d+){2,3}$' -or $ImageVersion -eq 'latest') {
        throw "VM image version '$ImageVersion' is not immutable."
    }
    $vmConfig = if ($Role -eq 'Admin') { $Config.AdminVm } else { $Config.SqlVm }
    $resourceGroupName = [string] $Config.ResourceGroupName
    $vmId = Get-WorkshopComputeResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $resourceGroupName `
        -ResourceType 'virtualMachines' -Name $vmConfig.Name
    $nicName = if ($Role -eq 'Admin') { 'nic-mcpsql-admin' } else { 'nic-mcpsql-sql' }
    $nicId = Get-WorkshopNetworkResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $resourceGroupName `
        -ResourceType 'networkInterfaces' -Name $nicName
    $osDiskName = if ($Role -eq 'Admin') { 'osdisk-mcpsql-admin' } else { 'osdisk-mcpsql-sql' }
    $tags = [ordered]@{}
    foreach ($key in @($Config.Tags.Keys | Sort-Object)) { $tags[$key] = [string] $Config.Tags[$key] }
    $dataDisks = @()
    if ($Role -eq 'Sql') {
        $dataDisks = @(
            [pscustomobject][ordered]@{
                Name = 'disk-mcpsql-sql-data'; Id = (Get-WorkshopComputeResourceId -SubscriptionId $SubscriptionId `
                    -ResourceGroupName $resourceGroupName -ResourceType 'disks' -Name 'disk-mcpsql-sql-data')
                SizeGiB = [int] $Config.SqlVm.DataDiskGiB; Sku = 'Premium_LRS'; Lun = 0; Caching = 'ReadOnly'
            }
            [pscustomobject][ordered]@{
                Name = 'disk-mcpsql-sql-log'; Id = (Get-WorkshopComputeResourceId -SubscriptionId $SubscriptionId `
                    -ResourceGroupName $resourceGroupName -ResourceType 'disks' -Name 'disk-mcpsql-sql-log')
                SizeGiB = [int] $Config.SqlVm.LogDiskGiB; Sku = 'Premium_LRS'; Lun = 1; Caching = 'None'
            }
        )
    }
    [pscustomobject][ordered]@{
        Name = [string] $vmConfig.Name
        Id = $vmId
        Location = [string] $Config.Location
        VmSize = [string] $vmConfig.Size
        OsType = 'Windows'
        LicenseType = if ($Role -eq 'Admin') { 'Windows_Client' } else { $null }
        SecurityType = 'TrustedLaunch'
        SecureBoot = $true
        VTpm = $true
        Image = [pscustomobject][ordered]@{
            Publisher = [string] $vmConfig.Publisher
            Offer = [string] $vmConfig.Offer
            Sku = [string] $vmConfig.Sku
            Version = $ImageVersion
        }
        OsDisk = [pscustomobject][ordered]@{
            Name = $osDiskName
            SizeGiB = [int] $vmConfig.OsDiskGiB
            Sku = 'Premium_LRS'
            Caching = 'ReadWrite'
        }
        NetworkInterfaceIds = @($nicId)
        DataDisks = $dataDisks
        Tags = $tags
    }
}

function Get-WorkshopDiskSpecification {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject] $VmSpecification)

    @($VmSpecification.DataDisks | ForEach-Object {
        [pscustomobject][ordered]@{
            Name = $_.Name; Id = $_.Id; Location = $VmSpecification.Location
            SizeGiB = $_.SizeGiB; Sku = $_.Sku; Lun = $_.Lun; Caching = $_.Caching
            Tags = $VmSpecification.Tags
        }
    })
}

function ConvertFrom-WorkshopAzVm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject] $Vm)

    [pscustomobject][ordered]@{
        Name = [string] $Vm.Name
        Id = [string] $Vm.Id
        Location = [string] $Vm.Location
        VmSize = [string] $Vm.HardwareProfile.VmSize
        OsType = [string] $Vm.StorageProfile.OsDisk.OsType
        LicenseType = if ([string]::IsNullOrWhiteSpace([string] $Vm.LicenseType)) { $null } else { [string] $Vm.LicenseType }
        SecurityType = if ($null -eq $Vm.SecurityProfile) { $null } else { [string] $Vm.SecurityProfile.SecurityType }
        SecureBoot = $null -ne $Vm.SecurityProfile -and [bool] $Vm.SecurityProfile.UefiSettings.SecureBootEnabled
        VTpm = $null -ne $Vm.SecurityProfile -and [bool] $Vm.SecurityProfile.UefiSettings.VTpmEnabled
        Image = [pscustomobject][ordered]@{
            Publisher = [string] $Vm.StorageProfile.ImageReference.Publisher
            Offer = [string] $Vm.StorageProfile.ImageReference.Offer
            Sku = [string] $Vm.StorageProfile.ImageReference.Sku
            Version = [string] $Vm.StorageProfile.ImageReference.Version
        }
        OsDisk = [pscustomobject][ordered]@{
            Name = [string] $Vm.StorageProfile.OsDisk.Name
            SizeGiB = [int] $Vm.StorageProfile.OsDisk.DiskSizeGB
            Sku = [string] $Vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
            Caching = [string] $Vm.StorageProfile.OsDisk.Caching
        }
        NetworkInterfaceIds = @($Vm.NetworkProfile.NetworkInterfaces | ForEach-Object { [string] $_.Id })
        DataDisks = @($Vm.StorageProfile.DataDisks | Sort-Object Lun | ForEach-Object {
            [pscustomobject][ordered]@{
                Name = [string] $_.Name; Id = [string] $_.ManagedDisk.Id; SizeGiB = [int] $_.DiskSizeGB
                Sku = [string] $_.ManagedDisk.StorageAccountType; Lun = [int] $_.Lun; Caching = [string] $_.Caching
            }
        })
        Tags = if ($null -eq $Vm.Tags) { [ordered]@{} } else { $Vm.Tags }
    }
}

function ConvertFrom-WorkshopAzDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $Disk,
        [Parameter(Mandatory)][psobject] $Expected
    )

    [pscustomobject][ordered]@{
        Name = [string] $Disk.Name; Id = [string] $Disk.Id; Location = [string] $Disk.Location
        SizeGiB = [int] $Disk.DiskSizeGB; Sku = [string] $Disk.Sku.Name
        Lun = [int] $Expected.Lun; Caching = [string] $Expected.Caching
        Tags = if ($null -eq $Disk.Tags) { [ordered]@{} } else { $Disk.Tags }
    }
}

function Get-DefaultWorkshopVmOperationSet {
    [CmdletBinding()]
    param()

    @{
        GetSubscriptionId = {
            $context = Get-AzContext -ErrorAction Stop
            $id = Get-WorkshopNestedIdentifier -InputObject $context -PropertyName 'Subscription'
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'The active Azure context did not return a subscription ID.' }
            $id
        }
        GetVm = {
            param($Name, $ResourceGroupName)
            try {
                ConvertFrom-WorkshopAzVm -Vm (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop)
            }
            catch {
                if (Test-WorkshopAzureNotFound -ErrorRecord $_) { return $null }
                throw
            }
        }
        GetDisk = {
            param($Name, $ResourceGroupName, $Expected)
            try {
                $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $Name -ErrorAction Stop
                ConvertFrom-WorkshopAzDisk -Disk $disk -Expected $Expected
            }
            catch {
                if (Test-WorkshopAzureNotFound -ErrorRecord $_) { return $null }
                throw
            }
        }
        CreateDisk = {
            param($Spec, $ResourceGroupName)
            $diskConfig = New-AzDiskConfig -Location $Spec.Location -SkuName $Spec.Sku `
                -DiskSizeGB $Spec.SizeGiB -CreateOption Empty -Tag $Spec.Tags -ErrorAction Stop
            New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $Spec.Name `
                -Disk $diskConfig -ErrorAction Stop
        }
        CreateVm = {
            param($Spec, [PSCredential] $Credential, $ResourceGroupName)
            $vmConfigParameters = @{
                VMName = $Spec.Name; VMSize = $Spec.VmSize; Tags = $Spec.Tags; ErrorAction = 'Stop'
            }
            if (-not [string]::IsNullOrWhiteSpace([string] $Spec.LicenseType)) {
                $vmConfigParameters.LicenseType = $Spec.LicenseType
            }
            $vm = New-AzVMConfig @vmConfigParameters
            $osParameters = @{
                VM = $vm; Windows = $true; ComputerName = $Spec.Name; Credential = $Credential
                ProvisionVMAgent = $true; EnableAutoUpdate = $true; ErrorAction = 'Stop'
            }
            $vm = Set-AzVMOperatingSystem @osParameters
            $vm = Set-AzVMSourceImage -VM $vm -PublisherName $Spec.Image.Publisher -Offer $Spec.Image.Offer `
                -Skus $Spec.Image.Sku -Version $Spec.Image.Version -ErrorAction Stop
            $vm = Set-AzVMOSDisk -VM $vm -Name $Spec.OsDisk.Name -DiskSizeInGB $Spec.OsDisk.SizeGiB `
                -StorageAccountType $Spec.OsDisk.Sku -Caching $Spec.OsDisk.Caching -CreateOption FromImage `
                -ErrorAction Stop
            if ($Spec.SecurityType -eq 'TrustedLaunch') {
                $vm = Set-AzVMSecurityProfile -VM $vm -SecurityType TrustedLaunch -ErrorAction Stop
                $vm = Set-AzVmUefi -VM $vm -EnableVtpm:$Spec.VTpm -EnableSecureBoot:$Spec.SecureBoot `
                    -ErrorAction Stop
            }
            $vm = Add-AzVMNetworkInterface -VM $vm -Id $Spec.NetworkInterfaceIds[0] -Primary -ErrorAction Stop
            foreach ($disk in @($Spec.DataDisks | Sort-Object Lun)) {
                $vm = Add-AzVMDataDisk -VM $vm -Name $disk.Name -ManagedDiskId $disk.Id `
                    -Lun $disk.Lun -Caching $disk.Caching -CreateOption Attach -ErrorAction Stop
            }
            New-AzVM -ResourceGroupName $ResourceGroupName -Location $Spec.Location -VM $vm -ErrorAction Stop
        }
    }
}

function Assert-WorkshopVmOperationSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Operations, [switch] $ReadOnly)

    $required = @('GetSubscriptionId', 'GetVm', 'GetDisk')
    if (-not $ReadOnly) { $required += @('CreateVm', 'CreateDisk') }
    foreach ($name in $required) {
        if (-not $Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]) {
            throw "Operations must provide scriptblock '$name'."
        }
    }
}

function Invoke-WorkshopVmDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Admin', 'Sql')][string] $Role,
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $ImageVersion,
        [Parameter(Mandatory)][PSCredential] $Credential,
        [Parameter(Mandatory)][hashtable] $Operations
    )

    Assert-WorkshopVmOperationSet -Operations $Operations
    $subscriptionId = [string] (& $Operations.GetSubscriptionId)
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) { throw 'VM operations returned an empty subscription ID.' }
    $vmSpec = Get-WorkshopVmSpecification -Role $Role -Config $Config -ImageVersion $ImageVersion `
        -SubscriptionId $subscriptionId
    $diskSpecs = @(Get-WorkshopDiskSpecification -VmSpecification $vmSpec)
    $existingVm = & $Operations.GetVm $vmSpec.Name $Config.ResourceGroupName
    $existingDisks = @{}
    foreach ($diskSpec in $diskSpecs) {
        $existingDisks[$diskSpec.Name] = & $Operations.GetDisk $diskSpec.Name $Config.ResourceGroupName $diskSpec
    }

    if ($null -ne $existingVm -and -not (Test-WorkshopNetworkResourceMatch -Expected $vmSpec -Actual $existingVm)) {
        throw "VirtualMachine '$($vmSpec.Name)' conflicts with the approved shape."
    }
    foreach ($diskSpec in $diskSpecs) {
        $existingDisk = $existingDisks[$diskSpec.Name]
        if ($null -ne $existingDisk -and -not (Test-WorkshopNetworkResourceMatch -Expected $diskSpec -Actual $existingDisk)) {
            throw "ManagedDisk '$($diskSpec.Name)' conflicts with the approved shape."
        }
    }

    $checkpoint = [System.Collections.Generic.List[string]]::new()
    foreach ($diskSpec in $diskSpecs) {
        if ($null -eq $existingDisks[$diskSpec.Name]) {
            $null = & $Operations.CreateDisk $diskSpec $Config.ResourceGroupName
            $readBack = & $Operations.GetDisk $diskSpec.Name $Config.ResourceGroupName $diskSpec
            if ($null -eq $readBack -or -not (Test-WorkshopNetworkResourceMatch -Expected $diskSpec -Actual $readBack)) {
                throw "ManagedDisk '$($diskSpec.Name)' failed positive read-back. Checkpoint: $($checkpoint -join ', ')."
            }
            $checkpoint.Add("ManagedDisk/$($diskSpec.Name):created-and-verified")
        }
        else {
            $checkpoint.Add("ManagedDisk/$($diskSpec.Name):matched")
        }
    }
    if ($null -eq $existingVm) {
        $null = & $Operations.CreateVm $vmSpec $Credential $Config.ResourceGroupName
        $readBack = & $Operations.GetVm $vmSpec.Name $Config.ResourceGroupName
        if ($null -eq $readBack -or -not (Test-WorkshopNetworkResourceMatch -Expected $vmSpec -Actual $readBack)) {
            throw "VirtualMachine '$($vmSpec.Name)' failed positive read-back. Checkpoint: $($checkpoint -join ', ')."
        }
        $checkpoint.Add("VirtualMachine/$($vmSpec.Name):created-and-verified")
    }
    else {
        $checkpoint.Add("VirtualMachine/$($vmSpec.Name):matched")
    }
    [pscustomobject][ordered]@{ Completed = $true; Checkpoint = $checkpoint.ToArray(); VirtualMachine = $vmSpec }
}

function New-WorkshopAdminVm {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $ImageVersion,
        [Parameter(Mandatory)][PSCredential] $Credential,
        [Parameter(Mandatory)][bool] $WindowsClientLicenseAttested,
        [hashtable] $Operations
    )

    if (-not $WindowsClientLicenseAttested) {
        throw 'Windows client license attestation is required before creating the administration VM.'
    }
    if (-not $PSCmdlet.ShouldProcess($Config.AdminVm.Name, 'Create or exactly match the administration VM')) {
        return [pscustomobject][ordered]@{ Completed = $false; Checkpoint = @('ShouldProcess declined') }
    }
    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopVmOperationSet }
    Invoke-WorkshopVmDeployment -Role Admin -Config $Config -ImageVersion $ImageVersion `
        -Credential $Credential -Operations $Operations
}

function New-WorkshopSqlVm {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $ImageVersion,
        [Parameter(Mandatory)][PSCredential] $Credential,
        [hashtable] $Operations
    )

    if (-not $PSCmdlet.ShouldProcess($Config.SqlVm.Name, 'Create or exactly match the SQL VM and managed disks')) {
        return [pscustomobject][ordered]@{ Completed = $false; Checkpoint = @('ShouldProcess declined') }
    }
    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopVmOperationSet }
    Invoke-WorkshopVmDeployment -Role Sql -Config $Config -ImageVersion $ImageVersion `
        -Credential $Credential -Operations $Operations
}

function Test-WorkshopVmBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][hashtable] $ResolvedImages,
        [hashtable] $Operations
    )

    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopVmOperationSet }
    Assert-WorkshopVmOperationSet -Operations $Operations -ReadOnly
    $checks = [System.Collections.Generic.List[object]]::new()
    try {
        $subscriptionId = [string] (& $Operations.GetSubscriptionId)
        foreach ($role in @('Admin', 'Sql')) {
            $version = [string] $ResolvedImages[$role].Version
            $expectedVm = Get-WorkshopVmSpecification -Role $role -Config $Config -ImageVersion $version `
                -SubscriptionId $subscriptionId
            $actualVm = & $Operations.GetVm $expectedVm.Name $Config.ResourceGroupName
            Add-WorkshopBoundaryCheck -Checks $checks -Name "$role VM exact shape" `
                -Passed ($null -ne $actualVm -and (Test-WorkshopNetworkResourceMatch -Expected $expectedVm -Actual $actualVm)) `
                -Detail 'VM identity, image, size, security, OS disk, NICs, and data disks must exactly match.'
            foreach ($diskSpec in @(Get-WorkshopDiskSpecification -VmSpecification $expectedVm)) {
                $actualDisk = & $Operations.GetDisk $diskSpec.Name $Config.ResourceGroupName $diskSpec
                Add-WorkshopBoundaryCheck -Checks $checks -Name "Managed disk $($diskSpec.Name) exact shape" `
                    -Passed ($null -ne $actualDisk -and (Test-WorkshopNetworkResourceMatch -Expected $diskSpec -Actual $actualDisk)) `
                    -Detail 'Managed disk identity, size, SKU, LUN, and cache intent must exactly match.'
            }
        }
    }
    catch {
        Add-WorkshopBoundaryCheck -Checks $checks -Name 'VM boundary read' -Passed $false `
            -Detail (ConvertTo-WorkshopSafeDetail -Value $_.Exception.Message)
    }
    [pscustomobject][ordered]@{
        Passed = @($checks | Where-Object Status -EQ 'Failed').Count -eq 0
        Checks = $checks.ToArray()
    }
}

function Get-WorkshopSqlIaasSpecification {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config, [Parameter(Mandatory)][string] $SubscriptionId)

    $name = [string] $Config.SqlVm.Name
    $resourceGroupName = [string] $Config.ResourceGroupName
    [pscustomobject][ordered]@{
        Name = $name
        Id = "/subscriptions/$SubscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/$name"
        Location = [string] $Config.Location
        LicenseType = 'PAYG'
        VirtualMachineId = Get-WorkshopComputeResourceId -SubscriptionId $SubscriptionId `
            -ResourceGroupName $resourceGroupName -ResourceType 'virtualMachines' -Name $name
    }
}

function Get-DefaultWorkshopServiceOperationSet {
    [CmdletBinding()]
    param()

    @{
        GetSubscriptionId = {
            $context = Get-AzContext -ErrorAction Stop
            Get-WorkshopNestedIdentifier -InputObject $context -PropertyName 'Subscription'
        }
        GetTenantId = {
            $context = Get-AzContext -ErrorAction Stop
            Get-WorkshopNestedIdentifier -InputObject $context -PropertyName 'Tenant'
        }
        GetSqlIaas = {
            param($Spec, $ResourceGroupName)
            try {
                $resource = Get-AzSqlVM -ResourceGroupName $ResourceGroupName -Name $Spec.Name -ErrorAction Stop
                $licenseType = if ($resource.PSObject.Properties.Name -contains 'SqlServerLicenseType') {
                    [string] $resource.SqlServerLicenseType
                }
                elseif ($resource.PSObject.Properties.Name -contains 'LicenseType') {
                    [string] $resource.LicenseType
                }
                else {
                    $null
                }
                [pscustomobject][ordered]@{
                    Name = [string] $resource.Name; Id = [string] $resource.Id; Location = [string] $resource.Location
                    LicenseType = $licenseType
                    VirtualMachineId = [string] $resource.VirtualMachineResourceId
                }
            }
            catch {
                if (Test-WorkshopAzureNotFound -ErrorRecord $_) { return $null }
                throw
            }
        }
        CreateSqlIaas = {
            param($Spec, $ResourceGroupName)
            New-AzSqlVM -ResourceGroupName $ResourceGroupName -Name $Spec.Name -Location $Spec.Location `
                -LicenseType PAYG -ErrorAction Stop
        }
        GetSchedule = {
            param($Name, $ResourceGroupName, $Spec)
            $null = $ResourceGroupName
            try {
                $resource = Get-AzResource -ResourceId $Spec.Id -ApiVersion '2018-09-15' `
                    -ExpandProperties -ErrorAction Stop
                [pscustomobject][ordered]@{
                    Name = $Name; Id = [string] $resource.ResourceId
                    Location = [string] $resource.Location
                    Status = [string] $resource.Properties.status; TaskType = [string] $resource.Properties.taskType
                    DailyRecurrenceTime = [string] $resource.Properties.dailyRecurrence.time
                    TimeZoneId = [string] $resource.Properties.timeZoneId
                    TargetResourceId = [string] $resource.Properties.targetResourceId
                    NotificationStatus = [string] $resource.Properties.notificationSettings.status
                    NotificationTimeInMinutes = [int] $resource.Properties.notificationSettings.timeInMinutes
                }
            }
            catch {
                if (Test-WorkshopAzureNotFound -ErrorRecord $_) { return $null }
                throw
            }
        }
        CreateSchedule = {
            param($Spec, $ResourceGroupName)
            $null = $ResourceGroupName
            $properties = @{
                status = $Spec.Status; taskType = $Spec.TaskType; timeZoneId = $Spec.TimeZoneId
                dailyRecurrence = @{ time = $Spec.DailyRecurrenceTime }
                targetResourceId = $Spec.TargetResourceId
                notificationSettings = @{
                    status = $Spec.NotificationStatus
                    timeInMinutes = $Spec.NotificationTimeInMinutes
                }
            }
            New-AzResource -ResourceId $Spec.Id -ApiVersion '2018-09-15' -Location $Spec.Location `
                -Properties $properties `
                -Force -ErrorAction Stop
        }
        EnsureEmergencyStop = {
            param($Config, $SubscriptionId, $TenantId)
            Initialize-WorkshopEmergencyStopScheduledTask -Config $Config `
                -SubscriptionId $SubscriptionId -TenantId $TenantId
        }
    }
}

${function:Register-WorkshopSqlIaas} = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config, [hashtable] $Operations)

    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopServiceOperationSet }
    foreach ($name in @('GetSubscriptionId', 'GetSqlIaas', 'CreateSqlIaas')) {
        if (-not $Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]) {
            throw "Operations must provide scriptblock '$name'."
        }
    }
    $spec = Get-WorkshopSqlIaasSpecification -Config $Config -SubscriptionId ([string] (& $Operations.GetSubscriptionId))
    $existing = & $Operations.GetSqlIaas $spec $Config.ResourceGroupName
    if ($null -ne $existing -and -not (Test-WorkshopNetworkResourceMatch -Expected $spec -Actual $existing)) {
        throw "SQL IaaS registration '$($spec.Name)' conflicts with the approved shape."
    }
    $status = 'matched'
    if ($null -eq $existing) {
        $null = & $Operations.CreateSqlIaas $spec $Config.ResourceGroupName
        $readBack = & $Operations.GetSqlIaas $spec $Config.ResourceGroupName
        if ($null -eq $readBack -or -not (Test-WorkshopNetworkResourceMatch -Expected $spec -Actual $readBack)) {
            throw "SQL IaaS registration '$($spec.Name)' failed positive read-back."
        }
        $status = 'created-and-verified'
    }
    [pscustomobject][ordered]@{ Completed = $true; Checkpoint = @("SqlIaas/$($spec.Name):$status"); Resource = $spec }
}

function Get-WorkshopShutdownSpecification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $TimeZoneId
    )

    foreach ($vmName in @($Config.AdminVm.Name, $Config.SqlVm.Name)) {
        $name = "shutdown-computevm-$vmName"
        [pscustomobject][ordered]@{
            Name = $name
            Id = "/subscriptions/$SubscriptionId/resourceGroups/$($Config.ResourceGroupName)/providers/microsoft.devtestlab/schedules/$name"
            Location = [string] $Config.AutoShutdownLocation
            Status = 'Enabled'
            TaskType = 'ComputeVmShutdownTask'
            DailyRecurrenceTime = [string] $Config.AutoShutdownTime
            TimeZoneId = $TimeZoneId
            TargetResourceId = Get-WorkshopComputeResourceId -SubscriptionId $SubscriptionId `
                -ResourceGroupName $Config.ResourceGroupName -ResourceType 'virtualMachines' -Name $vmName
            NotificationStatus = 'Disabled'
            NotificationTimeInMinutes = 30
        }
    }
}

function Get-WorkshopAutoShutdownCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config)

    $vmLocation = ([string] $Config.Location).ToLowerInvariant() -replace '[^a-z0-9]', ''
    $scheduleLocation = ([string] $Config.AutoShutdownLocation).ToLowerInvariant() -replace '[^a-z0-9]', ''
    $scheduleSupported = $vmLocation -ceq $scheduleLocation
    $fallbackDocumented = -not $scheduleSupported -and
        $vmLocation -ceq 'indonesiacentral' -and $scheduleLocation -ceq 'southeastasia'
    [pscustomobject][ordered]@{
        ScheduleSupported = $scheduleSupported
        FallbackDocumented = $fallbackDocumented
        VmLocation = [string] $Config.Location
        ScheduleLocation = [string] $Config.AutoShutdownLocation
        RequiredFallback = if ($fallbackDocumented) { 'LocalEmergencyStop' } else { $null }
    }
}

function Test-WorkshopScheduledTaskAbsent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord)

    # Get-ScheduledTask reports absence through several shapes across Windows builds, so
    # match the CIM not-found category and message as well as the error id.
    if ([string] $ErrorRecord.FullyQualifiedErrorId -match 'NoMatching|ObjectNotFound') { return $true }
    if ($ErrorRecord.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { return $true }
    [string] $ErrorRecord.Exception.Message -match 'No MSFT_ScheduledTask objects found'
}

function Get-DefaultWorkshopEmergencyStopTaskOperationSet {
    [CmdletBinding()]
    param()

    @{
        GetCurrentUser = { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        GetTask = {
            param($Name)
            try {
                $task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
                $trigger = @($task.Triggers)[0]
                $start = [datetime]::MinValue
                $dailyTime = if ($null -ne $trigger -and
                    [datetime]::TryParse([string] $trigger.StartBoundary, [ref] $start)) {
                    $start.ToString('HHmm', [Globalization.CultureInfo]::InvariantCulture)
                }
                else { '' }
                $action = @($task.Actions)[0]
                [pscustomobject][ordered]@{
                    Name = [string] $task.TaskName
                    UserId = [string] $task.Principal.UserId
                    LogonType = [string] $task.Principal.LogonType
                    RunLevel = [string] $task.Principal.RunLevel
                    Execute = [string] $action.Execute
                    Arguments = [string] $action.Arguments
                    WorkingDirectory = [string] $action.WorkingDirectory
                    DailyTime = $dailyTime
                    DaysInterval = [int] $trigger.DaysInterval
                    StartWhenAvailable = [bool] $task.Settings.StartWhenAvailable
                    Enabled = [bool] $task.Settings.Enabled
                }
            }
            catch {
                if (Test-WorkshopScheduledTaskAbsent -ErrorRecord $_) { return $null }
                throw
            }
        }
        CreateTask = {
            param($Spec)
            $hours = [int] $Spec.DailyTime.Substring(0, 2)
            $minutes = [int] $Spec.DailyTime.Substring(2, 2)
            $action = New-ScheduledTaskAction -Execute $Spec.Execute -Argument $Spec.Arguments `
                -WorkingDirectory $Spec.WorkingDirectory
            $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($hours).AddMinutes($minutes))
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
            $principal = New-ScheduledTaskPrincipal -UserId $Spec.UserId -LogonType $Spec.LogonType `
                -RunLevel $Spec.RunLevel
            Register-ScheduledTask -TaskName $Spec.Name -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal -Description $Spec.Description -ErrorAction Stop
        }
    }
}

function ConvertTo-WorkshopEmergencyStopComparableTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Task)

    $result = [ordered]@{}
    foreach ($name in @(
        'Name', 'UserId', 'LogonType', 'RunLevel', 'Execute', 'Arguments',
        'WorkingDirectory', 'DailyTime', 'DaysInterval', 'StartWhenAvailable', 'Enabled'
    )) {
        $property = $Task.PSObject.Properties[$name]
        $result[$name] = if ($null -eq $property) { $null } else { $property.Value }
    }
    [pscustomobject] $result
}

function Get-WorkshopPwshPath {
    [CmdletBinding()]
    param([hashtable] $TaskOperations)

    # Resolve an absolute path so the task does not depend on the PATH of whichever
    # logon session eventually runs it.
    if ($null -ne $TaskOperations -and $TaskOperations.ContainsKey('GetPwshPath') -and
        $TaskOperations['GetPwshPath'] -is [scriptblock]) {
        $resolved = [string] (& $TaskOperations.GetPwshPath)
        if (-not [string]::IsNullOrWhiteSpace($resolved)) { return $resolved }
        throw 'The emergency-stop task requires a resolvable pwsh.exe path.'
    }
    $processPath = [string] ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    if ($processPath -match '(?i)\\pwsh\.exe$') { return $processPath }
    $command = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return [string] $command.Source }
    throw 'The emergency-stop task requires a resolvable pwsh.exe path.'
}

function Initialize-WorkshopEmergencyStopScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $SubscriptionId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $TenantId,
        [hashtable] $TaskOperations
    )

    if ($null -eq $TaskOperations) { $TaskOperations = Get-DefaultWorkshopEmergencyStopTaskOperationSet }
    foreach ($name in @('GetCurrentUser', 'GetTask', 'CreateTask')) {
        if (-not $TaskOperations.ContainsKey($name) -or $TaskOperations[$name] -isnot [scriptblock]) {
            throw "TaskOperations must provide scriptblock '$name'."
        }
    }
    if ([string] $Config.AutoShutdownTime -notmatch '^(?:[01]\d|2[0-3])[0-5]\d$') {
        throw 'AutoShutdownTime must use 24-hour HHmm format.'
    }
    $user = [string] (& $TaskOperations.GetCurrentUser)
    if ([string]::IsNullOrWhiteSpace($user) -or $user -match '(?i)(^|\\)SYSTEM$') {
        throw 'The emergency-stop task requires a non-SYSTEM current user identity.'
    }
    $stopScript = Join-Path $PSScriptRoot 'Stop-WorkshopEnvironment.ps1'
    # Task Scheduler hands this string to the process command line verbatim, and Windows
    # command-line parsing only strips DOUBLE quotes. Single quotes would be passed through
    # literally and pwsh.exe would reject the script path (exit 64).
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($stopScript.Replace('"', '""'))`" " +
        "-SubscriptionId $SubscriptionId -TenantId $TenantId -Confirm:`$false"
    $expected = [pscustomobject][ordered]@{
        Name = 'McpSqlWorkshop-EmergencyStop'
        UserId = $user
        LogonType = 'Interactive'
        RunLevel = 'Limited'
        Execute = Get-WorkshopPwshPath -TaskOperations $TaskOperations
        Arguments = $arguments
        WorkingDirectory = $PSScriptRoot
        DailyTime = [string] $Config.AutoShutdownTime
        DaysInterval = 1
        StartWhenAvailable = $true
        Enabled = $true
        Description = 'Secret-free local safety stop for the MCP SQL workshop.'
    }
    $comparableExpected = [pscustomobject][ordered]@{
        Name = $expected.Name; UserId = $expected.UserId; LogonType = $expected.LogonType
        RunLevel = $expected.RunLevel; Execute = $expected.Execute; Arguments = $expected.Arguments
        WorkingDirectory = $expected.WorkingDirectory; DailyTime = $expected.DailyTime
        DaysInterval = $expected.DaysInterval; StartWhenAvailable = $expected.StartWhenAvailable
        Enabled = $expected.Enabled
    }
    $existing = & $TaskOperations.GetTask $expected.Name
    $existingComparable = if ($null -eq $existing) {
        $null
    }
    else {
        ConvertTo-WorkshopEmergencyStopComparableTask -Task $existing
    }
    if ($null -ne $existingComparable -and
        -not (Test-WorkshopNetworkResourceMatch -Expected $comparableExpected -Actual $existingComparable)) {
        throw "Local emergency-stop task '$($expected.Name)' conflicts with the approved secret-free current-user shape."
    }
    if ($null -ne $existingComparable) {
        return [pscustomobject][ordered]@{ Status = 'matched-and-verified'; Task = $comparableExpected }
    }
    $null = & $TaskOperations.CreateTask $expected
    $readBack = & $TaskOperations.GetTask $expected.Name
    $readBackComparable = if ($null -eq $readBack) {
        $null
    }
    else {
        ConvertTo-WorkshopEmergencyStopComparableTask -Task $readBack
    }
    if ($null -eq $readBackComparable -or
        -not (Test-WorkshopNetworkResourceMatch -Expected $comparableExpected -Actual $readBackComparable)) {
        throw "Local emergency-stop task '$($expected.Name)' was not positively verified after installation."
    }
    [pscustomobject][ordered]@{ Status = 'installed-and-verified'; Task = $comparableExpected }
}

function Set-WorkshopAutoShutdown {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [ValidateNotNullOrEmpty()][string] $TimeZoneId = 'UTC',
        [hashtable] $Operations
    )

    $capability = Get-WorkshopAutoShutdownCapability -Config $Config
    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopServiceOperationSet }
    if (-not $capability.ScheduleSupported -and $capability.FallbackDocumented) {
        foreach ($name in @('GetSubscriptionId', 'GetTenantId', 'EnsureEmergencyStop')) {
            if (-not $Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]) {
                throw "Operations must provide scriptblock '$name'."
            }
        }
        $subscriptionId = [string] (& $Operations.GetSubscriptionId)
        $tenantId = [string] (& $Operations.GetTenantId)
        if (-not $PSCmdlet.ShouldProcess('McpSqlWorkshop-EmergencyStop', 'Install or exactly match the local emergency-stop task')) {
            return [pscustomobject][ordered]@{ Completed = $false; Checkpoint = @('ShouldProcess declined') }
        }
        $fallbackResult = & $Operations.EnsureEmergencyStop $Config $subscriptionId $tenantId
        $fallbackStatus = if ($null -ne $fallbackResult -and
            $fallbackResult.PSObject.Properties.Name -contains 'Status') {
            [string] $fallbackResult.Status
        }
        if ($fallbackStatus -notin @('installed-and-verified', 'matched-and-verified')) {
            throw 'The local emergency-stop task was not installed or exactly matched and positively verified.'
        }
        return [pscustomobject][ordered]@{
            Completed = $true
            ScheduleCreationSkipped = $true
            FallbackRequired = $true
            Fallback = 'LocalEmergencyStop'
            FallbackStatus = $fallbackStatus
            Reason = "DevTestLab cross-region scheduling from '$($capability.ScheduleLocation)' to '$($capability.VmLocation)' is unsupported."
            Checkpoint = @('AutoShutdown:unsupported-cross-region', "LocalEmergencyStop:$fallbackStatus")
            Schedules = @()
        }
    }
    if (-not $capability.ScheduleSupported) {
        throw "DevTestLab cross-region scheduling is unsupported and this location pair is not an approved fallback."
    }
    if (-not $PSCmdlet.ShouldProcess($Config.ResourceGroupName, 'Create or exactly match both VM auto-shutdown schedules')) {
        return [pscustomobject][ordered]@{ Completed = $false; Checkpoint = @('ShouldProcess declined') }
    }
    foreach ($name in @('GetSubscriptionId', 'GetSchedule', 'CreateSchedule')) {
        if (-not $Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]) {
            throw "Operations must provide scriptblock '$name'."
        }
    }
    $specs = @(Get-WorkshopShutdownSpecification -Config $Config `
        -SubscriptionId ([string] (& $Operations.GetSubscriptionId)) -TimeZoneId $TimeZoneId)
    $existing = @{}
    foreach ($spec in $specs) {
        $existing[$spec.Name] = & $Operations.GetSchedule $spec.Name $Config.ResourceGroupName $spec
    }
    foreach ($spec in $specs) {
        if ($null -ne $existing[$spec.Name] -and
            -not (Test-WorkshopNetworkResourceMatch -Expected $spec -Actual $existing[$spec.Name])) {
            throw "Auto-shutdown schedule '$($spec.Name)' conflicts with the approved shape."
        }
    }
    $checkpoint = [System.Collections.Generic.List[string]]::new()
    foreach ($spec in $specs) {
        if ($null -eq $existing[$spec.Name]) {
            $null = & $Operations.CreateSchedule $spec $Config.ResourceGroupName
            $readBack = & $Operations.GetSchedule $spec.Name $Config.ResourceGroupName $spec
            if ($null -eq $readBack -or -not (Test-WorkshopNetworkResourceMatch -Expected $spec -Actual $readBack)) {
                throw "Auto-shutdown schedule '$($spec.Name)' failed positive read-back."
            }
            $checkpoint.Add("AutoShutdown/$($spec.Name):created-and-verified")
        }
        else { $checkpoint.Add("AutoShutdown/$($spec.Name):matched") }
    }
    [pscustomobject][ordered]@{ Completed = $true; Checkpoint = $checkpoint.ToArray(); Schedules = $specs }
}

function Get-DefaultWorkshopStopOperationSet {
    [CmdletBinding()]
    param()

    @{
        SetContext = {
            param($SubscriptionId, $TenantId)
            $parameters = @{ SubscriptionId = $SubscriptionId; ErrorAction = 'Stop' }
            if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $parameters.Tenant = $TenantId }
            Set-AzContext @parameters
        }
        GetVm = {
            param($Name, $ResourceGroupName)
            Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
        }
        StopVm = {
            param($Name, $ResourceGroupName)
            Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Force -ErrorAction Stop
        }
        GetPowerState = {
            param($Name, $ResourceGroupName)
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status -ErrorAction Stop
            [string] @($vm.Statuses | Where-Object Code -Like 'PowerState/*' | Select-Object -First 1).Code
        }
    }
}

function Stop-WorkshopEnvironment {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SubscriptionId,
        [ValidateNotNullOrEmpty()][string] $TenantId,
        [hashtable] $Operations
    )

    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopStopOperationSet }
    foreach ($name in @('SetContext', 'GetVm', 'StopVm', 'GetPowerState')) {
        if (-not $Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]) {
            throw "Operations must provide scriptblock '$name'."
        }
    }
    $null = & $Operations.SetContext $SubscriptionId $TenantId
    $errors = [System.Collections.Generic.List[string]]::new()
    $checkpoint = [System.Collections.Generic.List[string]]::new()
    foreach ($vmName in @($Config.AdminVm.Name, $Config.SqlVm.Name)) {
        try {
            $vm = & $Operations.GetVm $vmName $Config.ResourceGroupName
            $expectedId = Get-WorkshopComputeResourceId -SubscriptionId $SubscriptionId `
                -ResourceGroupName $Config.ResourceGroupName -ResourceType 'virtualMachines' -Name $vmName
            $actualId = if ($null -eq $vm) { '' } else { [string] $vm.Id }
            if ((ConvertTo-WorkshopComparableValue $actualId) -cne (ConvertTo-WorkshopComparableValue $expectedId)) {
                throw "VM '$vmName' did not have the approved full resource ID."
            }
            if ($PSCmdlet.ShouldProcess($actualId, 'Deallocate workshop VM')) {
                $null = & $Operations.StopVm $vmName $Config.ResourceGroupName
                $powerState = [string] (& $Operations.GetPowerState $vmName $Config.ResourceGroupName)
                if ($powerState -cne 'PowerState/deallocated') {
                    throw "VM '$vmName' power state '$powerState' was not PowerState/deallocated."
                }
                $checkpoint.Add("VirtualMachine/$vmName:deallocated-and-verified")
            }
        }
        catch {
            $errors.Add((ConvertTo-WorkshopSafeDetail -Value $_.Exception.Message))
        }
    }
    if ($errors.Count -gt 0) { throw "Workshop VM deallocation failed: $($errors -join '; ')" }
    [pscustomobject][ordered]@{ Completed = $true; Checkpoint = $checkpoint.ToArray() }
}

function Wait-WorkshopResourceGroupRemoval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][ValidateRange(1, 100)][int] $MaximumAttempts,
        [Parameter(Mandatory)][scriptblock] $ReadOperation,
        [Parameter(Mandatory)][scriptblock] $WaitOperation
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $state = [string] (& $ReadOperation $Name)
        if ($state -ceq 'NotFound') { return $true }
        if ($state -cne 'Found') {
            throw "Resource group removal read returned unexpected state '$state'."
        }
        if ($attempt -lt $MaximumAttempts) { $null = & $WaitOperation }
    }
    $false
}

function Get-DefaultWorkshopRemoveOperationSet {
    [CmdletBinding()]
    param()

    @{
        SetContext = {
            param($SubscriptionId, $TenantId)
            $parameters = @{ SubscriptionId = $SubscriptionId; ErrorAction = 'Stop' }
            if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $parameters.Tenant = $TenantId }
            Set-AzContext @parameters
        }
        GetResourceGroup = {
            param($Name)
            try {
                [pscustomobject]@{ Status = 'Found'; ResourceGroup = Get-AzResourceGroup -Name $Name -ErrorAction Stop }
            }
            catch {
                if (Test-WorkshopAzureNotFound -ErrorRecord $_) {
                    return [pscustomobject]@{ Status = 'NotFound'; ResourceGroup = $null }
                }
                throw
            }
        }
        RemoveResourceGroup = {
            param($Name)
            Remove-AzResourceGroup -Name $Name -Force -ErrorAction Stop
        }
        WaitForRemoval = {
            param($Name, $MaximumAttempts)
            $readOperation = {
                param($ResourceGroupName)
                try {
                    $null = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
                    'Found'
                }
                catch {
                    if (Test-WorkshopAzureNotFound -ErrorRecord $_) { return 'NotFound' }
                    throw
                }
            }
            Wait-WorkshopResourceGroupRemoval -Name $Name -MaximumAttempts $MaximumAttempts `
                -ReadOperation $readOperation -WaitOperation { [System.Threading.Thread]::Sleep(3000) }
        }
        GetTaggedResources = {
            param($Environment, $Workload, $ManagedBy, $SubscriptionId, $ResourceGroupName)
            $null = $SubscriptionId, $ResourceGroupName
            try {
                # This runs after the group is already NotFound, so it must be scoped to the
                # whole subscription. Scoping it to the deleted group could only ever return
                # nothing, which would make the absence checkpoint unfalsifiable.
                @(Get-AzResource -TagName 'managedBy' -TagValue $ManagedBy -ErrorAction Stop | Where-Object {
                    $null -ne $_.Tags -and
                    $_.Tags['environment'] -ceq $Environment -and
                    $_.Tags['workload'] -ceq $Workload -and
                    $_.Tags['managedBy'] -ceq $ManagedBy
                })
            }
            catch {
                if (Test-WorkshopAzureNotFound -ErrorRecord $_) { return @() }
                throw
            }
        }
        RemoveEmergencyStopTask = {
            # The fallback task lives on the facilitator workstation, so deleting the
            # resource group alone would leave a daily task pointed at nothing.
            $name = 'McpSqlWorkshop-EmergencyStop'
            if ($null -eq (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { return 'absent' }
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
            if ($null -ne (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) {
                throw "Local emergency-stop task '$name' still exists after removal."
            }
            'removed'
        }
    }
}

function Remove-WorkshopEnvironment {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SubscriptionId,
        [ValidateNotNullOrEmpty()][string] $TenantId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ConfirmationPhrase,
        [ValidateRange(1, 100)][int] $MaximumAttempts = 40,
        [hashtable] $Operations
    )

    $requiredPhrase = "DELETE $($Config.ResourceGroupName)"
    if ($ConfirmationPhrase -cne $requiredPhrase -or $requiredPhrase -cne 'DELETE rg-mcp-sql-workshop') {
        throw "Removal confirmation phrase must be exactly 'DELETE rg-mcp-sql-workshop'."
    }
    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopRemoveOperationSet }
    foreach ($name in @('SetContext', 'GetResourceGroup', 'RemoveResourceGroup', 'WaitForRemoval',
        'GetTaggedResources', 'RemoveEmergencyStopTask')) {
        if (-not $Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]) {
            throw "Operations must provide scriptblock '$name'."
        }
    }
    $null = & $Operations.SetContext $SubscriptionId $TenantId
    $read = & $Operations.GetResourceGroup $Config.ResourceGroupName
    if ($null -eq $read -or $read.Status -cne 'Found' -or $null -eq $read.ResourceGroup) {
        throw "Target resource group '$($Config.ResourceGroupName)' was not positively read before removal."
    }
    $resourceGroup = $read.ResourceGroup
    $expectedId = "/subscriptions/$SubscriptionId/resourceGroups/$($Config.ResourceGroupName)"
    if ($resourceGroup.ResourceGroupName -cne $Config.ResourceGroupName -or
        (ConvertTo-WorkshopComparableValue $resourceGroup.ResourceId) -cne (ConvertTo-WorkshopComparableValue $expectedId) -or
        $null -eq $resourceGroup.Tags -or
        $resourceGroup.Tags['environment'] -cne [string] $Config.Tags.environment -or
        $resourceGroup.Tags['workload'] -cne [string] $Config.Tags.workload -or
        $resourceGroup.Tags['managedBy'] -cne [string] $Config.Tags.managedBy) {
        throw 'Target resource group name, subscription-qualified ID, or required workshop tags did not match.'
    }
    if (-not $PSCmdlet.ShouldProcess($expectedId, 'Permanently remove the workshop resource group')) {
        return [pscustomobject][ordered]@{ Completed = $false; Checkpoint = @('ShouldProcess declined') }
    }
    $null = & $Operations.RemoveResourceGroup $Config.ResourceGroupName
    if (-not (& $Operations.WaitForRemoval $Config.ResourceGroupName $MaximumAttempts)) {
        throw "Resource group deletion did not reach NotFound within $MaximumAttempts checks."
    }
    $postRead = & $Operations.GetResourceGroup $Config.ResourceGroupName
    if ($null -eq $postRead -or $postRead.Status -cne 'NotFound' -or $null -ne $postRead.ResourceGroup) {
        throw 'Resource group deletion was not verified by an explicit NotFound read.'
    }
    $remaining = @(& $Operations.GetTaggedResources $Config.Tags.environment $Config.Tags.workload `
        $Config.Tags.managedBy `
        $SubscriptionId $Config.ResourceGroupName)
    if ($remaining.Count -gt 0) {
        throw "Tagged workshop resource absence verification failed; $($remaining.Count) resource(s) remain."
    }
    $emergencyStopState = [string] (& $Operations.RemoveEmergencyStopTask)
    if ($emergencyStopState -cnotin @('absent', 'removed')) {
        throw "Local emergency-stop task removal returned unexpected state '$emergencyStopState'."
    }
    [pscustomobject][ordered]@{
        Completed = $true
        Checkpoint = @(
            'Resource group removal requested', 'Resource group NotFound verified',
            'Tagged resource absence verified', "Local emergency-stop task $emergencyStopState"
        )
    }
}

function ConvertFrom-WorkshopSecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.SecureString] $Value)

    $pointer = [IntPtr]::Zero
    $plainText = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        return $plainText
    }
    finally {
        $plainText = $null
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Get-WorkshopBootstrapArchiveUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^https://github\.com/[^/]+/[^/]+(?:\.git)?$')][string] $RepositoryUrl,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $RepositoryCommit
    )

    $base = $RepositoryUrl -replace '\.git$', ''
    if ($base -cne 'https://github.com/ibranibeny/mcp-sql-query-store-workshop') {
        throw "RepositoryUrl must identify the approved repository 'https://github.com/ibranibeny/mcp-sql-query-store-workshop'."
    }
    "$base/archive/$RepositoryCommit.zip"
}

function Expand-WorkshopBootstrapArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $DestinationPath,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $RepositoryCommit,
        [Parameter(Mandatory)][ValidateSet('Initialize-SqlVm.ps1', 'Invoke-AdminBootstrap.ps1')][string] $ApprovedBootstrapEntryPoint,
        [ValidateRange(1, 10)][int] $MaximumPromotionAttempts = 5,
        [scriptblock] $PromoteOperation = {
            param($Source, $Destination)
            Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
        },
        [scriptblock] $WaitOperation = {
            [System.Threading.Thread]::Sleep(500)
        }
    )

    $expectedRootName = "mcp-sql-query-store-workshop-$RepositoryCommit"
    $expectedEntryPoint = "$expectedRootName/deploy/$ApprovedBootstrapEntryPoint"
    $destinationParent = Split-Path -Parent $DestinationPath
    # Kept short on purpose: the guest extracts under a deployment-scoped path and the
    # archive adds a 69-character root folder, so a long staging name overruns MAX_PATH.
    $stagingPath = Join-Path $destinationParent ('.s' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $archive = $null
    $stream = $null
    try {
        $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
        if ($archive.Entries.Count -eq 0) { throw 'Repository archive rejected: the archive is empty.' }
        $entryPointPresent = $false
        foreach ($entry in $archive.Entries) {
            $entryName = ([string]$entry.FullName).Replace('\', '/')
            $segments = @($entryName.Split('/') | Where-Object { $_.Length -gt 0 })
            if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName.StartsWith('/') -or
                $segments.Count -eq 0 -or $segments[0] -cne $expectedRootName -or
                @($segments | Where-Object { $_ -in @('.', '..') }).Count -gt 0 -or
                $entryName -match '(^|/)[^/]*:[^/]*(/|$)' -or $entryName -match '//') {
                throw "Repository archive rejected: entry '$entryName' is outside the single expected top-level directory."
            }
            $unixFileType = ([int64]$entry.ExternalAttributes -shr 16) -band 0xF000
            $windowsAttributes = [int64]$entry.ExternalAttributes -band 0xFFFF
            if ($unixFileType -eq 0xA000 -or
                ($windowsAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Repository archive rejected: reparse entry '$entryName' is not permitted."
            }
            if ($entryName.TrimEnd('/') -ceq $expectedEntryPoint) { $entryPointPresent = $true }
            $stagedLength = $stagingPath.Length + 1 + $entryName.TrimEnd('/').Length
            if ($stagedLength -gt 259) {
                throw "Repository archive rejected: entry '$entryName' would extract to $stagedLength characters, beyond the $([int]259)-character Windows path limit."
            }
        }
        if (-not $entryPointPresent) {
            throw "Repository archive rejected: approved bootstrap entry point '$ApprovedBootstrapEntryPoint' is missing."
        }
        $archive.Dispose()
        $archive = $null
        $stream.Dispose()
        $stream = $null

        $null = New-Item -ItemType Directory -Path $destinationParent -Force
        [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $stagingPath)
        $topLevelEntries = @(Get-ChildItem -LiteralPath $stagingPath -Force)
        if ($topLevelEntries.Count -ne 1 -or -not $topLevelEntries[0].PSIsContainer -or
            $topLevelEntries[0].Name -cne $expectedRootName) {
            throw 'Repository archive rejected: extracted layout is not the single expected top-level directory.'
        }
        $reparseEntries = @(Get-ChildItem -LiteralPath $stagingPath -Force -Recurse | Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
        if ($reparseEntries.Count -ne 0) {
            throw 'Repository archive rejected: extracted content contains a reparse entry.'
        }
        $approvedEntryPointPath = Join-Path $topLevelEntries[0].FullName "deploy\$ApprovedBootstrapEntryPoint"
        if (-not (Test-Path -LiteralPath $approvedEntryPointPath -PathType Leaf)) {
            throw 'Repository archive rejected: approved bootstrap entry point did not extract as a regular file.'
        }
        if (Test-Path -LiteralPath $DestinationPath) { Remove-Item -LiteralPath $DestinationPath -Recurse -Force }
        $promotionError = $null
        for ($attempt = 1; $attempt -le $MaximumPromotionAttempts; $attempt++) {
            try {
                & $PromoteOperation $topLevelEntries[0].FullName $DestinationPath
                $promotionError = $null
                break
            }
            catch {
                $promotionError = $_
                if (Test-Path -LiteralPath $DestinationPath) {
                    throw 'Repository archive promotion created an ambiguous partial destination.'
                }
                if ($attempt -lt $MaximumPromotionAttempts) {
                    & $WaitOperation $attempt
                }
            }
        }
        if ($null -ne $promotionError) { throw $promotionError }
        if (-not (Test-Path -LiteralPath (Join-Path $DestinationPath "deploy\$ApprovedBootstrapEntryPoint") -PathType Leaf)) {
            throw 'Repository archive promotion did not preserve the approved bootstrap entry point.'
        }
        if (@(Get-ChildItem -LiteralPath $DestinationPath -Force -Recurse | Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            }).Count -ne 0) {
            throw 'Repository archive promotion produced a reparse entry.'
        }
        $DestinationPath
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
    }
}

function Get-DefaultWorkshopBootstrapOperationSet {
    [CmdletBinding()]
    param()

    @{
        GetSubscriptionId = {
            $context = Get-AzContext -ErrorAction Stop
            $subscriptionId = Get-WorkshopNestedIdentifier -InputObject $context -PropertyName 'Subscription'
            if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
                throw 'The active Azure context did not return a subscription ID for bootstrap locking.'
            }
            $subscriptionId
        }
        AcquireDeploymentLock = {
            param($SubscriptionId, $ResourceGroupName, $VmName)
            Enter-WorkshopBootstrapLock -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ResourceGroupName -VmName $VmName
        }
        ReleaseDeploymentLock = {
            param($Lease)
            Exit-WorkshopBootstrapLock -Lease $Lease
        }
        GetRecipientCertificate = {
            param($VmName, $ResourceGroupName)
            $command = @'
$ErrorActionPreference = 'Stop'
$subject = 'CN=McpSqlWorkshopBootstrapPayload'
$certificate = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.Subject -ceq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(1)
} | Sort-Object NotAfter -Descending | Select-Object -First 1
if ($null -eq $certificate) {
    $certificate = New-SelfSignedCertificate -Type DocumentEncryptionCert -Subject $subject `
        -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddDays(7)
}
$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
if ($rsa -isnot [Security.Cryptography.RSACng]) {
    throw 'Bootstrap payload certificate must use an RSA CNG private key.'
}
$keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$($rsa.Key.UniqueName)"
$keyAcl = Get-Acl -LiteralPath $keyPath
$keyAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    'BUILTIN\Administrators', 'Read', 'Allow'
))
Set-Acl -LiteralPath $keyPath -AclObject $keyAcl
$keyAclReadback = Get-Acl -LiteralPath $keyPath
if ($null -eq ($keyAclReadback.Access | Where-Object {
        $_.IdentityReference.Value -eq 'BUILTIN\Administrators' -and
        $_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read
    } | Select-Object -First 1)) {
    throw 'Bootstrap payload certificate key ACL was not verified.'
}
$path = Join-Path $env:TEMP 'mcp-workshop-bootstrap-public.cer'
$null = Export-Certificate -Cert $certificate -FilePath $path -Force
try { [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) }
finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
'@
            $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VmName `
                -CommandId RunPowerShellScript -ScriptString $command -ErrorAction Stop
            (@($result.Value | ForEach-Object Message) -join '').Trim()
        }
        ProtectPayload = {
            param($RecipientCertificateBase64, $Payload)
            $certificateBytes = [Convert]::FromBase64String($RecipientCertificateBase64)
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
            try {
                $json = $Payload | ConvertTo-Json -Depth 12 -Compress
                Protect-CmsMessage -To $certificate -Content $json
            }
            finally {
                $json = $null
                $certificate.Dispose()
                [Array]::Clear($certificateBytes, 0, $certificateBytes.Length)
            }
        }
        StageBootstrapFiles = {
            param($VmName, $ResourceGroupName, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit, $DeploymentId)
            $bootstrapEntryPoint = if ($BootstrapScript -ceq 'Initialize-AdminVm.ps1') {
                'Invoke-AdminBootstrap.ps1'
            }
            else {
                $BootstrapScript
            }
            $archiveExpansionFunction = ${function:Expand-WorkshopBootstrapArchive}.ToString()
            $launcherTemplate = @'
$ErrorActionPreference = 'Stop'
$root = 'C:\McpSqlWorkshop'
$deploymentRoot = Join-Path $root 'deployments\__DEPLOYMENT_ID__'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Expand-WorkshopBootstrapArchive {
__ARCHIVE_EXPANSION_FUNCTION__
}
$archives = @(Get-ChildItem -LiteralPath (Get-Location) -Filter '*.zip' -File)
if ($archives.Count -ne 1) { throw 'Exactly one immutable repository archive is required.' }
$repo = Join-Path $deploymentRoot 'repo'
$null = Expand-WorkshopBootstrapArchive -ArchivePath $archives[0].FullName -DestinationPath $repo `
    -RepositoryCommit '__REPOSITORY_COMMIT__' -ApprovedBootstrapEntryPoint '__BOOTSTRAP_ENTRY_POINT__'
$payloadPath = Join-Path $deploymentRoot 'protected-bootstrap.cms'
if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
    throw 'The staged protected bootstrap payload is unavailable.'
}
& (Join-Path $repo 'deploy\__BOOTSTRAP_ENTRY_POINT__') -ProtectedPayloadPath $payloadPath
'@
            $launcher = $launcherTemplate.Replace(
                '__ARCHIVE_EXPANSION_FUNCTION__', $archiveExpansionFunction
            ).Replace(
                '__REPOSITORY_COMMIT__', $RepositoryCommit
            ).Replace(
                '__BOOTSTRAP_ENTRY_POINT__', $bootstrapEntryPoint
            ).Replace(
                '__DEPLOYMENT_ID__', $DeploymentId
            )
            $launcherBytes = [Text.Encoding]::UTF8.GetBytes($launcher)
            $envelopeBytes = [Text.Encoding]::UTF8.GetBytes($ProtectedEnvelope)
            try {
                $launcherBase64 = [Convert]::ToBase64String($launcherBytes)
                $envelopeBase64 = [Convert]::ToBase64String($envelopeBytes)
                $launcherHash = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($launcherBytes)
                )
                $envelopeHash = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($envelopeBytes)
                )
                $stageScript = @"
`$ErrorActionPreference = 'Stop'
`$deploymentRoot = 'C:\McpSqlWorkshop\deployments\$DeploymentId'
New-Item -ItemType Directory -Path `$deploymentRoot -Force | Out-Null
# Each retry stages a fresh repository copy, so drop the folders of earlier attempts.
Get-ChildItem -LiteralPath 'C:\McpSqlWorkshop\deployments' -Directory -ErrorAction SilentlyContinue |
    Where-Object { `$_.Name -cne '$DeploymentId' } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
`$launcherPath = Join-Path `$deploymentRoot 'bootstrap-launcher.ps1'
`$payloadPath = Join-Path `$deploymentRoot 'protected-bootstrap.cms'
[IO.File]::WriteAllBytes(`$launcherPath, [Convert]::FromBase64String('$launcherBase64'))
[IO.File]::WriteAllBytes(`$payloadPath, [Convert]::FromBase64String('$envelopeBase64'))
foreach (`$path in @(`$launcherPath, `$payloadPath)) {
    `$acl = [Security.AccessControl.FileSecurity]::new()
    `$acl.SetAccessRuleProtection(`$true, `$false)
    foreach (`$identity in @('BUILTIN\Administrators','NT AUTHORITY\SYSTEM')) {
        `$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(`$identity,'FullControl','Allow'))
    }
    Set-Acl -LiteralPath `$path -AclObject `$acl
}
if ((Get-FileHash -LiteralPath `$launcherPath -Algorithm SHA256).Hash -cne '$launcherHash' -or
    (Get-FileHash -LiteralPath `$payloadPath -Algorithm SHA256).Hash -cne '$envelopeHash') {
    throw 'Staged bootstrap file hash verification failed.'
}
'MCP_BOOTSTRAP_STAGED:${launcherHash}:$envelopeHash'
"@
                $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VmName `
                    -CommandId RunPowerShellScript -ScriptString $stageScript -ErrorAction Stop
                $message = @($result.Value | ForEach-Object Message) -join [Environment]::NewLine
                if ($message -notmatch [regex]::Escape("MCP_BOOTSTRAP_STAGED:${launcherHash}:$envelopeHash")) {
                    throw 'Bootstrap launcher and encrypted payload staging was not positively verified.'
                }
            }
            finally {
                $launcher = $null
                $launcherBase64 = $null
                $envelopeBase64 = $null
                $stageScript = $null
                [Array]::Clear($launcherBytes, 0, $launcherBytes.Length)
                [Array]::Clear($envelopeBytes, 0, $envelopeBytes.Length)
            }
        }
        SetExtension = {
            param($VmName, $ResourceGroupName, $Location, $ArchiveUri, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit, $DeploymentId)
            $null = $ProtectedEnvelope, $RepositoryCommit
            $publicSettings = @{ timestamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') }
            $protectedSettings = @{
                fileUris = @($ArchiveUri)
                commandToExecute = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\McpSqlWorkshop\deployments\$DeploymentId\bootstrap-launcher.ps1"
            }
            Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName -Location $Location `
                -Name "McpSqlWorkshop-$BootstrapScript" -Publisher 'Microsoft.Compute' `
                -ExtensionType 'CustomScriptExtension' -TypeHandlerVersion '1.10' `
                -SettingString ($publicSettings | ConvertTo-Json -Compress) `
                -ProtectedSettingString ($protectedSettings | ConvertTo-Json -Depth 6 -Compress) `
                -ErrorAction Stop
        }
        GetExtension = {
            param($VmName, $ResourceGroupName, $BootstrapScript)
            try {
                Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName `
                    -Name "McpSqlWorkshop-$BootstrapScript" -Status -ErrorAction Stop
            }
            catch {
                if (Test-WorkshopAzureNotFound -ErrorRecord $_) { return $null }
                throw
            }
        }
        ReadReadiness = {
            param($VmName, $ResourceGroupName, $Path)
            $command = "`$ErrorActionPreference='Stop'; Get-Content -LiteralPath '$($Path.Replace("'", "''"))' -Raw"
            $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VmName `
                -CommandId RunPowerShellScript -ScriptString $command -ErrorAction Stop
            $text = @($result.Value | ForEach-Object Message) -join [Environment]::NewLine
            $text | ConvertFrom-Json
        }
        ReadPublicCertificate = {
            param($VmName, $ResourceGroupName, $Path)
            $command = "`$ErrorActionPreference='Stop'; [Convert]::ToBase64String([IO.File]::ReadAllBytes('$($Path.Replace("'", "''"))'))"
            $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VmName `
                -CommandId RunPowerShellScript -ScriptString $command -ErrorAction Stop
            (@($result.Value | ForEach-Object Message) -join '').Trim()
        }
    }
}

function Assert-WorkshopBootstrapOperationSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Operations, [switch] $Admin)

    $required = @(
        'GetSubscriptionId', 'AcquireDeploymentLock', 'ReleaseDeploymentLock',
        'GetRecipientCertificate', 'ProtectPayload', 'StageBootstrapFiles',
        'SetExtension', 'GetExtension', 'ReadReadiness'
    )
    if ($Admin) { $required += 'ReadPublicCertificate' }
    foreach ($name in $required) {
        if (-not $Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]) {
            throw "Operations must provide scriptblock '$name'."
        }
    }
}

function Enter-WorkshopBootstrapLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $VmName,
        [ValidateRange(0, 60000)][int] $TimeoutMilliseconds = 15000
    )

    $identity = "$($SubscriptionId.ToLowerInvariant())|$($ResourceGroupName.ToLowerInvariant())|$($VmName.ToLowerInvariant())"
    # The identity holds no secret; hashing only keeps the mutex name short and legal.
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($identity)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    # Global\ with default security is deliberate: two facilitators signed in to different
    # sessions on the same jump host must exclude each other, which Local\ or a
    # current-user ACL would not do. The name is a hash of non-secret identifiers, so the
    # worst local abuse is a denial of service bounded by TimeoutMilliseconds.
    $mutex = $null
    $acquired = $false
    try {
        $mutex = [Threading.Mutex]::new($false, "Global\McpSqlWorkshop-Bootstrap-$hash")
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw "Another local bootstrap attempt holds the deployment lock for VM '$VmName'."
        }
        [pscustomobject][ordered]@{
            Mutex = $mutex
            Acquired = $true
            Name = "Global\McpSqlWorkshop-Bootstrap-$hash"
        }
    }
    catch [UnauthorizedAccessException] {
        # Another account already owns the name, which is contention, not a defect.
        if ($null -ne $mutex) { $mutex.Dispose() }
        throw "Another local bootstrap attempt holds the deployment lock for VM '$VmName'."
    }
    catch {
        if ($null -ne $mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch { Write-Verbose $_.Exception.Message }
            }
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-WorkshopBootstrapLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject] $Lease)

    if ($Lease.Acquired -and $null -ne $Lease.Mutex) {
        try { $Lease.Mutex.ReleaseMutex() }
        finally {
            $Lease.Acquired = $false
            $Lease.Mutex.Dispose()
        }
    }
}

function Get-WorkshopBootstrapExtensionState {
    [CmdletBinding()]
    param([AllowNull()][object] $Extension)

    if ($null -eq $Extension) { return 'Absent' }
    $known = @{
        succeeded = 'Succeeded'; failed = 'Failed'; canceled = 'Canceled'
        creating = 'Creating'; updating = 'Updating'; deleting = 'Deleting'; transitioning = 'Transitioning'
    }
    $signals = [System.Collections.Generic.List[string]]::new()
    $invalid = $false
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue($Extension)
    $visited = 0
    while ($pending.Count -gt 0 -and $visited -lt 16) {
        $candidate = $pending.Dequeue()
        $visited++
        if ($null -eq $candidate -or $candidate -is [string] -or $candidate -is [ValueType]) {
            $invalid = $true
            continue
        }
        $candidateProperties = @($candidate.PSObject.Properties | ForEach-Object Name)
        foreach ($wrapperName in @('Resource', 'Value')) {
            if ($candidateProperties -contains $wrapperName) {
                $wrapped = $candidate.$wrapperName
                if ($null -eq $wrapped) { $invalid = $true } else { $pending.Enqueue($wrapped) }
            }
        }
        if ($candidateProperties -contains 'ProvisioningState') {
            $state = $candidate.ProvisioningState
            if ($state -isnot [string] -or [string]::IsNullOrWhiteSpace($state) -or
                -not $known.ContainsKey($state.ToLowerInvariant())) {
                $invalid = $true
            }
            else { $signals.Add($known[$state.ToLowerInvariant()]) }
        }
        foreach ($statusContainer in @(
            @{ Parent = $candidate; Name = 'Statuses' },
            @{ Parent = if ($candidateProperties -contains 'InstanceView') { $candidate.InstanceView } else { $null }; Name = 'Statuses' }
        )) {
            $parent = $statusContainer.Parent
            $parentProperties = if ($null -eq $parent) { @() } else { @($parent.PSObject.Properties | ForEach-Object Name) }
            if ($null -eq $parent -or $parentProperties -notcontains $statusContainer.Name) { continue }
            $statuses = @($parent.($statusContainer.Name))
            if ($statuses.Count -eq 0) { $invalid = $true; continue }
            foreach ($status in $statuses) {
                $statusProperties = if ($null -eq $status) { @() } else { @($status.PSObject.Properties | ForEach-Object Name) }
                if ($null -eq $status -or $statusProperties -notcontains 'Code' -or
                    $status.Code -isnot [string] -or
                    $status.Code -notmatch '(?i)^provisioningstate/([a-z]+)(?:/.*)?$' -or
                    -not $known.ContainsKey($Matches[1].ToLowerInvariant())) {
                    $invalid = $true
                }
                else { $signals.Add($known[$Matches[1].ToLowerInvariant()]) }
            }
        }
    }
    $distinct = @($signals | Sort-Object -Unique)
    # A truncated traversal may have dropped a contradicting signal, so fail closed.
    if ($pending.Count -gt 0) { $invalid = $true }
    if ($invalid -or $distinct.Count -ne 1) { return 'Unknown' }
    $distinct[0]
}

function Invoke-WorkshopBootstrapExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Sql', 'Admin')][string] $Role,
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $ArchiveUri,
        [Parameter(Mandatory)][hashtable] $ProtectedPayload,
        [Parameter(Mandatory)][hashtable] $Operations
    )

    $isSql = $Role -eq 'Sql'
    $vm = if ($isSql) { $Config.SqlVm } else { $Config.AdminVm }
    $scriptName = if ($isSql) { 'Initialize-SqlVm.ps1' } else { 'Initialize-AdminVm.ps1' }
    $readinessPath = if ($isSql) {
        'C:\McpSqlWorkshop\evidence\sql-vm-readiness.json'
    }
    else {
        'C:\McpSqlWorkshop\evidence\admin-vm-readiness.json'
    }
    $lease = $null
    $protectedEnvelope = $null
    $primaryError = $null
    $releaseError = $null
    try {
        $lease = & $Operations.AcquireDeploymentLock ([string] (& $Operations.GetSubscriptionId)) `
            $Config.ResourceGroupName $vm.Name
        $lockedExtension = & $Operations.GetExtension $vm.Name $Config.ResourceGroupName $scriptName
        $lockedState = Get-WorkshopBootstrapExtensionState -Extension $lockedExtension
        if ($lockedState -eq 'Unknown') {
            throw "$Role bootstrap extension state is Unknown and cannot be safely reconciled."
        }
        if ($lockedState -in @('Creating', 'Updating', 'Deleting', 'Transitioning')) {
            throw "$Role bootstrap extension has an active operation in state '$lockedState'."
        }
        $recipientCertificate = & $Operations.GetRecipientCertificate $vm.Name $Config.ResourceGroupName
        if ([string]::IsNullOrWhiteSpace([string]$recipientCertificate)) {
            throw "$Role bootstrap payload recipient certificate was not returned."
        }
        $protectedEnvelope = & $Operations.ProtectPayload $recipientCertificate $ProtectedPayload
        if ([string]::IsNullOrWhiteSpace([string]$protectedEnvelope)) {
            throw "$Role bootstrap payload encryption did not return a CMS envelope."
        }
        $null = & $Operations.StageBootstrapFiles $vm.Name $Config.ResourceGroupName `
            $protectedEnvelope $scriptName $ProtectedPayload.RepositoryCommit $ProtectedPayload.DeploymentId
        $null = & $Operations.SetExtension $vm.Name $Config.ResourceGroupName $Config.Location `
            $ArchiveUri $protectedEnvelope $scriptName $ProtectedPayload.RepositoryCommit $ProtectedPayload.DeploymentId
        $extension = & $Operations.GetExtension $vm.Name $Config.ResourceGroupName $scriptName
        $status = Get-WorkshopBootstrapExtensionState -Extension $extension
        if ($status -cne 'Succeeded') {
            throw "$Role bootstrap extension did not report a succeeded provisioning state."
        }
        $readiness = & $Operations.ReadReadiness $vm.Name $Config.ResourceGroupName $readinessPath
        $readinessDeploymentProperty = if ($null -eq $readiness) {
            $null
        }
        else {
            $readiness.PSObject.Properties['DeploymentId']
        }
        $readinessDeploymentId = if ($null -eq $readinessDeploymentProperty) {
            $null
        }
        else {
            $readinessDeploymentProperty.Value
        }
        if ($null -eq $readiness -or $readiness.Completed -isnot [bool] -or -not $readiness.Completed -or
            [string] $readinessDeploymentId -cne [string] $ProtectedPayload.DeploymentId) {
            throw "$Role bootstrap readiness did not report Completed=true for the expected deployment."
        }
    }
    catch { $primaryError = $_ }
    finally {
        $protectedEnvelope = $null
        if ($null -ne $lease) {
            try { $null = & $Operations.ReleaseDeploymentLock $lease }
            catch { $releaseError = $_ }
        }
    }
    if ($null -ne $releaseError) {
        if ($null -ne $primaryError) {
            throw [InvalidOperationException]::new(
                "$($primaryError.Exception.Message) Local bootstrap lock release also failed: $($releaseError.Exception.Message)",
                $primaryError.Exception
            )
        }
        throw $releaseError
    }
    if ($null -ne $primaryError) { throw $primaryError }
    [pscustomobject][ordered]@{
        Completed = $true
        Checkpoint = @("$Role bootstrap extension succeeded", "$Role readiness positively read")
        Readiness = $readiness
    }
}

function Initialize-WorkshopSqlVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][PSCredential] $AdministratorCredential,
        [Parameter(Mandatory)][Security.SecureString] $DatabaseMasterKeyPassword,
        [Parameter(Mandatory)][Security.SecureString] $McpReaderPassword,
        [Parameter(Mandatory)][ValidatePattern('^https://github\.com/[^/]+/[^/]+(?:\.git)?$')][string] $RepositoryUrl,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $RepositoryCommit,
        [Parameter(Mandatory)][ValidateScript({
            # Must match the canonical form the guest bootstrap validates, or the mismatch
            # would only surface inside the VM.
            [guid] $parsed = [guid]::Empty
            [guid]::TryParseExact($_, 'D', [ref] $parsed) -and $parsed.ToString('D') -ceq $_
        })][string] $DeploymentId,
        [hashtable] $Operations
    )

    if ($null -eq $AdministratorCredential -or
        [string]::IsNullOrWhiteSpace($AdministratorCredential.UserName) -or
        $AdministratorCredential.Password.Length -eq 0 -or
        $DatabaseMasterKeyPassword.Length -eq 0 -or $McpReaderPassword.Length -eq 0) {
        throw 'SQL bootstrap secrets must be nonempty SecureString values.'
    }
    $archiveUri = Get-WorkshopBootstrapArchiveUri -RepositoryUrl $RepositoryUrl -RepositoryCommit $RepositoryCommit
    if ($Config.AdventureWorksBackup.Uri -cne 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak' -or
        $Config.AdventureWorksBackup.Sha256 -notmatch '^[A-F0-9]{64}$') {
        throw 'AdventureWorks backup source or expected SHA256 is not approved.'
    }
    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopBootstrapOperationSet }
    Assert-WorkshopBootstrapOperationSet -Operations $Operations
    $administratorSecret = $null
    $masterKeySecret = $null
    $readerSecret = $null
    $payload = $null
    try {
        $administratorSecret = ConvertFrom-WorkshopSecureString $AdministratorCredential.Password
        $masterKeySecret = ConvertFrom-WorkshopSecureString $DatabaseMasterKeyPassword
        $readerSecret = ConvertFrom-WorkshopSecureString $McpReaderPassword
        $payload = @{
            ExpectedVmName = [string] $Config.SqlVm.Name
            ExpectedVmSize = [string] $Config.SqlVm.Size
            ExpectedLocation = [string] $Config.Location
            AdministratorUserName = [string] $AdministratorCredential.UserName
            AdministratorSecret = $administratorSecret
            DataDiskGiB = [int] $Config.SqlVm.DataDiskGiB
            LogDiskGiB = [int] $Config.SqlVm.LogDiskGiB
            RepositoryRoot = "C:\McpSqlWorkshop\deployments\$DeploymentId\repo"
            RepositoryCommit = $RepositoryCommit
            AdventureWorksBackupUri = [string] $Config.AdventureWorksBackup.Uri
            AdventureWorksBackupSha256 = [string] $Config.AdventureWorksBackup.Sha256
            DeploymentId = $DeploymentId
            DatabaseMasterKeySecret = $masterKeySecret
            McpReaderSecret = $readerSecret
        }
        Invoke-WorkshopBootstrapExtension -Role Sql -Config $Config -ArchiveUri $archiveUri `
            -ProtectedPayload $payload -Operations $Operations
    }
    finally {
        $administratorSecret = $null
        $masterKeySecret = $null
        $readerSecret = $null
        if ($null -ne $payload) {
            $payload.AdministratorSecret = $null
            $payload.DatabaseMasterKeySecret = $null
            $payload.McpReaderSecret = $null
        }
    }
}

function Initialize-WorkshopAdminVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][Security.SecureString] $McpReaderPassword,
        [Parameter(Mandatory)][ValidatePattern('^https://github\.com/[^/]+/[^/]+(?:\.git)?$')][string] $RepositoryUrl,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $RepositoryCommit,
        [Parameter(Mandatory)][ValidateScript({
            # Must match the canonical form the guest bootstrap validates, or the mismatch
            # would only surface inside the VM.
            [guid] $parsed = [guid]::Empty
            [guid]::TryParseExact($_, 'D', [ref] $parsed) -and $parsed.ToString('D') -ceq $_
        })][string] $DeploymentId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $InteractiveUserName,
        [Parameter(Mandatory)][bool] $WindowsClientLicenseAttested,
        [Parameter(Mandatory)][psobject] $SqlReadiness,
        [string] $NugetPackagesPath,
        [string] $NugetConfigPath,
        [hashtable] $Operations
    )

    if ($McpReaderPassword.Length -eq 0) { throw 'MCP reader secret must be a nonempty SecureString.' }
    $archiveUri = Get-WorkshopBootstrapArchiveUri -RepositoryUrl $RepositoryUrl -RepositoryCommit $RepositoryCommit
    if ($null -eq $Operations) { $Operations = Get-DefaultWorkshopBootstrapOperationSet }
    Assert-WorkshopBootstrapOperationSet -Operations $Operations -Admin
    if (-not $SqlReadiness.Completed -or -not $SqlReadiness.Certificate.PublicCertificateSha256) {
        throw 'Verified SQL readiness with a public certificate fingerprint is required.'
    }
    $publicCertificate = & $Operations.ReadPublicCertificate $Config.SqlVm.Name $Config.ResourceGroupName `
        ([string]$SqlReadiness.Certificate.PublicCertificatePath)
    $readerSecret = $null
    $payload = $null
    try {
        $readerSecret = ConvertFrom-WorkshopSecureString $McpReaderPassword
        $payload = @{
            ExpectedVmName = [string] $Config.AdminVm.Name
            ExpectedVmSize = [string] $Config.AdminVm.Size
            ExpectedLocation = [string] $Config.Location
            RepositoryRoot = 'C:\McpSqlWorkshop\workspace'
            RepositoryUrl = $RepositoryUrl
            RepositoryCommit = $RepositoryCommit
            DeploymentId = $DeploymentId
            InteractiveUserName = $InteractiveUserName
            WindowsClientLicenseAttested = $WindowsClientLicenseAttested
            McpReaderSecret = $readerSecret
            PublicCertificateBase64 = [string] $publicCertificate
            PublicCertificateSha256 = [string] $SqlReadiness.Certificate.PublicCertificateSha256
            CertificateThumbprint = [string] $SqlReadiness.Certificate.Thumbprint
            NugetPackagesPath = $NugetPackagesPath
            NugetConfigPath = $NugetConfigPath
        }
        Invoke-WorkshopBootstrapExtension -Role Admin -Config $Config -ArchiveUri $archiveUri `
            -ProtectedPayload $payload -Operations $Operations
    }
    finally {
        $readerSecret = $null
        if ($null -ne $payload) {
            $payload.McpReaderSecret = $null
            $payload.PublicCertificateBase64 = $null
        }
    }
}

function ConvertTo-WorkshopCanonicalValue {
    [CmdletBinding()]
    param([AllowNull()][object] $Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $canonical = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $canonical[$key] = ConvertTo-WorkshopCanonicalValue $Value[$key]
        }
        return $canonical
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-WorkshopCanonicalValue $_ })
    }
    $canonical = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
        $canonical[$property.Name] = ConvertTo-WorkshopCanonicalValue $property.Value
    }
    $canonical
}

function Get-WorkshopCanonicalRecordSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject] $Record)

    $canonicalJson = ConvertTo-WorkshopCanonicalValue $Record | ConvertTo-Json -Depth 100 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($canonicalJson)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Test-WorkshopReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $SqlReadiness,
        [Parameter(Mandatory)][psobject] $AdminReadiness
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    function Get-ReadinessValue {
        param([AllowNull()][object] $Record, [Parameter(Mandatory)][string] $Path)
        $value = $Record
        foreach ($segment in $Path.Split('.')) {
            if ($null -eq $value) { return $null }
            $property = $value.PSObject.Properties[$segment]
            if ($null -eq $property) { return $null }
            $value = $property.Value
        }
        $value
    }
    function Test-ExactSet {
        param([AllowNull()][object[]] $Actual, [Parameter(Mandatory)][string[]] $Expected)
        $actualSet = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        ($actualSet | ConvertTo-Json -Compress) -ceq (($Expected | Sort-Object) | ConvertTo-Json -Compress)
    }
    $expectedTools = @(
        'aggregate_records', 'compare_workshop_runs', 'describe_entities', 'execute_entity',
        'get_active_workshop_grants', 'get_memory_snapshot', 'get_procedure_plan_summary',
        'get_query_store_top_queries', 'get_query_store_waits', 'read_records'
    )
    $expectedPackages = @('Microsoft.PowerShell', 'Microsoft.VisualStudioCode', 'Microsoft.SQLServerManagementStudio', 'Microsoft.DotNet.SDK.9', 'Git.Git', 'GitHub.cli')
    $expectedExtensions = @('ms-mssql.mssql', 'GitHub.copilot', 'GitHub.copilot-chat', 'ms-vscode.powershell')
    $actualTools = @(Get-ReadinessValue $AdminReadiness 'Mcp.ToolNames')
    $exactToolAllowlist = Test-ExactSet -Actual $actualTools -Expected $expectedTools
    $packageRecords = @(Get-ReadinessValue $AdminReadiness 'Tools.WingetPackages')
    $packageIds = @($packageRecords | ForEach-Object { Get-ReadinessValue $_ 'Id' })
    $packageVersionsObserved = $packageRecords.Count -eq $expectedPackages.Count -and
        @($packageRecords | Where-Object { [string]::IsNullOrWhiteSpace([string](Get-ReadinessValue $_ 'VersionReadback')) }).Count -eq 0
    $extensionRecords = @(Get-ReadinessValue $AdminReadiness 'Tools.Extensions')
    $extensionIds = @($extensionRecords | ForEach-Object { ([string]$_ -split '@')[0] })
    $disks = @(Get-ReadinessValue $SqlReadiness 'Disks')
    $dataDisk = @($disks | Where-Object { (Get-ReadinessValue $_ 'Lun') -eq 0 })
    $logDisk = @($disks | Where-Object { (Get-ReadinessValue $_ 'Lun') -eq 1 })
    $tempDbFiles = @(Get-ReadinessValue $SqlReadiness 'TempDb.Files')
    $tempDbRoot = [string](Get-ReadinessValue $SqlReadiness 'TempDb.ApprovedRoot')
    $tempDbPrefix = if ([string]::IsNullOrWhiteSpace($tempDbRoot)) { '' } else { $tempDbRoot.TrimEnd('\') + '\' }
    $tempDbPathsValid = $tempDbFiles.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($tempDbPrefix) -and
        @($tempDbFiles | Where-Object { -not ([string](Get-ReadinessValue $_ 'PhysicalName')).StartsWith($tempDbPrefix, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
    $thumbprint = [string](Get-ReadinessValue $SqlReadiness 'Certificate.Thumbprint')
    $publicHash = [string](Get-ReadinessValue $SqlReadiness 'Certificate.PublicCertificateSha256')
    $sqlCommit = [string](Get-ReadinessValue $SqlReadiness 'Repository.Commit')
    $adminCommit = [string](Get-ReadinessValue $AdminReadiness 'Repository.Commit')
    $deploymentId = [string](Get-ReadinessValue $SqlReadiness 'DeploymentId')
    $adminDeploymentId = [string](Get-ReadinessValue $AdminReadiness 'DeploymentId')
    $authStatus = [string](Get-ReadinessValue $AdminReadiness 'Auth.GitHubCliAuthStatus')
    $activation = [string](Get-ReadinessValue $AdminReadiness 'Vm.Activation')
    [guid]$parsedDeploymentId = [guid]::Empty
    $deploymentIdValid = [guid]::TryParseExact($deploymentId, 'D', [ref]$parsedDeploymentId) -and
        $parsedDeploymentId.ToString('D') -ceq $deploymentId
    [version]$parsedDabVersion = [version]'0.0'
    $dabVersionValid = [version]::TryParse(
        [regex]::Match([string](Get-ReadinessValue $AdminReadiness 'Tools.DAB'), '\d+\.\d+\.\d+').Value,
        [ref]$parsedDabVersion
    ) -and $parsedDabVersion -ge [version]'2.0.9'
    foreach ($check in @(
        @{ Name = 'Readiness records complete and sanitized'; Passed = (Get-ReadinessValue $SqlReadiness 'Completed') -eq $true -and (Get-ReadinessValue $AdminReadiness 'Completed') -eq $true -and (Get-ReadinessValue $SqlReadiness 'SchemaVersion') -ceq '1.0' -and (Get-ReadinessValue $AdminReadiness 'SchemaVersion') -ceq '1.0' -and (Get-ReadinessValue $SqlReadiness 'Evidence.Sanitized') -eq $true -and (Get-ReadinessValue $AdminReadiness 'Evidence.Sanitized') -eq $true }
        @{ Name = 'Cross-record deployment identity'; Passed = $deploymentIdValid -and $adminDeploymentId -ceq $deploymentId }
        @{ Name = 'Cross-record immutable repository commit'; Passed = $sqlCommit -match '^[0-9a-f]{40}$' -and $adminCommit -ceq $sqlCommit }
        @{ Name = 'SQL VM exact identity and private boundary'; Passed = (Get-ReadinessValue $SqlReadiness 'Vm.Name') -ceq 'vm-mcpsql-sql' -and (Get-ReadinessValue $SqlReadiness 'Vm.Size') -ceq 'Standard_E8s_v5' -and (Get-ReadinessValue $SqlReadiness 'Vm.Location') -ceq 'indonesiacentral' -and (Get-ReadinessValue $SqlReadiness 'Vm.PublicIp') -eq $false }
        @{ Name = 'SQL VM Trusted Launch'; Passed = (Get-ReadinessValue $SqlReadiness 'Vm.SecureBoot') -eq $true -and (Get-ReadinessValue $SqlReadiness 'Vm.Tpm') -eq $true }
        @{ Name = 'SQL Server exact product and service'; Passed = (Get-ReadinessValue $SqlReadiness 'Sql.Version') -eq 16 -and ([string](Get-ReadinessValue $SqlReadiness 'Sql.Edition')) -match 'Enterprise' -and -not [string]::IsNullOrWhiteSpace([string](Get-ReadinessValue $SqlReadiness 'Sql.Service')) -and (Get-ReadinessValue $SqlReadiness 'Sql.State') -ceq 'Running' -and (Get-ReadinessValue $SqlReadiness 'Sql.Port') -eq 1433 -and (Get-ReadinessValue $SqlReadiness 'Sql.BrowserStartupType') -ceq 'Disabled' }
        @{ Name = 'SQL exact data and log disks'; Passed = $disks.Count -eq 2 -and $dataDisk.Count -eq 1 -and $logDisk.Count -eq 1 -and (Get-ReadinessValue $dataDisk[0] 'Drive') -ceq 'F:' -and (Get-ReadinessValue $dataDisk[0] 'Label') -ceq 'SQLData' -and (Get-ReadinessValue $dataDisk[0] 'AllocationUnitSize') -eq 65536 -and (Get-ReadinessValue $dataDisk[0] 'SizeGiB') -eq 256 -and (Get-ReadinessValue $logDisk[0] 'Drive') -ceq 'G:' -and (Get-ReadinessValue $logDisk[0] 'Label') -ceq 'SQLLog' -and (Get-ReadinessValue $logDisk[0] 'AllocationUnitSize') -eq 65536 -and (Get-ReadinessValue $logDisk[0] 'SizeGiB') -eq 128 }
        @{ Name = 'TempDB complete approved placement'; Passed = (Get-ReadinessValue $SqlReadiness 'TempDb.EnoughSpace') -eq $true -and (Get-ReadinessValue $SqlReadiness 'TempDb.FileCount') -eq $tempDbFiles.Count -and $tempDbPathsValid -and (Get-ReadinessValue $SqlReadiness 'TempDb.AllFilesUnderApprovedRoot') -eq $true -and (Get-ReadinessValue $SqlReadiness 'TempDb.OldPathCount') -eq 0 -and ((Get-ReadinessValue $SqlReadiness 'TempDb.Storage') -ceq 'Temporary' -or ((Get-ReadinessValue $SqlReadiness 'TempDb.Storage') -ceq 'ManagedData' -and -not [string]::IsNullOrWhiteSpace([string](Get-ReadinessValue $SqlReadiness 'TempDb.Deviation')))) }
        @{ Name = 'SQL firewall and Browser boundary'; Passed = (Get-ReadinessValue $SqlReadiness 'Firewall.Rule') -ceq 'MCP SQL Workshop 1433' -and (Get-ReadinessValue $SqlReadiness 'Firewall.RemoteAddress') -ceq '10.20.1.0/24' -and (Get-ReadinessValue $SqlReadiness 'Firewall.BroadRule') -eq $false }
        @{ Name = 'SQL exact TLS registry and certificate'; Passed = $thumbprint -match '^[A-F0-9]{40}$' -and (Get-ReadinessValue $SqlReadiness 'Certificate.RegistryCertificate') -ceq $thumbprint -and (Get-ReadinessValue $SqlReadiness 'Certificate.StoreThumbprint') -ceq $thumbprint -and (Get-ReadinessValue $SqlReadiness 'Certificate.PublicCertificateThumbprint') -ceq $thumbprint -and (Get-ReadinessValue $SqlReadiness 'Certificate.ForceEncryption') -eq 1 -and (Get-ReadinessValue $SqlReadiness 'Certificate.HasPrivateKey') -eq $true -and (Get-ReadinessValue $SqlReadiness 'Certificate.ServerAuthenticationEku') -eq $true -and (Get-ReadinessValue $SqlReadiness 'Certificate.SanVerified') -eq $true -and (Get-ReadinessValue $SqlReadiness 'Certificate.ServiceKeyAclVerified') -eq $true -and (Get-ReadinessValue $SqlReadiness 'Certificate.PrivateKeyExported') -eq $false -and $publicHash -match '^[A-F0-9]{64}$' -and (Get-ReadinessValue $SqlReadiness 'Certificate.TlsLoadFailures') -eq 0 -and (Get-ReadinessValue $SqlReadiness 'Certificate.StartupBindingEvidence') -in @('ExactThumbprint', 'DeferredRemoteValidation') }
        @{ Name = 'SQL backup and pre-candidate database configuration'; Passed = (Get-ReadinessValue $SqlReadiness 'Backup.VerifyOnly') -eq $true -and (Get-ReadinessValue $SqlReadiness 'Backup.ChecksumClassification') -ceq 'expected-verified' -and ([string](Get-ReadinessValue $SqlReadiness 'Backup.Sha256')) -ceq ([string](Get-ReadinessValue $SqlReadiness 'Backup.ExpectedSha256')) -and ([string](Get-ReadinessValue $SqlReadiness 'Backup.ExpectedSha256')) -match '^[A-F0-9]{64}$' -and (Get-ReadinessValue $SqlReadiness 'Database.Marker') -ceq '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C' -and (Get-ReadinessValue $SqlReadiness 'Database.QueryStore') -ceq 'READ_WRITE' -and (Get-ReadinessValue $SqlReadiness 'Database.ResourceGovernor') -ceq 'Enabled' -and (Get-ReadinessValue $SqlReadiness 'Database.ProcedureCount') -eq 7 }
        @{ Name = 'Administration VM exact identity and security'; Passed = (Get-ReadinessValue $AdminReadiness 'Vm.Name') -ceq 'vm-mcpsql-admin' -and (Get-ReadinessValue $AdminReadiness 'Vm.Size') -ceq 'Standard_D4s_v5' -and (Get-ReadinessValue $AdminReadiness 'Vm.Location') -ceq 'indonesiacentral' -and (Get-ReadinessValue $AdminReadiness 'Vm.AdminPublicIpBoundaryObserved') -eq $true -and (Get-ReadinessValue $AdminReadiness 'Vm.PublicIpCount') -eq 1 -and (Get-ReadinessValue $AdminReadiness 'Vm.SecureBoot') -eq $true -and (Get-ReadinessValue $AdminReadiness 'Vm.Tpm') -eq $true -and ([string](Get-ReadinessValue $AdminReadiness 'Vm.Os')) -match 'Windows 11 Enterprise' -and [int](Get-ReadinessValue $AdminReadiness 'Vm.Build') -ge 26100 -and (Get-ReadinessValue $AdminReadiness 'Vm.WindowsClientLicenseAttested') -eq $true -and $activation -in @('Licensed', 'ObservedUnknown') }
        @{ Name = 'Administration exact tools and extensions'; Passed = (Test-ExactSet -Actual $packageIds -Expected $expectedPackages) -and $packageVersionsObserved -and (Test-ExactSet -Actual $extensionIds -Expected $expectedExtensions) -and $dabVersionValid }
        @{ Name = 'Administration workspace and environment ACLs'; Passed = (Get-ReadinessValue $AdminReadiness 'Workspace.WorkspaceUserModify') -eq $true -and (Get-ReadinessValue $AdminReadiness 'RootEnvAcl.Path') -ceq 'C:\McpSqlWorkshop\workspace\.env' -and (Get-ReadinessValue $AdminReadiness 'RootEnvAcl.Restricted') -eq $true -and (Get-ReadinessValue $AdminReadiness 'RootEnvAcl.EnvAclRestricted') -eq $true }
        @{ Name = 'Administration private network checks'; Passed = (Get-ReadinessValue $AdminReadiness 'Network.DnsName') -ceq 'sql01.mcpworkshop.internal' -and (Get-ReadinessValue $AdminReadiness 'Network.ResolvedAddress') -ceq '10.20.2.10' -and (Get-ReadinessValue $AdminReadiness 'Network.Tcp1433') -eq $true }
        @{ Name = 'Administration validated SQL TLS'; Passed = (Get-ReadinessValue $AdminReadiness 'SqlTls.EncryptOption') -ceq 'TRUE' -and (Get-ReadinessValue $AdminReadiness 'SqlTls.TrustServerCertificate') -eq $false -and (Get-ReadinessValue $AdminReadiness 'SqlTls.CertificateValidated') -eq $true -and (Get-ReadinessValue $AdminReadiness 'SqlTls.ValidationMethod') -ceq 'SqlClientChainHostAndTransferredCertificate' -and (Get-ReadinessValue $AdminReadiness 'SqlTls.RemoteAdminTest') -eq $true -and (Get-ReadinessValue $AdminReadiness 'SqlTls.CertificateThumbprint') -ceq $thumbprint -and (Get-ReadinessValue $AdminReadiness 'SqlTls.PublicCertificateSha256') -ceq $publicHash -and (Get-ReadinessValue $AdminReadiness 'SqlTls.HostNameInCertificate') -ceq 'sql01.mcpworkshop.internal' }
        @{ Name = 'MCP configuration and exact tool allowlist valid'; Passed = (Get-ReadinessValue $AdminReadiness 'Mcp.ConfigValid') -eq $true -and (Get-ReadinessValue $AdminReadiness 'Mcp.DabMinimumVersionMet') -eq $true -and (Get-ReadinessValue $AdminReadiness 'Mcp.ForbiddenMutationTools') -eq $false -and $exactToolAllowlist }
        @{ Name = 'Authentication observations explicit'; Passed = $authStatus -in @('Authenticated', 'NotAuthenticated', 'Unavailable') -and (Get-ReadinessValue $AdminReadiness 'Auth.CopilotAuthStatus') -ceq 'InteractiveSignInRequired' }
    )) {
        Add-WorkshopCheck -Checks $checks -Name $check.Name -Passed ([bool]$check.Passed) `
            -Detail $(if ($check.Passed) { 'Verified.' } else { 'Not verified.' }) `
            -Remediation 'Correct the failed bootstrap checkpoint and rerun the idempotent bootstrap.'
    }
    if ($activation -ceq 'ObservedUnknown' -and (Get-ReadinessValue $AdminReadiness 'Vm.WindowsClientLicenseAttested') -eq $true) {
        $checks.Add([pscustomobject][ordered]@{
            Name = 'Administration activation observation'
            Status = 'Warning'
            Detail = 'Activation was observed but not confirmed; Windows client licensing was explicitly attested.'
            Remediation = 'Confirm activation interactively before the workshop if required by organizational policy.'
        })
    }
    [pscustomobject][ordered]@{
        Passed = @($checks | Where-Object Status -EQ 'Failed').Count -eq 0
        Checks = $checks.ToArray()
        SourceHashes = [pscustomobject][ordered]@{
            Algorithm = 'SHA-256'
            Canonicalization = 'SortedObjectPropertiesUtf8JsonV1'
            SqlReadinessSha256 = Get-WorkshopCanonicalRecordSha256 -Record $SqlReadiness
            AdminReadinessSha256 = Get-WorkshopCanonicalRecordSha256 -Record $AdminReadiness
        }
    }
}

function Export-WorkshopDeploymentEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $SqlReadiness,
        [Parameter(Mandatory)][psobject] $AdminReadiness,
        [Parameter(Mandatory)][psobject] $ReadinessResult,
        [Parameter(Mandatory)][string] $OutputDirectory
    )

    & (Join-Path $PSScriptRoot 'Capture-DeploymentEvidence.ps1') -SqlReadiness $SqlReadiness `
        -AdminReadiness $AdminReadiness -ReadinessResult $ReadinessResult -OutputDirectory $OutputDirectory
}

Export-ModuleMember -Function @(
    'Assert-WorkshopHostCidr'
    'New-WorkshopNetworkModel'
    'New-WorkshopNetwork'
    'Resolve-WorkshopImageVersion'
    'New-WorkshopAdminVm'
    'New-WorkshopSqlVm'
    'Register-WorkshopSqlIaas'
    'Set-WorkshopAutoShutdown'
    'Stop-WorkshopEnvironment'
    'Remove-WorkshopEnvironment'
    'Get-WorkshopPlan'
    'Test-WorkshopPrerequisites'
    'Test-WorkshopNetworkBoundary'
    'Test-WorkshopVmBoundary'
    'Format-WorkshopPlanCard'
    'Initialize-WorkshopSqlVm'
    'Initialize-WorkshopAdminVm'
    'Test-WorkshopReadiness'
    'Export-WorkshopDeploymentEvidence'
)
