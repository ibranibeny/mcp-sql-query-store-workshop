Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psd1'
    Import-Module $script:ModulePath -Force

    function Get-TestSetting {
        [ordered]@{
            workers = 2
            maximumDurationSeconds = 300
            sampleIntervalSeconds = 5
            workerRampSeconds = 20
            resourcePool = 'mcp_sql_workshop_pool'
            workloadGroup = 'mcp_sql_workshop_group'
            maxServerMemoryMB = 49152
            databaseScopedConfigurationHash = 'f17f4c4220d254854e22408ef682ff809567b66df49560b17a21169614ee0dc4'
            dataHash = ('a' * 64)
            indexStatisticsHash = ('b' * 64)
            procedureHash = ('c' * 64)
            validationBatchHash = ('d' * 64)
            parameterSchedule = @('2025-01-01/2025-02-01', '2025-02-01/2025-03-01')
            parameterScheduleHash = '095562b669618122fb74005f471f9c67e41e88a1e8ad0398ef0cc593170b1bb1'
        }
    }

    function Get-TestEnvironment {
        [ordered]@{
            sqlVersion = '16.0.1135.2'
            sqlEdition = 'Enterprise Edition (64-bit)'
            physicalMemoryMB = 65536
        }
    }

    function Get-TestTargetBand {
        [ordered]@{
            baseline = [ordered]@{ minimum = 75; maximum = 85 }
            optimized = [ordered]@{ minimum = 35; maximum = 45 }
        }
    }

    function Get-MeasuredRun {
        $run = New-WorkshopRunRecord -Phase Comparison -Status Completed `
            -EvidenceClassification LAB-MEASURED -FrozenSettings (Get-TestSetting) `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand) `
            -StartUtc ([datetimeoffset]'2026-09-01T10:00:00Z') `
            -EndUtc ([datetimeoffset]'2026-09-01T10:01:00Z')
        $run | Add-Member NoteProperty Trials (Get-ValidTrial)
        return $run
    }

    function Get-ValidTrial {
        $phases = @('Baseline','Optimized','Optimized','Baseline','Optimized','Baseline','Baseline','Optimized','Baseline','Optimized','Optimized','Baseline')
        for ($index = 0; $index -lt 12; $index++) {
            $optimized = $phases[$index] -eq 'Optimized'
            [pscustomobject][ordered]@{
                TrialSequence=$index+1; ParameterSlot=[math]::Floor($index/2)+1; Phase=$phases[$index]
                DurationMs=$(if ($optimized) { 9 } else { 10 }); CpuMs=5; LogicalReads=20; GrantedKB=30; UsedKB=25; SpillKB=0; WaitMs=1
                ResultRowCount=2; ResultHash=('ab'*32); ExpectedRowCount=2; ActualRowCount=2
                DifferenceCount=0; Correct=$true; ValidationBatchID='11111111-1111-1111-1111-111111111111'
                StartedAtUtc='2026-09-01T10:00:00.0000000Z'; CompletedAtUtc='2026-09-01T10:00:01.0000000Z'
            }
        }
    }

    function Get-ValidSample {
        @(
            [ordered]@{
                sequence = 1; timestampUtc = '2026-09-01T10:00:05.0000000Z'; phase = 'Baseline'
                grantedKb = 800; totalKb = 1000; grantUtilizationPercent = 80
                hostUsedPercent = 70; hostAvailableMB = 12000
                processPhysicalLow = $false; processVirtualLow = $false
            }
            [ordered]@{
                sequence = 2; timestampUtc = '2026-09-01T10:00:10.0000000Z'; phase = 'Optimized'
                grantedKb = 400; totalKb = 1000; grantUtilizationPercent = 40
                hostUsedPercent = 71; hostAvailableMB = 11800
                processPhysicalLow = $false; processVirtualLow = $false
            }
        )
    }

    function Get-ValidRequestSample {
        @(
            [ordered]@{
                sampleSequence=1; sessionId=51; requestId=0; requestedMemoryKB=1000; grantedMemoryKB=900
                requiredMemoryKB=100; idealMemoryKB=1200; usedMemoryKB=800; maxUsedMemoryKB=850
                waitOrder=$null; waitTimeMs=100; queryId=$null; planId=$null
            }
            [ordered]@{
                sampleSequence=2; sessionId=52; requestId=0; requestedMemoryKB=500; grantedMemoryKB=450
                requiredMemoryKB=100; idealMemoryKB=600; usedMemoryKB=400; maxUsedMemoryKB=425
                waitOrder=$null; waitTimeMs=20; queryId=$null; planId=$null
            }
        )
    }

    function Get-ValidValidation {
        param([object[]] $Trials = (Get-ValidTrial))
        $assessment = Get-WorkshopTrialAssessment -Trials $Trials
        $linkage = @($assessment.Trials | ForEach-Object {
            [ordered]@{
                sequence = [int]$_.TrialSequence
                slot = [int]$_.ParameterSlot
                phase = [string]$_.Phase
                resultRowCount = [int64]$_.ResultRowCount
                resultHash = ([string]$_.ResultHash).ToLowerInvariant()
                expectedRowCount = [int64]$_.ExpectedRowCount
                actualRowCount = [int64]$_.ActualRowCount
                differenceCount = [int64]$_.DifferenceCount
                correct = [bool]$_.Correct
                validationBatchId = ([guid]$_.ValidationBatchID).ToString('D')
            }
        })
        $json = ConvertTo-Json $linkage -Depth 8 -Compress
        $hash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))
        ).ToLowerInvariant()
        [ordered]@{
            passed = $assessment.CorrectnessPassed
            materialRegression = $assessment.MaterialRegression
            additionalMetricImproved = $assessment.AdditionalMetricImproved
            validationHash = $hash
        }
    }
}

Describe 'Workshop workload module contract' {
    It 'exports the workload decision, orchestration, stop, and export functions' {
        $manifest = Test-ModuleManifest $ModulePath
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'ConvertFrom-WorkshopTrialReader'
            'ConvertTo-WorkshopEvidence'
            'Export-WorkshopEvidenceFile'
            'Get-GrantUtilization'
            'Get-WorkshopApplicationName'
            'Get-WorkshopKillPlan'
            'Get-WorkshopOutcome'
            'Get-WorkshopParameterSchedule'
            'Get-WorkshopSqlOperationSet'
            'Get-WorkshopTrialAssessment'
            'Get-WorkshopTrialSequence'
            'Invoke-WorkshopExperiment'
            'New-WorkshopRunRecord'
            'Test-TargetBand'
            'Test-WorkshopFingerprintMatch'
            'Test-WorkshopPreflight'
            'Test-WorkshopSafetySample'
        )
        $manifest.PowerShellVersion | Should -Be ([version]'7.4')
    }
}

Describe 'Get-GrantUtilization' {
    It 'returns a stable decimal percentage' {
        $result = Get-GrantUtilization -GrantedKb 1 -TotalKb 3
        $result | Should -BeOfType ([decimal])
        $result | Should -Be ([decimal]'33.333333')
    }

    It 'accepts the exact resource-semaphore boundaries' {
        Get-GrantUtilization -GrantedKb 0 -TotalKb 1 | Should -Be ([decimal]0)
        Get-GrantUtilization -GrantedKb 10 -TotalKb 10 | Should -Be ([decimal]100)
    }

    It 'rejects invalid finite, sign, total, and ordering values' -ForEach @(
        @{ Granted = -1; Total = 10 }
        @{ Granted = 1; Total = 0 }
        @{ Granted = 1; Total = -1 }
        @{ Granted = 11; Total = 10 }
        @{ Granted = [double]::NaN; Total = 10 }
        @{ Granted = [double]::PositiveInfinity; Total = 10 }
        @{ Granted = 1; Total = [double]::NegativeInfinity }
        @{ Granted = 'not-numeric'; Total = 10 }
    ) {
        { Get-GrantUtilization -GrantedKb $Granted -TotalKb $Total } | Should -Throw
    }
}

Describe 'Test-TargetBand' {
    It 'uses inclusive approved boundaries' -ForEach @(
        @{ Value = 75; Phase = 'Baseline'; Expected = $true }
        @{ Value = 85; Phase = 'Baseline'; Expected = $true }
        @{ Value = [decimal]'74.999'; Phase = 'Baseline'; Expected = $false }
        @{ Value = [decimal]'85.001'; Phase = 'Baseline'; Expected = $false }
        @{ Value = 35; Phase = 'Optimized'; Expected = $true }
        @{ Value = 45; Phase = 'Optimized'; Expected = $true }
        @{ Value = [decimal]'34.999'; Phase = 'Optimized'; Expected = $false }
        @{ Value = [decimal]'45.001'; Phase = 'Optimized'; Expected = $false }
    ) {
        Test-TargetBand -Value $Value -Phase $Phase | Should -Be $Expected
    }

    It 'rejects unknown phases and invalid percentages' -ForEach @(
        @{ Value = 40; Phase = 'Other' }
        @{ Value = -1; Phase = 'Baseline' }
        @{ Value = 101; Phase = 'Optimized' }
        @{ Value = [double]::NaN; Phase = 'Baseline' }
        @{ Value = [double]::PositiveInfinity; Phase = 'Optimized' }
        @{ Value = 'forty'; Phase = 'Optimized' }
    ) {
        { Test-TargetBand -Value $Value -Phase $Phase } | Should -Throw
    }
}

Describe 'Test-WorkshopSafetySample' {
    It 'continues for a healthy sample' {
        $result = Test-WorkshopSafetySample -HostUsedPercent 87.5 -HostAvailableMB 8192 `
            -ProcessPhysicalLow $false -ProcessVirtualLow $false -ConsecutiveHealthFailures 1 `
            -ElapsedSeconds 59 -MaximumDurationSeconds 60 -Phase Baseline -ManualStop $false
        $result.Decision | Should -Be 'Continue'
        $result.Outcome | Should -BeNullOrEmpty
        $result.Reasons | Should -BeNullOrEmpty
    }

    It 'stops at every strict safety boundary' -ForEach @(
        @{ Name = 'host utilization'; Used = [decimal]'87.5001'; Available = 9000; Physical = $false; Virtual = $false; Failures = 0 }
        @{ Name = 'host availability'; Used = 70; Available = [decimal]'8191.999'; Physical = $false; Virtual = $false; Failures = 0 }
        @{ Name = 'physical pressure'; Used = 70; Available = 9000; Physical = $true; Virtual = $false; Failures = 0 }
        @{ Name = 'virtual pressure'; Used = 70; Available = 9000; Physical = $false; Virtual = $true; Failures = 0 }
        @{ Name = 'health failures'; Used = 70; Available = 9000; Physical = $false; Virtual = $false; Failures = 2 }
    ) {
        $result = Test-WorkshopSafetySample -HostUsedPercent $Used -HostAvailableMB $Available `
            -ProcessPhysicalLow $Physical -ProcessVirtualLow $Virtual `
            -ConsecutiveHealthFailures $Failures -ElapsedSeconds 1 -MaximumDurationSeconds 60 `
            -Phase Baseline -ManualStop $false
        $result.Decision | Should -Be 'Stop'
        $result.Outcome | Should -Be 'SafetyStop'
        $result.Reasons.Count | Should -BeGreaterThan 0
    }

    It 'gives manual stop precedence over simultaneous safety and timeout signals' {
        $result = Test-WorkshopSafetySample -HostUsedPercent 99 -HostAvailableMB 1 `
            -ProcessPhysicalLow $true -ProcessVirtualLow $true -ConsecutiveHealthFailures 3 `
            -ElapsedSeconds 60 -MaximumDurationSeconds 60 -Phase Optimized -ManualStop $true
        $result.Decision | Should -Be 'Stop'
        $result.Outcome | Should -Be 'ManualStop'
        $result.Reasons | Should -Contain 'Manual stop requested.'
    }

    It 'returns a phase-aware timeout without claiming a target' -ForEach @(
        @{ Phase = 'Baseline'; Outcome = 'BaselineTargetNotReached' }
        @{ Phase = 'Optimized'; Outcome = 'NoMaterialImprovement' }
    ) {
        $result = Test-WorkshopSafetySample -HostUsedPercent 70 -HostAvailableMB 9000 `
            -ProcessPhysicalLow $false -ProcessVirtualLow $false -ConsecutiveHealthFailures 0 `
            -ElapsedSeconds 60 -MaximumDurationSeconds 60 -Phase $Phase -ManualStop $false
        $result.Decision | Should -Be 'Stop'
        $result.Outcome | Should -Be $Outcome
        $result.Outcome | Should -Not -Be 'TargetMet'
    }

    It 'rejects invalid sample values and durations' -ForEach @(
        @{ Used = [double]::NaN; Available = 9000; Failures = 0; Elapsed = 1; Maximum = 60 }
        @{ Used = 101; Available = 9000; Failures = 0; Elapsed = 1; Maximum = 60 }
        @{ Used = 70; Available = [double]::PositiveInfinity; Failures = 0; Elapsed = 1; Maximum = 60 }
        @{ Used = 70; Available = -1; Failures = 0; Elapsed = 1; Maximum = 60 }
        @{ Used = 70; Available = 9000; Failures = -1; Elapsed = 1; Maximum = 60 }
        @{ Used = 70; Available = 9000; Failures = 0; Elapsed = -1; Maximum = 60 }
        @{ Used = 70; Available = 9000; Failures = 0; Elapsed = 1; Maximum = 0 }
    ) {
        {
            Test-WorkshopSafetySample -HostUsedPercent $Used -HostAvailableMB $Available `
                -ProcessPhysicalLow $false -ProcessVirtualLow $false `
                -ConsecutiveHealthFailures $Failures -ElapsedSeconds $Elapsed `
                -MaximumDurationSeconds $Maximum -Phase Baseline -ManualStop $false
        } | Should -Throw
    }
}

