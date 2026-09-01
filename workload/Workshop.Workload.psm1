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

function Get-WorkshopApplicationName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $RunId,

        [Parameter(Mandatory)]
        [ValidateSet('Baseline', 'Optimized')]
        [string] $Phase,

        [Parameter(Mandatory)]
        [ValidateRange(1, 4)]
        [int] $Worker
    )

    return "MCP-SQL-Workshop-$($RunId.ToString('D'))-$Phase-$Worker"
}

function Get-WorkshopParameterSchedule {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject][ordered]@{ StartDate = '2022-01-01'; EndDateExclusive = '2023-01-01'; TerritoryID = $null; TopCount = 100 }
        [pscustomobject][ordered]@{ StartDate = '2021-04-01'; EndDateExclusive = '2022-04-01'; TerritoryID = 1; TopCount = 100 }
        [pscustomobject][ordered]@{ StartDate = '2019-01-01'; EndDateExclusive = '2020-01-01'; TerritoryID = $null; TopCount = 250 }
        [pscustomobject][ordered]@{ StartDate = '2022-06-01'; EndDateExclusive = '2022-07-01'; TerritoryID = 4; TopCount = 100 }
    )
}

function Get-WorkshopTrialSequence {
    [CmdletBinding()]
    param()

    return @('A', 'B', 'B', 'A', 'B', 'A', 'A', 'B', 'A', 'B', 'B', 'A')
}

function Test-WorkshopPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Snapshot
    )

    $requiredHashes = @(
        'ServerConfigurationHash', 'PoolConfigurationHash', 'DatabaseConfigurationHash',
        'DataHash', 'IndexStatisticsHash', 'ProcedureHash'
    )
    $failures = [System.Collections.Generic.List[string]]::new()
    if (-not $Snapshot.MarkerValid) { $failures.Add('The workshop marker is invalid.') }
    if ([int] $Snapshot.SqlMajorVersion -ne 16) { $failures.Add('SQL Server major version 16 is required.') }
    if ([string] $Snapshot.SqlEdition -notmatch 'Enterprise') { $failures.Add('SQL Server Enterprise edition is required.') }
    if ([int64] $Snapshot.PhysicalMemoryMB -lt 63000 -or [int64] $Snapshot.PhysicalMemoryMB -gt 66000) {
        $failures.Add('The 64 GB host memory profile is required.')
    }
    if ([string] $Snapshot.QueryStoreActualState -cne 'READ_WRITE') { $failures.Add('Query Store must be READ_WRITE.') }
    if ([string] $Snapshot.ResourcePool -cne 'mcp_sql_workshop_pool') { $failures.Add('The exact workshop resource pool is required.') }
    if ([string] $Snapshot.WorkloadGroup -cne 'mcp_sql_workshop_group') { $failures.Add('The exact workshop workload group is required.') }
    if (-not $Snapshot.MemoryGrantFeedbackDisabled) { $failures.Add('Memory grant feedback must be disabled for the experiment.') }
    if ([string]::IsNullOrWhiteSpace([string] $Snapshot.PriorMemoryGrantFeedbackState)) {
        $failures.Add('The prior memory grant feedback state must be recorded.')
    }
    if (-not $Snapshot.ProceduresPresent) { $failures.Add('Both workload procedures must be present.') }
    if (-not $Snapshot.EvidenceSchemaPresent) { $failures.Add('The evidence schema must be present.') }
    $validationBatch = [guid]::Empty
    if (-not $Snapshot.ValidationPassed -or
        -not [guid]::TryParseExact([string] $Snapshot.ValidationBatchID, 'D', [ref] $validationBatch)) {
        $failures.Add('A complete passing correctness validation batch is required.')
    }
    foreach ($name in $requiredHashes) {
        if ([string] $Snapshot.$name -cnotmatch '^[a-f0-9]{64}$') {
            $failures.Add("$name must be a lowercase SHA-256 fingerprint.")
        }
    }
    if ($failures.Count -gt 0) {
        throw "Workshop preflight failed: $($failures -join ' ')"
    }
    return $true
}

function Assert-WorkshopOperationSet {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $OperationSet)

    $required = @('OpenConnection', 'StartWorker', 'Sample', 'StopWorker', 'KillTagged', 'Persist', 'Delay', 'Clock', 'Export')
    $missing = @($required | Where-Object { -not $OperationSet.Contains($_) -or $OperationSet[$_] -isnot [scriptblock] })
    if ($missing.Count -gt 0) {
        throw "OperationSet is missing scriptblock operations: $($missing -join ', ')."
    }
}

function Test-WorkshopFingerprintMatch {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )

    foreach ($name in @(
        'ServerConfigurationHash', 'PoolConfigurationHash', 'DatabaseConfigurationHash',
        'DataHash', 'IndexStatisticsHash', 'ProcedureHash'
    )) {
        if ([string] $Expected.$name -cne [string] $Actual.$name) { return $false }
    }
    return $true
}

