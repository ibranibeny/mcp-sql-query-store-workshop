Set-StrictMode -Version Latest

$script:OutcomeValues = @(
    'TargetMet',
    'ImprovedOutsideTarget',
    'NoMaterialImprovement',
    'BaselineTargetNotReached',
    'SafetyStop',
    'ManualStop',
    'Failed'
)
$script:SecretNamePattern = '(?i)(password|passwd|pwd|secret|token|credential|connection.?string|private.?key)'
$script:SecretAssignmentPattern = @'
(?ix)
(?:
    ["']?\s*
    (?:
        password|passwd|pwd|token|access[_\s-]?token|refresh[_\s-]?token|
        client[_\s-]?secret|secret|account[_\s-]?key|shared[_\s-]?access[_\s-]?key|
        shared[_\s-]?access[_\s-]?signature|user\s+id|uid
    )
    \s*["']?\s*[:=]
)
|(?:-----BEGIN\s+.*PRIVATE\s+KEY-----)
'@

function Resolve-CanonicalEnum {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [string[]] $AllowedValues,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $match = @($AllowedValues | Where-Object { $_ -ieq $Value })
    if ($match.Count -ne 1) {
        throw "Unknown $Name '$Value'."
    }
    return $match[0]
}

function ConvertTo-FiniteDecimal {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        throw "$Name must be a finite numeric value."
    }

    $typeCode = [System.Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @(
        [System.TypeCode]::Byte,
        [System.TypeCode]::SByte,
        [System.TypeCode]::Int16,
        [System.TypeCode]::UInt16,
        [System.TypeCode]::Int32,
        [System.TypeCode]::UInt32,
        [System.TypeCode]::Int64,
        [System.TypeCode]::UInt64,
        [System.TypeCode]::Single,
        [System.TypeCode]::Double,
        [System.TypeCode]::Decimal
    )) {
        throw "$Name must be a finite numeric value."
    }

    $doubleValue = [double] $Value
    if ([double]::IsNaN($doubleValue) -or [double]::IsInfinity($doubleValue)) {
        throw "$Name must be a finite numeric value."
    }

    try {
        return [decimal] $Value
    }
    catch {
        throw "$Name must be representable as a decimal value."
    }
}

function Get-ObjectEntry {
    param(
        [Parameter(Mandatory)]
        [object] $InputObject
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        return @($InputObject.Keys | ForEach-Object {
            [pscustomobject]@{ Name = [string] $_; Value = $InputObject[$_] }
        })
    }

    return @($InputObject.psobject.Properties | Where-Object MemberType -in @(
        'NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty'
    ) | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Value = $_.Value }
    })
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory)]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter()]
        [switch] $Required
    )

    $found = $false
    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        if (@($InputObject.Keys) -contains $Name) {
            $found = $true
            $value = $InputObject[$Name]
        }
    }
    else {
        $property = $InputObject.psobject.Properties[$Name]
        if ($null -ne $property) {
            $found = $true
            $value = $property.Value
        }
    }

    if ($found) {
        if ($value -is [System.Collections.IEnumerable] -and
            $value -isnot [string] -and $value -isnot [System.Collections.IDictionary]) {
            Write-Output -InputObject $value -NoEnumerate
        }
        else {
            return $value
        }
        return
    }

    if ($Required) {
        throw "Required property '$Name' is missing."
    }
    return $null
}

function Assert-ExactProperty {
    param(
        [Parameter(Mandatory)]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string[]] $RequiredNames,

        [Parameter(Mandatory)]
        [string] $Context
    )

    $actualNames = @(Get-ObjectEntry -InputObject $InputObject | ForEach-Object Name)
    $missing = @($RequiredNames | Where-Object { $_ -notin $actualNames })
    $unknown = @($actualNames | Where-Object { $_ -notin $RequiredNames })
    if ($missing.Count -gt 0 -or $unknown.Count -gt 0) {
        throw "$Context has an invalid shape. Missing: $($missing -join ', '); unknown: $($unknown -join ', ')."
    }
}

function Assert-NoSecretField {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter()]
        [string] $Path = '$'
    )

    if ($InputObject -is [string]) {
        if ($InputObject -match $script:SecretAssignmentPattern) {
            throw "Secret-shaped value at '$Path' is not allowed in evidence."
        }
        return
    }
    if ($null -eq $InputObject -or $InputObject.GetType().IsPrimitive) {
        return
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and
        $InputObject -isnot [System.Collections.IDictionary]) {
        $index = 0
        foreach ($item in $InputObject) {
            Assert-NoSecretField -InputObject $item -Path "$Path[$index]"
            $index++
        }
        return
    }

    foreach ($entry in Get-ObjectEntry -InputObject $InputObject) {
        if ($entry.Name -match $script:SecretNamePattern) {
            throw "Secret-shaped field '$Path.$($entry.Name)' is not allowed in evidence."
        }
        Assert-NoSecretField -InputObject $entry.Value -Path "$Path.$($entry.Name)"
    }
}

