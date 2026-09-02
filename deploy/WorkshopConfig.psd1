@{
    Location = 'indonesiacentral'
    ResourceGroupName = 'rg-mcp-sql-workshop'
    VNet = @{ Name = 'vnet-mcpsql-workshop'; AddressPrefix = '10.20.0.0/16' }
    AdminSubnet = @{ Name = 'snet-admin'; Prefix = '10.20.1.0/24'; DefaultOutboundAccess = $false }
    SqlSubnet = @{ Name = 'snet-sql'; Prefix = '10.20.2.0/24'; DefaultOutboundAccess = $false }
    AdminAsg = 'asg-mcpsql-admin'
    SqlAsg = 'asg-mcpsql-sql'
    PrivateDnsZone = 'mcpworkshop.internal'
    SqlPrivateIp = '10.20.2.10'
    ApprovedRepositoryUrl = 'https://github.com/ibranibeny/mcp-sql-query-store-workshop'
    AdventureWorksBackup = @{
        Uri = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak'
        Sha256 = 'D17567ADB1521F972E1DC183A7216CEA869C4580B5D75632425BCADBAF82CE5E'
    }
    AdminVm = @{
        Name = 'vm-mcpsql-admin'
        Size = 'Standard_D4s_v5'
        Publisher = 'MicrosoftWindowsDesktop'
        Offer = 'windows-11'
        Sku = 'win11-24h2-ent'
        OsDiskGiB = 128
    }
    SqlVm = @{
        Name = 'vm-mcpsql-sql'
        Size = 'Standard_E8s_v5'
        Publisher = 'MicrosoftSQLServer'
        Offer = 'SQL2022-WS2022'
        Sku = 'enterprise-gen2'
        OsDiskGiB = 128
        DataDiskGiB = 256
        LogDiskGiB = 128
        LicenseType = 'PAYG'
    }
    AutoShutdownTime = '1900'
    AutoShutdownLocation = 'southeastasia'
    Tags = @{ environment = 'workshop'; workload = 'mcp-sql'; managedBy = 'PowerShell'; costconstraint = 'ignore' }
}