function Get-WorkshopTrialAssessment {
    param([Parameter(Mandatory)][object[]] $Trials)

    $baseline = @($Trials | Where-Object Phase -eq 'Baseline')
    $optimized = @($Trials | Where-Object Phase -eq 'Optimized')
    $correctnessPassed = @($Trials | Where-Object { -not $_.Correct }).Count -eq 0
    $metrics = @('DurationMs', 'CpuMs', 'LogicalReads', 'GrantsKb', 'SpillsMb', 'WaitMs')
    $improved = $false
    $materialRegression = $false
    foreach ($metric in $metrics) {
        $baselineAverage = [decimal] (($baseline | Measure-Object -Property $metric -Average).Average)
        $optimizedAverage = [decimal] (($optimized | Measure-Object -Property $metric -Average).Average)
        if ($optimizedAverage -lt $baselineAverage) { $improved = $true }
        if ($baselineAverage -gt 0 -and $optimizedAverage -gt ($baselineAverage * [decimal]'1.10')) {
            $materialRegression = $true
        }
    }
    return [pscustomobject]@{
        CorrectnessPassed = $correctnessPassed
        AdditionalMetricImproved = $improved
        MaterialRegression = $materialRegression
    }
}

function Invoke-WorkshopExperiment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [guid] $RunId,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $OperationSet,

        [Parameter()]
        [ValidateRange(1, 4)]
        [int] $MaximumWorkers = 4,

        [Parameter()]
        [ValidateRange(60, 600)]
        [int] $MaximumDurationSeconds = 600,

        [Parameter()]
        [ValidateRange(5, 30)]
        [int] $SampleIntervalSeconds = 5,

        [Parameter()]
        [ValidateRange(10, 60)]
        [int] $WorkerRampSeconds = 20
    )

    Assert-WorkshopOperationSet $OperationSet
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Run bounded workshop memory-grant experiment')) { return }

    $preflight = & $OperationSet.OpenConnection 'Preflight'
    [void] (Test-WorkshopPreflight -Snapshot $preflight)
    $scheduleObjects = @(Get-WorkshopParameterSchedule)
    $schedule = @($scheduleObjects | ForEach-Object { ConvertTo-Json $_ -Compress })
    $scheduleJson = ConvertTo-Json $schedule -Compress
    $workers = [System.Collections.Generic.List[object]]::new()
    $samples = [System.Collections.Generic.List[object]]::new()
    $trials = [System.Collections.Generic.List[object]]::new()
    $start = [datetimeoffset] (& $OperationSet.Clock)
    $lastRamp = $start.AddSeconds(-$WorkerRampSeconds)
    $consecutive = 0
    $outcome = $null
    $frozen = $null

    try {
        $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase Baseline -Worker 1
        $workers.Add((& $OperationSet.StartWorker $RunId 'Baseline' 1 $applicationName $schedule))
        while ($null -eq $outcome -and $null -eq $frozen) {
            $now = [datetimeoffset] (& $OperationSet.Clock)
            $elapsed = ($now - $start).TotalSeconds
            $sample = & $OperationSet.Sample $RunId 'Baseline' 'Memory' $null $null
            $samples.Add($sample)
            $safety = Test-WorkshopSafetySample -HostUsedPercent $sample.HostUsedPercent `
                -HostAvailableMB $sample.HostAvailableMB -ProcessPhysicalLow $sample.ProcessPhysicalLow `
                -ProcessVirtualLow $sample.ProcessVirtualLow `
                -ConsecutiveHealthFailures $(if ($sample.Healthy) { 0 } else { 2 }) `
                -ElapsedSeconds $elapsed -MaximumDurationSeconds $MaximumDurationSeconds `
                -Phase Baseline -ManualStop $sample.ManualStopRequested
            if ($safety.Decision -eq 'Stop') { $outcome = $safety.Outcome; break }
            if (Test-TargetBand $sample.GrantUtilizationPercent Baseline) { $consecutive++ } else { $consecutive = 0 }
            if ($consecutive -ge 3) {
                $frozen = [ordered]@{
                    workers = $workers.Count
                    maximumDurationSeconds = $MaximumDurationSeconds
                    sampleIntervalSeconds = $SampleIntervalSeconds
                    workerRampSeconds = $WorkerRampSeconds
                    resourcePool = 'mcp_sql_workshop_pool'
                    workloadGroup = 'mcp_sql_workshop_group'
                    maxServerMemoryMB = 49152
                    databaseScopedConfigurationHash = [string] $preflight.DatabaseConfigurationHash
                    parameterSchedule = $schedule
                    parameterScheduleHash = Get-Sha256 $scheduleJson
                }
                $frozenJson = ConvertTo-Json (ConvertTo-CanonicalValue $frozen) -Depth 20 -Compress
                $frozenHash = Get-Sha256 $frozenJson
                break
            }
            if ($sample.Healthy -and $sample.GrantUtilizationPercent -lt 75 -and
                $sample.HostAvailableMB -gt 12288 -and $workers.Count -lt $MaximumWorkers -and
                ($now - $lastRamp).TotalSeconds -ge $WorkerRampSeconds) {
                $workerNumber = $workers.Count + 1
                $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase Baseline -Worker $workerNumber
                $workers.Add((& $OperationSet.StartWorker $RunId 'Baseline' $workerNumber $applicationName $schedule))
                $lastRamp = $now
            }
            & $OperationSet.Delay $SampleIntervalSeconds
        }

        foreach ($worker in @($workers)) { & $OperationSet.StopWorker $worker }
        foreach ($worker in @($workers)) { if ($worker -is [System.IDisposable] -or $worker.psobject.Methods['Dispose']) { $worker.Dispose() } }
        $workers.Clear()

        if ($null -ne $outcome) {
            $result = [pscustomobject]@{ RunId = $RunId; Outcome = $outcome; FrozenSettings = $null; Samples = $samples.ToArray(); Trials = @() }
            & $OperationSet.Persist $result
            & $OperationSet.Export $result
            return $result
        }

        $drainStart = [datetimeoffset] (& $OperationSet.Clock)
        do {
            $drain = & $OperationSet.Sample $RunId 'Baseline' 'Drain' $null $null
            if ([int] $drain.ActiveGrantCount -eq 0) { break }
            & $OperationSet.Delay $SampleIntervalSeconds
        } while ((([datetimeoffset] (& $OperationSet.Clock)) - $drainStart).TotalSeconds -lt 60)
        if ([int] $drain.ActiveGrantCount -ne 0) { throw 'Baseline grants did not drain within the bounded interval.' }

        $optimizedFingerprint = & $OperationSet.Sample $RunId 'Optimized' 'Fingerprint' $null $null
        if (-not (Test-WorkshopFingerprintMatch -Expected $preflight -Actual $optimizedFingerprint)) {
            throw 'Optimized phase rejected because configuration or data drift was detected.'
        }

        $consecutive = 0
        for ($index = 1; $index -le [int] $frozen.workers; $index++) {
            $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase Optimized -Worker $index
            $workers.Add((& $OperationSet.StartWorker $RunId 'Optimized' $index $applicationName $schedule))
        }
        while ($null -eq $outcome) {
            $now = [datetimeoffset] (& $OperationSet.Clock)
            $sample = & $OperationSet.Sample $RunId 'Optimized' 'Memory' $null $null
            $samples.Add($sample)
            $safety = Test-WorkshopSafetySample -HostUsedPercent $sample.HostUsedPercent `
                -HostAvailableMB $sample.HostAvailableMB -ProcessPhysicalLow $sample.ProcessPhysicalLow `
                -ProcessVirtualLow $sample.ProcessVirtualLow `
                -ConsecutiveHealthFailures $(if ($sample.Healthy) { 0 } else { 2 }) `
                -ElapsedSeconds (($now - $start).TotalSeconds) `
                -MaximumDurationSeconds $MaximumDurationSeconds -Phase Optimized `
                -ManualStop $sample.ManualStopRequested
            if ($safety.Decision -eq 'Stop') { $outcome = $safety.Outcome; break }
            if (Test-TargetBand $sample.GrantUtilizationPercent Optimized) { $consecutive++ } else { $consecutive = 0 }
            if ($consecutive -ge 3) { break }
            & $OperationSet.Delay $SampleIntervalSeconds
        }

        foreach ($worker in @($workers)) { & $OperationSet.StopWorker $worker }
        foreach ($worker in @($workers)) { if ($worker -is [System.IDisposable] -or $worker.psobject.Methods['Dispose']) { $worker.Dispose() } }
        $workers.Clear()

        if ($null -eq $outcome) {
            $sequence = @(Get-WorkshopTrialSequence)
            for ($index = 0; $index -lt $sequence.Count; $index++) {
                if ((([datetimeoffset] (& $OperationSet.Clock)) - $start).TotalSeconds -ge $MaximumDurationSeconds) {
                    $outcome = 'NoMaterialImprovement'
                    break
                }
                $trialPhase = if ($sequence[$index] -eq 'A') { 'Baseline' } else { 'Optimized' }
                $entry = $schedule[$index % $schedule.Count]
                $trials.Add((& $OperationSet.Sample $RunId 'Comparison' 'Trial' $trialPhase $entry))
            }
            $assessment = Get-WorkshopTrialAssessment -Trials $trials.ToArray()
            $baselinePeak = [decimal] ((@($samples | Where-Object Phase -eq Baseline | Measure-Object GrantUtilizationPercent -Maximum).Maximum))
            $optimizedPeak = [decimal] ((@($samples | Where-Object Phase -eq Optimized | Measure-Object GrantUtilizationPercent -Maximum).Maximum))
            $outcome = Get-WorkshopOutcome -BaselinePeak $baselinePeak -OptimizedPeak $optimizedPeak `
                -CorrectnessPassed $assessment.CorrectnessPassed `
                -MaterialRegression $assessment.MaterialRegression `
                -AdditionalMetricImproved $assessment.AdditionalMetricImproved
        }

        $result = [pscustomobject]@{
            RunId = $RunId
            Outcome = $outcome
            ValidationBatchID = $preflight.ValidationBatchID
            FrozenSettings = [pscustomobject] $frozen
            FrozenSettingsJson = $frozenJson
            FrozenSettingsHash = $frozenHash
            BaselineFingerprint = $preflight
            Samples = $samples.ToArray()
            Trials = $trials.ToArray()
        }
        & $OperationSet.Persist $result
        & $OperationSet.Export $result
        return $result
    }
    finally {
        foreach ($worker in @($workers)) {
            try { & $OperationSet.StopWorker $worker } catch { Write-Verbose 'Worker stop failed during cleanup.' }
            try { if ($worker -is [System.IDisposable] -or $worker.psobject.Methods['Dispose']) { $worker.Dispose() } } catch { Write-Verbose 'Worker disposal failed during cleanup.' }
        }
        if ($workers.Count -gt 0) { [void] (& $OperationSet.KillTagged $RunId) }
    }
}