function ConvertTo-CanonicalValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject -or $InputObject -is [string] -or
        $InputObject -is [bool] -or $InputObject.GetType().IsPrimitive -or
        $InputObject -is [decimal] -or $InputObject -is [datetime] -or
        $InputObject -is [datetimeoffset] -or $InputObject -is [guid]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and
        $InputObject -isnot [System.Collections.IDictionary]) {
        return @($InputObject | ForEach-Object { ConvertTo-CanonicalValue -InputObject $_ })
    }

    $ordered = [ordered]@{}
    foreach ($entry in @(Get-ObjectEntry -InputObject $InputObject | Sort-Object Name)) {
        $ordered[$entry.Name] = ConvertTo-CanonicalValue -InputObject $entry.Value
    }
    return $ordered
}

function ConvertTo-ReadOnlyValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject -or $InputObject -is [string] -or
        $InputObject -is [bool] -or $InputObject.GetType().IsPrimitive -or
        $InputObject -is [decimal]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and
        $InputObject -isnot [System.Collections.IDictionary]) {
        $items = [object[]] @($InputObject | ForEach-Object {
            ConvertTo-ReadOnlyValue -InputObject $_
        })
        return [System.Array]::AsReadOnly($items)
    }

    $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in Get-ObjectEntry -InputObject $InputObject) {
        $dictionary.Add($entry.Name, (ConvertTo-ReadOnlyValue -InputObject $entry.Value))
    }
    return [System.Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($dictionary)
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function ConvertTo-UtcText {
    param(
        [Parameter(Mandatory)]
        [datetimeoffset] $Value
    )

    return $Value.UtcDateTime.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-UtcText {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') {
        throw "$Name must be an ISO 8601 UTC timestamp ending in Z."
    }

    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref] $parsed
    )) {
        throw "$Name must be a valid UTC timestamp."
    }
    return $parsed.ToUniversalTime()
}

function Assert-FrozenSetting {
    param(
        [Parameter(Mandatory)]
        [object] $Settings
    )

    $names = @(
        'workers', 'maximumDurationSeconds', 'sampleIntervalSeconds', 'workerRampSeconds',
        'resourcePool', 'workloadGroup', 'maxServerMemoryMB',
        'databaseScopedConfigurationHash', 'parameterSchedule', 'parameterScheduleHash'
    )
    Assert-ExactProperty -InputObject $Settings -RequiredNames $names -Context 'Frozen settings'
    Assert-NoSecretField -InputObject $Settings

    $workers = ConvertTo-FiniteDecimal (Get-ObjectValue $Settings workers -Required) 'workers'
    $duration = ConvertTo-FiniteDecimal (Get-ObjectValue $Settings maximumDurationSeconds -Required) 'maximumDurationSeconds'
    $sample = ConvertTo-FiniteDecimal (Get-ObjectValue $Settings sampleIntervalSeconds -Required) 'sampleIntervalSeconds'
    $ramp = ConvertTo-FiniteDecimal (Get-ObjectValue $Settings workerRampSeconds -Required) 'workerRampSeconds'
    $memory = ConvertTo-FiniteDecimal (Get-ObjectValue $Settings maxServerMemoryMB -Required) 'maxServerMemoryMB'
    if ($workers -ne [math]::Truncate($workers) -or $workers -lt 1 -or $workers -gt 4) {
        throw 'workers must be an integer from 1 through 4.'
    }
    if ($duration -ne [math]::Truncate($duration) -or $duration -lt 1 -or $duration -gt 600) {
        throw 'maximumDurationSeconds must be an integer from 1 through 600.'
    }
    if ($sample -ne [math]::Truncate($sample) -or $sample -lt 5 -or $sample -gt 30) {
        throw 'sampleIntervalSeconds must be an integer from 5 through 30.'
    }
    if ($ramp -ne [math]::Truncate($ramp) -or $ramp -lt 10 -or $ramp -gt 60) {
        throw 'workerRampSeconds must be an integer from 10 through 60.'
    }
    if ($memory -ne [math]::Truncate($memory) -or $memory -le 0) {
        throw 'maxServerMemoryMB must be a positive integer.'
    }

    foreach ($name in @('resourcePool', 'workloadGroup')) {
        $value = Get-ObjectValue $Settings $name -Required
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "$name must be a nonempty string."
        }
    }
    foreach ($name in @('databaseScopedConfigurationHash', 'parameterScheduleHash')) {
        if ((Get-ObjectValue $Settings $name -Required) -cnotmatch '^[a-f0-9]{64}$') {
            throw "$name must be a SHA-256 hash."
        }
    }

    $scheduleValue = Get-ObjectValue $Settings parameterSchedule -Required
    if ($scheduleValue -is [string] -or $scheduleValue -isnot [System.Collections.IEnumerable]) {
        throw 'parameterSchedule must contain at least one entry.'
    }
    $schedule = @($scheduleValue)
    if ($schedule.Count -lt 1) { throw 'parameterSchedule must contain at least one entry.' }
    foreach ($entry in $schedule) {
        if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
            throw 'parameterSchedule entries must be nonempty strings.'
        }
    }
    $scheduleJson = ConvertTo-Json -InputObject @($schedule) -Compress
    if ((Get-ObjectValue $Settings parameterScheduleHash -Required) -cne (Get-Sha256 $scheduleJson)) {
        throw 'parameterScheduleHash does not match the canonical parameterSchedule JSON.'
    }
}

