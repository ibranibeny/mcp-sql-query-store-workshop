@{
    RootModule = 'Workshop.Workload.psm1'
    ModuleVersion = '0.1.0'
    GUID = '8f858a36-53dd-4e43-baa0-b2ee43e9d986'
    Author = 'ibranibeny'
    CompanyName = 'Community'
    Copyright = '(c) 2026 ibranibeny. MIT License.'
    Description = 'Pure bounded workload decisions and truthful workshop evidence serialization.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Get-GrantUtilization'
        'Test-TargetBand'
        'Test-WorkshopSafetySample'
        'Get-WorkshopOutcome'
        'New-WorkshopRunRecord'
        'ConvertTo-WorkshopEvidence'
        'Get-WorkshopApplicationName'
        'Get-WorkshopParameterSchedule'
        'Get-WorkshopTrialSequence'
        'ConvertFrom-WorkshopTrialReader'
        'Get-WorkshopTrialAssessment'
        'Test-WorkshopFingerprintMatch'
        'Test-WorkshopPreflight'
        'Invoke-WorkshopExperiment'
        'Get-WorkshopKillPlan'
        'Export-WorkshopEvidenceFile'
        'Get-WorkshopSqlOperationSet'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('SQL', 'Workshop', 'Evidence')
            LicenseUri = 'https://opensource.org/license/mit'
        }
    }
}