function Get-WorkshopKillPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid] $RunId,
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][ValidateRange(1, 32767)][int] $CurrentSessionId
    )

    $namePattern = '^MCP-SQL-Workshop-' + [regex]::Escape($RunId.ToString('D')) + '-(?:Baseline|Optimized)-[1-4]$'
    $expectedBytes = $RunId.ToByteArray()
    return @($Sessions | Where-Object {
        $sessionId = 0
        $validId = [int]::TryParse([string] $_.SessionId, [ref] $sessionId)
        $context = [byte[]] $_.ContextInfo
        $contextMatches = $context.Length -eq $expectedBytes.Length -and
            [System.Linq.Enumerable]::SequenceEqual[byte]($context, $expectedBytes)
        $validId -and $sessionId -gt 0 -and $sessionId -ne $CurrentSessionId -and
            $_.IsUserProcess -and $_.IsActive -and
            ([string] $_.ProgramName) -cmatch $namePattern -and
            $contextMatches
    } | Sort-Object SessionId | ForEach-Object {
        $sessionId = [int] $_.SessionId
        [pscustomobject][ordered]@{ SessionId = $sessionId; Statement = "KILL $sessionId;" }
    })
}

function Export-WorkshopEvidenceFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][object] $Evidence,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter()][scriptblock] $SemanticValidator,
        [Parameter()][switch] $AllowReplaceCompletedRun
    )

    $parsedRunId = [guid]::Empty
    if (-not [guid]::TryParseExact($RunId, 'D', [ref] $parsedRunId) -or $parsedRunId.ToString('D') -cne $RunId) {
        throw 'RunId must be a lowercase canonical GUID.'
    }
    Assert-NoSecretField -InputObject $Evidence
    if ([string] (Get-ObjectValue $Evidence runId) -and [string] (Get-ObjectValue $Evidence runId) -cne $RunId) {
        throw 'Evidence run ID does not match the output run ID.'
    }
    $runsRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'evidence/runs'))
    $directory = [IO.Path]::GetFullPath((Join-Path $runsRoot $RunId))
    if (-not $directory.StartsWith("$runsRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Evidence output path escapes the runs directory.'
    }
    [void] (New-Item -ItemType Directory -Path $runsRoot -Force)
    if (Test-Path -LiteralPath $directory) {
        $directoryItem = Get-Item -LiteralPath $directory -Force
        if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Evidence output cannot be a reparse point or symbolic link.'
        }
    }
    $jsonPath = Join-Path $directory 'evidence.json'
    $csvPath = Join-Path $directory 'samples.csv'
    if ((Test-Path -LiteralPath $jsonPath) -and -not $AllowReplaceCompletedRun) {
        throw 'A completed run cannot be overwritten without the explicit safe replace flag.'
    }
    if ((Test-Path -LiteralPath $jsonPath) -and $AllowReplaceCompletedRun) {
        $existing = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        if ([string] $existing.runId -cne $RunId) { throw 'Existing completed run identity does not match.' }
    }
    if (-not $PSCmdlet.ShouldProcess($directory, 'Write validated workshop evidence')) { return }

    $utf8 = [Text.UTF8Encoding]::new($false)
    $stagingDirectory = Join-Path $runsRoot ".$RunId.$([guid]::NewGuid().ToString('N')).tmp"
    [void] (New-Item -ItemType Directory -Path $stagingDirectory)
    $jsonTemp = Join-Path $stagingDirectory 'evidence.json'
    $csvTemp = Join-Path $stagingDirectory 'samples.csv'
    try {
        [IO.File]::WriteAllText($jsonTemp, (ConvertTo-Json $Evidence -Depth 30), $utf8)
        if ($SemanticValidator) {
            if (-not (& $SemanticValidator $jsonTemp)) { throw 'Canonical semantic evidence validation failed.' }
        }
        else {
            $python = Join-Path $RepositoryRoot '.venv/Scripts/python.exe'
            $validator = Join-Path $RepositoryRoot 'evidence/validate_evidence.py'
            $schema = Join-Path $RepositoryRoot 'evidence/evidence-schema.json'
            & $python $validator --schema $schema $jsonTemp | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Canonical semantic evidence validation failed.' }
        }
        $csv = @((Get-ObjectValue $Evidence samples)) | ConvertTo-Csv -NoTypeInformation
        [IO.File]::WriteAllLines($csvTemp, [string[]] $csv, $utf8)
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        Move-Item -LiteralPath $stagingDirectory -Destination $directory
    }
    finally {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Directory = $directory; JsonPath = $jsonPath; CsvPath = $csvPath }
}