function Assert-EnvironmentFingerprint {
    param(
        [Parameter(Mandatory)]
        [object] $Environment
    )

    $names = @('sqlVersion', 'sqlEdition', 'vmSku', 'region', 'imageVersion')
    Assert-ExactProperty -InputObject $Environment -RequiredNames $names -Context 'Environment fingerprint'
    Assert-NoSecretField -InputObject $Environment
    foreach ($name in $names) {
        $value = Get-ObjectValue $Environment $name -Required
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Environment field '$name' must be a nonempty string."
        }
    }
}

function Assert-TargetBand {
    param(
        [Parameter(Mandatory)]
        [object] $TargetBands
    )

    Assert-ExactProperty -InputObject $TargetBands -RequiredNames @('baseline', 'optimized') -Context 'Target bands'
    $expected = @{ baseline = @(75, 85); optimized = @(35, 45) }
    foreach ($phase in @('baseline', 'optimized')) {
        $band = Get-ObjectValue $TargetBands $phase -Required
        Assert-ExactProperty -InputObject $band -RequiredNames @('minimum', 'maximum') -Context "$phase target band"
        if ((Get-ObjectValue $band minimum -Required) -ne $expected[$phase][0] -or
            (Get-ObjectValue $band maximum -Required) -ne $expected[$phase][1]) {
            throw "$phase target band must be exactly $($expected[$phase][0]) through $($expected[$phase][1])."
        }
    }
}

function Get-GrantUtilization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $GrantedKb,

        [Parameter(Mandatory)]
        [object] $TotalKb
    )

    $granted = ConvertTo-FiniteDecimal $GrantedKb 'GrantedKb'
    $total = ConvertTo-FiniteDecimal $TotalKb 'TotalKb'
    if ($granted -lt 0 -or $total -le 0 -or $granted -gt $total) {
        throw 'GrantedKb must be nonnegative, TotalKb must be positive, and GrantedKb cannot exceed TotalKb.'
    }
    return [decimal]::Round(($granted * 100 / $total), 6, [System.MidpointRounding]::AwayFromZero)
}

function Test-TargetBand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Phase
    )

    $percentage = ConvertTo-FiniteDecimal $Value 'Value'
    if ($percentage -lt 0 -or $percentage -gt 100) {
        throw 'Value must be from 0 through 100.'
    }

    switch ($Phase.ToLowerInvariant()) {
        'baseline' { return $percentage -ge 75 -and $percentage -le 85 }
        'optimized' { return $percentage -ge 35 -and $percentage -le 45 }
        default { throw "Unknown phase '$Phase'." }
    }
}

