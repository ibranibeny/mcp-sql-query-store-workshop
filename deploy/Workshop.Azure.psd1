@{
    RootModule = 'Workshop.Azure.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'ecb2eaf1-c05b-493e-a444-0f39ea8c7394'
    Author = 'ibranibeny'
    CompanyName = 'Community'
    Copyright = '(c) 2026 ibranibeny. MIT License.'
    Description = 'Workshop planning, prerequisite validation, and private network deployment.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Assert-WorkshopHostCidr'
        'New-WorkshopNetworkModel'
        'New-WorkshopNetwork'
        'Get-WorkshopPlan'
        'Test-WorkshopPrerequisites'
        'Test-WorkshopNetworkBoundary'
        'Format-WorkshopPlanCard'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Azure', 'Workshop', 'Preflight')
            LicenseUri = 'https://opensource.org/license/mit'
        }
    }
}