function Get-WorkshopSqlOperationSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Server,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][pscredential] $Credential,
        [Parameter(Mandatory)][string] $HostNameInCertificate
    )

    try { Add-Type -AssemblyName Microsoft.Data.SqlClient -ErrorAction Stop } catch {
        throw 'Microsoft.Data.SqlClient is required. Install it from NuGet (Microsoft.Data.SqlClient) before running the workshop; no insecure fallback is available.'
    }
    if ($Server -match '^\s*(?:localhost|\.|\d{1,3}(?:\.\d{1,3}){3})(?:,\d+)?\s*$' -or $Server -notmatch '\.') {
        throw 'Server must be the SQL VM private DNS name.'
    }
    if ($HostNameInCertificate -cne $Server) {
        throw 'HostNameInCertificate must exactly match the private DNS server name.'
    }
    Write-Verbose "Preparing SQL operations for database '$Database' and credential user '$($Credential.UserName)'."

    $invokeTable = {
        param([string] $ApplicationName, [string] $CommandText, [hashtable] $Parameters)
        $builder = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $builder.DataSource = $Server
        $builder.InitialCatalog = $Database
        $builder.Encrypt = $true
        $builder.TrustServerCertificate = $false
        $builder.HostNameInCertificate = $HostNameInCertificate
        $builder.ApplicationName = $ApplicationName
        $builder.UserID = $Credential.UserName
        $bstr = [IntPtr]::Zero
        $connection = $null
        $command = $null
        $reader = $null
        try {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
            $builder.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $connection = [Microsoft.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandText = $CommandText
            $command.CommandTimeout = 60
            foreach ($name in @($Parameters.Keys)) {
                $specification = $Parameters[$name]
                $parameter = $command.Parameters.Add($name, $specification.Type)
                if ($specification.ContainsKey('Size')) { $parameter.Size = $specification.Size }
                $parameter.Value = if ($null -eq $specification.Value) { [DBNull]::Value } else { $specification.Value }
            }
            $reader = $command.ExecuteReader()
            $rows = [System.Collections.Generic.List[object]]::new()
            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($index = 0; $index -lt $reader.FieldCount; $index++) {
                    $row[$reader.GetName($index)] = if ($reader.IsDBNull($index)) { $null } else { $reader.GetValue($index) }
                }
                $rows.Add([pscustomobject] $row)
            }
            return $rows.ToArray()
        }
        finally {
            $builder.Password = [string]::Empty
            if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $command) { $command.Dispose() }
            if ($null -ne $connection) { $connection.Dispose() }
        }
    }.GetNewClosure()

    $stopRequestPath = Join-Path (Split-Path -Parent $PSScriptRoot) "evidence/runs/{0}/stop.request"
    $preflightSql = @'