Describe 'Get-WorkshopOutcome' {
    It 'uses the prescribed calls without requiring an additional metric argument' -ForEach @(
        @{ Baseline = 80; Optimized = 40; Expected = 'TargetMet' }
        @{ Baseline = 80; Optimized = 51; Expected = 'ImprovedOutsideTarget' }
    ) {
        Get-WorkshopOutcome -BaselinePeak $Baseline -OptimizedPeak $Optimized `
            -CorrectnessPassed $true -MaterialRegression $false |
            Should -Be $Expected
    }

    It 'treats an explicitly false additional metric result as no material improvement' {
        Get-WorkshopOutcome -BaselinePeak 80 -OptimizedPeak 40 `
            -CorrectnessPassed $true -MaterialRegression $false `
            -AdditionalMetricImproved $false |
            Should -Be 'NoMaterialImprovement'
    }

    It 'returns every exact evidence outcome according to precedence and gates' -ForEach @(
        @{ Expected = 'ManualStop'; Baseline = 80; Optimized = 40; Correct = $true; Regression = $false; Extra = $true; Safety = $true; Manual = $true }
        @{ Expected = 'SafetyStop'; Baseline = 80; Optimized = 40; Correct = $true; Regression = $false; Extra = $true; Safety = $true; Manual = $false }
        @{ Expected = 'BaselineTargetNotReached'; Baseline = 74; Optimized = 40; Correct = $true; Regression = $false; Extra = $true; Safety = $false; Manual = $false }
        @{ Expected = 'TargetMet'; Baseline = 75; Optimized = 45; Correct = $true; Regression = $false; Extra = $true; Safety = $false; Manual = $false }
        @{ Expected = 'ImprovedOutsideTarget'; Baseline = 80; Optimized = 51; Correct = $true; Regression = $false; Extra = $true; Safety = $false; Manual = $false }
        @{ Expected = 'NoMaterialImprovement'; Baseline = 80; Optimized = 56; Correct = $true; Regression = $false; Extra = $true; Safety = $false; Manual = $false }
        @{ Expected = 'Failed'; Baseline = 80; Optimized = 40; Correct = $false; Regression = $false; Extra = $true; Safety = $false; Manual = $false }
        @{ Expected = 'NoMaterialImprovement'; Baseline = 80; Optimized = 40; Correct = $true; Regression = $true; Extra = $true; Safety = $false; Manual = $false }
        @{ Expected = 'NoMaterialImprovement'; Baseline = 80; Optimized = 40; Correct = $true; Regression = $false; Extra = $false; Safety = $false; Manual = $false }
        @{ Expected = 'Failed'; Baseline = 80; Optimized = $null; Correct = $true; Regression = $false; Extra = $true; Safety = $false; Manual = $false }
    ) {
        Get-WorkshopOutcome -BaselinePeak $Baseline -OptimizedPeak $Optimized `
            -CorrectnessPassed $Correct -MaterialRegression $Regression `
            -AdditionalMetricImproved $Extra -SafetyStopped $Safety -ManualStopped $Manual |
            Should -Be $Expected
    }

    It 'requires a measured baseline and never substitutes a target' {
        Get-WorkshopOutcome -BaselinePeak $null -OptimizedPeak 40 -CorrectnessPassed $true `
            -MaterialRegression $false -AdditionalMetricImproved $true |
            Should -Be 'BaselineTargetNotReached'
    }

    It 'uses an inclusive 25 point measured delta' {
        Get-WorkshopOutcome -BaselinePeak 80 -OptimizedPeak 55 -CorrectnessPassed $true `
            -MaterialRegression $false -AdditionalMetricImproved $true |
            Should -Be 'ImprovedOutsideTarget'
    }

    It 'rejects nonfinite and out-of-range measured peaks' -ForEach @(
        @{ Baseline = [double]::NaN; Optimized = 40 }
        @{ Baseline = 80; Optimized = [double]::PositiveInfinity }
        @{ Baseline = -1; Optimized = 40 }
        @{ Baseline = 80; Optimized = 101 }
    ) {
        {
            Get-WorkshopOutcome -BaselinePeak $Baseline -OptimizedPeak $Optimized `
                -CorrectnessPassed $true -MaterialRegression $false `
                -AdditionalMetricImproved $true
        } | Should -Throw
    }
}

Describe 'New-WorkshopRunRecord' {
    It 'canonicalizes case-insensitive enum inputs to schema casing' {
        $record = New-WorkshopRunRecord -Phase baseline -Status planned `
            -EvidenceClassification target -FrozenSettings (Get-TestSetting) `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)

        $record.Phase | Should -BeExactly 'Baseline'
        $record.Status | Should -BeExactly 'Planned'
        $record.EvidenceClassification | Should -BeExactly 'TARGET'
    }

    It 'creates UTC identity metadata and deterministic immutable settings' {
        $settingsA = Get-TestSetting
        $settingsB = [ordered]@{}
        @($settingsA.Keys) | Sort-Object -Descending | ForEach-Object { $settingsB[$_] = $settingsA[$_] }

        $recordA = New-WorkshopRunRecord -Phase Baseline -Status Planned `
            -EvidenceClassification TARGET -FrozenSettings $settingsA `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand) `
            -StartUtc ([datetimeoffset]'2026-09-01T10:00:00+02:00')
        $recordB = New-WorkshopRunRecord -Phase Baseline -Status Planned `
            -EvidenceClassification TARGET -FrozenSettings $settingsB `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand) `
            -StartUtc ([datetimeoffset]'2026-09-01T08:00:00Z')

        { [guid]::Parse($recordA.RunId) } | Should -Not -Throw
        $recordA.StartUtc | Should -Be '2026-09-01T08:00:00.0000000Z'
        $recordA.FrozenSettingsJson | Should -Be $recordB.FrozenSettingsJson
        $recordA.FrozenSettingsHash | Should -Be $recordB.FrozenSettingsHash
        $recordA.FrozenSettingsHash | Should -Match '^[a-f0-9]{64}$'
        { $recordA.FrozenSettings.workers = 4 } | Should -Throw
    }

    It 'changes the canonical frozen settings hash when any database fingerprint changes' -ForEach @(
        @{ Field = 'dataHash' }
        @{ Field = 'indexStatisticsHash' }
        @{ Field = 'procedureHash' }
    ) {
        $original = Get-TestSetting
        $changed = Get-TestSetting
        $changed[$Field] = ('e' * 64)

        $recordA = New-WorkshopRunRecord -Phase Baseline -Status Planned `
            -EvidenceClassification TARGET -FrozenSettings $original `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        $recordB = New-WorkshopRunRecord -Phase Baseline -Status Planned `
            -EvidenceClassification TARGET -FrozenSettings $changed `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)

        $recordA.FrozenSettingsHash | Should -Not -BeExactly $recordB.FrozenSettingsHash
        $recordB.FrozenSettingsJson | Should -Match ('"' + $Field + '":"' + ('e' * 64) + '"')
    }

    It 'rejects missing and malformed frozen database fingerprints' -ForEach @(
        @{ Field = 'dataHash'; Value = $null }
        @{ Field = 'indexStatisticsHash'; Value = ('A' * 64) }
        @{ Field = 'procedureHash'; Value = ('f' * 63) }
    ) {
        $settings = Get-TestSetting
        if ($null -eq $Value) { $settings.Remove($Field) } else { $settings[$Field] = $Value }
        {
            New-WorkshopRunRecord -Phase Baseline -Status Planned `
                -EvidenceClassification TARGET -FrozenSettings $settings `
                -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        } | Should -Throw
    }

    It 'rejects secret-shaped fields recursively' {
        $settings = Get-TestSetting
        $secretKey = -join @(112, 97, 115, 115, 119, 111, 114, 100 | ForEach-Object { [char] $_ })
        $settings[$secretKey] = 'not-a-real-value'
        {
            New-WorkshopRunRecord -Phase Baseline -Status Planned `
                -EvidenceClassification TARGET -FrozenSettings $settings `
                -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        } | Should -Throw
    }

    It 'rejects secret-shaped string values and uppercase hashes' {
        $settings = Get-TestSetting
        $credentialMarker = -join @(80, 97, 115, 115, 119, 111, 114, 100 | ForEach-Object { [char] $_ })
        $settings.resourcePool = "Server=tcp:example;User ID=operator;$credentialMarker=not-real"
        {
            New-WorkshopRunRecord -Phase Baseline -Status Planned `
                -EvidenceClassification TARGET -FrozenSettings $settings `
                -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        } | Should -Throw

        $settings = Get-TestSetting
        $settings.parameterScheduleHash = ('B' * 64)
        {
            New-WorkshopRunRecord -Phase Baseline -Status Planned `
                -EvidenceClassification TARGET -FrozenSettings $settings `
                -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        } | Should -Throw
    }

    It 'rejects assignment-shaped token and secret values recursively without echoing them' -ForEach @(
        @{ Prefix = 'token'; Separator = '=' }
        @{ Prefix = 'access_token'; Separator = ':' }
        @{ Prefix = 'refresh_token'; Separator = '=' }
        @{ Prefix = 'client_secret'; Separator = ':' }
        @{ Prefix = 'secret'; Separator = '=' }
        @{ Prefix = 'AccountKey'; Separator = '=' }
    ) {
        $settings = Get-TestSetting
        $canary = 'do-not-echo-canary'
        $settings.parameterSchedule = @(
            'words such as token and secret are safe in prose',
            @("$Prefix$Separator$canary")
        )
        $caught = $null
        try {
            New-WorkshopRunRecord -Phase Baseline -Status Planned `
                -EvidenceClassification TARGET -FrozenSettings $settings `
                -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        }
        catch {
            $caught = $_
        }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Not -Match $canary
    }

    It 'allows credential words in prose when they are not assignment-shaped' {
        $settings = Get-TestSetting
        $settings.resourcePool = 'Token rotation and password guidance are documented here'
        {
            New-WorkshopRunRecord -Phase Baseline -Status Planned `
                -EvidenceClassification TARGET -FrozenSettings $settings `
                -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        } | Should -Not -Throw
    }

    It 'accepts a single frozen parameter schedule entry' {
        $settings = Get-TestSetting
        $settings.parameterSchedule = @('2025-01-01/2025-02-01')
        $settings.parameterScheduleHash = '14399e9e4a086d2ce435ca2850f8e1bb2802591a87aa7d65f804aa6b9e2a06ef'
        {
            New-WorkshopRunRecord -Phase Baseline -Status Planned `
                -EvidenceClassification TARGET -FrozenSettings $settings `
                -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        } | Should -Not -Throw
    }

    It 'forbids an end timestamp before start' {
        {
            New-WorkshopRunRecord -Phase Comparison -Status Completed `
                -EvidenceClassification LAB-MEASURED -FrozenSettings (Get-TestSetting) `
                -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand) `
                -StartUtc ([datetimeoffset]'2026-09-01T10:00:00Z') `
                -EndUtc ([datetimeoffset]'2026-09-01T09:59:59Z')
        } | Should -Throw
    }

    It 'requires physical memory to be a positive integer within four petabytes' -ForEach @(
        @{ Value = $true }
        @{ Value = [decimal]'65536.5' }
        @{ Value = 0 }
        @{ Value = -1 }
        @{ Value = [decimal]'4294967297' }
    ) {
        $environment = Get-TestEnvironment
        $environment.physicalMemoryMB = $Value
        {
            New-WorkshopRunRecord -Phase Target -Status Planned `
                -EvidenceClassification TARGET -FrozenSettings (Get-TestSetting) `
                -EnvironmentFingerprint $environment -TargetBands (Get-TestTargetBand)
        } | Should -Throw
    }
}

Describe 'ConvertTo-WorkshopEvidence' {
    It 'emits a deterministic ordered schema-shaped measured object' {
        $run = Get-MeasuredRun
        $first = ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
            -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
            -Outcome TargetMet
        $second = ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
            -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
            -Outcome TargetMet

        $first.psobject.Properties.Name | Should -Be @(
            'schemaVersion', 'evidenceClassification', 'disclaimer', 'runId', 'phase', 'status',
            'startUtc', 'endUtc', 'environment', 'frozenSettings', 'frozenSettingsJson',
            'frozenSettingsHash', 'targetBands', 'samples', 'requestSamples', 'trials', 'measuredPeaks',
            'correctness', 'terminationEvidence', 'outcome'
        )
        ($first | ConvertTo-Json -Depth 20 -Compress) | Should -Be `
            ($second | ConvertTo-Json -Depth 20 -Compress)
        $first.measuredPeaks.baseline | Should -Be 80
        $first.measuredPeaks.optimized | Should -Be 40
        $first.frozenSettings.dataHash | Should -BeExactly ('a' * 64)
        $first.frozenSettings.indexStatisticsHash | Should -BeExactly ('b' * 64)
        $first.frozenSettings.procedureHash | Should -BeExactly ('c' * 64)
        $first.targetBands.baseline.minimum | Should -Be 75
        $first.terminationEvidence | ConvertTo-Json -Compress | Should -Be `
            '{"manualStopRequested":false,"safetyStopTriggered":false,"safetyReasons":[],"timeout":false}'
    }

    It 'canonicalizes lowercase record, sample, classification, and outcome values' {
        $run = Get-MeasuredRun
        $run.Phase = 'comparison'
        $run.Status = 'completed'
        $run.EvidenceClassification = 'lab-measured'
        $samples = Get-ValidSample
        $samples[0].phase = 'baseline'
        $samples[1].phase = 'optimized'
        $requests = Get-ValidRequestSample
        $requests[0].phase = 'baseline'
        $requests[1].phase = 'optimized'

        $result = ConvertTo-WorkshopEvidence -RunRecord $run -Samples $samples `
            -RequestSamples $requests -Validation (Get-ValidValidation) -Outcome targetmet

        $result.evidenceClassification | Should -BeExactly 'LAB-MEASURED'
        $result.phase | Should -BeExactly 'Comparison'
        $result.status | Should -BeExactly 'Completed'
        $result.samples.phase | Should -BeExactly @('Baseline', 'Optimized')
        $result.requestSamples.sampleSequence | Should -BeExactly @(1, 2)
        $result.outcome | Should -BeExactly 'TargetMet'
    }

    It 'requires independent safety termination evidence for SafetyStop' {
        $run = Get-MeasuredRun
        $run.Phase = 'Optimized'
        $run.Status = 'SafetyStop'
        $termination = [ordered]@{
            manualStopRequested = $false
            safetyStopTriggered = $true
            safetyReasons = @('Host memory utilization exceeded 87.5 percent.')
            timeout = $false
        }

        $result = ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
            -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
            -TerminationEvidence $termination -Outcome safetystop
        $result.outcome | Should -BeExactly 'SafetyStop'
        $result.terminationEvidence.safetyStopTriggered | Should -BeTrue

        $termination.safetyStopTriggered = $false
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -TerminationEvidence $termination -Outcome SafetyStop } | Should -Throw
    }

    It 'requires independent manual termination evidence for ManualStop' {
        $run = Get-MeasuredRun
        $run.Phase = 'Optimized'
        $run.Status = 'ManualStop'
        $termination = [ordered]@{
            manualStopRequested = $true
            safetyStopTriggered = $false
            safetyReasons = @()
            timeout = $false
        }

        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -TerminationEvidence $termination -Outcome ManualStop } | Should -Not -Throw

        $termination.manualStopRequested = $false
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -TerminationEvidence $termination -Outcome ManualStop } | Should -Throw
    }

    It 'rejects contradictory or false stop claims in termination evidence' {
        $run = Get-MeasuredRun
        $bothStops = [ordered]@{
            manualStopRequested = $true
            safetyStopTriggered = $true
            safetyReasons = @('pressure')
            timeout = $false
        }
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -TerminationEvidence $bothStops -Outcome TargetMet } | Should -Throw

        $falseStop = [ordered]@{
            manualStopRequested = $true
            safetyStopTriggered = $false
            safetyReasons = @()
            timeout = $false
        }
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -TerminationEvidence $falseStop -Outcome TargetMet } | Should -Throw
    }

    It 'still requires independently measured metric improvement for measured success' {
        $validation = Get-ValidValidation
        $validation.additionalMetricImproved = $false
        { ConvertTo-WorkshopEvidence -RunRecord (Get-MeasuredRun) -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation $validation `
                -Outcome TargetMet } | Should -Throw
    }

    It 'derives NoMaterialImprovement from identical A/B trial metrics despite 80/40 peaks' {
        $trials = @(Get-ValidTrial)
        foreach ($trial in $trials | Where-Object Phase -eq 'Optimized') {
            $trial.DurationMs = 10
        }
        $run = Get-MeasuredRun
        $run.Trials = $trials
        $validation = Get-ValidValidation -Trials $trials

        $result = ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
            -RequestSamples (Get-ValidRequestSample) -Validation $validation `
            -Outcome NoMaterialImprovement

        $result.correctness.additionalMetricImproved | Should -BeFalse
        $result.outcome | Should -BeExactly 'NoMaterialImprovement'
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation $validation `
                -Outcome TargetMet } | Should -Throw '*does not match the measured evidence outcome*'
    }

    It 'rejects forged caller success fields when paired trial hashes do not match' {
        $trials = @(Get-ValidTrial)
        ($trials | Where-Object { $_.ParameterSlot -eq 1 -and $_.Phase -eq 'Optimized' }).ResultHash = ('cd' * 32)
        $run = Get-MeasuredRun
        $run.Trials = $trials
        $validation = Get-ValidValidation -Trials $trials
        $validation.passed = $true
        $validation.materialRegression = $false
        $validation.additionalMetricImproved = $true

        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation $validation `
                -Outcome TargetMet } | Should -Throw '*does not match values derived from trials*'
    }

    It 'emits target evidence with no measured claims' {
        $run = New-WorkshopRunRecord -Phase Target -Status Planned `
            -EvidenceClassification TARGET -FrozenSettings (Get-TestSetting) `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand) `
            -StartUtc ([datetimeoffset]'2026-09-01T10:00:00Z')
        $result = ConvertTo-WorkshopEvidence -RunRecord $run -Samples @() -RequestSamples @()

        $result.samples.Count | Should -Be 0
        $result.requestSamples.Count | Should -Be 0
        $result.measuredPeaks.baseline | Should -BeNullOrEmpty
        $result.measuredPeaks.optimized | Should -BeNullOrEmpty
        $result.correctness | Should -BeNullOrEmpty
        $result.outcome | Should -BeNullOrEmpty
        $result.disclaimer | Should -Match 'not an executed benchmark'
    }

    It 'rejects sequence, timestamp, metric, and frozen-hash corruption' {
        $run = Get-MeasuredRun
        $samples = Get-ValidSample
        $samples[1].sequence = 3
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples $samples `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -Outcome TargetMet } | Should -Throw

        $samples = Get-ValidSample
        $samples[1].timestampUtc = $samples[0].timestampUtc
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples $samples `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -Outcome TargetMet } | Should -Throw

        $samples = Get-ValidSample
        $samples[0].grantUtilizationPercent = 101
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples $samples `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -Outcome TargetMet } | Should -Throw

        $run.FrozenSettingsHash = ('0' * 64)
        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
            -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -Outcome TargetMet } | Should -Throw
    }

    It 'rejects measurements on TARGET evidence and absent measurements on LAB-MEASURED evidence' {
        $targetRun = New-WorkshopRunRecord -Phase Target -Status Planned `
            -EvidenceClassification TARGET -FrozenSettings (Get-TestSetting) `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand)
        { ConvertTo-WorkshopEvidence -RunRecord $targetRun -Samples (Get-ValidSample) `
                -RequestSamples @() } | Should -Throw

        $measuredRun = Get-MeasuredRun
        { ConvertTo-WorkshopEvidence -RunRecord $measuredRun -Samples @() `
                -RequestSamples @() -Validation (Get-ValidValidation) `
                -Outcome TargetMet } | Should -Throw
    }

    It 'rejects an outcome that is inconsistent with measured peaks and validation gates' {
        $run = Get-MeasuredRun
        $samples = Get-ValidSample
        $samples[1].grantedKb = 600
        $samples[1].grantUtilizationPercent = 60

        {
            ConvertTo-WorkshopEvidence -RunRecord $run -Samples $samples `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -Outcome TargetMet
        } | Should -Throw
    }

    It 'requires both baseline and optimized samples for measured comparison outcomes' -ForEach @(
        @{ KeepPhase = 'Baseline'; Outcome = 'TargetMet' }
        @{ KeepPhase = 'Optimized'; Outcome = 'TargetMet' }
        @{ KeepPhase = 'Baseline'; Outcome = 'ImprovedOutsideTarget' }
        @{ KeepPhase = 'Optimized'; Outcome = 'NoMaterialImprovement' }
    ) {
        $run = Get-MeasuredRun
        $samples = @(Get-ValidSample | Where-Object phase -eq $KeepPhase)
        $samples[0].sequence = 1
        {
            ConvertTo-WorkshopEvidence -RunRecord $run -Samples $samples `
                -RequestSamples @() -Validation (Get-ValidValidation) -Outcome $Outcome
        } | Should -Throw
    }

    It 'computes each measured peak as the exact maximum sample utilization' {
        $samples = @(
            [ordered]@{ sequence = 1; timestampUtc = '2026-09-01T10:00:05.0000000Z'; phase = 'Baseline'; grantedKb = 750; totalKb = 1000; grantUtilizationPercent = 75; hostUsedPercent = 70; hostAvailableMB = 12000; processPhysicalLow = $false; processVirtualLow = $false }
            [ordered]@{ sequence = 2; timestampUtc = '2026-09-01T10:00:10.0000000Z'; phase = 'Optimized'; grantedKb = 350; totalKb = 1000; grantUtilizationPercent = 35; hostUsedPercent = 70; hostAvailableMB = 12000; processPhysicalLow = $false; processVirtualLow = $false }
            [ordered]@{ sequence = 3; timestampUtc = '2026-09-01T10:00:15.0000000Z'; phase = 'Baseline'; grantedKb = 850; totalKb = 1000; grantUtilizationPercent = 85; hostUsedPercent = 70; hostAvailableMB = 12000; processPhysicalLow = $false; processVirtualLow = $false }
            [ordered]@{ sequence = 4; timestampUtc = '2026-09-01T10:00:20.0000000Z'; phase = 'Optimized'; grantedKb = 450; totalKb = 1000; grantUtilizationPercent = 45; hostUsedPercent = 70; hostAvailableMB = 12000; processPhysicalLow = $false; processVirtualLow = $false }
        )

        $result = ConvertTo-WorkshopEvidence -RunRecord (Get-MeasuredRun) -Samples $samples `
            -RequestSamples @() -Validation (Get-ValidValidation) -Outcome TargetMet

        $result.measuredPeaks.baseline | Should -BeExactly ([decimal]85)
        $result.measuredPeaks.optimized | Should -BeExactly ([decimal]45)
    }

    It 'rejects an exact utilization mismatch instead of deriving a false peak' {
        $samples = Get-ValidSample
        $samples[0].grantUtilizationPercent = [decimal]'79.999999'

        { ConvertTo-WorkshopEvidence -RunRecord (Get-MeasuredRun) -Samples $samples `
                -RequestSamples @() -Validation (Get-ValidValidation) -Outcome TargetMet } |
            Should -Throw '*does not match grantedKb and totalKb*'
    }

    It 'allows BaselineTargetNotReached only with baseline samples and a null optimized peak' {
        $run = Get-MeasuredRun
        $run.Phase = 'Baseline'
        $run.Status = 'BaselineTargetNotReached'
        $samples = @(Get-ValidSample | Where-Object phase -eq 'Baseline')
        $samples[0].grantedKb = 700
        $samples[0].grantUtilizationPercent = 70

        $result = ConvertTo-WorkshopEvidence -RunRecord $run -Samples $samples `
            -RequestSamples @() -Validation (Get-ValidValidation) `
            -Outcome BaselineTargetNotReached
        $result.measuredPeaks.baseline | Should -BeExactly ([decimal]70)
        $result.measuredPeaks.optimized | Should -BeNullOrEmpty

        { ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples @() -Validation (Get-ValidValidation) `
                -Outcome BaselineTargetNotReached } | Should -Throw
    }

    It 'allows independently evidenced stops in either sampled phase' -ForEach @(
        @{ Phase = 'Baseline'; Outcome = 'SafetyStop' }
        @{ Phase = 'Optimized'; Outcome = 'SafetyStop' }
        @{ Phase = 'Baseline'; Outcome = 'ManualStop' }
        @{ Phase = 'Optimized'; Outcome = 'ManualStop' }
    ) {
        $run = Get-MeasuredRun
        $run.Phase = $Phase
        $run.Status = $Outcome
        $samples = @(Get-ValidSample | Where-Object phase -eq $Phase)
        $samples[0].sequence = 1
        $termination = [ordered]@{
            manualStopRequested = $Outcome -eq 'ManualStop'
            safetyStopTriggered = $Outcome -eq 'SafetyStop'
            safetyReasons = @(if ($Outcome -eq 'SafetyStop') { 'pressure' })
            timeout = $false
        }

        $result = ConvertTo-WorkshopEvidence -RunRecord $run -Samples $samples `
            -RequestSamples @() -Validation (Get-ValidValidation) `
            -TerminationEvidence $termination -Outcome $Outcome

        $result.measuredPeaks.$($Phase.ToLowerInvariant()) | Should -Not -BeNullOrEmpty
        $otherPhase = if ($Phase -eq 'Baseline') { 'optimized' } else { 'baseline' }
        $result.measuredPeaks.$otherPhase | Should -BeNullOrEmpty
    }

    It 'rejects mutated run phase and status values before serialization' {
        $run = Get-MeasuredRun
        $run.Phase = 'Target'
        $run.Status = 'Planned'
        {
            ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                -RequestSamples (Get-ValidRequestSample) -Validation (Get-ValidValidation) `
                -Outcome TargetMet
        } | Should -Throw
    }

    It 'rejects fractional, Boolean, negative, and overflowing trial integers before conversion' -ForEach @(
        @{ Value = [decimal]'9.999' }
        @{ Value = $true }
        @{ Value = -1 }
        @{ Value = [decimal]'9223372036854775808' }
    ) {
        foreach ($metric in @('DurationMs','CpuMs','LogicalReads','GrantedKB','UsedKB','SpillKB','WaitMs',
            'ResultRowCount','ExpectedRowCount','ActualRowCount','DifferenceCount')) {
            $run = Get-MeasuredRun
            $run.Trials[0].$metric = $Value
            {
                ConvertTo-WorkshopEvidence -RunRecord $run -Samples (Get-ValidSample) `
                    -RequestSamples @() -Validation (Get-ValidValidation) -Outcome TargetMet
            } | Should -Throw
        }
    }
}

