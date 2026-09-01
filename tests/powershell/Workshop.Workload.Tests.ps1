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
            parameterSchedule = @('2025-01-01/2025-02-01', '2025-02-01/2025-03-01')
            parameterScheduleHash = '095562b669618122fb74005f471f9c67e41e88a1e8ad0398ef0cc593170b1bb1'
        }
    }

    function Get-TestEnvironment {
        [ordered]@{
            sqlVersion = '16.0.1135.2'
            sqlEdition = 'Enterprise Edition (64-bit)'
            vmSku = 'Standard_E8s_v5'
            region = 'indonesiacentral'
            imageVersion = '16.0.1135.2'
        }
    }

    function Get-TestTargetBand {
        [ordered]@{
            baseline = [ordered]@{ minimum = 75; maximum = 85 }
            optimized = [ordered]@{ minimum = 35; maximum = 45 }
        }
    }

    function Get-MeasuredRun {
        New-WorkshopRunRecord -Phase Comparison -Status Completed `
            -EvidenceClassification LAB-MEASURED -FrozenSettings (Get-TestSetting) `
            -EnvironmentFingerprint (Get-TestEnvironment) -TargetBands (Get-TestTargetBand) `
            -StartUtc ([datetimeoffset]'2026-09-01T10:00:00Z') `
            -EndUtc ([datetimeoffset]'2026-09-01T10:01:00Z')
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
                sequence = 1; timestampUtc = '2026-09-01T10:00:06.0000000Z'; phase = 'Baseline'
                durationMs = 1200; cpuMs = 800; logicalReads = 20000; spillsMb = 24; waitMs = 100
            }
            [ordered]@{
                sequence = 2; timestampUtc = '2026-09-01T10:00:11.0000000Z'; phase = 'Optimized'
                durationMs = 700; cpuMs = 450; logicalReads = 12000; spillsMb = 4; waitMs = 20
            }
        )
    }

    function Get-ValidValidation {
        [ordered]@{
            passed = $true
            materialRegression = $false
            additionalMetricImproved = $true
            validationHash = ('c' * 64)
        }
    }
}