SELECT
    CONVERT(bit, CASE WHEN DB_NAME() = N'AdventureWorks2022' AND EXISTS
        (SELECT 1 FROM lab.WorkshopMarker WHERE MarkerId = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C') THEN 1 ELSE 0 END) AS MarkerValid,
    CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) AS SqlMajorVersion,
    CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS SqlEdition,
    CONVERT(bigint, memory.total_physical_memory_kb / 1024) AS PhysicalMemoryMB,
    CONVERT(varchar(60), queryStore.actual_state_desc) AS QueryStoreActualState,
    CONVERT(sysname, pool.name) AS ResourcePool,
    CONVERT(sysname, workloadGroup.name) AS WorkloadGroup,
    CONVERT(bit, CASE WHEN databaseConfig.value = 0 THEN 1 ELSE 0 END) AS MemoryGrantFeedbackDisabled,
    CONVERT(nvarchar(60), backupState.PriorMemoryGrantFeedbackState) AS PriorMemoryGrantFeedbackState,
    CONVERT(bit, CASE WHEN OBJECT_ID(N'lab.usp_MonthEndSalesBaseline', N'P') IS NOT NULL
        AND OBJECT_ID(N'lab.usp_MonthEndSalesOptimized', N'P') IS NOT NULL THEN 1 ELSE 0 END) AS ProceduresPresent,
    CONVERT(bit, CASE WHEN OBJECT_ID(N'lab.WorkshopRun', N'U') IS NOT NULL
        AND OBJECT_ID(N'lab.WorkshopSample', N'U') IS NOT NULL
        AND OBJECT_ID(N'lab.WorkshopRequestSample', N'U') IS NOT NULL THEN 1 ELSE 0 END) AS EvidenceSchemaPresent,
    validation.ValidationBatchID,
    CONVERT(bit, CASE WHEN validation.PassingCases = 11 AND validation.TotalCases = 11 THEN 1 ELSE 0 END) AS ValidationPassed,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT(SERVERPROPERTY('ProductVersion'), N'|', configuration.value_in_use)), 2)) AS ServerConfigurationHash,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT(pool.name, N'|', pool.max_memory_percent, N'|', workloadGroup.request_max_memory_grant_percent)), 2)) AS PoolConfigurationHash,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT(DATABASEPROPERTYEX(DB_NAME(), 'Updateability'), N'|', databaseConfig.value)), 2)) AS DatabaseConfigurationHash,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT((SELECT COUNT_BIG(*) FROM lab.FactSales), N'|', (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(SyntheticSalesID)) FROM lab.FactSales))), 2)) AS DataHash,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT((SELECT COUNT_BIG(*) FROM sys.indexes WHERE object_id = OBJECT_ID(N'lab.FactSales')), N'|', (SELECT SUM(row_count) FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID(N'lab.FactSales')))), 2)) AS IndexStatisticsHash,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT(OBJECT_DEFINITION(OBJECT_ID(N'lab.usp_MonthEndSalesBaseline')), OBJECT_DEFINITION(OBJECT_ID(N'lab.usp_MonthEndSalesOptimized')))), 2)) AS ProcedureHash
