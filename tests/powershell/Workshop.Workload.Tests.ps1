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
    It 'exports exactly the six pure functions' {
        $manifest = Test-ModuleManifest $ModulePath
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'ConvertTo-WorkshopEvidence'
            'Get-GrantUtilization'
            'Get-WorkshopOutcome'
            'New-WorkshopRunRecord'
            'Test-TargetBand'
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