Describe 'Task 12 workload orchestration' {
    BeforeAll {
        function Get-TestPreflight {
            param([string] $Hash = ('a' * 64))
            [pscustomobject]@{
                MarkerValid = $true
                SqlMajorVersion = 16
                SqlProductVersion = '16.0.1135.2'
                SqlEdition = 'Enterprise Edition (64-bit)'
                VmSku = 'Standard_E8s_v5'
                Region = 'indonesiacentral'
                ImageVersion = '16.0.2026.801'
                PhysicalMemoryMB = 65536
                QueryStoreActualState = 'READ_WRITE'
                ResourcePool = 'mcp_sql_workshop_pool'
                PoolMinMemoryPercent = 0
                PoolMaxMemoryPercent = 50
                WorkloadGroup = 'mcp_sql_workshop_group'
                GroupRequestMaxMemoryGrantPercent = 40
                GroupMaxDop = 4
                GroupMaxRequests = 4
                MaxServerMemoryMB = 49152
                MinServerMemoryMB = 0
                RowModeMemoryGrantFeedbackDisabled = $true
                BatchModeMemoryGrantFeedbackDisabled = $true
                ControllerSessionInWorkloadGroup = $true
                PriorMemoryGrantFeedbackState = 'ON'
                ProceduresPresent = $true
                WorkshopRunPresent = $true
                WorkshopSamplePresent = $true
                WorkshopRequestSamplePresent = $true
                WorkshopTrialPresent = $true
                ValidationBatchID = '11111111-1111-1111-1111-111111111111'
                ValidationPassed = $true
                ValidationValidatedAtUtc = [datetimeoffset]::UtcNow.AddMinutes(-5)
                ValidationBatchHash = ('d' * 64)
                ServerConfigurationHash = $Hash
                PoolConfigurationHash = $Hash
                DatabaseConfigurationHash = $Hash
                DataHash = $Hash
                IndexStatisticsHash = $Hash
                ProcedureHash = $Hash
            }
        }

        function Get-TestSample {
            param([string] $Phase, [decimal] $Utilization, [int] $ActiveGrants = 1)
            [pscustomobject]@{
                Phase = $Phase
                GrantedKb = [int64] ($Utilization * 10)
                TotalKb = [int64] 1000
                GrantUtilizationPercent = $Utilization
                HostUsedPercent = [decimal] 70
                HostAvailableMB = [decimal] 16000
                ProcessPhysicalLow = $false
                ProcessVirtualLow = $false
                Healthy = $true
                ActiveGrantCount = $ActiveGrants
                ManualStopRequested = $false
            }
        }

        function Get-TestOperationSet {
            param(
                [object[]] $Baseline = @(
                    (Get-TestSample Baseline 60),
                    (Get-TestSample Baseline 70),
                    (Get-TestSample Baseline 70),
                    (Get-TestSample Baseline 70),
                    (Get-TestSample Baseline 70),
                    (Get-TestSample Baseline 75),
                    (Get-TestSample Baseline 80),
                    (Get-TestSample Baseline 82)
                ),
                [object[]] $Optimized = @(
                    (Get-TestSample Optimized 35),
                    (Get-TestSample Optimized 40),
                    (Get-TestSample Optimized 42)
                ),
                [object] $Preflight = (Get-TestPreflight)
            )
            Write-Verbose "Creating fixture with $($Baseline.Count) baseline and $($Optimized.Count) optimized samples."
            $state = [pscustomobject]@{
                Now = [datetimeoffset]'2026-09-01T10:00:00Z'
                BaselineIndex = 0
                OptimizedIndex = 0
                Starts = [System.Collections.Generic.List[object]]::new()
                Stops = [System.Collections.Generic.List[object]]::new()
                Trials = [System.Collections.Generic.List[object]]::new()
                Persisted = [System.Collections.Generic.List[object]]::new()
                Events = [System.Collections.Generic.List[object]]::new()
                KillCalls = 0
                Exported = $false
                ExportedResult = $null
                Preflight = $Preflight
                HealthChecks = 0
            }
            $operations = @{
                OpenConnection = { param($Purpose) Write-Verbose $Purpose; $state.Preflight }
                StartWorker = {
                    param($RunId, $Phase, $Worker, $ApplicationName, $Schedule, $Deadline)
                    $handle = [pscustomobject]@{ RunId = $RunId; Phase = $Phase; Worker = $Worker; ApplicationName = $ApplicationName; Schedule = @($Schedule); Deadline = $Deadline; StartedAt = $state.Now; Disposed = $false }
                    $handle | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
                    $state.Starts.Add($handle)
                    $handle
                }
                Sample = {
                    param($RunId, $Phase, $Kind, $TrialPhase, $ScheduleEntry, $RemainingSeconds)
                    Write-Verbose "$RunId $ScheduleEntry"
                    $state.Events.Add([pscustomobject]@{ Phase=$Phase; Kind=$Kind; TrialPhase=$TrialPhase; At=$state.Now; RemainingSeconds=$RemainingSeconds })
                    if ($Kind -eq 'Fingerprint') { return $state.Preflight }
                    if ($Kind -eq 'Trial') {
                        $optimizedTrial = $TrialPhase -eq 'Optimized'
                        $trial = [pscustomobject]@{ Phase = $TrialPhase; DurationMs = if ($optimizedTrial) { 70 } else { 100 }; CpuMs = if ($optimizedTrial) { 35 } else { 50 }; LogicalReads = if ($optimizedTrial) { 700 } else { 1000 }; GrantedKB = if ($optimizedTrial) { 200 } else { 400 }; UsedKB = if ($optimizedTrial) { 150 } else { 300 }; SpillKB = 0; WaitMs = if ($optimizedTrial) { 2 } else { 5 }; ResultRowCount=2; ResultHash=('ab'*32); ExpectedRowCount=2; ActualRowCount=2; DifferenceCount=1; Correct=$false; ValidationBatchID=$state.Preflight.ValidationBatchID; StartedAtUtc=$state.Now; CompletedAtUtc=$state.Now.AddSeconds(1) }
                        $state.Trials.Add($trial)
                        return $trial
                    }
                    if ($Kind -eq 'Drain') {
                        return [pscustomobject]@{ Phase = $Phase; GrantedKb = 0; TotalKb = 1000; GrantUtilizationPercent = 0; HostUsedPercent = 70; HostAvailableMB = 16000; ProcessPhysicalLow = $false; ProcessVirtualLow = $false; Healthy = $true; ActiveGrantCount = 0; ManualStopRequested = $false }
                    }
                    if ($Phase -eq 'Baseline') {
                        $result = $Baseline[[math]::Min($state.BaselineIndex, $Baseline.Count - 1)]
                        $state.BaselineIndex++
                        return $result
                    }
                    $result = $Optimized[[math]::Min($state.OptimizedIndex, $Optimized.Count - 1)]
                    $state.OptimizedIndex++
                    return $result
                }
                TestWorkerHealth = {
                    param([object[]] $Handles)
                    $state.HealthChecks++
                    [pscustomobject]@{ Healthy = $true; Reason = $null; ActiveHandleCount = $Handles.Count }
                }
                StopWorker = { param($Handle) $state.Stops.Add($Handle) }
                KillTagged = { param($RunId) Write-Verbose $RunId; $state.KillCalls++; @() }
                Persist = { param($Record) $state.Persisted.Add($Record) }
                Delay = { param([int] $Seconds) $state.Now = $state.Now.AddSeconds($Seconds) }
                Clock = { $state.Now }
                Export = { param($Result) Write-Verbose $Result.Outcome; $state.Exported = $true; $state.ExportedResult = $Result }
            }
            foreach ($name in @($operations.Keys)) {
                $operations[$name] = $operations[$name].GetNewClosure()
            }
            [pscustomobject]@{ State = $state; Operations = $operations }
        }
    }

    It 'uses exact application names and a fixed parameterized schedule' {
        $run = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        Get-WorkshopApplicationName -RunId $run -Phase Baseline -Worker 1 |
            Should -BeExactly 'MCP-SQL-Workshop-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-Baseline-1'
        { Get-WorkshopApplicationName -RunId $run -Phase Optimized -Worker 5 } | Should -Throw

        $schedule = Get-WorkshopParameterSchedule
        $schedule.Count | Should -BeGreaterThan 1
        foreach ($entry in $schedule) {
            $entry.psobject.Properties.Name | Should -Be @('StartDate', 'EndDateExclusive', 'TerritoryID', 'TopCount')
        }
    }

    It 'rejects a worker ramp interval below twenty seconds' {
        $fixture = Get-TestOperationSet
        { Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
                -WorkerRampSeconds 19 } | Should -Throw
    }

    It 'requires two consecutive worker health failures and resets after recovery' {
        $transient = Get-TestOperationSet
        $transient.State | Add-Member NoteProperty HealthSequence @($false, $true)
        $transient.Operations.TestWorkerHealth = {
            param([object[]] $Handles)
            $healthy = if ($transient.State.HealthChecks -lt $transient.State.HealthSequence.Count) {
                $transient.State.HealthSequence[$transient.State.HealthChecks]
            }
            else { $true }
            $transient.State.HealthChecks++
            [pscustomobject]@{ Healthy = $healthy; Reason = 'injected'; ActiveHandleCount = $Handles.Count }
        }.GetNewClosure()
        (Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $transient.Operations `
                -WorkerRampSeconds 20).Outcome | Should -Be 'TargetMet'

        $consecutive = Get-TestOperationSet
        $consecutive.Operations.TestWorkerHealth = {
            param([object[]] $Handles)
            $consecutive.State.HealthChecks++
            [pscustomobject]@{ Healthy = $false; Reason = 'injected'; ActiveHandleCount = $Handles.Count }
        }.GetNewClosure()
        (Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $consecutive.Operations `
                -WorkerRampSeconds 20).Outcome | Should -Be 'SafetyStop'
        $consecutive.State.HealthChecks | Should -Be 2
    }

    It 'ramps one worker at a time, freezes after three baseline samples, and reuses exact conditions' {
        $fixture = Get-TestOperationSet
        $result = Invoke-WorkshopExperiment -RunId ([guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') `
            -OperationSet $fixture.Operations -MaximumWorkers 4 -MaximumDurationSeconds 600 `
            -SampleIntervalSeconds 5 -WorkerRampSeconds 20

        $result.Outcome | Should -Be 'TargetMet'
        $result.FrozenSettings.Workers | Should -Be 2
        @($fixture.State.Starts | Where-Object Phase -eq Baseline).Count | Should -Be 2
        @($fixture.State.Starts | Where-Object Phase -eq Optimized).Count | Should -Be 2
        @($fixture.State.Starts | Where-Object Phase -eq Optimized) | ForEach-Object {
            ($_.Schedule | ConvertTo-Json -Compress) | Should -Be ($result.FrozenSettings.ParameterSchedule | ConvertTo-Json -Compress)
        }
        $fixture.State.Exported | Should -BeTrue
        @($fixture.State.Starts | Where-Object Disposed -eq $false).Count | Should -Be 0
    }

    It 'preserves the invoked run identity through evidence and export injection' {
        $runId = [guid]'12345678-1234-1234-1234-123456789abc'
        $fixture = Get-TestOperationSet
        $result = Invoke-WorkshopExperiment -RunId $runId -OperationSet $fixture.Operations -WorkerRampSeconds 20

        $result.RunId | Should -Be $runId
        $result.Evidence.runId | Should -BeExactly $runId.ToString('D')
        $fixture.State.ExportedResult.RunId | Should -Be $runId
        $fixture.State.ExportedResult.Evidence.runId | Should -BeExactly $runId.ToString('D')
    }

    It 'uses actual bounded settings when baseline stops before freeze' {
        $baseline = 1..20 | ForEach-Object { Get-TestSample Baseline 70 }
        $fixture = Get-TestOperationSet -Baseline $baseline
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumWorkers 3 -MaximumDurationSeconds 60 -SampleIntervalSeconds 6 -WorkerRampSeconds 20

        $result.Outcome | Should -Be 'BaselineTargetNotReached'
        $result.FrozenSettings.maximumDurationSeconds | Should -Be 60
        $result.FrozenSettings.sampleIntervalSeconds | Should -Be 6
        $result.FrozenSettings.workerRampSeconds | Should -Be 20
    }

    It 'builds evidence environment only from SQL-observed preflight values' {
        $fixture = Get-TestOperationSet
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations -WorkerRampSeconds 20

        $result.Evidence.environment.sqlVersion | Should -BeExactly '16.0.1135.2'
        $result.Evidence.environment.physicalMemoryMB | Should -BeExactly 65536
    }

    It 'sets the first ramp clock when worker one starts and never starts worker two before the exact ramp' {
        $fixture = Get-TestOperationSet
        [void](Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumWorkers 4 -MaximumDurationSeconds 600 -SampleIntervalSeconds 5 -WorkerRampSeconds 20)
        $baselineStarts = @($fixture.State.Starts | Where-Object Phase -eq Baseline)
        $baselineStarts[0].StartedAt | Should -BeExactly ([datetimeoffset]'2026-09-01T10:00:00Z')
        $baselineStarts[1].StartedAt | Should -BeExactly ([datetimeoffset]'2026-09-01T10:00:20Z')
    }

    It 'samples safety immediately before and after every one of twelve trials' {
        $fixture = Get-TestOperationSet
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -WorkerRampSeconds 20
        $trialStart = [array]::IndexOf(@($fixture.State.Events.Kind), 'Trial')
        $comparisonEvents = @($fixture.State.Events | Select-Object -Skip ($trialStart - 1) |
            Where-Object Kind -ne 'Fingerprint')
        $comparisonEvents.Count | Should -Be 36
        for ($index = 0; $index -lt 12; $index++) {
            $comparisonEvents[$index*3].Kind | Should -Be 'Memory'
            $comparisonEvents[$index*3+1].Kind | Should -Be 'Trial'
            $comparisonEvents[$index*3+2].Kind | Should -Be 'Memory'
        }
        $result.Trials.Count | Should -Be 12
    }

    It 'passes a positive bounded remaining deadline to every synchronous sample operation' {
        $fixture = Get-TestOperationSet
        [void](Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumDurationSeconds 60 -WorkerRampSeconds 20)

        @($fixture.State.Events).Count | Should -BeGreaterThan 0
        foreach ($sampleCall in $fixture.State.Events) {
            $sampleCall.RemainingSeconds | Should -BeGreaterOrEqual 1
            $sampleCall.RemainingSeconds | Should -BeLessOrEqual 60
        }
    }

    It 'passes the same absolute experiment deadline to every worker start' {
        $fixture = Get-TestOperationSet
        [void](Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumDurationSeconds 60 -WorkerRampSeconds 20)

        @($fixture.State.Starts).Count | Should -BeGreaterThan 0
        @($fixture.State.Starts | Select-Object -ExpandProperty Deadline -Unique).Count | Should -Be 1
        $fixture.State.Starts[0].Deadline | Should -BeExactly ([datetimeoffset]'2026-09-01T10:01:00Z')
    }

    It 'fails at the exact experiment deadline during drain without entering optimized measurement' {
        $fixture = Get-TestOperationSet
        $inner = $fixture.Operations.Sample
        $fixture.Operations.Sample = {
            param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
            $value = & $inner $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            if ($Kind -eq 'Drain') {
                $fixture.State.Now = [datetimeoffset]'2026-09-01T10:01:00Z'
                $value.ActiveGrantCount = 1
            }
            return $value
        }.GetNewClosure()

        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumDurationSeconds 60 -WorkerRampSeconds 20

        $result.Outcome | Should -BeExactly 'Failed'
        $result.TerminationEvidence.Timeout | Should -BeTrue
        @($fixture.State.Starts | Where-Object Phase -eq Optimized).Count | Should -Be 0
        $fixture.State.KillCalls | Should -BeGreaterOrEqual 1
    }

    It 'fails at the exact experiment deadline after a synchronous trial and discards partial performance evidence' {
        $fixture = Get-TestOperationSet
        $inner = $fixture.Operations.Sample
        $fixture.Operations.Sample = {
            param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
            $value = & $inner $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            if ($Kind -eq 'Trial') {
                $fixture.State.Now = [datetimeoffset]'2026-09-01T10:01:00Z'
            }
            return $value
        }.GetNewClosure()

        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumDurationSeconds 60 -WorkerRampSeconds 20

        $result.Outcome | Should -BeExactly 'Failed'
        $result.TerminationEvidence.Timeout | Should -BeTrue
        $result.Trials.Count | Should -Be 0
        $result.Validation.Passed | Should -BeFalse
        $fixture.State.KillCalls | Should -BeGreaterOrEqual 1
    }

    It 'fails and kills tagged sessions when an active worker completes or errors unexpectedly' -ForEach @(
        @{ Reason = 'Worker completed unexpectedly.' }
        @{ Reason = 'Worker failed: injected async failure.' }
    ) {
        $fixture = Get-TestOperationSet
        $fixture.Operations.TestWorkerHealth = {
            param([object[]] $Handles)
            [pscustomobject]@{ Healthy = $false; Reason = $Reason; ActiveHandleCount = $Handles.Count }
        }.GetNewClosure()

        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumDurationSeconds 60 -WorkerRampSeconds 20

        $result.Outcome | Should -BeExactly 'SafetyStop'
        $result.Trials.Count | Should -Be 0
        $fixture.State.KillCalls | Should -BeGreaterOrEqual 1
        @($fixture.State.Starts | Where-Object Disposed -eq $false).Count | Should -Be 0
    }

    It 'gives a trial manual stop precedence, cancels tagged sessions immediately, and never succeeds partially' {
        $fixture = Get-TestOperationSet
        $inner = $fixture.Operations.Sample
        $fixture.State | Add-Member NoteProperty TrialSeen $false
        $fixture.Operations.Sample = {
            param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
            if ($Kind -eq 'Trial') { $fixture.State.TrialSeen = $true }
            $value = & $inner $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            if ($fixture.State.TrialSeen -and $Kind -eq 'Memory') {
                $value = $value.psobject.Copy()
                $value.ManualStopRequested = $true
                $value.HostUsedPercent = 99
            }
            return $value
        }.GetNewClosure()
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -WorkerRampSeconds 20
        $result.Outcome | Should -Be 'ManualStop'
        $result.Trials.Count | Should -BeLessThan 12
        $result.Trials.Count | Should -BeGreaterThan 0
        @($result.Trials | Where-Object { $_.Correct -or $_.DifferenceCount -lt 1 }).Count | Should -Be 0
        $result.Validation.Passed | Should -BeFalse
        $fixture.State.KillCalls | Should -BeGreaterOrEqual 1
    }

    It 'kills and returns persisted exported Failed evidence for operational exceptions after a safety sample' -ForEach @(
        @{ FailurePoint = 'Sample' }
        @{ FailurePoint = 'Worker' }
        @{ FailurePoint = 'Fingerprint' }
        @{ FailurePoint = 'Trial' }
    ) {
        $fixture = Get-TestOperationSet
        if ($FailurePoint -eq 'Sample') {
            $inner = $fixture.Operations.Sample
            $script:memoryCalls = 0
            $fixture.Operations.Sample = {
                param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
                if ($Kind -eq 'Memory') {
                    $script:memoryCalls++
                    if ($script:memoryCalls -eq 2) { throw 'injected sample failure' }
                }
                & $inner $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            }.GetNewClosure()
        }
        elseif ($FailurePoint -eq 'Worker') {
            $inner = $fixture.Operations.StartWorker
            $fixture.Operations.StartWorker = {
                param($RunId,$Phase,$Worker,$ApplicationName,$Schedule,$Deadline)
                if ($Worker -eq 2) { throw 'injected worker failure' }
                & $inner $RunId $Phase $Worker $ApplicationName $Schedule $Deadline
            }.GetNewClosure()
        }
        elseif ($FailurePoint -eq 'Fingerprint') {
            $inner = $fixture.Operations.Sample
            $fixture.Operations.Sample = {
                param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
                if ($Kind -eq 'Fingerprint') { throw 'injected fingerprint failure' }
                & $inner $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            }.GetNewClosure()
        }
        else {
            $inner = $fixture.Operations.Sample
            $script:trialCalls = 0
            $fixture.Operations.Sample = {
                param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
                if ($Kind -eq 'Trial') {
                    $script:trialCalls++
                    if ($script:trialCalls -eq 2) { throw 'injected trial failure' }
                }
                & $inner $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            }.GetNewClosure()
        }

        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumDurationSeconds 60 -WorkerRampSeconds 20

        $result.Outcome | Should -BeExactly 'Failed'
        $result.Samples.Count | Should -BeGreaterThan 0
        @($result.Trials | Where-Object { $_.Correct -or $_.DifferenceCount -lt 1 }).Count | Should -Be 0
        $result.Validation.Passed | Should -BeFalse
        $fixture.State.KillCalls | Should -BeGreaterOrEqual 1
        $fixture.State.Persisted.Count | Should -Be 1
        $fixture.State.Exported | Should -BeTrue
    }

    It 'persists and atomically exports truthful failure evidence before the first sample' -ForEach @(
        @{ FailurePoint = 'StartWorker' }
        @{ FailurePoint = 'Sample' }
    ) {
        $fixture = Get-TestOperationSet
        $runId = [guid]::NewGuid()
        $canary = 'startup-secret-canary'
        if ($FailurePoint -eq 'StartWorker') {
            $fixture.Operations.StartWorker = { throw "Password=$canary" }.GetNewClosure()
        }
        else {
            $fixture.Operations.Sample = { throw "Password=$canary" }.GetNewClosure()
        }
        $fixture.Operations.Export = {
            param($Result)
            Export-WorkshopEvidenceFile -RunId $Result.RunId.ToString('D') -Evidence $Result.Evidence `
                -RepositoryRoot $TestDrive -SemanticValidator { $true }
        }.GetNewClosure()

        $result = Invoke-WorkshopExperiment -RunId $runId -OperationSet $fixture.Operations

        $result.Outcome | Should -BeExactly 'Failed'
        $result.Phase | Should -BeExactly 'Baseline'
        $result.Samples.Count | Should -Be 0
        $result.Trials.Count | Should -Be 0
        $result.Evidence.correctness | Should -BeNullOrEmpty
        $result.Evidence.measuredPeaks.baseline | Should -BeNullOrEmpty
        $result.Evidence.measuredPeaks.optimized | Should -BeNullOrEmpty
        $result.Evidence.terminationEvidence.failure.startupFailure | Should -BeTrue
        $result.Evidence.terminationEvidence.failure.stage | Should -BeExactly $FailurePoint
        $result.Evidence.terminationEvidence.failure.message | Should -Not -Match $canary
        $fixture.State.KillCalls | Should -BeGreaterOrEqual 1
        $fixture.State.Persisted.Count | Should -Be 1

        $runDirectory = Join-Path $TestDrive "evidence/runs/$($runId.ToString('D'))"
        $jsonPath = Join-Path $runDirectory 'evidence.json'
        Test-Path -LiteralPath $jsonPath | Should -BeTrue
        @(Get-ChildItem (Join-Path $TestDrive 'evidence/runs') -Filter '*.tmp' -Directory).Count | Should -Be 0
        $python = Join-Path $PSScriptRoot '../../.venv/Scripts/python.exe'
        $validator = Join-Path $PSScriptRoot '../../evidence/validate_evidence.py'
        $schema = Join-Path $PSScriptRoot '../../evidence/evidence-schema.json'
        $validationOutput = & $python $validator --schema $schema $jsonPath
        $LASTEXITCODE | Should -Be 0 -Because ($validationOutput -join '; ')
    }

    It 'exports sanitized local failure evidence when SQL failure persistence also fails' {
        $fixture = Get-TestOperationSet
        $inner = $fixture.Operations.Sample
        $script:memoryCalls = 0
        $fixture.Operations.Sample = {
            param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
            if ($Kind -eq 'Memory') {
                $script:memoryCalls++
                if ($script:memoryCalls -eq 2) { throw 'original sample failure' }
            }
            & $inner $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
        }.GetNewClosure()
        $fixture.Operations.Persist = { throw 'injected persistence failure' }

        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumDurationSeconds 60 -WorkerRampSeconds 20

        $result.Outcome | Should -BeExactly 'Failed'
        $result.Evidence.terminationEvidence.failure.code | Should -BeExactly 'PERSISTENCE_FAILED'
        $result.Evidence.terminationEvidence.failure.stage | Should -BeExactly 'Persistence'
        $result.Evidence.terminationEvidence.failure.message | Should -Not -Match 'Password|secret|token'
        $fixture.State.Exported | Should -BeTrue
        $fixture.State.KillCalls | Should -BeGreaterOrEqual 1
    }

    It 'returns Failed and does not calculate performance success for a paired trial mismatch' {
        $fixture = Get-TestOperationSet
        $inner = $fixture.Operations.Sample
        $fixture.State | Add-Member NoteProperty TrialNumber 0
        $fixture.Operations.Sample = {
            param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
            $value = & $inner $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            if ($Kind -eq 'Trial') {
                $fixture.State.TrialNumber++
                if ($fixture.State.TrialNumber -eq 2) { $value.ResultHash = ('cd'*32) }
            }
            return $value
        }.GetNewClosure()
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -WorkerRampSeconds 20
        $result.Outcome | Should -Be 'Failed'
        $result.Validation.Passed | Should -BeFalse
    }

    It 'hashes the final assessed trial linkage with byte hashes encoded as hex' {
        $matching = Get-TestOperationSet
        $matchingSample = $matching.Operations.Sample
        $matching.Operations.Sample = {
            param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
            $value = & $matchingSample $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            if ($Kind -eq 'Trial') { $value.ResultHash = [byte[]](1..32) }
            return $value
        }.GetNewClosure()
        $matchingResult = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $matching.Operations -WorkerRampSeconds 20

        $mismatching = Get-TestOperationSet
        $mismatchingSample = $mismatching.Operations.Sample
        $mismatching.State | Add-Member NoteProperty TrialNumber 0
        $mismatching.Operations.Sample = {
            param($RunId,$Phase,$Kind,$TrialPhase,$ScheduleEntry,$RemainingSeconds)
            $value = & $mismatchingSample $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
            if ($Kind -eq 'Trial') {
                $mismatching.State.TrialNumber++
                $value.ResultHash = if ($mismatching.State.TrialNumber -eq 2) { [byte[]](2..33) } else { [byte[]](1..32) }
            }
            return $value
        }.GetNewClosure()
        $mismatchingResult = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $mismatching.Operations -WorkerRampSeconds 20

        $matchingResult.Validation.Passed | Should -BeTrue
        $mismatchingResult.Validation.Passed | Should -BeFalse
        $mismatchingResult.Outcome | Should -Be 'Failed'
        $mismatchingResult.Validation.validationHash | Should -Not -BeExactly $matchingResult.Validation.validationHash
    }

    It 'rejects each frozen fingerprint drift before optimized workers start' -ForEach @(
        @{ Field = 'DataHash' }
        @{ Field = 'IndexStatisticsHash' }
        @{ Field = 'ProcedureHash' }
    ) {
        $fixture = Get-TestOperationSet
        $sampleOperation = $fixture.Operations.Sample
        $drift = Get-TestPreflight -Hash ('a' * 64)
        $drift.$Field = ('b' * 64)
        $fixture.Operations.Sample = {
            param($RunId, $Phase, $Kind, $TrialPhase, $ScheduleEntry, $RemainingSeconds)
            if ($Kind -eq 'Fingerprint') { return $drift }
            & $sampleOperation $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
        }.GetNewClosure()
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations
        $result.Outcome | Should -BeExactly 'Failed'
        $result.Validation.Passed | Should -BeFalse
        @($fixture.State.Starts | Where-Object Phase -eq Optimized).Count | Should -Be 0
        $fixture.State.KillCalls | Should -BeGreaterOrEqual 1
        $fixture.State.Persisted.Count | Should -Be 1
        $fixture.State.Exported | Should -BeTrue
    }

    It 'rejects fingerprint drift introduced during optimized measurement' {
        $fixture = Get-TestOperationSet
        $sampleOperation = $fixture.Operations.Sample
        $fixture.State | Add-Member NoteProperty FingerprintCalls 0
        $fixture.Operations.Sample = {
            param($RunId, $Phase, $Kind, $TrialPhase, $ScheduleEntry, $RemainingSeconds)
            if ($Kind -eq 'Fingerprint') {
                $fixture.State.FingerprintCalls++
                if ($fixture.State.FingerprintCalls -ge 2) {
                    $drift = $fixture.State.Preflight.psobject.Copy()
                    $drift.IndexStatisticsHash = ('b' * 64)
                    return $drift
                }
            }
            & $sampleOperation $RunId $Phase $Kind $TrialPhase $ScheduleEntry $RemainingSeconds
        }.GetNewClosure()

        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) `
            -OperationSet $fixture.Operations -WorkerRampSeconds 20
        $result.Outcome | Should -BeExactly 'Failed'
        $result.Validation.Passed | Should -BeFalse
        $fixture.State.FingerprintCalls | Should -BeGreaterOrEqual 2
    }

    It 'never claims optimized success when baseline cannot reach target' {
        $baseline = 1..130 | ForEach-Object { Get-TestSample Baseline 70 }
        $fixture = Get-TestOperationSet -Baseline $baseline
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumWorkers 4 -MaximumDurationSeconds 60 -SampleIntervalSeconds 5 -WorkerRampSeconds 20
        $result.Outcome | Should -Be 'BaselineTargetNotReached'
        @($fixture.State.Starts | Where-Object Phase -eq Optimized).Count | Should -Be 0
        $fixture.State.Exported | Should -BeTrue
    }

    It 'stops immediately for safety with manual stop precedence' {
        $unsafe = Get-TestSample Baseline 60
        $unsafe.HostUsedPercent = 90
        $fixture = Get-TestOperationSet -Baseline @($unsafe)
        (Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations).Outcome |
            Should -Be 'SafetyStop'

        $manual = Get-TestSample Baseline 60
        $manual.HostAvailableMB = 100
        $manual.ManualStopRequested = $true
        $fixture = Get-TestOperationSet -Baseline @($manual)
        (Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations).Outcome |
            Should -Be 'ManualStop'
    }

    It 'runs the exact twelve interleaved ABBA BAAB ABBA trials and records all metrics' {
        Get-WorkshopTrialSequence | Should -BeExactly @('A','B','B','A','B','A','A','B','A','B','B','A')
        $fixture = Get-TestOperationSet
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -WorkerRampSeconds 20
        $result.Trials.Count | Should -Be 12
        $result.Trials.Phase | Should -BeExactly @('Baseline','Optimized','Optimized','Baseline','Optimized','Baseline','Baseline','Optimized','Baseline','Optimized','Optimized','Baseline')
        @($result.Trials.ValidationBatchID | Select-Object -Unique) | Should -Be @('11111111-1111-1111-1111-111111111111')
        foreach ($metric in @('DurationMs','CpuMs','LogicalReads','GrantedKB','UsedKB','SpillKB','WaitMs')) {
            $result.Trials[0].psobject.Properties.Name | Should -Contain $metric
        }
    }

    It 'rejects incomplete preflight including SQL, memory, Query Store, MGF, objects, and validation' -ForEach @(
        @{ Property = 'MarkerValid'; Value = $false }
        @{ Property = 'SqlMajorVersion'; Value = 15 }
        @{ Property = 'SqlProductVersion'; Value = '' }
        @{ Property = 'SqlEdition'; Value = 'Standard Edition' }
        @{ Property = 'PhysicalMemoryMB'; Value = 32768 }
        @{ Property = 'QueryStoreActualState'; Value = 'READ_ONLY' }
        @{ Property = 'ResourcePool'; Value = 'default' }
        @{ Property = 'WorkloadGroup'; Value = 'default' }
        @{ Property = 'RowModeMemoryGrantFeedbackDisabled'; Value = $false }
        @{ Property = 'PriorMemoryGrantFeedbackState'; Value = $null }
        @{ Property = 'ProceduresPresent'; Value = $false }
        @{ Property = 'WorkshopTrialPresent'; Value = $false }
        @{ Property = 'ValidationPassed'; Value = $false }
        @{ Property = 'ValidationValidatedAtUtc'; Value = ([datetimeoffset]::UtcNow.AddHours(-25)) }
        @{ Property = 'ValidationBatchHash'; Value = ('z' * 64) }
        @{ Property = 'DataHash'; Value = ('a' * 63) }
        @{ Property = 'IndexStatisticsHash'; Value = ('A' * 64) }
        @{ Property = 'ProcedureHash'; Value = $null }
    ) {
        $preflight = Get-TestPreflight
        $preflight.$Property = $Value
        { Test-WorkshopPreflight -Snapshot $preflight } | Should -Throw
    }

    It 'treats validation batch identity and hash as frozen optimized fingerprint inputs' {
        $snapshot = Get-TestPreflight
        Test-WorkshopPreflight $snapshot | Should -BeTrue
        foreach ($field in @('ValidationBatchID','ValidationBatchHash')) {
            $copy = $snapshot.psobject.Copy()
            $copy.$field = if ($field -eq 'ValidationBatchID') { [guid]::NewGuid().ToString('D') } else { 'e' * 64 }
            Test-WorkshopFingerprintMatch -Expected $snapshot -Actual $copy | Should -BeFalse
        }
    }
}

Describe 'Task 12 stop and export safety' {
    It 'builds KILL only for active, exact doubly tagged user sessions' {
        $run = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $rows = @(
            [pscustomobject]@{ SessionId = 51; IsUserProcess = $true; IsActive = $true; ProgramName = "MCP-SQL-Workshop-$run-Baseline-1"; ContextInfo = $run.ToByteArray() }
            [pscustomobject]@{ SessionId = 52; IsUserProcess = $true; IsActive = $true; ProgramName = "MCP-SQL-Workshop-$run-Optimized-1"; ContextInfo = ([guid]::NewGuid()).ToByteArray() }
            [pscustomobject]@{ SessionId = 53; IsUserProcess = $true; IsActive = $false; ProgramName = "MCP-SQL-Workshop-$run-Baseline-2"; ContextInfo = $run.ToByteArray() }
            [pscustomobject]@{ SessionId = 54; IsUserProcess = $false; IsActive = $true; ProgramName = "MCP-SQL-Workshop-$run-Baseline-3"; ContextInfo = $run.ToByteArray() }
        )
        $plan = @(Get-WorkshopKillPlan -RunId $run -Sessions $rows -CurrentSessionId 99)
        $plan.Count | Should -Be 1
        $plan[0].SessionId | Should -Be 51
        $plan[0].Statement | Should -BeExactly 'KILL 51;'
    }

    It 'rejects noncanonical run paths and reparse-point output' {
        { Export-WorkshopEvidenceFile -RunId '../escape' -Evidence @{} -RepositoryRoot $TestDrive } | Should -Throw
        { Export-WorkshopEvidenceFile -RunId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
            -Evidence ([ordered]@{ samples=@(); trials=@() }) -RepositoryRoot $TestDrive `
            -SemanticValidator { $true } } | Should -Throw '*run ID*'
        $link = Join-Path $TestDrive 'evidence/runs/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $target = Join-Path $TestDrive 'junction-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Junction -Path $link -Target $target -Force | Out-Null
        { Export-WorkshopEvidenceFile -RunId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
            -Evidence ([ordered]@{ runId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }) -RepositoryRoot $TestDrive } |
            Should -Throw '*reparse*'
    }

    It 'writes UTF-8 JSON and CSV atomically, redacts secrets, and protects completed runs' {
        $run = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $evidence = [ordered]@{ runId = $run; outcome = 'TargetMet'; samples = @([pscustomobject]@{ sequence = 1; phase = 'Baseline' }) }
        $result = Export-WorkshopEvidenceFile -RunId $run -Evidence $evidence -RepositoryRoot $TestDrive `
            -SemanticValidator { param($JsonPath) Write-Verbose $JsonPath; $true }
        Test-Path -LiteralPath $result.JsonPath | Should -BeTrue
        Test-Path -LiteralPath $result.CsvPath | Should -BeTrue
        [IO.File]::ReadAllBytes($result.JsonPath)[0..2] | Should -Not -Be @(0xEF,0xBB,0xBF)
        @(Get-ChildItem $result.Directory -Filter '*.tmp').Count | Should -Be 0
        { Export-WorkshopEvidenceFile -RunId $run -Evidence $evidence -RepositoryRoot $TestDrive `
                -SemanticValidator { $true } } | Should -Throw '*completed run*'

        $secretName = -join @([char]80,[char]97,[char]115,[char]115,[char]119,[char]111,[char]114,[char]100)
        $secretEvidence = [ordered]@{ runId = ([guid]::NewGuid().ToString()); outcome = 'Failed'; samples = @(); note = "$secretName=canary" }
        { Export-WorkshopEvidenceFile -RunId $secretEvidence.runId -Evidence $secretEvidence `
                -RepositoryRoot $TestDrive -SemanticValidator { $true } } | Should -Throw '*Secret-shaped*'
    }

    It 'exports a deterministic union of sample and trial columns' {
        $run = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $evidence = [ordered]@{
            runId = $run
            samples = @([pscustomobject][ordered]@{ sequence=1; phase='Baseline'; grantedKb=800 })
            trials = @([pscustomobject][ordered]@{ TrialSequence=1; Phase='Baseline'; DurationMs=10; ResultHash=('ab'*32) })
        }
        $result = Export-WorkshopEvidenceFile -RunId $run -Evidence $evidence -RepositoryRoot $TestDrive `
            -SemanticValidator { $true }
        $rows = @(Import-Csv -LiteralPath $result.CsvPath)

        $rows.Count | Should -Be 2
        $rows[0].recordType | Should -BeExactly 'Sample'
        $rows[0].sequence | Should -Be '1'
        $rows[0].grantedKb | Should -Be '800'
        $rows[1].recordType | Should -BeExactly 'Trial'
        $rows[1].DurationMs | Should -Be '10'
        $rows[1].ResultHash | Should -BeExactly ('ab'*32)
    }

    It 'declares strict entry bounds, ShouldProcess, and no insecure SQL fallback or Start-Sleep' {
        $start = Get-Content (Join-Path $PSScriptRoot '../../workload/Start-MemoryGrantLab.ps1') -Raw
        $stop = Get-Content (Join-Path $PSScriptRoot '../../workload/Stop-MemoryGrantLab.ps1') -Raw
        $export = Get-Content (Join-Path $PSScriptRoot '../../workload/Export-WorkshopEvidence.ps1') -Raw
        $module = Get-Content (Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psm1') -Raw
        $start | Should -Match 'ValidateRange\(1,\s*4\)'
        $start | Should -Match 'ValidateRange\(60,\s*600\)'
        $start | Should -Match 'ValidateRange\(5,\s*30\)'
        $start | Should -Match 'ValidateRange\(20,\s*60\)'
        $stop | Should -Match 'SupportsShouldProcess'
        $export | Should -Match 'SupportsShouldProcess'
        "$start`n$stop`n$export`n$module" | Should -Not -Match 'System\.Data\.SqlClient'
        $module | Should -Not -Match 'Start-Sleep'
        $module | Should -Match 'Microsoft\.Data\.SqlClient'
        $module | Should -Match 'ZeroFreeBSTR'
        $module | Should -Match 'TrustServerCertificate\s*=\s*\$false'
        $module | Should -Match 'HostNameInCertificate'
    }

    It 'implements exact tagged parameterized SQL workers in disposable async runspaces' {
        $module = Get-Content (Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psm1') -Raw
        $module | Should -Match 'SET\s+CONTEXT_INFO\s+@RunBytes'
        $module | Should -Match "sp_set_session_context.+WorkshopRunId"
        $module | Should -Match "sp_set_session_context.+WorkshopPhase"
        $module | Should -Match 'lab\.usp_MonthEndSalesBaseline'
        $module | Should -Match 'lab\.usp_MonthEndSalesOptimized'
        $module | Should -Match 'Parameters\.Add'
        $module | Should -Match 'RunspaceFactory'
        $module | Should -Match 'BeginInvoke'
        $module | Should -Match 'EndInvoke'
        $module | Should -Match '\.Dispose\(\)'
        $module | Should -Not -Match 'AddWithValue'
        $module | Should -Not -Match 'CommandTimeout\s*=\s*600'
        $module | Should -Match 'param\([^)]*\[datetimeoffset\]\s*\$Deadline'
        $module | Should -Match 'CommandTimeout\s*=\s*\[math\]::Max\(1,\s*\[int\]\[math\]::Ceiling\('
        $module | Should -Match 'if\s*\(\[datetimeoffset\]::UtcNow\s*-ge\s*\$WorkerDeadline\)\s*\{\s*break\s*\}'
    }

    It 'signals worker readiness after production tagging and assigns the ramp clock only after StartWorker returns' {
        $module = Get-Content (Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psm1') -Raw
        $module | Should -Match 'ManualResetEventSlim'
        $module | Should -Match '\.Wait\('
        $module | Should -Not -Match 'Start-Sleep'
        $tagIndex = $module.IndexOf('[void] $tag.ExecuteNonQuery()')
        $readyIndex = $module.IndexOf('$readySignal.Set()', $tagIndex)
        $tagIndex | Should -BeGreaterOrEqual 0
        $readyIndex | Should -BeGreaterThan $tagIndex
        $startIndex = $module.IndexOf('$OperationSet.StartWorker $RunId ''Baseline'' 1')
        $rampIndex = $module.IndexOf('$lastRamp = [datetimeoffset] (& $OperationSet.Clock)', $startIndex)
        $startIndex | Should -BeGreaterOrEqual 0
        $rampIndex | Should -BeGreaterThan $startIndex
    }

    It 'owns worker setup resources in a catch cleanup contract for every setup and readiness failure' {
        $module = Get-Content (Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psm1') -Raw
        $workerRegion = $module.Substring($module.IndexOf('$startWorker = {'), $module.IndexOf('$sample = {') - $module.IndexOf('$startWorker = {'))
        foreach ($operation in @('CreateRunspace','\.Open\(\)','\[powershell\]::Create','AddScript','BeginInvoke','\.Wait\(')) {
            $workerRegion | Should -Match $operation
        }
        $workerRegion | Should -Match 'catch\s*\{[\s\S]*PowerShell\.Stop\(\)[\s\S]*PowerShell\.Dispose\(\)[\s\S]*Runspace\.Dispose\(\)[\s\S]*ReadySignal\.Dispose\(\)'
    }
}

Describe 'Task 12 remaining blocker contracts' {
    BeforeAll {
        function Get-FakeTrialReader {
            param([object[]] $ResultSets)
            $reader = [pscustomobject]@{ Sets = $ResultSets; SetIndex = 0; RowIndex = -1; Disposed = $false }
            $reader | Add-Member ScriptProperty FieldCount {
                if ($this.SetIndex -ge $this.Sets.Count) { return 0 }
                return @($this.Sets[$this.SetIndex].Names).Count
            }
            $reader | Add-Member ScriptMethod GetName { param($Index) [string] $this.Sets[$this.SetIndex].Names[$Index] }
            $reader | Add-Member ScriptMethod Read {
                $this.RowIndex++
                return $this.RowIndex -lt @($this.Sets[$this.SetIndex].Rows).Count
            }
            $reader | Add-Member ScriptMethod IsDBNull { param($Index) $null -eq $this.Sets[$this.SetIndex].Rows[$this.RowIndex][$Index] }
            $reader | Add-Member ScriptMethod GetValue { param($Index) $this.Sets[$this.SetIndex].Rows[$this.RowIndex][$Index] }
            $reader | Add-Member ScriptMethod NextResult {
                $this.SetIndex++
                $this.RowIndex = -1
                return $this.SetIndex -lt $this.Sets.Count
            }
            $reader | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
            return $reader
        }

        function Get-ValidTrialMetricName {
            @('DurationMs','CpuMs','LogicalReads','GrantedKB','UsedKB','SpillKB','WaitMs',
              'ResultRowCount','ResultHash','ExpectedRowCount','ActualRowCount','DifferenceCount',
              'Correct','ValidationBatchID','StartedAtUtc','CompletedAtUtc')
        }

        function Get-ValidTrialMetricValue {
                        $values = [object[]]@([int64]10,[int64]5,[int64]20,[int64]30,[int64]25,[int64]0,[int64]1,
                            [int64]2,$null,[int64]2,[int64]2,[int64]0,$true,
              [guid]'11111111-1111-1111-1111-111111111111',
              [datetime]'2026-09-01T10:00:00Z',[datetime]'2026-09-01T10:00:01Z')
                        $values[8] = [byte[]](1..32)
                        Write-Output -InputObject $values -NoEnumerate
        }

                    function Get-ConcreteTestPreflight {
                        [pscustomobject]@{
                            MarkerValid=$true; SqlMajorVersion=16; SqlEdition='Enterprise Edition (64-bit)'
                            SqlProductVersion='16.0.1135.2'; VmSku='Standard_E8s_v5'
                            Region='indonesiacentral'; ImageVersion='16.0.2026.801'
                            PhysicalMemoryMB=65536; QueryStoreActualState='READ_WRITE'
                            ResourcePool='mcp_sql_workshop_pool'; PoolMinMemoryPercent=0; PoolMaxMemoryPercent=50
                            WorkloadGroup='mcp_sql_workshop_group'; GroupRequestMaxMemoryGrantPercent=40
                            GroupMaxDop=4; GroupMaxRequests=4; MaxServerMemoryMB=49152; MinServerMemoryMB=0
                            RowModeMemoryGrantFeedbackDisabled=$true; BatchModeMemoryGrantFeedbackDisabled=$true
                            ControllerSessionInWorkloadGroup=$true; PriorMemoryGrantFeedbackState='ON'
                            ProceduresPresent=$true; WorkshopRunPresent=$true; WorkshopSamplePresent=$true
                            WorkshopRequestSamplePresent=$true; WorkshopTrialPresent=$true
                            ValidationBatchID='11111111-1111-1111-1111-111111111111'; ValidationPassed=$true
                            ValidationValidatedAtUtc=[datetimeoffset]::UtcNow.AddMinutes(-5)
                            ValidationBatchHash=('d'*64)
                            DataHash=('a'*64); IndexStatisticsHash=('a'*64); ProcedureHash=('a'*64)
                        }
                    }
    }

    It 'drains procedure rows and later result sets and accepts exactly one exact trial metric schema' {
        $reader = Get-FakeTrialReader @(
            [pscustomobject]@{ Names = @('TerritoryID','CustomerID'); Rows = @(@(1,2),@(3,4)) },
            [pscustomobject]@{ Names = @(); Rows = @() },
            [pscustomobject]@{ Names = Get-ValidTrialMetricName; Rows = @(,(Get-ValidTrialMetricValue)) }
        )
        $result = ConvertFrom-WorkshopTrialReader -Reader $reader
        $result.DurationMs | Should -Be 10
        $result.ResultHash.Length | Should -Be 32
        $reader.SetIndex | Should -Be 3
    }

    It 'rejects duplicate, missing, extra, nonfinite, negative, null, and multirow trial metric sets' {
        $names = Get-ValidTrialMetricName
        $values = Get-ValidTrialMetricValue
        $badSets = @(
            @([pscustomobject]@{ Names = $names; Rows = @(,$values) }, [pscustomobject]@{ Names = $names; Rows = @(,$values) }),
            @([pscustomobject]@{ Names = $names[0..14]; Rows = @(,$values[0..14]) }),
            @([pscustomobject]@{ Names = @($names + 'Extra'); Rows = @(,@($values + 1)) }),
            @([pscustomobject]@{ Names = $names; Rows = @(,@([double]::NaN) + $values[1..15]) }),
            @([pscustomobject]@{ Names = $names; Rows = @(,@([decimal]'9.999') + $values[1..15]) }),
            @([pscustomobject]@{ Names = $names; Rows = @(,@($true) + $values[1..15]) }),
            @([pscustomobject]@{ Names = $names; Rows = @(,@(-1) + $values[1..15]) }),
            @([pscustomobject]@{ Names = $names; Rows = @(,@([decimal]'9223372036854775808') + $values[1..15]) }),
            @([pscustomobject]@{ Names = $names; Rows = @(,@($null) + $values[1..15]) }),
            @([pscustomobject]@{ Names = $names; Rows = @($values,$values) })
        )
        foreach ($sets in $badSets) {
            { ConvertFrom-WorkshopTrialReader -Reader (Get-FakeTrialReader $sets) } | Should -Throw
        }
    }

    It 'pairs one A and one B by each of six parameter slots and fails exact rowcount or hash mismatches' {
        $trials = for ($slot = 1; $slot -le 6; $slot++) {
            foreach ($phase in @('Baseline','Optimized')) {
                [pscustomobject]@{
                    TrialSequence = (($slot - 1) * 2) + $(if ($phase -eq 'Baseline') { 1 } else { 2 })
                    ParameterSlot = $slot; Phase = $phase; DurationMs = 10; CpuMs = 5
                    LogicalReads = 20; GrantedKB = 30; UsedKB = 25; SpillKB = 0; WaitMs = 1
                    ResultRowCount = 2; ResultHash = ('ab' * 32)
                    ExpectedRowCount = 0; ActualRowCount = 0; DifferenceCount = 0
                    Correct = $false; ValidationBatchID = '11111111-1111-1111-1111-111111111111'
                    StartedAtUtc = '2026-09-01T10:00:00.0000000Z'; CompletedAtUtc = '2026-09-01T10:00:01.0000000Z'
                }
            }
        }
        $assessment = Get-WorkshopTrialAssessment -Trials $trials
        $assessment.CorrectnessPassed | Should -BeTrue
        @($assessment.Trials | Where-Object Correct -eq $false).Count | Should -Be 0
        $assessment.Trials.ExpectedRowCount | Should -Be @(2,2,2,2,2,2,2,2,2,2,2,2)

        $trials[3].ResultHash = ('cd' * 32)
        $mismatch = Get-WorkshopTrialAssessment -Trials $trials
        $mismatch.CorrectnessPassed | Should -BeFalse
        @($mismatch.Trials | Where-Object ParameterSlot -eq 2).Correct | Should -Be @($false,$false)
        @($mismatch.Trials | Where-Object ParameterSlot -eq 2).DifferenceCount | Should -Be @(1,1)
    }

    It 'rejects invalid integer metrics before trial assessment conversion' -ForEach @(
        @{ Value = [decimal]'9.999' }
        @{ Value = $true }
        @{ Value = -1 }
        @{ Value = [decimal]'9223372036854775808' }
    ) {
        foreach ($metric in @('DurationMs','CpuMs','LogicalReads','GrantedKB','UsedKB','SpillKB','WaitMs',
            'ResultRowCount','ExpectedRowCount','ActualRowCount','DifferenceCount')) {
            $trials = @(Get-ValidTrial)
            $trials[0].$metric = $Value
            { Get-WorkshopTrialAssessment -Trials $trials } | Should -Throw
        }
    }

    It 'uses the SQL comparison metric set and exact ten-percent material thresholds' {
        $trials = for ($slot = 1; $slot -le 6; $slot++) {
            foreach ($phase in @('Baseline','Optimized')) {
                $optimized = $phase -eq 'Optimized'
                [pscustomobject]@{
                    TrialSequence = (($slot - 1) * 2) + $(if ($optimized) { 2 } else { 1 })
                    ParameterSlot = $slot; Phase = $phase
                    DurationMs = if ($optimized) { 90 } else { 100 }
                    CpuMs = 100; LogicalReads = 100; GrantedKB = if ($optimized) { 1 } else { 100 }
                    UsedKB = if ($optimized) { 1 } else { 100 }; SpillKB = 100; WaitMs = 100
                    ResultRowCount = 2; ResultHash = ('ab' * 32)
                    ExpectedRowCount = 0; ActualRowCount = 0; DifferenceCount = 0; Correct = $false
                    ValidationBatchID = '11111111-1111-1111-1111-111111111111'
                    StartedAtUtc = '2026-09-01T10:00:00.0000000Z'; CompletedAtUtc = '2026-09-01T10:00:01.0000000Z'
                }
            }
        }

        $material = Get-WorkshopTrialAssessment -Trials $trials
        $material.AdditionalMetricImproved | Should -BeTrue
        $material.MaterialRegression | Should -BeFalse

        foreach ($trial in $trials | Where-Object Phase -eq 'Optimized') { $trial.DurationMs = 91 }
        (Get-WorkshopTrialAssessment -Trials $trials).AdditionalMetricImproved | Should -BeFalse

        foreach ($trial in $trials | Where-Object Phase -eq 'Optimized') { $trial.CpuMs = 111 }
        (Get-WorkshopTrialAssessment -Trials $trials).MaterialRegression | Should -BeTrue
    }

    It 'derives and compares a canonical configuration fingerprint from every concrete preflight field' {
        $snapshot = Get-ConcreteTestPreflight
        Test-WorkshopPreflight $snapshot | Should -BeTrue
        $snapshot.CanonicalConfigurationFingerprint | Should -Match '^[a-f0-9]{64}$'
        foreach ($field in @('PoolMinMemoryPercent','PoolMaxMemoryPercent','GroupRequestMaxMemoryGrantPercent',
            'GroupMaxDop','GroupMaxRequests','MaxServerMemoryMB','MinServerMemoryMB',
            'RowModeMemoryGrantFeedbackDisabled','BatchModeMemoryGrantFeedbackDisabled',
            'ControllerSessionInWorkloadGroup','QueryStoreActualState')) {
            $copy = $snapshot.psobject.Copy()
            $copy.$field = if ($copy.$field -is [bool]) { -not $copy.$field } else { "$($copy.$field)-drift" }
            Test-WorkshopFingerprintMatch -Expected $snapshot -Actual $copy | Should -BeFalse
        }
    }

    It 'contains production-shape typed trial capture, exact tags, transactional full persistence, and count verification' {
        $module = Get-Content (Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psm1') -Raw
        $module | Should -Match 'CREATE TABLE #TrialResult'
        $module | Should -Match 'INSERT\s+#TrialResult\s+EXEC\s+__PROCEDURE__'
        $module | Should -Match 'HASHBYTES\(''SHA2_256'''
        $module | Should -Not -Match '@Correct'
        $module | Should -Match 'Get-WorkshopApplicationName\s+-RunId\s+\$RunId\s+-Phase\s+\$TrialPhase'
        $module | Should -Match 'SET\s+CONTEXT_INFO\s+@RunBytes'
        $module | Should -Match "WorkshopRunId"
        $module | Should -Match "WorkshopPhase"
        $module | Should -Match 'BEGIN TRANSACTION'
        foreach ($table in @('WorkshopRun','WorkshopSample','WorkshopRequestSample','WorkshopTrial')) {
            $module | Should -Match "INSERT\s+lab\.$table"
        }
        $module | Should -Match 'InsertedTrialCount'
        $module | Should -Match 'ROLLBACK TRANSACTION'
        $module | Should -Match 'CONVERT\(bigint,\s*1\)\s+AS\s+DifferenceCount'
        $module | Should -Match 'CONVERT\(bit,\s*0\)\s+AS\s+Correct'
        $module | Should -Not -Match 'CASE\s+WHEN\s+@ResultRowCount\s*>=\s*0'
        $module | Should -Match 'Exact persisted workshop evidence does not match'
        $module | Should -Match 'ExistingSampleCount'
        $module | Should -Match 'ExistingRequestSampleCount'
        $module | Should -Match 'ExistingTrialCount'
        $module | Should -Match 'RETURN;'
        $module | Should -Match 'BaselineRunID\s+IS\s+NULL'
        $module | Should -Match 'OptimizedRunID\s+IS\s+NULL'
        $module | Should -Match 'DATEADD\(hour,\s*-24,\s*SYSUTCDATETIME\(\)\)'
        $module | Should -Match 'AS\s+ValidationBatchHash'
        $module | Should -Match 'ValidationValidatedAtUtc'
        foreach ($fingerprint in @('dataHash','indexStatisticsHash','procedureHash')) {
            $module | Should -Match $fingerprint
        }
        $module | Should -Match '(?s)STRING_AGG.+WITHIN GROUP \(ORDER BY SyntheticSalesID\)'
        $module | Should -Match 'sys\.dm_db_stats_properties'
        $module | Should -Match 'OBJECT_DEFINITION'
        $module | Should -Match 'FrozenSettingsJson=@FrozenSettingsJson'
    }

    It 'caches the production preflight snapshot used for trial validation linkage' {
        $module = Get-Content (Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psm1') -Raw
        $module | Should -Match '\$preflightSnapshot\s*=\s*\[pscustomobject\]@\{\s*Value\s*=\s*\$null\s*\}'
        $module | Should -Match 'if\s*\(\$null\s*-eq\s*\$preflightSnapshot\.Value\)\s*\{\s*\$preflightSnapshot\.Value\s*=\s*\$rows\[0\]\s*\}'
        $module | Should -Match '\[guid\]\$preflightSnapshot\.Value\.ValidationBatchID'
        $module | Should -Not -Match '\[guid\]\$preflight\.ValidationBatchID'
    }

    It 'emits exact ordered production rows before the trial metric result set' {
        $module = Get-Content (Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psm1') -Raw
        $trialSqlStart = $module.IndexOf('CREATE TABLE #TrialResult')
        $trialSqlEnd = $module.IndexOf("'@", $trialSqlStart)
        $trialSql = $module.Substring($trialSqlStart, $trialSqlEnd - $trialSqlStart)
        $insertIndex = $trialSql.IndexOf('INSERT #TrialResult EXEC __PROCEDURE__')
        $rowsIndex = $trialSql.IndexOf('SELECT TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank', $insertIndex)
        $metricIndex = $trialSql.IndexOf('AS DurationMs', $insertIndex)

        $insertIndex | Should -BeGreaterOrEqual 0
        $rowsIndex | Should -BeGreaterThan $insertIndex
        $metricIndex | Should -BeGreaterThan $rowsIndex
        $trialSql.Substring($rowsIndex, $metricIndex - $rowsIndex) | Should -Match 'ORDER BY SalesRank, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID'
    }

    It 'uses safe backup replacement and restores the completed destination when stage promotion fails' {
        $run = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $destination = Join-Path $TestDrive "evidence/runs/$run"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $destination 'marker.txt') -Value old -NoNewline
        Set-Content -LiteralPath (Join-Path $destination 'evidence.json') -Value "{`"runId`":`"$run`"}" -NoNewline
        $moveState = [pscustomobject]@{ Count = 0 }
        $ops = @{
            MoveDirectory = {
                param($Source,$Target)
                $moveState.Count++
                if ($moveState.Count -eq 2) { throw 'injected promotion failure' }
                [IO.Directory]::Move($Source,$Target)
            }.GetNewClosure()
        }
        { Export-WorkshopEvidenceFile -RunId $run -Evidence ([ordered]@{ runId=$run; samples=@(); trials=@() }) `
                -RepositoryRoot $TestDrive -AllowReplaceCompletedRun -SemanticValidator { $true } `
                -FileOperations $ops } | Should -Throw '*promotion failure*'
        (Get-Content -LiteralPath (Join-Path $destination 'marker.txt') -Raw) | Should -BeExactly 'old'
        (Get-Content -LiteralPath (Join-Path $destination 'evidence.json') -Raw) | Should -Match $run
    }

    It 'removes a first-time promoted destination when post-promotion validation fails' {
        $run = 'abababab-abab-abab-abab-abababababab'
        $destination = Join-Path $TestDrive "evidence/runs/$run"
        $script:firstPromotionValidationCalls = 0
        $validator = {
            param($Path)
            Write-Verbose $Path
            $script:firstPromotionValidationCalls++
            return $script:firstPromotionValidationCalls -eq 1
        }

        { Export-WorkshopEvidenceFile -RunId $run -Evidence ([ordered]@{ runId=$run; samples=@(); trials=@() }) `
                -RepositoryRoot $TestDrive -SemanticValidator $validator } |
            Should -Throw '*validation failed after promotion*'
        Test-Path -LiteralPath $destination | Should -BeFalse
    }


    It 'restores old evidence when the destination-to-backup move completes and then throws' {
        $run = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        $destination = Join-Path $TestDrive "evidence/runs/$run"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $destination 'marker.txt') -Value old -NoNewline
        Set-Content -LiteralPath (Join-Path $destination 'evidence.json') -Value "{`"runId`":`"$run`"}" -NoNewline
        $script:movesAfterFirst = 0
        $ops = @{ MoveDirectory = {
            param($Source,$Target)
            $script:movesAfterFirst++
            [IO.Directory]::Move($Source,$Target)
            if ($script:movesAfterFirst -eq 1) { throw 'injected after first move' }
        } }
        { Export-WorkshopEvidenceFile -RunId $run -Evidence ([ordered]@{ runId=$run; samples=@(); trials=@() }) `
                -RepositoryRoot $TestDrive -AllowReplaceCompletedRun -SemanticValidator { $true } -FileOperations $ops } |
            Should -Throw '*after first move*'
        (Get-Content -LiteralPath (Join-Path $destination 'marker.txt') -Raw) | Should -BeExactly 'old'
        (Get-Content -LiteralPath (Join-Path $destination 'evidence.json') -Raw) | Should -Match $run
    }

    It 'restores old evidence when stage promotion completes then throws or post-validation fails' -ForEach @(
        @{ ThrowAfterMove = $true; ValidationFails = $false; Message = 'injected after second move' }
        @{ ThrowAfterMove = $false; ValidationFails = $true; Message = 'validation failed after promotion' }
    ) {
        $run = [guid]::NewGuid().ToString('D')
        $destination = Join-Path $TestDrive "evidence/runs/$run"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $destination 'marker.txt') -Value old -NoNewline
        Set-Content -LiteralPath (Join-Path $destination 'evidence.json') -Value "{`"runId`":`"$run`"}" -NoNewline
        $script:movesAfterSecond = 0
        $script:validationCalls = 0
        $ops = @{ MoveDirectory = {
            param($Source,$Target)
            $script:movesAfterSecond++
            [IO.Directory]::Move($Source,$Target)
            if ($ThrowAfterMove -and $script:movesAfterSecond -eq 2) { throw $Message }
        }.GetNewClosure() }
        $validator = {
            param($Path)
            Write-Verbose $Path
            $script:validationCalls++
            if ($ValidationFails -and $script:validationCalls -eq 2) { return $false }
            return $true
        }.GetNewClosure()
        { Export-WorkshopEvidenceFile -RunId $run -Evidence ([ordered]@{ runId=$run; samples=@(); trials=@() }) `
                -RepositoryRoot $TestDrive -AllowReplaceCompletedRun -SemanticValidator $validator -FileOperations $ops } |
            Should -Throw
        (Get-Content -LiteralPath (Join-Path $destination 'marker.txt') -Raw) | Should -BeExactly 'old'
        (Get-Content -LiteralPath (Join-Path $destination 'evidence.json') -Raw) | Should -Match $run
    }
}