FROM sys.dm_os_sys_memory AS memory
CROSS JOIN sys.database_query_store_options AS queryStore
INNER JOIN sys.dm_resource_governor_resource_pools AS pool ON pool.name = N'mcp_sql_workshop_pool'
INNER JOIN sys.dm_resource_governor_workload_groups AS workloadGroup ON workloadGroup.pool_id = pool.pool_id AND workloadGroup.name = N'mcp_sql_workshop_group'
INNER JOIN sys.database_scoped_configurations AS databaseConfig ON databaseConfig.name = N'ROW_MODE_MEMORY_GRANT_FEEDBACK'
INNER JOIN sys.configurations AS configuration ON configuration.name = N'max server memory (MB)'
OUTER APPLY (SELECT TOP (1) CONVERT(nvarchar(60), RowModeMemoryGrantFeedback) AS PriorMemoryGrantFeedbackState FROM WorkshopAdmin.dbo.DatabaseConfigurationBackup WHERE DatabaseName = DB_NAME() ORDER BY CapturedAtUtc DESC) AS backupState
OUTER APPLY (SELECT TOP (1) ValidationBatchID, COUNT_BIG(*) AS TotalCases, SUM(CONVERT(bigint, Passed)) AS PassingCases FROM lab.ValidationRun GROUP BY ValidationBatchID HAVING COUNT_BIG(*) = 11 ORDER BY MAX(ValidatedAtUtc) DESC) AS validation;
'@
    $getPreflight = {
        $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Preflight' $preflightSql @{})
        if ($rows.Count -ne 1) { throw 'Workshop SQL preflight did not return exactly one row.' }
        return $rows[0]
    }.GetNewClosure()

    $startWorker = {
        param([guid] $RunId, [string] $Phase, [int] $Worker, [string] $ApplicationName, [object[]] $Schedule)
        Write-Verbose "Starting workshop worker $Worker for $Phase."
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $powerShell = [powershell]::Create()
        $powerShell.Runspace = $runspace
        [void] $powerShell.AddScript({
            param($WorkerServer, $WorkerDatabase, [pscredential] $WorkerCredential, $WorkerCertificateName,
                $WorkerRunId, $WorkerPhase, $WorkerApplicationName, $WorkerSchedule)
            Add-Type -AssemblyName Microsoft.Data.SqlClient -ErrorAction Stop
            $builder = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
            $builder.DataSource = $WorkerServer
            $builder.InitialCatalog = $WorkerDatabase
            $builder.Encrypt = $true
            $builder.TrustServerCertificate = $false
            $builder.HostNameInCertificate = $WorkerCertificateName
            $builder.ApplicationName = $WorkerApplicationName
            $builder.UserID = $WorkerCredential.UserName
            $bstr = [IntPtr]::Zero
            $connection = $null
            try {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($WorkerCredential.Password)
                $builder.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $connection = [Microsoft.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
                $connection.Open()
                $tag = $connection.CreateCommand()
                try {
                    $tag.CommandText = "SET CONTEXT_INFO @RunBytes; EXEC sys.sp_set_session_context @key=N'WorkshopRunId', @value=@RunId; EXEC sys.sp_set_session_context @key=N'WorkshopPhase', @value=@Phase;"
                    [void] $tag.Parameters.Add('@RunBytes', [Data.SqlDbType]::Binary, 16)
                    $tag.Parameters['@RunBytes'].Value = ([guid] $WorkerRunId).ToByteArray()
                    [void] $tag.Parameters.Add('@RunId', [Data.SqlDbType]::UniqueIdentifier)
                    $tag.Parameters['@RunId'].Value = [guid] $WorkerRunId
                    [void] $tag.Parameters.Add('@Phase', [Data.SqlDbType]::NVarChar, 16)
                    $tag.Parameters['@Phase'].Value = $WorkerPhase
                    [void] $tag.ExecuteNonQuery()
                }
                finally { $tag.Dispose() }

                for ($iteration = 0; $iteration -lt 10000; $iteration++) {
                    $entry = $WorkerSchedule[$iteration % $WorkerSchedule.Count] | ConvertFrom-Json
                    $command = $connection.CreateCommand()
                    try {
                        $procedure = if ($WorkerPhase -eq 'Baseline') { 'lab.usp_MonthEndSalesBaseline' } else { 'lab.usp_MonthEndSalesOptimized' }
                        $command.CommandText = "EXEC $procedure @StartDate=@StartDate, @EndDateExclusive=@EndDateExclusive, @TerritoryID=@TerritoryID, @TopCount=@TopCount;"
                        $command.CommandTimeout = 600
                        [void] $command.Parameters.Add('@StartDate', [Data.SqlDbType]::Date)
                        $command.Parameters['@StartDate'].Value = [datetime] $entry.StartDate
                        [void] $command.Parameters.Add('@EndDateExclusive', [Data.SqlDbType]::Date)
                        $command.Parameters['@EndDateExclusive'].Value = [datetime] $entry.EndDateExclusive
                        [void] $command.Parameters.Add('@TerritoryID', [Data.SqlDbType]::Int)
                        $command.Parameters['@TerritoryID'].Value = if ($null -eq $entry.TerritoryID) { [DBNull]::Value } else { [int] $entry.TerritoryID }
                        [void] $command.Parameters.Add('@TopCount', [Data.SqlDbType]::Int)
                        $command.Parameters['@TopCount'].Value = [int] $entry.TopCount
                        [void] $command.ExecuteNonQuery()
                    }
                    finally { $command.Dispose() }
                }
            }
            finally {
                $builder.Password = [string]::Empty
                if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                if ($null -ne $connection) { $connection.Dispose() }
            }
        }).AddArgument($Server).AddArgument($Database).AddArgument($Credential).AddArgument($HostNameInCertificate).AddArgument($RunId).AddArgument($Phase).AddArgument($ApplicationName).AddArgument($Schedule)
        try { $asyncResult = $powerShell.BeginInvoke() }
        catch {
            $powerShell.Dispose()
            $runspace.Dispose()
            throw
        }
        $handle = [pscustomobject]@{
            PowerShell = $powerShell
            Runspace = $runspace
            AsyncResult = $asyncResult
            Disposed = $false
        }
        $handle | Add-Member ScriptMethod Dispose {
            if ($this.Disposed) { return }
            try {
                if (-not $this.AsyncResult.IsCompleted) { $this.PowerShell.Stop() }
                try { [void] $this.PowerShell.EndInvoke($this.AsyncResult) } catch { Write-Verbose 'Worker ended after cancellation.' }
            }
            finally {
                $this.PowerShell.Dispose()
                $this.Runspace.Dispose()
                $this.Disposed = $true
            }
        }
        return $handle
    }.GetNewClosure()

    $sample = {
        param([guid] $RunId, [string] $Phase, [string] $Kind, [string] $TrialPhase, [string] $ScheduleEntry)
        if ($Kind -eq 'Fingerprint') { return (& $getPreflight) }
        if ($Kind -eq 'Memory' -or $Kind -eq 'Drain') {
            $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Sample' 'EXEC lab.usp_GetMemorySnapshot;' @{})
            if ($rows.Count -ne 1) { throw 'Memory snapshot did not return exactly one row.' }
            $row = $rows[0]
            $totalHost = [decimal] $row.HostAvailableMemoryKB + [decimal] $row.HostUsedMemoryKB
            return [pscustomobject]@{
                Phase = $Phase; GrantedKb = $row.PoolGrantedMemoryKB; TotalKb = $row.PoolTotalMemoryKB
                GrantUtilizationPercent = $row.GrantUtilizationPercent
                HostUsedPercent = if ($totalHost -eq 0) { 100 } else { 100 * [decimal] $row.HostUsedMemoryKB / $totalHost }
                HostAvailableMB = [decimal] $row.HostAvailableMemoryKB / 1024
                ProcessPhysicalLow = [bool] $row.ProcessLowMemorySignal
                ProcessVirtualLow = [bool] $row.SystemLowMemorySignal
                Healthy = $true; ActiveGrantCount = [int] $row.GranteeCount + [int] $row.WaiterCount
                ManualStopRequested = Test-Path -LiteralPath ($stopRequestPath -f $RunId.ToString('D'))
            }
        }
        if ($Kind -eq 'Trial') {
            $entry = $ScheduleEntry | ConvertFrom-Json
            $procedure = if ($TrialPhase -eq 'Baseline') { 'lab.usp_MonthEndSalesBaseline' } else { 'lab.usp_MonthEndSalesOptimized' }
            $sql = "SET NOCOUNT ON; DECLARE @Started datetime2(7)=SYSUTCDATETIME(), @Cpu bigint=(SELECT cpu_time FROM sys.dm_exec_sessions WHERE session_id=@@SPID), @Reads bigint=(SELECT logical_reads FROM sys.dm_exec_sessions WHERE session_id=@@SPID), @Wait bigint=(SELECT COALESCE(SUM(wait_time_ms),0) FROM sys.dm_exec_session_wait_stats WHERE session_id=@@SPID); EXEC $procedure @StartDate=@StartDate, @EndDateExclusive=@EndDateExclusive, @TerritoryID=@TerritoryID, @TopCount=@TopCount; SELECT CONVERT(bigint,DATEDIFF_BIG(microsecond,@Started,SYSUTCDATETIME())/1000) AS DurationMs, CONVERT(bigint,s.cpu_time-@Cpu) AS CpuMs, CONVERT(bigint,s.logical_reads-@Reads) AS LogicalReads, CONVERT(bigint,COALESCE(p.last_grant_kb,0)) AS GrantsKb, CONVERT(decimal(19,2),COALESCE(p.last_spills,0)*8.0/1024) AS SpillsMb, CONVERT(bigint,(SELECT COALESCE(SUM(wait_time_ms),0) FROM sys.dm_exec_session_wait_stats WHERE session_id=@@SPID)-@Wait) AS WaitMs, CONVERT(bit,@Correct) AS Correct FROM sys.dm_exec_sessions AS s OUTER APPLY (SELECT TOP (1) last_grant_kb,last_spills FROM sys.dm_exec_query_stats CROSS APPLY sys.dm_exec_sql_text(sql_handle) AS t WHERE t.objectid=OBJECT_ID(N'$procedure') ORDER BY last_execution_time DESC) AS p WHERE s.session_id=@@SPID;"
            $parameters = @{
                '@StartDate' = @{ Type = [Data.SqlDbType]::Date; Value = [datetime] $entry.StartDate }
                '@EndDateExclusive' = @{ Type = [Data.SqlDbType]::Date; Value = [datetime] $entry.EndDateExclusive }
                '@TerritoryID' = @{ Type = [Data.SqlDbType]::Int; Value = $entry.TerritoryID }
                '@TopCount' = @{ Type = [Data.SqlDbType]::Int; Value = [int] $entry.TopCount }
                '@Correct' = @{ Type = [Data.SqlDbType]::Bit; Value = $true }
            }
            $rows = @(& $invokeTable "MCP-SQL-Workshop-$($RunId.ToString('D'))-$TrialPhase-1" $sql $parameters)
            $rows[0] | Add-Member NoteProperty Phase $TrialPhase -PassThru
        }
    }.GetNewClosure()

    $stopWorker = {
        param($Handle)
        if ($null -ne $Handle -and $Handle.psobject.Methods['Dispose']) { $Handle.Dispose() }
    }

    $killTagged = {
        param([guid] $RunId)
        $sessionSql = "SELECT CONVERT(int,s.session_id) AS SessionId, CONVERT(bit,s.is_user_process) AS IsUserProcess, CONVERT(bit,CASE WHEN r.session_id IS NOT NULL THEN 1 ELSE 0 END) AS IsActive, CONVERT(nvarchar(128),s.program_name) AS ProgramName, CONVERT(varbinary(128),s.context_info) AS ContextInfo, CONVERT(int,@@SPID) AS CurrentSessionId FROM sys.dm_exec_sessions AS s LEFT JOIN sys.dm_exec_requests AS r ON r.session_id=s.session_id WHERE s.program_name LIKE @Prefix;"
        $parameters = @{ '@Prefix' = @{ Type = [Data.SqlDbType]::NVarChar; Size = 128; Value = "MCP-SQL-Workshop-$($RunId.ToString('D'))-%" } }
        $sessions = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Stop' $sessionSql $parameters)
        if ($sessions.Count -eq 0) { return @() }
        $plan = @(Get-WorkshopKillPlan -RunId $RunId -Sessions $sessions -CurrentSessionId $sessions[0].CurrentSessionId)
        foreach ($entry in $plan) {
            # Persist the exact captured row before executing a KILL generated solely from a validated integer SPID.
            [void] (& $invokeTable 'MCP-SQL-Workshop-Controller-Stop' $entry.Statement @{})
        }
        return @($plan.SessionId)
    }.GetNewClosure()

    $persist = {
        param($Record)
        if ($null -eq $Record.FrozenSettingsJson -or $null -eq $Record.FrozenSettingsHash) {
            Write-Verbose "Run $($Record.RunId) terminated before frozen conditions existed; terminal evidence remains file-backed."
            return
        }
        $hashBytes = [Convert]::FromHexString([string] $Record.FrozenSettingsHash)
        $sql = @'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF NOT EXISTS (SELECT 1 FROM lab.WorkshopRun WITH (UPDLOCK, HOLDLOCK) WHERE RunID=@RunId)
    INSERT lab.WorkshopRun
        (RunID, ParentComparisonID, EvidenceClassification, Phase, RunStatus, Outcome,
         StartedAtUtc, CompletedAtUtc, FrozenSettingsHash, FrozenSettingsJson)
    VALUES
        (@RunId, NULL, 'LAB-MEASURED', 'Comparison', 'Completed', @Outcome,
         @CompletedAtUtc, @CompletedAtUtc, @FrozenSettingsHash, @FrozenSettingsJson);
COMMIT TRANSACTION;
'@
        [void] (& $invokeTable 'MCP-SQL-Workshop-Controller-Persist' $sql @{
            '@RunId' = @{ Type = [Data.SqlDbType]::UniqueIdentifier; Value = $Record.RunId }
            '@Outcome' = @{ Type = [Data.SqlDbType]::NVarChar; Size = 24; Value = $Record.Outcome }
            '@CompletedAtUtc' = @{ Type = [Data.SqlDbType]::DateTime2; Value = [datetime]::UtcNow }
            '@FrozenSettingsHash' = @{ Type = [Data.SqlDbType]::Binary; Size = 32; Value = $hashBytes }
            '@FrozenSettingsJson' = @{ Type = [Data.SqlDbType]::NVarChar; Size = 4000; Value = $Record.FrozenSettingsJson }
        })
    }.GetNewClosure()

    return @{
        OpenConnection = { param($Purpose) Write-Verbose "Opening $Purpose controller connection."; & $getPreflight }.GetNewClosure()
        StartWorker = $startWorker
        Sample = $sample
        StopWorker = $stopWorker
        KillTagged = $killTagged
        Persist = $persist
        Delay = { param([int] $Seconds) [Threading.Tasks.Task]::Delay([TimeSpan]::FromSeconds($Seconds)).GetAwaiter().GetResult() }
        Clock = { [datetimeoffset]::UtcNow }
        Export = { param($Result) if ($Result.psobject.Properties['Evidence']) { Export-WorkshopEvidenceFile -RunId $Result.RunId.ToString('D') -Evidence $Result.Evidence -RepositoryRoot (Split-Path -Parent $PSScriptRoot) -Confirm:$false } else { Write-Verbose "Run $($Result.RunId) persisted; canonical evidence is exported after evidence conversion." } }
    }
}

Export-ModuleMember -Function @(
    'Get-GrantUtilization',
    'Test-TargetBand',
    'Test-WorkshopSafetySample',
    'Get-WorkshopOutcome',
    'New-WorkshopRunRecord',
    'ConvertTo-WorkshopEvidence',
    'Get-WorkshopApplicationName',
    'Get-WorkshopParameterSchedule',
    'Get-WorkshopTrialSequence',
    'Test-WorkshopPreflight',
    'Invoke-WorkshopExperiment',
    'Get-WorkshopKillPlan',
    'Export-WorkshopEvidenceFile',
    'Get-WorkshopSqlOperationSet'
)