Describe 'Workshop workload module contract' {
    It 'exports the workload decision, orchestration, stop, and export functions' {
        $manifest = Test-ModuleManifest $ModulePath
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'ConvertTo-WorkshopEvidence'
            'Export-WorkshopEvidenceFile'
            'Get-GrantUtilization'
            'Get-WorkshopApplicationName'
            'Get-WorkshopKillPlan'
            'Get-WorkshopOutcome'
            'Get-WorkshopParameterSchedule'
            'Get-WorkshopSqlOperationSet'
            'Get-WorkshopTrialSequence'
            'Invoke-WorkshopExperiment'
            'New-WorkshopRunRecord'
            'Test-TargetBand'
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
            'frozenSettingsHash', 'targetBands', 'samples', 'requestSamples', 'measuredPeaks',
            'correctness', 'terminationEvidence', 'outcome'
        )
        ($first | ConvertTo-Json -Depth 20 -Compress) | Should -Be `
            ($second | ConvertTo-Json -Depth 20 -Compress)
        $first.measuredPeaks.baseline | Should -Be 80
        $first.measuredPeaks.optimized | Should -Be 40
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
        $result.requestSamples.phase | Should -BeExactly @('Baseline', 'Optimized')
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
}

Describe 'Task 12 workload orchestration' {
    BeforeAll {
        function Get-TestPreflight {
            param([string] $Hash = ('a' * 64))
            [pscustomobject]@{
                MarkerValid = $true
                SqlMajorVersion = 16
                SqlEdition = 'Enterprise Edition (64-bit)'
                PhysicalMemoryMB = 65536
                QueryStoreActualState = 'READ_WRITE'
                ResourcePool = 'mcp_sql_workshop_pool'
                WorkloadGroup = 'mcp_sql_workshop_group'
                MemoryGrantFeedbackDisabled = $true
                PriorMemoryGrantFeedbackState = 'ON'
                ProceduresPresent = $true
                EvidenceSchemaPresent = $true
                ValidationBatchID = '11111111-1111-1111-1111-111111111111'
                ValidationPassed = $true
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
                Exported = $false
                Preflight = $Preflight
            }
            $operations = @{
                OpenConnection = { param($Purpose) Write-Verbose $Purpose; $state.Preflight }
                StartWorker = {
                    param($RunId, $Phase, $Worker, $ApplicationName, $Schedule)
                    $handle = [pscustomobject]@{ RunId = $RunId; Phase = $Phase; Worker = $Worker; ApplicationName = $ApplicationName; Schedule = @($Schedule); Disposed = $false }
                    $handle | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
                    $state.Starts.Add($handle)
                    $handle
                }
                Sample = {
                    param($RunId, $Phase, $Kind, $TrialPhase, $ScheduleEntry)
                    Write-Verbose $RunId
                    if ($Kind -eq 'Fingerprint') { return $state.Preflight }
                    if ($Kind -eq 'Trial') {
                        $optimizedTrial = $TrialPhase -eq 'Optimized'
                        $trial = [pscustomobject]@{ Phase = $TrialPhase; DurationMs = if ($optimizedTrial) { 70 } else { 100 }; CpuMs = if ($optimizedTrial) { 35 } else { 50 }; LogicalReads = if ($optimizedTrial) { 700 } else { 1000 }; GrantsKb = if ($optimizedTrial) { 200 } else { 400 }; SpillsMb = 0; WaitMs = if ($optimizedTrial) { 2 } else { 5 }; Correct = $true; ScheduleEntry = $ScheduleEntry }
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
                StopWorker = { param($Handle) $state.Stops.Add($Handle) }
                KillTagged = { param($RunId) Write-Verbose $RunId; @() }
                Persist = { param($Record) $state.Persisted.Add($Record) }
                Delay = { param([int] $Seconds) $state.Now = $state.Now.AddSeconds($Seconds) }
                Clock = { $state.Now }
                Export = { param($Result) Write-Verbose $Result.Outcome; $state.Exported = $true }
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

    It 'ramps one worker at a time, freezes after three baseline samples, and reuses exact conditions' {
        $fixture = Get-TestOperationSet
        $result = Invoke-WorkshopExperiment -RunId ([guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') `
            -OperationSet $fixture.Operations -MaximumWorkers 4 -MaximumDurationSeconds 600 `
            -SampleIntervalSeconds 5 -WorkerRampSeconds 10

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

    It 'requires exact unchanged optimized fingerprints' {
        $fixture = Get-TestOperationSet
        $sampleOperation = $fixture.Operations.Sample
        $drift = Get-TestPreflight -Hash ('a' * 64)
        $drift.DataHash = ('b' * 64)
        $fixture.Operations.Sample = {
            param($RunId, $Phase, $Kind, $TrialPhase, $ScheduleEntry)
            if ($Kind -eq 'Fingerprint') { return $drift }
            & $sampleOperation $RunId $Phase $Kind $TrialPhase $ScheduleEntry
        }.GetNewClosure()
        { Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations } |
            Should -Throw '*configuration or data drift*'
    }

    It 'never claims optimized success when baseline cannot reach target' {
        $baseline = 1..130 | ForEach-Object { Get-TestSample Baseline 70 }
        $fixture = Get-TestOperationSet -Baseline $baseline
        $result = Invoke-WorkshopExperiment -RunId ([guid]::NewGuid()) -OperationSet $fixture.Operations `
            -MaximumWorkers 4 -MaximumDurationSeconds 60 -SampleIntervalSeconds 5 -WorkerRampSeconds 10
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
            -WorkerRampSeconds 10
        $result.Trials.Count | Should -Be 12
        $result.Trials.Phase | Should -BeExactly @('Baseline','Optimized','Optimized','Baseline','Optimized','Baseline','Baseline','Optimized','Baseline','Optimized','Optimized','Baseline')
        foreach ($metric in @('DurationMs','CpuMs','LogicalReads','GrantsKb','SpillsMb','WaitMs')) {
            $result.Trials[0].psobject.Properties.Name | Should -Contain $metric
        }
    }

    It 'rejects incomplete preflight including SQL, memory, Query Store, MGF, objects, and validation' -ForEach @(
        @{ Property = 'MarkerValid'; Value = $false }
        @{ Property = 'SqlMajorVersion'; Value = 15 }
        @{ Property = 'SqlEdition'; Value = 'Standard Edition' }
        @{ Property = 'PhysicalMemoryMB'; Value = 32768 }
        @{ Property = 'QueryStoreActualState'; Value = 'READ_ONLY' }
        @{ Property = 'ResourcePool'; Value = 'default' }
        @{ Property = 'WorkloadGroup'; Value = 'default' }
        @{ Property = 'MemoryGrantFeedbackDisabled'; Value = $false }
        @{ Property = 'PriorMemoryGrantFeedbackState'; Value = $null }
        @{ Property = 'ProceduresPresent'; Value = $false }
        @{ Property = 'EvidenceSchemaPresent'; Value = $false }
        @{ Property = 'ValidationPassed'; Value = $false }
    ) {
        $preflight = Get-TestPreflight
        $preflight.$Property = $Value
        { Test-WorkshopPreflight -Snapshot $preflight } | Should -Throw
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
        $link = Join-Path $TestDrive 'evidence/runs/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $target = Join-Path $TestDrive 'junction-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Junction -Path $link -Target $target -Force | Out-Null
        { Export-WorkshopEvidenceFile -RunId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Evidence @{} -RepositoryRoot $TestDrive } |
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

    It 'declares strict entry bounds, ShouldProcess, and no insecure SQL fallback or Start-Sleep' {
        $start = Get-Content (Join-Path $PSScriptRoot '../../workload/Start-MemoryGrantLab.ps1') -Raw
        $stop = Get-Content (Join-Path $PSScriptRoot '../../workload/Stop-MemoryGrantLab.ps1') -Raw
        $export = Get-Content (Join-Path $PSScriptRoot '../../workload/Export-WorkshopEvidence.ps1') -Raw
        $module = Get-Content (Join-Path $PSScriptRoot '../../workload/Workshop.Workload.psm1') -Raw
        $start | Should -Match 'ValidateRange\(1,\s*4\)'
        $start | Should -Match 'ValidateRange\(60,\s*600\)'
        $start | Should -Match 'ValidateRange\(5,\s*30\)'
        $start | Should -Match 'ValidateRange\(10,\s*60\)'
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
    }
}