function Test-WorkshopSafetySample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $HostUsedPercent,

        [Parameter(Mandatory)]
        [object] $HostAvailableMB,

        [Parameter(Mandatory)]
        [bool] $ProcessPhysicalLow,

        [Parameter(Mandatory)]
        [bool] $ProcessVirtualLow,

        [Parameter()]
        [int] $ConsecutiveHealthFailures = 0,

        [Parameter(Mandatory)]
        [object] $ElapsedSeconds,

        [Parameter(Mandatory)]
        [object] $MaximumDurationSeconds,

        [Parameter()]
        [string] $Phase = 'Baseline',

        [Parameter()]
        [bool] $ManualStop = $false
    )

    $hostUsed = ConvertTo-FiniteDecimal $HostUsedPercent 'HostUsedPercent'
    $available = ConvertTo-FiniteDecimal $HostAvailableMB 'HostAvailableMB'
    $elapsed = ConvertTo-FiniteDecimal $ElapsedSeconds 'ElapsedSeconds'
    $maximum = ConvertTo-FiniteDecimal $MaximumDurationSeconds 'MaximumDurationSeconds'
    if ($hostUsed -lt 0 -or $hostUsed -gt 100 -or $available -lt 0 -or
        $ConsecutiveHealthFailures -lt 0 -or $elapsed -lt 0 -or $maximum -le 0) {
        throw 'Safety sample values are outside their valid ranges.'
    }
    if ($Phase -notin @('Baseline', 'Optimized')) {
        throw "Unknown phase '$Phase'."
    }

    if ($ManualStop) {
        return [pscustomobject][ordered]@{
            Decision = 'Stop'
            Outcome = 'ManualStop'
            Reasons = @('Manual stop requested.')
        }
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($hostUsed -gt [decimal]'87.5') { $reasons.Add('Host memory utilization exceeded 87.5 percent.') }
    if ($available -lt 8192) { $reasons.Add('Host available memory fell below 8192 MB.') }
    if ($ProcessPhysicalLow) { $reasons.Add('SQL process physical low-memory flag is set.') }
    if ($ProcessVirtualLow) { $reasons.Add('SQL process virtual low-memory flag is set.') }
    if ($ConsecutiveHealthFailures -ge 2) { $reasons.Add('Two consecutive health checks failed.') }
    if ($reasons.Count -gt 0) {
        return [pscustomobject][ordered]@{
            Decision = 'Stop'
            Outcome = 'SafetyStop'
            Reasons = $reasons.ToArray()
        }
    }

    if ($elapsed -ge $maximum) {
        $timeoutOutcome = if ($Phase -eq 'Baseline') {
            'BaselineTargetNotReached'
        }
        else {
            'NoMaterialImprovement'
        }
        return [pscustomobject][ordered]@{
            Decision = 'Stop'
            Outcome = $timeoutOutcome
            Reasons = @("$Phase maximum duration reached without a measured target decision.")
        }
    }

    return [pscustomobject][ordered]@{
        Decision = 'Continue'
        Outcome = $null
        Reasons = @()
    }
}

function Get-WorkshopOutcome {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $BaselinePeak,

        [Parameter()]
        [AllowNull()]
        [object] $OptimizedPeak,

        [Parameter(Mandatory)]
        [bool] $CorrectnessPassed,

        [Parameter(Mandatory)]
        [bool] $MaterialRegression,

        [Parameter()]
        [AllowNull()]
        [Nullable[bool]] $AdditionalMetricImproved = $null,

        [Parameter()]
        [bool] $SafetyStopped = $false,

        [Parameter()]
        [bool] $ManualStopped = $false
    )

    if ($ManualStopped) { return 'ManualStop' }
    if ($SafetyStopped) { return 'SafetyStop' }

    $baseline = if ($null -eq $BaselinePeak) {
        $null
    }
    else {
        $value = ConvertTo-FiniteDecimal $BaselinePeak 'BaselinePeak'
        if ($value -lt 0 -or $value -gt 100) { throw 'BaselinePeak must be from 0 through 100.' }
        $value
    }
    $optimized = if ($null -eq $OptimizedPeak) {
        $null
    }
    else {
        $value = ConvertTo-FiniteDecimal $OptimizedPeak 'OptimizedPeak'
        if ($value -lt 0 -or $value -gt 100) { throw 'OptimizedPeak must be from 0 through 100.' }
        $value
    }

    if ($null -eq $baseline -or -not (Test-TargetBand $baseline Baseline)) {
        return 'BaselineTargetNotReached'
    }
    if (-not $CorrectnessPassed -or $null -eq $optimized) {
        return 'Failed'
    }
    if ($MaterialRegression -or
        ($null -ne $AdditionalMetricImproved -and -not [bool] $AdditionalMetricImproved)) {
        return 'NoMaterialImprovement'
    }
    if (Test-TargetBand $optimized Optimized) {
        return 'TargetMet'
    }
    if (($baseline - $optimized) -ge 25) {
        return 'ImprovedOutsideTarget'
    }
    return 'NoMaterialImprovement'
}

