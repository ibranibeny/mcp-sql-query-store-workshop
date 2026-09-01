@{
    RootModule = 'Workshop.Azure.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'ecb2eaf1-c05b-493e-a444-0f39ea8c7394'
    Author = 'ibranibeny'
    CompanyName = 'Community'
    Copyright = '(c) 2026 ibranibeny. MIT License.'
    Description = 'Workshop planning, prerequisite validation, private deployment, and verified lifecycle automation.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
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