function New-WorkshopRunRecord {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Baseline', 'Optimized', 'Comparison', 'Target')]
        [string] $Phase,

        [Parameter(Mandatory)]
        [ValidateSet('Planned', 'Completed', 'BaselineTargetNotReached', 'SafetyStop', 'ManualStop', 'Failed')]
        [string] $Status,

        [Parameter(Mandatory)]
        [ValidateSet('TARGET', 'LAB-MEASURED')]
        [string] $EvidenceClassification,

        [Parameter(Mandatory)]
        [object] $FrozenSettings,

        [Parameter(Mandatory)]
        [object] $EnvironmentFingerprint,

        [Parameter(Mandatory)]
        [object] $TargetBands,

        [Parameter()]
        [datetimeoffset] $StartUtc = [datetimeoffset]::UtcNow,

        [Parameter()]
        [AllowNull()]
        [object] $EndUtc
    )

    Assert-FrozenSetting -Settings $FrozenSettings
    Assert-EnvironmentFingerprint -Environment $EnvironmentFingerprint
    Assert-TargetBand -TargetBands $TargetBands
    Assert-NoSecretField -InputObject $FrozenSettings
    Assert-NoSecretField -InputObject $EnvironmentFingerprint

    $Phase = Resolve-CanonicalEnum $Phase @('Baseline', 'Optimized', 'Comparison', 'Target') 'phase'
    $Status = Resolve-CanonicalEnum $Status @(
        'Planned', 'Completed', 'BaselineTargetNotReached', 'SafetyStop', 'ManualStop', 'Failed'
    ) 'status'
    $EvidenceClassification = Resolve-CanonicalEnum `
        $EvidenceClassification @('TARGET', 'LAB-MEASURED') 'evidence classification'

    $normalizedEndUtc = if ($null -eq $EndUtc) { $null } else { [datetimeoffset] $EndUtc }
    if ($null -ne $normalizedEndUtc -and $normalizedEndUtc -lt $StartUtc) {
        throw 'EndUtc cannot precede StartUtc.'
    }
    if ($EvidenceClassification -eq 'TARGET') {
        if ($Status -ne 'Planned' -or $Phase -ne 'Target' -and $Phase -ne 'Baseline' -or $null -ne $normalizedEndUtc) {
            throw 'TARGET records must be planned, unended Target or Baseline records.'
        }
    }
    elseif ($Status -eq 'Planned' -or $null -eq $normalizedEndUtc) {
        throw 'LAB-MEASURED records require a terminal status and EndUtc.'
    }

    $canonicalSettings = ConvertTo-CanonicalValue -InputObject $FrozenSettings
    $settingsJson = ConvertTo-Json -InputObject $canonicalSettings -Depth 20 -Compress
    return [pscustomobject][ordered]@{
        RunId = [guid]::NewGuid().ToString('D')
        Phase = $Phase
        Status = $Status
        EvidenceClassification = $EvidenceClassification
        StartUtc = ConvertTo-UtcText $StartUtc
        EndUtc = if ($null -eq $normalizedEndUtc) { $null } else { ConvertTo-UtcText $normalizedEndUtc }
        Environment = ConvertTo-ReadOnlyValue (ConvertTo-CanonicalValue $EnvironmentFingerprint)
        FrozenSettings = ConvertTo-ReadOnlyValue $canonicalSettings
        FrozenSettingsJson = $settingsJson
        FrozenSettingsHash = Get-Sha256 $settingsJson
        TargetBands = ConvertTo-ReadOnlyValue (ConvertTo-CanonicalValue $TargetBands)
    }
}

function Assert-SampleCollection {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Samples,

        [Parameter(Mandatory)]
        [datetimeoffset] $StartUtc,

        [Parameter()]
        [AllowNull()]
        [object] $EndUtc,

        [Parameter()]
        [switch] $Request
    )

    $previousTimestamp = [datetimeoffset]::MinValue
    for ($index = 0; $index -lt $Samples.Count; $index++) {
        $sample = $Samples[$index]
        $expectedNames = if ($Request) {
            @('sequence', 'timestampUtc', 'phase', 'durationMs', 'cpuMs', 'logicalReads', 'spillsMb', 'waitMs')
        }
        else {
            @(
                'sequence', 'timestampUtc', 'phase', 'grantedKb', 'totalKb',
                'grantUtilizationPercent', 'hostUsedPercent', 'hostAvailableMB',
                'processPhysicalLow', 'processVirtualLow'
            )
        }
        Assert-ExactProperty -InputObject $sample -RequiredNames $expectedNames -Context 'Sample'
        Assert-NoSecretField -InputObject $sample
        if ((Get-ObjectValue $sample sequence -Required) -ne ($index + 1)) {
            throw 'Sample sequence must start at 1 and be contiguous.'
        }
        $timestamp = ConvertFrom-UtcText (Get-ObjectValue $sample timestampUtc -Required) 'sample timestampUtc'
        if ($timestamp -le $previousTimestamp) {
            throw 'Sample timestamps must be strictly increasing.'
        }
        if ($timestamp -lt $StartUtc -or ($null -ne $EndUtc -and $timestamp -gt ([datetimeoffset] $EndUtc))) {
            throw 'Sample timestamp falls outside the run interval.'
        }
        $previousTimestamp = $timestamp

        [void] (Resolve-CanonicalEnum `
            (Get-ObjectValue $sample phase -Required) @('Baseline', 'Optimized') 'sample phase')

        if ($Request) {
            foreach ($name in @('durationMs', 'cpuMs', 'logicalReads', 'spillsMb', 'waitMs')) {
                $metric = ConvertTo-FiniteDecimal (Get-ObjectValue $sample $name -Required) $name
                if ($metric -lt 0) { throw "$name cannot be negative." }
            }
        }
        else {
            $calculated = Get-GrantUtilization `
                (Get-ObjectValue $sample grantedKb -Required) `
                (Get-ObjectValue $sample totalKb -Required)
            $reported = ConvertTo-FiniteDecimal `
                (Get-ObjectValue $sample grantUtilizationPercent -Required) `
                'grantUtilizationPercent'
            $hostUsed = ConvertTo-FiniteDecimal `
                (Get-ObjectValue $sample hostUsedPercent -Required) `
                'hostUsedPercent'
            $available = ConvertTo-FiniteDecimal `
                (Get-ObjectValue $sample hostAvailableMB -Required) `
                'hostAvailableMB'
            if ($reported -lt 0 -or $reported -gt 100 -or $reported -ne $calculated) {
                throw 'grantUtilizationPercent is invalid or does not match grantedKb and totalKb.'
            }
            if ($hostUsed -lt 0 -or $hostUsed -gt 100 -or $available -lt 0) {
                throw 'Host memory metrics are outside their valid ranges.'
            }
            foreach ($name in @('processPhysicalLow', 'processVirtualLow')) {
                if ((Get-ObjectValue $sample $name -Required) -isnot [bool]) {
                    throw "$name must be Boolean."
                }
            }
        }
    }
}

function ConvertTo-CanonicalSampleCollection {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Samples
    )

    return @($Samples | ForEach-Object {
        $canonical = ConvertTo-CanonicalValue $_
        $canonical.phase = Resolve-CanonicalEnum `
            (Get-ObjectValue $_ phase -Required) @('Baseline', 'Optimized') 'sample phase'
        $canonical
    })
}

function ConvertTo-TerminationEvidence {
    param(
        [Parameter()]
        [AllowNull()]
        [object] $TerminationEvidence
    )

    if ($null -eq $TerminationEvidence) {
        return [ordered]@{
            manualStopRequested = $false
            safetyStopTriggered = $false
            safetyReasons = @()
            timeout = $false
        }
    }

    Assert-ExactProperty -InputObject $TerminationEvidence -RequiredNames @(
        'manualStopRequested', 'safetyStopTriggered', 'safetyReasons', 'timeout'
    ) -Context 'Termination evidence'
    Assert-NoSecretField $TerminationEvidence
    foreach ($name in @('manualStopRequested', 'safetyStopTriggered', 'timeout')) {
        if ((Get-ObjectValue $TerminationEvidence $name -Required) -isnot [bool]) {
            throw "Termination evidence field '$name' must be Boolean."
        }
    }

    $reasonValue = Get-ObjectValue $TerminationEvidence safetyReasons -Required
    if ($reasonValue -is [string] -or $reasonValue -isnot [System.Collections.IEnumerable]) {
        throw 'safetyReasons must be an array of strings.'
    }
    $reasons = @($reasonValue)
    foreach ($reason in $reasons) {
        if ($reason -isnot [string] -or [string]::IsNullOrWhiteSpace($reason)) {
            throw 'safetyReasons entries must be nonempty strings.'
        }
    }

    $manual = Get-ObjectValue $TerminationEvidence manualStopRequested -Required
    $safety = Get-ObjectValue $TerminationEvidence safetyStopTriggered -Required
    if ($manual -and $safety) {
        throw 'Manual and safety stop flags cannot both be set.'
    }
    if ($safety -and $reasons.Count -eq 0) {
        throw 'A safety stop requires at least one safety reason.'
    }
    if (-not $safety -and $reasons.Count -ne 0) {
        throw 'Safety reasons require the safety stop flag.'
    }

    return [ordered]@{
        manualStopRequested = $manual
        safetyStopTriggered = $safety
        safetyReasons = $reasons
        timeout = Get-ObjectValue $TerminationEvidence timeout -Required
    }
}

function ConvertTo-WorkshopEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $RunRecord,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Samples,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $RequestSamples,

        [Parameter()]
        [AllowNull()]
        [object] $Validation,

        [Parameter()]
        [AllowNull()]
        [string] $Outcome,

        [Parameter()]
        [AllowNull()]
        [object] $TerminationEvidence
    )

    Assert-NoSecretField -InputObject $RunRecord
    $classification = Resolve-CanonicalEnum `
        (Get-ObjectValue $RunRecord EvidenceClassification -Required) `
        @('TARGET', 'LAB-MEASURED') 'evidence classification'
    $phase = Resolve-CanonicalEnum (Get-ObjectValue $RunRecord Phase -Required) `
        @('Baseline', 'Optimized', 'Comparison', 'Target') 'phase'
    $status = Resolve-CanonicalEnum (Get-ObjectValue $RunRecord Status -Required) @(
        'Planned', 'Completed', 'BaselineTargetNotReached', 'SafetyStop', 'ManualStop', 'Failed'
    ) 'status'
    if ($classification -eq 'TARGET') {
        if ($phase -notin @('Target', 'Baseline') -or $status -ne 'Planned') {
            throw 'TARGET evidence requires Target or Baseline phase and Planned status.'
        }
    }
    elseif ($phase -notin @('Baseline', 'Optimized', 'Comparison') -or $status -eq 'Planned') {
        throw 'LAB-MEASURED evidence requires a measured phase and terminal status.'
    }
    $runId = Get-ObjectValue $RunRecord RunId -Required
    $parsedRunId = [guid]::Empty
    if ($runId -isnot [string] -or -not [guid]::TryParseExact($runId, 'D', [ref] $parsedRunId)) {
        throw 'RunId must be a canonical GUID.'
    }

    $start = ConvertFrom-UtcText (Get-ObjectValue $RunRecord StartUtc -Required) 'StartUtc'
    $endText = Get-ObjectValue $RunRecord EndUtc
    $end = if ($null -eq $endText) { $null } else { ConvertFrom-UtcText $endText 'EndUtc' }
    if ($null -ne $end -and $end -lt $start) { throw 'EndUtc cannot precede StartUtc.' }

    $settings = Get-ObjectValue $RunRecord FrozenSettings -Required
    Assert-FrozenSetting $settings
    $canonicalSettings = ConvertTo-CanonicalValue $settings
    $settingsJson = ConvertTo-Json $canonicalSettings -Depth 20 -Compress
    $recordJson = Get-ObjectValue $RunRecord FrozenSettingsJson -Required
    $recordHash = Get-ObjectValue $RunRecord FrozenSettingsHash -Required
    if ($recordJson -cne $settingsJson -or $recordHash -cne (Get-Sha256 $settingsJson)) {
        throw 'Frozen settings JSON or SHA-256 hash does not match the frozen settings object.'
    }

    $environment = Get-ObjectValue $RunRecord Environment -Required
    $targetBands = Get-ObjectValue $RunRecord TargetBands -Required
    Assert-EnvironmentFingerprint $environment
    Assert-TargetBand $targetBands
    $Samples = @(ConvertTo-CanonicalSampleCollection $Samples)
    $RequestSamples = @(ConvertTo-CanonicalSampleCollection $RequestSamples)
    Assert-SampleCollection -Samples $Samples -StartUtc $start -EndUtc $end
    Assert-SampleCollection -Samples $RequestSamples -StartUtc $start -EndUtc $end -Request
    $termination = ConvertTo-TerminationEvidence $TerminationEvidence

    $baselinePeak = $null
    $optimizedPeak = $null
    if ($Samples.Count -gt 0) {
        $baselineValues = @($Samples | Where-Object {
            (Get-ObjectValue $_ phase -Required) -eq 'Baseline'
        } | ForEach-Object { Get-ObjectValue $_ grantUtilizationPercent -Required })
        $optimizedValues = @($Samples | Where-Object {
            (Get-ObjectValue $_ phase -Required) -eq 'Optimized'
        } | ForEach-Object { Get-ObjectValue $_ grantUtilizationPercent -Required })
        if ($baselineValues.Count -gt 0) { $baselinePeak = [decimal] (($baselineValues | Measure-Object -Maximum).Maximum) }
        if ($optimizedValues.Count -gt 0) { $optimizedPeak = [decimal] (($optimizedValues | Measure-Object -Maximum).Maximum) }
    }

    $correctness = $null
    if ($classification -eq 'TARGET') {
        if ($Samples.Count -ne 0 -or $RequestSamples.Count -ne 0 -or $null -ne $Validation -or
            -not [string]::IsNullOrEmpty($Outcome) -or $null -ne $end -or
            (Get-ObjectValue $RunRecord Status -Required) -ne 'Planned') {
            throw 'TARGET evidence cannot contain measurements, validation, an outcome, or an end timestamp.'
        }
        $baselinePeak = $null
        $optimizedPeak = $null
        $Outcome = $null
        if ($termination.manualStopRequested -or $termination.safetyStopTriggered -or
            $termination.safetyReasons.Count -ne 0 -or $termination.timeout) {
            throw 'TARGET evidence cannot contain termination claims.'
        }
    }
    else {
        if ($Samples.Count -eq 0 -or $null -eq $Validation -or $null -eq $end -or
            [string]::IsNullOrEmpty($Outcome)) {
            throw 'LAB-MEASURED evidence requires samples, validation, EndUtc, and outcome.'
        }
        Assert-ExactProperty -InputObject $Validation -RequiredNames @(
            'passed', 'materialRegression', 'additionalMetricImproved', 'validationHash'
        ) -Context 'Validation'
        Assert-NoSecretField $Validation
        foreach ($name in @('passed', 'materialRegression', 'additionalMetricImproved')) {
            if ((Get-ObjectValue $Validation $name -Required) -isnot [bool]) {
                throw "Validation field '$name' must be Boolean."
            }
        }
        if ((Get-ObjectValue $Validation validationHash -Required) -cnotmatch '^[a-f0-9]{64}$') {
            throw 'validationHash must be a SHA-256 hash.'
        }
        $Outcome = Resolve-CanonicalEnum $Outcome $script:OutcomeValues 'outcome'
        $baselineSamples = @($Samples | Where-Object {
            (Get-ObjectValue $_ phase -Required) -ceq 'Baseline'
        })
        $optimizedSamples = @($Samples | Where-Object {
            (Get-ObjectValue $_ phase -Required) -ceq 'Optimized'
        })
        if ($Outcome -in @('TargetMet', 'ImprovedOutsideTarget', 'NoMaterialImprovement') -and
            ($baselineSamples.Count -eq 0 -or $optimizedSamples.Count -eq 0 -or
                $null -eq $baselinePeak -or $null -eq $optimizedPeak)) {
            throw "Outcome '$Outcome' requires measured Baseline and Optimized samples and peaks."
        }
        if ($Outcome -ceq 'BaselineTargetNotReached' -and
            ($phase -cne 'Baseline' -or $baselineSamples.Count -eq 0 -or
                $optimizedSamples.Count -ne 0 -or $null -eq $baselinePeak -or
                $null -ne $optimizedPeak)) {
            throw 'BaselineTargetNotReached requires only Baseline samples and a null Optimized peak.'
        }
        if ($Outcome -in @('SafetyStop', 'ManualStop')) {
            $terminationPhaseSamples = if ($phase -ceq 'Baseline') {
                $baselineSamples
            }
            elseif ($phase -ceq 'Optimized') {
                $optimizedSamples
            }
            else {
                @()
            }
            if (@($terminationPhaseSamples).Count -eq 0) {
                throw "Outcome '$Outcome' requires a sample matching termination phase '$phase'."
            }
        }
        if ($termination.manualStopRequested -and $Outcome -cne 'ManualStop') {
            throw 'A manual stop flag requires the ManualStop outcome.'
        }
        if ($termination.safetyStopTriggered -and $Outcome -cne 'SafetyStop') {
            throw 'A safety stop flag requires the SafetyStop outcome.'
        }
        if ($Outcome -ceq 'ManualStop' -and -not $termination.manualStopRequested) {
            throw 'ManualStop requires an independent manual stop flag.'
        }
        if ($Outcome -ceq 'SafetyStop' -and -not $termination.safetyStopTriggered) {
            throw 'SafetyStop requires an independent safety stop flag.'
        }
        if ($Outcome -in @('TargetMet', 'ImprovedOutsideTarget') -and $termination.timeout) {
            throw "Outcome '$Outcome' cannot claim a timeout."
        }
        $expectedOutcome = Get-WorkshopOutcome -BaselinePeak $baselinePeak `
            -OptimizedPeak $optimizedPeak `
            -CorrectnessPassed (Get-ObjectValue $Validation passed -Required) `
            -MaterialRegression (Get-ObjectValue $Validation materialRegression -Required) `
            -AdditionalMetricImproved (Get-ObjectValue $Validation additionalMetricImproved -Required) `
            -SafetyStopped $termination.safetyStopTriggered `
            -ManualStopped $termination.manualStopRequested
        if ($Outcome -cne $expectedOutcome) {
            throw "Outcome '$Outcome' does not match the measured evidence outcome '$expectedOutcome'."
        }
        $expectedStatus = if ($Outcome -in @('TargetMet', 'ImprovedOutsideTarget', 'NoMaterialImprovement')) {
            'Completed'
        }
        else {
            $Outcome
        }
        if ($status -cne $expectedStatus) {
            throw "Status '$status' does not match outcome '$Outcome'."
        }
        $correctness = ConvertTo-CanonicalValue $Validation
    }

    return [pscustomobject][ordered]@{
        schemaVersion = '1.0.0'
        evidenceClassification = $classification
        disclaimer = if ($classification -eq 'TARGET') {
            'Targets only; this is not an executed benchmark and contains no measured results.'
        }
        else {
            'LAB-MEASURED evidence captured from the identified workshop environment.'
        }
        runId = $runId
        phase = $phase
        status = $status
        startUtc = Get-ObjectValue $RunRecord StartUtc -Required
        endUtc = $endText
        environment = ConvertTo-CanonicalValue $environment
        frozenSettings = $canonicalSettings
        frozenSettingsJson = $settingsJson
        frozenSettingsHash = $recordHash
        targetBands = ConvertTo-CanonicalValue $targetBands
        samples = @($Samples | ForEach-Object { ConvertTo-CanonicalValue $_ })
        requestSamples = @($RequestSamples | ForEach-Object { ConvertTo-CanonicalValue $_ })
        measuredPeaks = [ordered]@{ baseline = $baselinePeak; optimized = $optimizedPeak }
        correctness = $correctness
        terminationEvidence = $termination
        outcome = $Outcome
    }
}

Export-ModuleMember -Function @(
    'Get-GrantUtilization',
    'Test-TargetBand',
    'Test-WorkshopSafetySample',
    'Get-WorkshopOutcome',
    'New-WorkshopRunRecord',
    'ConvertTo-WorkshopEvidence'
)
