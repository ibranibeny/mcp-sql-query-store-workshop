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
    if ($null -eq $InputObject -or $InputObject.GetType().IsPrimitive -or
        $InputObject -is [decimal] -or $InputObject -is [datetime] -or
        $InputObject -is [datetimeoffset] -or $InputObject -is [guid]) {
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
        'databaseScopedConfigurationHash', 'validationBatchHash',
        'parameterSchedule', 'parameterScheduleHash'
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
    foreach ($name in @('databaseScopedConfigurationHash', 'validationBatchHash', 'parameterScheduleHash')) {
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

    $names = @('sqlVersion', 'sqlEdition', 'physicalMemoryMB')
    Assert-ExactProperty -InputObject $Environment -RequiredNames $names -Context 'Environment fingerprint'
    Assert-NoSecretField -InputObject $Environment
    foreach ($name in @('sqlVersion', 'sqlEdition')) {
        $value = Get-ObjectValue $Environment $name -Required
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Environment field '$name' must be a nonempty string."
        }
    }
    if ((Get-ObjectValue $Environment physicalMemoryMB -Required) -isnot [ValueType] -or
        [decimal](Get-ObjectValue $Environment physicalMemoryMB -Required) -le 0) {
        throw "Environment field 'physicalMemoryMB' must be a positive measured number."
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
        [guid] $RunId = [guid]::NewGuid(),

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
        RunId = $RunId.ToString('D')
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
                        @('sampleSequence','sessionId','requestId','requestedMemoryKB','grantedMemoryKB',
                            'requiredMemoryKB','idealMemoryKB','usedMemoryKB','maxUsedMemoryKB','waitOrder',
                            'waitTimeMs','queryId','planId')
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
        if ($Request) {
            foreach ($name in @('sampleSequence','sessionId','requestId','requestedMemoryKB','grantedMemoryKB',
                'requiredMemoryKB','idealMemoryKB','usedMemoryKB','maxUsedMemoryKB','waitTimeMs')) {
                $metric = ConvertTo-FiniteDecimal (Get-ObjectValue $sample $name -Required) $name
                if ($metric -lt 0) { throw "$name cannot be negative." }
            }
            continue
        }
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

        if (-not $Request) {
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
        [ordered]@{
            sequence = [int](Get-ObjectValue $_ sequence -Required)
            timestampUtc = [string](Get-ObjectValue $_ timestampUtc -Required)
            phase = Resolve-CanonicalEnum (Get-ObjectValue $_ phase -Required) @('Baseline', 'Optimized') 'sample phase'
            grantedKb = Get-ObjectValue $_ grantedKb -Required
            totalKb = Get-ObjectValue $_ totalKb -Required
            grantUtilizationPercent = Get-ObjectValue $_ grantUtilizationPercent -Required
            hostUsedPercent = Get-ObjectValue $_ hostUsedPercent -Required
            hostAvailableMB = Get-ObjectValue $_ hostAvailableMB -Required
            processPhysicalLow = Get-ObjectValue $_ processPhysicalLow -Required
            processVirtualLow = Get-ObjectValue $_ processVirtualLow -Required
        }
    })
}

function ConvertTo-CanonicalRequestSampleCollection {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Samples)
    return @($Samples | ForEach-Object {
        [ordered]@{
            sampleSequence = [int](Get-ObjectValue $_ sampleSequence -Required)
            sessionId = [int](Get-ObjectValue $_ sessionId -Required)
            requestId = [int](Get-ObjectValue $_ requestId -Required)
            requestedMemoryKB = Get-ObjectValue $_ requestedMemoryKB -Required
            grantedMemoryKB = Get-ObjectValue $_ grantedMemoryKB -Required
            requiredMemoryKB = Get-ObjectValue $_ requiredMemoryKB -Required
            idealMemoryKB = Get-ObjectValue $_ idealMemoryKB -Required
            usedMemoryKB = Get-ObjectValue $_ usedMemoryKB -Required
            maxUsedMemoryKB = Get-ObjectValue $_ maxUsedMemoryKB -Required
            waitOrder = Get-ObjectValue $_ waitOrder
            waitTimeMs = Get-ObjectValue $_ waitTimeMs -Required
            queryId = Get-ObjectValue $_ queryId
            planId = Get-ObjectValue $_ planId
        }
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

function ConvertTo-WorkshopTrialEvidence {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Trials)

    if ($Trials.Count -gt 12) { throw 'No more than twelve trials may be recorded.' }
    $result = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Trials.Count; $index++) {
        $trial = $Trials[$index]
        $required = @(
            'TrialSequence','ParameterSlot','Phase','DurationMs','CpuMs','LogicalReads',
            'GrantedKB','UsedKB','SpillKB','WaitMs','ResultRowCount','ResultHash',
            'ExpectedRowCount','ActualRowCount','DifferenceCount','Correct','ValidationBatchID',
            'StartedAtUtc','CompletedAtUtc'
        )
        Assert-ExactProperty $trial $required 'Trial'
        if ([int](Get-ObjectValue $trial TrialSequence -Required) -ne $index + 1) {
            throw 'TrialSequence must be contiguous from one.'
        }
        $slot = [int](Get-ObjectValue $trial ParameterSlot -Required)
        if ($slot -lt 1 -or $slot -gt 6) { throw 'ParameterSlot must be from one through six.' }
        $phase = Resolve-CanonicalEnum (Get-ObjectValue $trial Phase -Required) @('Baseline','Optimized') 'trial phase'
        foreach ($name in @('DurationMs','CpuMs','LogicalReads','GrantedKB','UsedKB','SpillKB','WaitMs',
            'ResultRowCount','ExpectedRowCount','ActualRowCount','DifferenceCount')) {
            $value = ConvertTo-FiniteDecimal (Get-ObjectValue $trial $name -Required) $name
            if ($value -lt 0) { throw "$name cannot be negative." }
        }
        $correct = Get-ObjectValue $trial Correct -Required
        if ($correct -isnot [bool]) { throw 'Correct must be Boolean.' }
        $difference = [int64](Get-ObjectValue $trial DifferenceCount -Required)
        if (($correct -and $difference -ne 0) -or (-not $correct -and $difference -lt 1)) {
            throw 'Correct and DifferenceCount are inconsistent.'
        }
        $hashValue = Get-ObjectValue $trial ResultHash -Required
        $hash = if ($hashValue -is [byte[]]) { [Convert]::ToHexString($hashValue).ToLowerInvariant() } else { [string] $hashValue }
        if ($hash -cnotmatch '^[a-f0-9]{64}$') { throw 'ResultHash must be a lowercase SHA-256 hash.' }
        $validationBatch = [guid]::Empty
        if (-not [guid]::TryParseExact([string](Get-ObjectValue $trial ValidationBatchID -Required), 'D', [ref]$validationBatch)) {
            throw 'ValidationBatchID must be a canonical GUID.'
        }
        $startedValue = Get-ObjectValue $trial StartedAtUtc -Required
        $completedValue = Get-ObjectValue $trial CompletedAtUtc -Required
        $started = if ($startedValue -is [string]) { ConvertFrom-UtcText $startedValue 'StartedAtUtc' } else { [datetimeoffset]$startedValue }
        $completed = if ($completedValue -is [string]) { ConvertFrom-UtcText $completedValue 'CompletedAtUtc' } else { [datetimeoffset]$completedValue }
        if ($completed -lt $started) { throw 'CompletedAtUtc cannot precede StartedAtUtc.' }
        $result.Add([ordered]@{
            trialSequence = [int](Get-ObjectValue $trial TrialSequence -Required)
            parameterSlot = $slot
            phase = $phase
            durationMs = [int64](Get-ObjectValue $trial DurationMs -Required)
            cpuMs = [int64](Get-ObjectValue $trial CpuMs -Required)
            logicalReads = [int64](Get-ObjectValue $trial LogicalReads -Required)
            grantedKB = [int64](Get-ObjectValue $trial GrantedKB -Required)
            usedKB = [int64](Get-ObjectValue $trial UsedKB -Required)
            spillKB = [int64](Get-ObjectValue $trial SpillKB -Required)
            waitMs = [int64](Get-ObjectValue $trial WaitMs -Required)
            resultRowCount = [int64](Get-ObjectValue $trial ResultRowCount -Required)
            resultHash = $hash
            expectedRowCount = [int64](Get-ObjectValue $trial ExpectedRowCount -Required)
            actualRowCount = [int64](Get-ObjectValue $trial ActualRowCount -Required)
            differenceCount = $difference
            correct = $correct
            validationBatchId = $validationBatch.ToString('D')
            startedAtUtc = ConvertTo-UtcText $started
            completedAtUtc = ConvertTo-UtcText $completed
        })
    }
    return $result.ToArray()
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
        [AllowEmptyCollection()]
        [object[]] $Trials = @(),

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
    $RequestSamples = @(ConvertTo-CanonicalRequestSampleCollection $RequestSamples)
    Assert-SampleCollection -Samples $Samples -StartUtc $start -EndUtc $end
    Assert-SampleCollection -Samples $RequestSamples -StartUtc $start -EndUtc $end -Request
    $termination = ConvertTo-TerminationEvidence $TerminationEvidence
    if ($Trials.Count -eq 0 -and $RunRecord.psobject.Properties['Trials']) {
        $Trials = @($RunRecord.Trials)
    }
    $trialEvidence = @(ConvertTo-WorkshopTrialEvidence $Trials)

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
        if ($Samples.Count -ne 0 -or $RequestSamples.Count -ne 0 -or $trialEvidence.Count -ne 0 -or $null -ne $Validation -or
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
        if ($phase -eq 'Comparison' -and $status -eq 'Completed' -and $trialEvidence.Count -ne 12) {
            throw 'A completed comparison requires exactly twelve trials.'
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
        if ($Outcome -in @('TargetMet', 'ImprovedOutsideTarget', 'NoMaterialImprovement') -and
            @($trialEvidence | Where-Object { -not $_.correct }).Count -gt 0) {
            throw 'A performance outcome cannot be calculated when a trial pair is incorrect.'
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
        if ($Outcome -cne 'Failed' -and $Outcome -cne $expectedOutcome) {
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
        trials = $trialEvidence
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
        [pscustomobject][ordered]@{ StartDate = '2020-01-01'; EndDateExclusive = '2021-01-01'; TerritoryID = 6; TopCount = 500 }
        [pscustomobject][ordered]@{ StartDate = '2023-01-01'; EndDateExclusive = '2023-02-01'; TerritoryID = $null; TopCount = 50 }
    )
}

function Get-WorkshopTrialSequence {
    [CmdletBinding()]
    param()

    return @('A', 'B', 'B', 'A', 'B', 'A', 'A', 'B', 'A', 'B', 'B', 'A')
}

function ConvertFrom-WorkshopTrialReader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Reader)

    $expected = @(
        'DurationMs', 'CpuMs', 'LogicalReads', 'GrantedKB', 'UsedKB', 'SpillKB', 'WaitMs',
        'ResultRowCount', 'ResultHash', 'ExpectedRowCount', 'ActualRowCount', 'DifferenceCount',
        'Correct', 'ValidationBatchID', 'StartedAtUtc', 'CompletedAtUtc'
    )
    $metricResultCount = 0
    $metricRow = $null
    do {
        $names = @(for ($index = 0; $index -lt [int] $Reader.FieldCount; $index++) {
            [string] $Reader.GetName($index)
        })
        $duplicateNames = @($names | Group-Object | Where-Object Count -gt 1)
        $isExactMetricSchema = $names.Count -eq $expected.Count -and
            $duplicateNames.Count -eq 0 -and
            (@(Compare-Object $expected $names -CaseSensitive).Count -eq 0)
        $containsMetricName = @($names | Where-Object { $_ -in $expected }).Count -gt 0
        if ($containsMetricName -and -not $isExactMetricSchema) {
            while ($Reader.Read()) { }
            throw 'A trial metric result set has missing, duplicate, or unexpected fields.'
        }

        $rows = [System.Collections.Generic.List[object]]::new()
        while ($Reader.Read()) {
            if ($isExactMetricSchema) {
                $row = [ordered]@{}
                for ($index = 0; $index -lt $names.Count; $index++) {
                    $row[$names[$index]] = if ($Reader.IsDBNull($index)) { $null } else { $Reader.GetValue($index) }
                }
                $rows.Add([pscustomobject] $row)
            }
        }
        if ($isExactMetricSchema) {
            $metricResultCount++
            if ($rows.Count -ne 1) { throw 'The trial metric result set must contain exactly one row.' }
            $metricRow = $rows[0]
        }
    } while ($Reader.NextResult())

    if ($metricResultCount -ne 1) {
        throw 'The trial command must return exactly one trial metric result set.'
    }
    foreach ($name in @(
        'DurationMs', 'CpuMs', 'LogicalReads', 'GrantedKB', 'UsedKB', 'SpillKB', 'WaitMs',
        'ResultRowCount', 'ExpectedRowCount', 'ActualRowCount', 'DifferenceCount'
    )) {
        $value = ConvertTo-FiniteDecimal (Get-ObjectValue $metricRow $name -Required) $name
        if ($value -lt 0) { throw "$name cannot be negative." }
    }
    $hash = Get-ObjectValue $metricRow ResultHash -Required
    if ($hash -isnot [byte[]] -and $hash -is [System.Collections.IEnumerable] -and $hash -isnot [string]) {
        try { $hash = [byte[]]@($hash); $metricRow.ResultHash = $hash } catch { throw 'ResultHash must contain exactly 32 bytes.' }
    }
    if ($hash -isnot [byte[]] -or $hash.Length -ne 32) { throw 'ResultHash must contain exactly 32 bytes.' }
    if ((Get-ObjectValue $metricRow Correct -Required) -isnot [bool]) { throw 'Correct must be Boolean.' }
    $validationBatch = [guid]::Empty
    if (-not [guid]::TryParse([string](Get-ObjectValue $metricRow ValidationBatchID -Required), [ref] $validationBatch)) {
        throw 'ValidationBatchID must be a GUID.'
    }
    $started = [datetimeoffset](Get-ObjectValue $metricRow StartedAtUtc -Required)
    $completed = [datetimeoffset](Get-ObjectValue $metricRow CompletedAtUtc -Required)
    if ($completed -lt $started) { throw 'CompletedAtUtc cannot precede StartedAtUtc.' }
    return $metricRow
}

function Get-WorkshopConfigurationFingerprint {
    param([Parameter(Mandatory)][object] $Snapshot)

    $configuration = [ordered]@{
        SqlMajorVersion = [int] $Snapshot.SqlMajorVersion
        SqlProductVersion = [string] $Snapshot.SqlProductVersion
        SqlEdition = [string] $Snapshot.SqlEdition
        PhysicalMemoryMB = [int64] $Snapshot.PhysicalMemoryMB
        QueryStoreActualState = [string] $Snapshot.QueryStoreActualState
        ResourcePool = [string] $Snapshot.ResourcePool
        PoolMinMemoryPercent = [decimal] $Snapshot.PoolMinMemoryPercent
        PoolMaxMemoryPercent = [decimal] $Snapshot.PoolMaxMemoryPercent
        WorkloadGroup = [string] $Snapshot.WorkloadGroup
        GroupRequestMaxMemoryGrantPercent = [decimal] $Snapshot.GroupRequestMaxMemoryGrantPercent
        GroupMaxDop = [int] $Snapshot.GroupMaxDop
        GroupMaxRequests = [int] $Snapshot.GroupMaxRequests
        MaxServerMemoryMB = [int] $Snapshot.MaxServerMemoryMB
        MinServerMemoryMB = [int] $Snapshot.MinServerMemoryMB
        RowModeMemoryGrantFeedbackDisabled = [bool] $Snapshot.RowModeMemoryGrantFeedbackDisabled
        BatchModeMemoryGrantFeedbackDisabled = [bool] $Snapshot.BatchModeMemoryGrantFeedbackDisabled
        ControllerSessionInWorkloadGroup = [bool] $Snapshot.ControllerSessionInWorkloadGroup
        MarkerValid = [bool] $Snapshot.MarkerValid
        ProceduresPresent = [bool] $Snapshot.ProceduresPresent
        WorkshopRunPresent = [bool] $Snapshot.WorkshopRunPresent
        WorkshopSamplePresent = [bool] $Snapshot.WorkshopSamplePresent
        WorkshopRequestSamplePresent = [bool] $Snapshot.WorkshopRequestSamplePresent
        WorkshopTrialPresent = [bool] $Snapshot.WorkshopTrialPresent
        ValidationBatchID = [string] $Snapshot.ValidationBatchID
        ValidationBatchHash = [string] $Snapshot.ValidationBatchHash
    }
    return Get-Sha256 (ConvertTo-Json $configuration -Compress)
}

function Test-WorkshopPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Snapshot
    )

    $requiredHashes = @('DataHash', 'IndexStatisticsHash', 'ProcedureHash')
    $failures = [System.Collections.Generic.List[string]]::new()
    if (-not $Snapshot.MarkerValid) { $failures.Add('The workshop marker is invalid.') }
    if ([int] $Snapshot.SqlMajorVersion -ne 16) { $failures.Add('SQL Server major version 16 is required.') }
    if ([string]::IsNullOrWhiteSpace([string] $Snapshot.SqlProductVersion)) {
        $failures.Add('The concrete SQL product version is required.')
    }
    if ([string] $Snapshot.SqlEdition -notmatch 'Enterprise') { $failures.Add('SQL Server Enterprise edition is required.') }
    if ([int64] $Snapshot.PhysicalMemoryMB -lt 63000 -or [int64] $Snapshot.PhysicalMemoryMB -gt 66000) {
        $failures.Add('The 64 GB host memory profile is required.')
    }
    if ([string] $Snapshot.QueryStoreActualState -cne 'READ_WRITE') { $failures.Add('Query Store must be READ_WRITE.') }
    if ([string] $Snapshot.ResourcePool -cne 'mcp_sql_workshop_pool') { $failures.Add('The exact workshop resource pool is required.') }
    if ([decimal] $Snapshot.PoolMinMemoryPercent -ne 0 -or [decimal] $Snapshot.PoolMaxMemoryPercent -ne 50) {
        $failures.Add('The resource pool must use exact minimum/maximum memory percentages 0/50.')
    }
    if ([string] $Snapshot.WorkloadGroup -cne 'mcp_sql_workshop_group') { $failures.Add('The exact workshop workload group is required.') }
    if ([decimal] $Snapshot.GroupRequestMaxMemoryGrantPercent -ne 40 -or
        [int] $Snapshot.GroupMaxDop -ne 4 -or [int] $Snapshot.GroupMaxRequests -ne 4) {
        $failures.Add('The workload group must use grant 40, MAX_DOP 4, and maximum requests 4.')
    }
    if ([int] $Snapshot.MaxServerMemoryMB -ne 49152 -or [int] $Snapshot.MinServerMemoryMB -ne 0) {
        $failures.Add('Server memory must use exact maximum/minimum values 49152/0 MB.')
    }
    if (-not $Snapshot.RowModeMemoryGrantFeedbackDisabled -or
        -not $Snapshot.BatchModeMemoryGrantFeedbackDisabled) {
        $failures.Add('Row and batch mode memory grant feedback must be disabled.')
    }
    if (-not $Snapshot.ControllerSessionInWorkloadGroup) {
        $failures.Add('The active controller session must be classified into the workshop workload group.')
    }
    if ([string]::IsNullOrWhiteSpace([string] $Snapshot.PriorMemoryGrantFeedbackState)) {
        $failures.Add('The prior memory grant feedback state must be recorded.')
    }
    if (-not $Snapshot.ProceduresPresent) { $failures.Add('Both workload procedures must be present.') }
    foreach ($name in @('WorkshopRunPresent','WorkshopSamplePresent','WorkshopRequestSamplePresent','WorkshopTrialPresent')) {
        if (-not $Snapshot.$name) { $failures.Add("The $name evidence table check failed.") }
    }
    $validationBatch = [guid]::Empty
    if (-not $Snapshot.ValidationPassed -or
        -not [guid]::TryParseExact([string] $Snapshot.ValidationBatchID, 'D', [ref] $validationBatch)) {
        $failures.Add('A complete passing correctness validation batch is required.')
    }
    $validatedAt = [datetimeoffset]::MinValue
    $validationTimestampParsed = if ($Snapshot.ValidationValidatedAtUtc -is [datetimeoffset] -or
        $Snapshot.ValidationValidatedAtUtc -is [datetime]) {
        $validatedAt = [datetimeoffset]$Snapshot.ValidationValidatedAtUtc
        $true
    }
    else {
        [datetimeoffset]::TryParse(
            [string]$Snapshot.ValidationValidatedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$validatedAt)
    }
    if (-not $validationTimestampParsed -or
        $validatedAt -lt [datetimeoffset]::UtcNow.AddHours(-24) -or
        $validatedAt -gt [datetimeoffset]::UtcNow.AddMinutes(5)) {
        $failures.Add('The correctness validation batch must be no more than 24 hours old.')
    }
    if ([string] $Snapshot.ValidationBatchHash -cnotmatch '^[a-f0-9]{64}$') {
        $failures.Add('ValidationBatchHash must be a lowercase SHA-256 fingerprint.')
    }
    foreach ($name in $requiredHashes) {
        if ([string] $Snapshot.$name -cnotmatch '^[a-f0-9]{64}$') {
            $failures.Add("$name must be a lowercase SHA-256 fingerprint.")
        }
    }
    if ($failures.Count -gt 0) {
        throw "Workshop preflight failed: $($failures -join ' ')"
    }
    $Snapshot | Add-Member NoteProperty CanonicalConfigurationFingerprint `
        (Get-WorkshopConfigurationFingerprint $Snapshot) -Force
    return $true
}

function Assert-WorkshopOperationSet {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $OperationSet)

    $required = @('OpenConnection', 'StartWorker', 'TestWorkerHealth', 'Sample', 'StopWorker', 'KillTagged', 'Persist', 'Delay', 'Clock', 'Export')
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

    try {
        if ((Get-WorkshopConfigurationFingerprint $Expected) -cne
            (Get-WorkshopConfigurationFingerprint $Actual)) { return $false }
    }
    catch { return $false }
    foreach ($name in @('DataHash', 'IndexStatisticsHash', 'ProcedureHash')) {
        if ([string] $Expected.$name -cne [string] $Actual.$name) { return $false }
    }
    return $true
}

function Get-WorkshopTrialAssessment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]] $Trials)

    if ($Trials.Count -ne 12) { throw 'Exactly twelve trials are required.' }
    $evaluated = @($Trials | ForEach-Object { $_.psobject.Copy() })
    foreach ($slot in 1..6) {
        $pair = @($evaluated | Where-Object ParameterSlot -eq $slot)
        $baselinePair = @($pair | Where-Object Phase -eq 'Baseline')
        $optimizedPair = @($pair | Where-Object Phase -eq 'Optimized')
        if ($pair.Count -ne 2 -or $baselinePair.Count -ne 1 -or $optimizedPair.Count -ne 1) {
            throw "Parameter slot $slot must have exactly one Baseline and one Optimized trial."
        }
        $expectedCount = [int64] $baselinePair[0].ResultRowCount
        $actualCount = [int64] $optimizedPair[0].ResultRowCount
        $baselineHashValue = $baselinePair[0].ResultHash
        $optimizedHashValue = $optimizedPair[0].ResultHash
        if ($baselineHashValue -isnot [byte[]] -and $baselineHashValue -is [System.Collections.IEnumerable] -and $baselineHashValue -isnot [string]) {
            $baselineHashValue = [byte[]]@($baselineHashValue)
        }
        if ($optimizedHashValue -isnot [byte[]] -and $optimizedHashValue -is [System.Collections.IEnumerable] -and $optimizedHashValue -isnot [string]) {
            $optimizedHashValue = [byte[]]@($optimizedHashValue)
        }
        $baselineHash = if ($baselineHashValue -is [byte[]]) { [Convert]::ToHexString($baselineHashValue) } else { [string]$baselineHashValue }
        $optimizedHash = if ($optimizedHashValue -is [byte[]]) { [Convert]::ToHexString($optimizedHashValue) } else { [string]$optimizedHashValue }
        $hashMatches = $baselineHash -ceq $optimizedHash
        $differenceCount = if ($expectedCount -eq $actualCount -and $hashMatches) { 0L } else { 1L }
        foreach ($trial in $pair) {
            $trial.ExpectedRowCount = $expectedCount
            $trial.ActualRowCount = $actualCount
            $trial.DifferenceCount = $differenceCount
            $trial.Correct = $differenceCount -eq 0
        }
    }
    $baseline = @($evaluated | Where-Object Phase -eq 'Baseline')
    $optimized = @($evaluated | Where-Object Phase -eq 'Optimized')
    $correctnessPassed = @($evaluated | Where-Object { -not $_.Correct }).Count -eq 0
    $metrics = @('DurationMs', 'CpuMs', 'LogicalReads', 'SpillKB', 'WaitMs')
    $improved = $false
    $materialRegression = $false
    if ($correctnessPassed) {
        foreach ($metric in $metrics) {
            $baselineAverage = [decimal] (($baseline | Measure-Object -Property $metric -Average).Average)
            $optimizedAverage = [decimal] (($optimized | Measure-Object -Property $metric -Average).Average)
            if ($baselineAverage -gt 0 -and $optimizedAverage -le ($baselineAverage * [decimal]'0.90')) {
                $improved = $true
            }
            if (($baselineAverage -eq 0 -and $optimizedAverage -gt 0) -or
                ($baselineAverage -gt 0 -and $optimizedAverage -gt ($baselineAverage * [decimal]'1.10'))) {
                $materialRegression = $true
            }
        }
    }
    return [pscustomobject]@{
        CorrectnessPassed = $correctnessPassed
        AdditionalMetricImproved = $improved
        MaterialRegression = $materialRegression
        Trials = $evaluated
    }
}

function Build-WorkshopExperimentResult {
    param(
        [guid]$RunId, [string]$Outcome, [string]$TerminalPhase,
        [AllowNull()][object]$FrozenSettings, [object]$Preflight,
        [object[]]$Samples, [object[]]$RequestSamples, [object[]]$Trials,
        [datetimeoffset]$StartedAtUtc, [datetimeoffset]$CompletedAtUtc,
        [bool]$ManualStopRequested, [bool]$SafetyStopTriggered,
        [string[]]$SafetyReasons, [bool]$Timeout, [int]$Workers,
        [string[]]$Schedule, [int]$MaximumDurationSeconds,
        [int]$SampleIntervalSeconds, [int]$WorkerRampSeconds
    )

    if ($null -eq $FrozenSettings) {
        $scheduleJson = ConvertTo-Json $Schedule -Compress
        $FrozenSettings = [ordered]@{
            workers = [math]::Max(1, $Workers)
            maximumDurationSeconds = $MaximumDurationSeconds
            sampleIntervalSeconds = $SampleIntervalSeconds
            workerRampSeconds = $WorkerRampSeconds
            resourcePool = 'mcp_sql_workshop_pool'
            workloadGroup = 'mcp_sql_workshop_group'
            maxServerMemoryMB = 49152
            databaseScopedConfigurationHash = Get-WorkshopConfigurationFingerprint $Preflight
            validationBatchHash = [string]$Preflight.ValidationBatchHash
            parameterSchedule = $Schedule
            parameterScheduleHash = Get-Sha256 $scheduleJson
        }
    }
    $status = if ($Outcome -in @('TargetMet','ImprovedOutsideTarget','NoMaterialImprovement')) { 'Completed' } else { $Outcome }
    $runRecord = New-WorkshopRunRecord -RunId $RunId -Phase $TerminalPhase -Status $status `
        -EvidenceClassification LAB-MEASURED -FrozenSettings $FrozenSettings `
        -EnvironmentFingerprint ([ordered]@{
            sqlVersion = [string]$Preflight.SqlProductVersion
            sqlEdition = [string]$Preflight.SqlEdition
            physicalMemoryMB = [int64]$Preflight.PhysicalMemoryMB
        }) -TargetBands ([ordered]@{
            baseline = [ordered]@{ minimum = 75; maximum = 85 }
            optimized = [ordered]@{ minimum = 35; maximum = 45 }
        }) -StartUtc $StartedAtUtc -EndUtc $CompletedAtUtc
    $assessment = $null
    if ($Trials.Count -eq 12) {
        $assessment = Get-WorkshopTrialAssessment $Trials
        $Trials = @($assessment.Trials)
    }
    else {
        $Trials = @($Trials | ForEach-Object {
            $partial = $_.psobject.Copy()
            $partial.Correct = $false
            $partial.DifferenceCount = [math]::Max(1L, [int64]$partial.DifferenceCount)
            $partial
        })
    }
    $runRecord | Add-Member NoteProperty Trials $Trials -Force
    $correctnessPassed = $null -ne $assessment -and $assessment.CorrectnessPassed
    $trialLinkage = @($Trials | ForEach-Object {
        $hashValue = $_.ResultHash
        if ($hashValue -isnot [byte[]] -and $hashValue -is [System.Collections.IEnumerable] -and $hashValue -isnot [string]) {
            $hashValue = [byte[]]@($hashValue)
        }
        $resultHash = if ($hashValue -is [byte[]]) {
            if ($hashValue.Length -ne 32) { throw 'ResultHash must contain exactly 32 bytes.' }
            [Convert]::ToHexString($hashValue).ToLowerInvariant()
        }
        else {
            ([string]$hashValue).ToLowerInvariant()
        }
        $_.ResultHash = $resultHash
        [ordered]@{
            sequence = [int]$_.TrialSequence
            slot = [int]$_.ParameterSlot
            phase = [string]$_.Phase
            resultRowCount = [int64]$_.ResultRowCount
            resultHash = $resultHash
            expectedRowCount = [int64]$_.ExpectedRowCount
            actualRowCount = [int64]$_.ActualRowCount
            differenceCount = [int64]$_.DifferenceCount
            correct = [bool]$_.Correct
        }
    })
    $validation = [ordered]@{
        passed = $correctnessPassed
        materialRegression = if ($null -eq $assessment) { $false } else { $assessment.MaterialRegression }
        additionalMetricImproved = if ($null -eq $assessment) { $false } else { $assessment.AdditionalMetricImproved }
        validationHash = Get-Sha256 (ConvertTo-Json $trialLinkage -Depth 8 -Compress)
    }
    $termination = [ordered]@{
        manualStopRequested = $ManualStopRequested
        safetyStopTriggered = $SafetyStopTriggered
        safetyReasons = @($SafetyReasons | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        timeout = $Timeout
    }
    $evidence = ConvertTo-WorkshopEvidence -RunRecord $runRecord -Samples $Samples `
        -RequestSamples $RequestSamples -Trials $Trials -Validation $validation `
        -Outcome $Outcome -TerminationEvidence $termination
    $settingsJson = ConvertTo-Json (ConvertTo-CanonicalValue $FrozenSettings) -Depth 20 -Compress
    return [pscustomobject]@{
        RunId = $RunId
        Outcome = $Outcome
        Phase = $TerminalPhase
        RunStatus = if ($status -eq 'Completed') { 'Completed' } elseif ($status -eq 'Failed') { 'Failed' } else { 'Stopped' }
        StartedAtUtc = $StartedAtUtc
        CompletedAtUtc = $CompletedAtUtc
        ValidationBatchID = $Preflight.ValidationBatchID
        FrozenSettings = [pscustomobject]$FrozenSettings
        FrozenSettingsJson = $settingsJson
        FrozenSettingsHash = Get-Sha256 $settingsJson
        BaselineFingerprint = $Preflight
        Samples = $Samples
        RequestSamples = $RequestSamples
        Trials = $Trials
        Validation = [pscustomobject]$validation
        TerminationEvidence = [pscustomobject]$termination
        Evidence = $evidence
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
        [ValidateRange(20, 60)]
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
    $requestSamples = [System.Collections.Generic.List[object]]::new()
    $trials = [System.Collections.Generic.List[object]]::new()
    $start = [datetimeoffset] (& $OperationSet.Clock)
    $lastRamp = $null
    $consecutive = 0
    $outcome = $null
    $frozen = $null
    $terminalPhase = 'Baseline'
    $manualStopRequested = $false
    $safetyStopTriggered = $false
    $safetyReasons = @()
    $timeout = $false
    $result = $null
    $sampleClockState = [pscustomobject]@{ Last = $start.AddTicks(-1) }
    $workerCountStarted = 0
    $healthState = [pscustomobject]@{ ConsecutiveFailures = 0 }
    $deadline = $start.AddSeconds($MaximumDurationSeconds)
    $getRemainingSeconds = {
        $remaining = ($deadline - [datetimeoffset] (& $OperationSet.Clock)).TotalSeconds
        if ($remaining -le 0) { return 0 }
        return [math]::Max(1, [int][math]::Ceiling($remaining))
    }.GetNewClosure()
    $testActiveWorkers = {
        if ($workers.Count -eq 0) { return $true }
        $health = & $OperationSet.TestWorkerHealth $workers.ToArray()
        return $null -ne $health -and [bool]$health.Healthy
    }.GetNewClosure()
    $updateHealthFailures = {
        param([bool]$Healthy)
        if ($Healthy) { $healthState.ConsecutiveFailures = 0 }
        else { $healthState.ConsecutiveFailures++ }
        return $healthState.ConsecutiveFailures
    }.GetNewClosure()
    $invokeBoundedSample = {
        param([string]$Phase, [string]$Kind, [AllowNull()][string]$TrialPhase, [AllowNull()][string]$ScheduleEntry)
        $remaining = & $getRemainingSeconds
        if ($remaining -le 0) { return $null }
        return & $OperationSet.Sample $RunId $Phase $Kind $TrialPhase $ScheduleEntry $remaining
    }.GetNewClosure()
    $assertFrozenFingerprint = {
        $actual = & $invokeBoundedSample 'Optimized' 'Fingerprint' $null $null
        if ($null -eq $actual -or -not (Test-WorkshopFingerprintMatch -Expected $preflight -Actual $actual)) {
            throw 'Optimized phase rejected because configuration or data drift was detected.'
        }
    }.GetNewClosure()
    $recordSample = {
        param($InputSample, [datetimeoffset]$ObservedAt)
        $sample = $InputSample.psobject.Copy()
        $timestamp = if ($sample.psobject.Properties['SampledAtUtc']) { [datetimeoffset]$sample.SampledAtUtc } else { $ObservedAt }
        if ($timestamp -le $sampleClockState.Last) { $timestamp = $sampleClockState.Last.AddTicks(1) }
        $sampleClockState.Last = $timestamp
        $sequence = $samples.Count + 1
        $sample | Add-Member NoteProperty Sequence $sequence -Force
        $sample | Add-Member NoteProperty TimestampUtc `
            ($timestamp.UtcDateTime.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)) -Force
        $sample | Add-Member NoteProperty SampleSequence $sequence -Force
        $sample | Add-Member NoteProperty SampledAtUtc $timestamp.UtcDateTime -Force
        $defaults = [ordered]@{
            PoolTotalMemoryKB = $sample.TotalKb; PoolGrantedMemoryKB = $sample.GrantedKb
            PoolUsedMemoryKB = 0; PoolAvailableMemoryKB = [math]::Max(0, [int64]$sample.TotalKb - [int64]$sample.GrantedKb)
            GranteeCount = 0; WaiterCount = 0; HostAvailableMemoryKB = [int64]([decimal]$sample.HostAvailableMB * 1024)
            HostUsedMemoryKB = 0; ProcessPhysicalMemoryKB = 0; TotalServerMemoryKB = 0; TargetServerMemoryKB = 0
            SystemLowMemorySignal = [bool]$sample.ProcessVirtualLow; ProcessLowMemorySignal = [bool]$sample.ProcessPhysicalLow
        }
        foreach ($entry in $defaults.GetEnumerator()) {
            if (-not $sample.psobject.Properties[$entry.Key]) { $sample | Add-Member NoteProperty $entry.Key $entry.Value }
        }
        if ($sample.psobject.Properties['RequestSamples']) {
            foreach ($request in @($sample.RequestSamples)) {
                $copy = $request.psobject.Copy()
                $copy | Add-Member NoteProperty SampleSequence $sequence -Force
                foreach ($name in @('QueryID','PlanID')) {
                    if (-not $copy.psobject.Properties[$name]) { $copy | Add-Member NoteProperty $name $null }
                }
                $requestSamples.Add($copy)
            }
        }
        $samples.Add($sample)
        return $sample
    }.GetNewClosure()
    try {
        $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase Baseline -Worker 1
        $workerHandle = & $OperationSet.StartWorker $RunId 'Baseline' 1 $applicationName $schedule $deadline
        $workers.Add($workerHandle)
        $workerCountStarted = 1
        $lastRamp = [datetimeoffset] (& $OperationSet.Clock)
        while ($null -eq $outcome -and $null -eq $frozen) {
            $now = [datetimeoffset] (& $OperationSet.Clock)
            if ($now -ge $deadline) {
                $outcome = 'BaselineTargetNotReached'
                $timeout = $true
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            $elapsed = ($now - $start).TotalSeconds
            $sample = & $recordSample (& $invokeBoundedSample 'Baseline' 'Memory' $null $null) $now
            $now = [datetimeoffset] (& $OperationSet.Clock)
            $elapsed = ($now - $start).TotalSeconds
            $workersHealthy = [bool](& $testActiveWorkers)
            $healthFailures = & $updateHealthFailures $workersHealthy
            $safety = Test-WorkshopSafetySample -HostUsedPercent $sample.HostUsedPercent `
                -HostAvailableMB $sample.HostAvailableMB -ProcessPhysicalLow $sample.ProcessPhysicalLow `
                -ProcessVirtualLow $sample.ProcessVirtualLow `
                -ConsecutiveHealthFailures $healthFailures `
                -ElapsedSeconds $elapsed -MaximumDurationSeconds $MaximumDurationSeconds `
                -Phase Baseline -ManualStop $sample.ManualStopRequested
            if ($safety.Decision -eq 'Stop') {
                $outcome = $safety.Outcome
                $manualStopRequested = $outcome -eq 'ManualStop'
                $safetyStopTriggered = $outcome -eq 'SafetyStop'
                $safetyReasons = if ($safetyStopTriggered) { @($safety.Reasons) } else { @() }
                $timeout = $outcome -eq 'BaselineTargetNotReached'
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
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
                    databaseScopedConfigurationHash = [string] $preflight.CanonicalConfigurationFingerprint
                    validationBatchHash = [string]$preflight.ValidationBatchHash
                    parameterSchedule = $schedule
                    parameterScheduleHash = Get-Sha256 $scheduleJson
                }
                break
            }
            if ($workersHealthy -and $sample.Healthy -and $sample.GrantUtilizationPercent -lt 75 -and
                $sample.HostAvailableMB -gt 12288 -and $workers.Count -lt $MaximumWorkers -and
                ($now - $lastRamp).TotalSeconds -ge $WorkerRampSeconds) {
                $workerNumber = $workers.Count + 1
                $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase Baseline -Worker $workerNumber
                $workerHandle = & $OperationSet.StartWorker $RunId 'Baseline' $workerNumber $applicationName $schedule $deadline
                $workers.Add($workerHandle)
                $workerCountStarted = [math]::Max($workerCountStarted, $workerNumber)
                $lastRamp = [datetimeoffset] (& $OperationSet.Clock)
            }
            $remaining = & $getRemainingSeconds
            if ($remaining -gt 0) {
                & $OperationSet.Delay ([math]::Min($SampleIntervalSeconds, $remaining))
            }
        }

        foreach ($worker in @($workers)) { & $OperationSet.StopWorker $worker }
        foreach ($worker in @($workers)) { if ($worker -is [System.IDisposable] -or $worker.psobject.Methods['Dispose']) { $worker.Dispose() } }
        $workers.Clear()

        if ($null -ne $outcome) {
            $result = Build-WorkshopExperimentResult -RunId $RunId -Outcome $outcome `
                -TerminalPhase Baseline -FrozenSettings $null -Preflight $preflight `
                -Samples $samples.ToArray() -RequestSamples $requestSamples.ToArray() -Trials @() `
                -StartedAtUtc $start -CompletedAtUtc $sampleClockState.Last `
                -ManualStopRequested $manualStopRequested -SafetyStopTriggered $safetyStopTriggered `
                -SafetyReasons $safetyReasons -Timeout $timeout -Workers $workerCountStarted -Schedule $schedule `
                -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
                -WorkerRampSeconds $WorkerRampSeconds
            & $OperationSet.Persist $result
            & $OperationSet.Export $result
            return $result
        }

        $drainDeadline = @($deadline, ([datetimeoffset] (& $OperationSet.Clock)).AddSeconds(60) | Sort-Object)[0]
        $drain = $null
        do {
            if (([datetimeoffset] (& $OperationSet.Clock)) -ge $drainDeadline) {
                $outcome = 'Failed'
                $timeout = $true
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            $drain = & $invokeBoundedSample 'Baseline' 'Drain' $null $null
            if (([datetimeoffset] (& $OperationSet.Clock)) -ge $deadline) {
                $outcome = 'Failed'
                $timeout = $true
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            if ([int] $drain.ActiveGrantCount -eq 0) { break }
            $remaining = & $getRemainingSeconds
            if ($remaining -gt 0) {
                & $OperationSet.Delay ([math]::Min($SampleIntervalSeconds, $remaining))
            }
        } while (([datetimeoffset] (& $OperationSet.Clock)) -lt $drainDeadline)
        if ($null -eq $outcome -and [int] $drain.ActiveGrantCount -ne 0) {
            throw 'Baseline grants did not drain within the bounded interval.'
        }

        if ($null -ne $outcome) {
            $result = Build-WorkshopExperimentResult -RunId $RunId -Outcome $outcome `
                -TerminalPhase Baseline -FrozenSettings $frozen -Preflight $preflight `
                -Samples $samples.ToArray() -RequestSamples $requestSamples.ToArray() -Trials @() `
                -StartedAtUtc $start -CompletedAtUtc $sampleClockState.Last `
                -ManualStopRequested $false -SafetyStopTriggered $false -SafetyReasons @() `
                -Timeout $timeout -Workers $workerCountStarted -Schedule $schedule `
                -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
                -WorkerRampSeconds $WorkerRampSeconds
            & $OperationSet.Persist $result
            & $OperationSet.Export $result
            return $result
        }

        $terminalPhase = 'Optimized'
        & $assertFrozenFingerprint

        $consecutive = 0
        for ($index = 1; $index -le [int] $frozen.workers; $index++) {
            if (([datetimeoffset] (& $OperationSet.Clock)) -ge $deadline) {
                $outcome = 'Failed'
                $timeout = $true
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase Optimized -Worker $index
            $workers.Add((& $OperationSet.StartWorker $RunId 'Optimized' $index $applicationName $schedule $deadline))
        }
        while ($null -eq $outcome) {
            $now = [datetimeoffset] (& $OperationSet.Clock)
            if ($now -ge $deadline) {
                $outcome = 'Failed'
                $timeout = $true
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            $sample = & $recordSample (& $invokeBoundedSample 'Optimized' 'Memory' $null $null) $now
            & $assertFrozenFingerprint
            $now = [datetimeoffset] (& $OperationSet.Clock)
            if ($now -ge $deadline) {
                $outcome = 'Failed'
                $timeout = $true
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            $workersHealthy = [bool](& $testActiveWorkers)
            $healthFailures = & $updateHealthFailures $workersHealthy
            $safety = Test-WorkshopSafetySample -HostUsedPercent $sample.HostUsedPercent `
                -HostAvailableMB $sample.HostAvailableMB -ProcessPhysicalLow $sample.ProcessPhysicalLow `
                -ProcessVirtualLow $sample.ProcessVirtualLow `
                -ConsecutiveHealthFailures $healthFailures `
                -ElapsedSeconds (($now - $start).TotalSeconds) `
                -MaximumDurationSeconds $MaximumDurationSeconds -Phase Optimized `
                -ManualStop $sample.ManualStopRequested
            if ($safety.Decision -eq 'Stop') {
                $outcome = $safety.Outcome
                $terminalPhase = 'Optimized'
                $manualStopRequested = $outcome -eq 'ManualStop'
                $safetyStopTriggered = $outcome -eq 'SafetyStop'
                $safetyReasons = if ($safetyStopTriggered) { @($safety.Reasons) } else { @() }
                $timeout = $outcome -eq 'NoMaterialImprovement'
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            if (Test-TargetBand $sample.GrantUtilizationPercent Optimized) { $consecutive++ } else { $consecutive = 0 }
            if ($consecutive -ge 3) { break }
            $remaining = & $getRemainingSeconds
            if ($remaining -gt 0) {
                & $OperationSet.Delay ([math]::Min($SampleIntervalSeconds, $remaining))
            }
        }

        foreach ($worker in @($workers)) { & $OperationSet.StopWorker $worker }
        foreach ($worker in @($workers)) { if ($worker -is [System.IDisposable] -or $worker.psobject.Methods['Dispose']) { $worker.Dispose() } }
        $workers.Clear()

        if ($null -eq $outcome) { & $assertFrozenFingerprint }

        if ($null -eq $outcome) {
            $terminalPhase = 'Comparison'
            $sequence = @(Get-WorkshopTrialSequence)
            for ($index = 0; $index -lt $sequence.Count; $index++) {
                if (([datetimeoffset] (& $OperationSet.Clock)) -ge $deadline) {
                    $outcome = 'Failed'
                    $timeout = $true
                    [void](& $OperationSet.KillTagged $RunId)
                    break
                }
                $trialPhase = if ($sequence[$index] -eq 'A') { 'Baseline' } else { 'Optimized' }
                $slot = [math]::Floor($index / 2) + 1
                $entry = $schedule[$slot - 1]
                & $assertFrozenFingerprint
                foreach ($position in @('Before','After')) {
                    if ($position -eq 'After') {
                        $trial = & $invokeBoundedSample 'Comparison' 'Trial' $trialPhase $entry
                        if ($null -eq $trial -or ([datetimeoffset] (& $OperationSet.Clock)) -ge $deadline) {
                            $outcome = 'Failed'
                            $timeout = $true
                            [void](& $OperationSet.KillTagged $RunId)
                            break
                        }
                        $trial | Add-Member NoteProperty TrialSequence ($index + 1) -Force
                        $trial | Add-Member NoteProperty ParameterSlot $slot -Force
                        $trial | Add-Member NoteProperty Phase $trialPhase -Force
                        $trials.Add($trial)
                    }
                    $safetyNow = [datetimeoffset](& $OperationSet.Clock)
                    if ($safetyNow -ge $deadline) {
                        $outcome = 'Failed'
                        $timeout = $true
                        [void](& $OperationSet.KillTagged $RunId)
                        break
                    }
                    $safetySample = & $recordSample `
                        (& $invokeBoundedSample $trialPhase 'Memory' $null $null) $safetyNow
                    $safetyNow = [datetimeoffset](& $OperationSet.Clock)
                    if ($safetyNow -ge $deadline) {
                        $outcome = 'Failed'
                        $timeout = $true
                        [void](& $OperationSet.KillTagged $RunId)
                        break
                    }
                    $safety = Test-WorkshopSafetySample -HostUsedPercent $safetySample.HostUsedPercent `
                        -HostAvailableMB $safetySample.HostAvailableMB `
                        -ProcessPhysicalLow $safetySample.ProcessPhysicalLow `
                        -ProcessVirtualLow $safetySample.ProcessVirtualLow `
                        -ConsecutiveHealthFailures (& $updateHealthFailures ([bool]$safetySample.Healthy)) `
                        -ElapsedSeconds (($safetyNow-$start).TotalSeconds) `
                        -MaximumDurationSeconds $MaximumDurationSeconds -Phase $trialPhase `
                        -ManualStop $safetySample.ManualStopRequested
                    if ($safety.Decision -eq 'Stop') {
                        $outcome = if ($safety.Outcome -in @('ManualStop','SafetyStop')) { $safety.Outcome } else { 'Failed' }
                        $terminalPhase = $trialPhase
                        $manualStopRequested = $outcome -eq 'ManualStop'
                        $safetyStopTriggered = $outcome -eq 'SafetyStop'
                        $safetyReasons = if ($safetyStopTriggered) { @($safety.Reasons) } else { @() }
                        $timeout = $safety.Outcome -notin @('ManualStop','SafetyStop')
                        [void](& $OperationSet.KillTagged $RunId)
                        break
                    }
                }
                if ($null -ne $outcome) { break }
                & $assertFrozenFingerprint
            }
            if ($null -eq $outcome -and $trials.Count -ne 12) { $outcome = 'Failed' }
            if ($null -eq $outcome) {
                $assessment = Get-WorkshopTrialAssessment -Trials $trials.ToArray()
                $trials.Clear()
                foreach ($trial in $assessment.Trials) { $trials.Add($trial) }
                $baselinePeak = [decimal] ((@($samples | Where-Object Phase -eq Baseline | Measure-Object GrantUtilizationPercent -Maximum).Maximum))
                $optimizedPeak = [decimal] ((@($samples | Where-Object Phase -eq Optimized | Measure-Object GrantUtilizationPercent -Maximum).Maximum))
                $outcome = if (-not $assessment.CorrectnessPassed) { 'Failed' } else {
                    Get-WorkshopOutcome -BaselinePeak $baselinePeak -OptimizedPeak $optimizedPeak `
                        -CorrectnessPassed $true -MaterialRegression $assessment.MaterialRegression `
                        -AdditionalMetricImproved $assessment.AdditionalMetricImproved
                }
            }
        }

        if ($outcome -eq 'NoMaterialImprovement' -and $trials.Count -ne 12) { $outcome = 'Failed' }
        $terminalPhase = if ($outcome -in @('ManualStop','SafetyStop')) { $terminalPhase } else { 'Comparison' }
        $result = Build-WorkshopExperimentResult -RunId $RunId -Outcome $outcome `
            -TerminalPhase $terminalPhase -FrozenSettings $frozen -Preflight $preflight `
            -Samples $samples.ToArray() -RequestSamples $requestSamples.ToArray() -Trials $trials.ToArray() `
            -StartedAtUtc $start -CompletedAtUtc $sampleClockState.Last `
            -ManualStopRequested $manualStopRequested -SafetyStopTriggered $safetyStopTriggered `
            -SafetyReasons $safetyReasons -Timeout $timeout -Workers $workerCountStarted -Schedule $schedule `
            -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
            -WorkerRampSeconds $WorkerRampSeconds
        & $OperationSet.Persist $result
        & $OperationSet.Export $result
        return $result
    }
    catch {
        $originalError = $_
        $originalText = [string]$originalError.Exception.Message
        if ([string]::IsNullOrWhiteSpace($originalText) -or
            $originalText -match $script:SecretAssignmentPattern -or
            $originalText -match $script:SecretNamePattern) {
            $originalText = 'operational failure details were redacted'
        }
        else {
            $originalText = [regex]::Replace($originalText, '\s+', ' ').Trim()
            $originalText = $originalText.Substring(0, [math]::Min(512, $originalText.Length))
        }
        $killError = $null
        try { [void](& $OperationSet.KillTagged $RunId) } catch { $killError = $_ }

        if ($null -eq $result -and $samples.Count -gt 0) {
            try {
                $completedAt = [datetimeoffset] (& $OperationSet.Clock)
                if ($completedAt -lt $sampleClockState.Last) { $completedAt = $sampleClockState.Last }
                $result = Build-WorkshopExperimentResult -RunId $RunId -Outcome Failed `
                    -TerminalPhase $terminalPhase -FrozenSettings $frozen -Preflight $preflight `
                    -Samples $samples.ToArray() -RequestSamples $requestSamples.ToArray() -Trials $trials.ToArray() `
                    -StartedAtUtc $start -CompletedAtUtc $completedAt `
                    -ManualStopRequested $false -SafetyStopTriggered $false -SafetyReasons @() `
                    -Timeout $false -Workers $workerCountStarted -Schedule $schedule `
                    -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
                    -WorkerRampSeconds $WorkerRampSeconds
            }
            catch {
                $finalizationText = [string]$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($finalizationText) -or
                    $finalizationText -match $script:SecretAssignmentPattern -or
                    $finalizationText -match $script:SecretNamePattern) {
                    $finalizationText = 'failed-result construction failed'
                }
                throw [InvalidOperationException]::new(
                    "Workshop operational failure: $originalText; finalization failure: $finalizationText.",
                    $originalError.Exception)
            }
        }

        if ($null -ne $result) {
            try {
                & $OperationSet.Persist $result
                & $OperationSet.Export $result
                if ($null -ne $killError) { throw $killError }
                return $result
            }
            catch {
                $finalizationText = [string]$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($finalizationText) -or
                    $finalizationText -match $script:SecretAssignmentPattern -or
                    $finalizationText -match $script:SecretNamePattern) {
                    $finalizationText = 'persistence or export finalization failed'
                }
                throw [InvalidOperationException]::new(
                    "Workshop operational failure: $originalText; finalization failure: $finalizationText.",
                    $originalError.Exception)
            }
        }

        if ($null -ne $killError) {
            $killText = [string]$killError.Exception.Message
            if ([string]::IsNullOrWhiteSpace($killText) -or
                $killText -match $script:SecretAssignmentPattern -or
                $killText -match $script:SecretNamePattern) {
                $killText = 'tagged-session cancellation failed'
            }
            throw [InvalidOperationException]::new(
                "Workshop operational failure: $originalText; finalization failure: $killText.",
                $originalError.Exception)
        }
        throw
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
        [Parameter()][switch] $AllowReplaceCompletedRun,
        [Parameter(DontShow)][System.Collections.IDictionary] $FileOperations
    )

    $parsedRunId = [guid]::Empty
    if (-not [guid]::TryParseExact($RunId, 'D', [ref] $parsedRunId) -or $parsedRunId.ToString('D') -cne $RunId) {
        throw 'RunId must be a lowercase canonical GUID.'
    }
    Assert-NoSecretField -InputObject $Evidence
    $evidenceRunId = [string] (Get-ObjectValue $Evidence runId)
    if ([string]::IsNullOrWhiteSpace($evidenceRunId) -or $evidenceRunId -cne $RunId) {
        throw 'Evidence run ID does not match the output run ID.'
    }
    $runsRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'evidence/runs'))
    $directory = [IO.Path]::GetFullPath((Join-Path $runsRoot $RunId))
    if (-not $directory.StartsWith("$runsRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Evidence output path escapes the runs directory.'
    }
    $defaultFileOperations = @{
        TestPath = { param($Path) Test-Path -LiteralPath $Path }
        GetItem = { param($Path) Get-Item -LiteralPath $Path -Force }
        CreateDirectory = { param($Path) [void] (New-Item -ItemType Directory -Path $Path -Force) }
        MoveDirectory = { param($Source, $Target) [IO.Directory]::Move($Source, $Target) }
        RemoveDirectory = { param($Path) if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force } }
        ReadText = { param($Path) Get-Content -LiteralPath $Path -Raw }
        WriteText = { param($Path, $Text, $Encoding) [IO.File]::WriteAllText($Path, $Text, $Encoding) }
        WriteLines = { param($Path, $Lines, $Encoding) [IO.File]::WriteAllLines($Path, [string[]] $Lines, $Encoding) }
    }
    if ($null -eq $FileOperations) { $FileOperations = @{} }
    foreach ($name in $defaultFileOperations.Keys) {
        if (-not $FileOperations.Contains($name)) { $FileOperations[$name] = $defaultFileOperations[$name] }
        if ($FileOperations[$name] -isnot [scriptblock]) { throw "File operation '$name' must be a scriptblock." }
    }
    $assertNoReparseAncestor = {
        param([string] $Path)
        $current = [IO.Path]::GetFullPath($Path)
        while ($null -ne $current) {
            if (& $FileOperations.TestPath $current) {
                $item = & $FileOperations.GetItem $current
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Evidence output paths and ancestors cannot be reparse points or symbolic links.'
                }
            }
            $parent = [IO.Directory]::GetParent($current)
            $current = if ($null -eq $parent) { $null } else { $parent.FullName }
        }
    }.GetNewClosure()
    & $FileOperations.CreateDirectory $runsRoot
    & $assertNoReparseAncestor $runsRoot
    & $assertNoReparseAncestor $directory
    $jsonPath = Join-Path $directory 'evidence.json'
    $csvPath = Join-Path $directory 'samples.csv'
    if ((& $FileOperations.TestPath $jsonPath) -and -not $AllowReplaceCompletedRun) {
        throw 'A completed run cannot be overwritten without the explicit safe replace flag.'
    }
    if ((& $FileOperations.TestPath $jsonPath) -and $AllowReplaceCompletedRun) {
        $existing = (& $FileOperations.ReadText $jsonPath) | ConvertFrom-Json
        if ([string] $existing.runId -cne $RunId) { throw 'Existing completed run identity does not match.' }
    }
    if (-not $PSCmdlet.ShouldProcess($directory, 'Write validated workshop evidence')) { return }

    $utf8 = [Text.UTF8Encoding]::new($false)
    $stagingDirectory = Join-Path $runsRoot ".$RunId.$([guid]::NewGuid().ToString('N')).tmp"
    $backupDirectory = Join-Path $runsRoot ".$RunId.$([guid]::NewGuid().ToString('N')).backup"
    $hadDestination = & $FileOperations.TestPath $directory
    & $FileOperations.CreateDirectory $stagingDirectory
    $jsonTemp = Join-Path $stagingDirectory 'evidence.json'
    $csvTemp = Join-Path $stagingDirectory 'samples.csv'
    $backupCreated = $false
    try {
        & $FileOperations.WriteText $jsonTemp (ConvertTo-Json $Evidence -Depth 30) $utf8
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
        $csvRows = @(
            @((Get-ObjectValue $Evidence samples) | Where-Object { $null -ne $_ }) | ForEach-Object {
                $row = [ordered]@{ recordType = 'Sample' }
                foreach ($entry in Get-ObjectEntry (ConvertTo-CanonicalValue $_)) { $row[$entry.Name] = $entry.Value }
                [pscustomobject]$row
            }
            @((Get-ObjectValue $Evidence trials) | Where-Object { $null -ne $_ }) | ForEach-Object {
                $row = [ordered]@{ recordType = 'Trial' }
                foreach ($entry in Get-ObjectEntry (ConvertTo-CanonicalValue $_)) { $row[$entry.Name] = $entry.Value }
                [pscustomobject]$row
            }
        )
        $columnNames = [System.Collections.Generic.List[string]]::new()
        $columnNames.Add('recordType')
        foreach ($row in $csvRows) {
            foreach ($property in $row.psobject.Properties) {
                if (-not $columnNames.Contains($property.Name)) { $columnNames.Add($property.Name) }
            }
        }
        $projectedRows = @($csvRows | ForEach-Object {
            $source = $_
            $projected = [ordered]@{}
            foreach ($name in $columnNames) {
                $property = $source.psobject.Properties[$name]
                $projected[$name] = if ($null -eq $property) { $null } else { $property.Value }
            }
            [pscustomobject]$projected
        })
        $csv = if ($projectedRows.Count -eq 0) { @('recordType') } else { @($projectedRows | ConvertTo-Csv -NoTypeInformation) }
        & $FileOperations.WriteLines $csvTemp $csv $utf8
        & $assertNoReparseAncestor $stagingDirectory
        & $assertNoReparseAncestor $backupDirectory
        & $assertNoReparseAncestor $directory
        if (& $FileOperations.TestPath $directory) {
            if (-not $AllowReplaceCompletedRun) { throw 'A completed run cannot be overwritten without the explicit safe replace flag.' }
            & $assertNoReparseAncestor $directory
            & $assertNoReparseAncestor $backupDirectory
            & $FileOperations.MoveDirectory $directory $backupDirectory
            $backupCreated = (& $FileOperations.TestPath $backupDirectory) -and -not (& $FileOperations.TestPath $directory)
        }
        & $assertNoReparseAncestor $stagingDirectory
        & $assertNoReparseAncestor $directory
        & $FileOperations.MoveDirectory $stagingDirectory $directory
        if ($SemanticValidator) {
            if (-not (& $SemanticValidator $jsonPath)) { throw 'Canonical semantic evidence validation failed after promotion.' }
        }
        else {
            & $python $validator --schema $schema $jsonPath | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Canonical semantic evidence validation failed after promotion.' }
        }
        if ($backupCreated) { & $FileOperations.RemoveDirectory $backupDirectory; $backupCreated = $false }
    }
    catch {
        if (& $FileOperations.TestPath $backupDirectory) {
            & $assertNoReparseAncestor $backupDirectory
            if (& $FileOperations.TestPath $directory) {
                & $assertNoReparseAncestor $directory
                & $FileOperations.RemoveDirectory $directory
            }
            & $FileOperations.MoveDirectory $backupDirectory $directory
            if (-not (& $FileOperations.TestPath $directory) -or (& $FileOperations.TestPath $backupDirectory)) {
                throw 'Failed to restore the prior completed evidence directory; the backup was preserved when possible.'
            }
            $restoredJsonPath = Join-Path $directory 'evidence.json'
            $restored = (& $FileOperations.ReadText $restoredJsonPath) | ConvertFrom-Json
            if ([string]$restored.runId -cne $RunId) {
                throw 'Restored completed evidence failed run identity validation.'
            }
            $backupCreated = $false
        }
        elseif (-not $hadDestination -and (& $FileOperations.TestPath $directory)) {
            & $assertNoReparseAncestor $directory
            & $FileOperations.RemoveDirectory $directory
        }
        throw
    }
    finally {
        try { & $FileOperations.RemoveDirectory $stagingDirectory } catch { Write-Verbose 'Staging cleanup failed.' }
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
    $preflightSnapshot = [pscustomobject]@{ Value = $null }
    Write-Verbose "Preparing SQL operations for database '$Database' and credential user '$($Credential.UserName)'."

    $invokeTable = {
        param([string] $ApplicationName, [string] $CommandText, [hashtable] $Parameters, [scriptblock] $ReaderParser, [int] $CommandTimeoutSeconds = 60)
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
            $command.CommandTimeout = [math]::Max(1, $CommandTimeoutSeconds)
            foreach ($name in @($Parameters.Keys)) {
                $specification = $Parameters[$name]
                $parameter = $command.Parameters.Add($name, $specification.Type)
                if ($specification.ContainsKey('Size')) { $parameter.Size = $specification.Size }
                $parameter.Value = if ($null -eq $specification.Value) { [DBNull]::Value } else { $specification.Value }
            }
            $reader = $command.ExecuteReader()
            if ($null -ne $ReaderParser) {
                return & $ReaderParser $reader
            }
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
CREATE TABLE #FactSalesChunkHash
(
    ChunkID bigint NOT NULL PRIMARY KEY,
    ChunkHash varbinary(32) NOT NULL
);
INSERT #FactSalesChunkHash (ChunkID, ChunkHash)
SELECT (SyntheticSalesID - 1) / 10000,
       HASHBYTES('SHA2_256', CONVERT(varbinary(max), STRING_AGG(CONVERT(nvarchar(max),
           CONCAT_WS(NCHAR(31), SyntheticSalesID, CONVERT(char(27), OrderDate, 126),
               COALESCE(CONVERT(varchar(11), TerritoryID), N'<NULL>'), CustomerID, ProductID,
               OrderQty, CONVERT(varchar(50), UnitPrice), CONVERT(varchar(50), SalesAmount),
               WidePayload, SourceCustomerID, SourceProductID, SourceChecksum)), NCHAR(30))
           WITHIN GROUP (ORDER BY SyntheticSalesID)))
FROM lab.FactSales
GROUP BY (SyntheticSalesID - 1) / 10000;

SELECT
    CONVERT(bit, CASE WHEN DB_NAME() = N'AdventureWorks2022' AND EXISTS
        (SELECT 1 FROM lab.WorkshopMarker WHERE MarkerId = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C') THEN 1 ELSE 0 END) AS MarkerValid,
    CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) AS SqlMajorVersion,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS SqlProductVersion,
    CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS SqlEdition,
    CONVERT(bigint, memory.total_physical_memory_kb / 1024) AS PhysicalMemoryMB,
    CONVERT(varchar(60), queryStore.actual_state_desc) AS QueryStoreActualState,
    CONVERT(sysname, pool.name) AS ResourcePool,
    CONVERT(decimal(9,4), pool.min_memory_percent) AS PoolMinMemoryPercent,
    CONVERT(decimal(9,4), pool.max_memory_percent) AS PoolMaxMemoryPercent,
    CONVERT(sysname, workloadGroup.name) AS WorkloadGroup,
    CONVERT(decimal(9,4), workloadGroup.request_max_memory_grant_percent) AS GroupRequestMaxMemoryGrantPercent,
    CONVERT(int, workloadGroup.max_dop) AS GroupMaxDop,
    CONVERT(int, workloadGroup.group_max_requests) AS GroupMaxRequests,
    CONVERT(int, maxMemory.value_in_use) AS MaxServerMemoryMB,
    CONVERT(int, minMemory.value_in_use) AS MinServerMemoryMB,
    CONVERT(bit, CASE WHEN rowFeedback.value = 0 THEN 1 ELSE 0 END) AS RowModeMemoryGrantFeedbackDisabled,
    CONVERT(bit, CASE WHEN batchFeedback.value = 0 THEN 1 ELSE 0 END) AS BatchModeMemoryGrantFeedbackDisabled,
    CONVERT(bit, CASE WHEN controller.group_id = workloadGroup.group_id THEN 1 ELSE 0 END) AS ControllerSessionInWorkloadGroup,
    CONVERT(nvarchar(60), backupState.PriorMemoryGrantFeedbackState) AS PriorMemoryGrantFeedbackState,
    CONVERT(bit, CASE WHEN OBJECT_ID(N'lab.usp_MonthEndSalesBaseline', N'P') IS NOT NULL
        AND OBJECT_ID(N'lab.usp_MonthEndSalesOptimized', N'P') IS NOT NULL THEN 1 ELSE 0 END) AS ProceduresPresent,
    CONVERT(bit, CASE WHEN OBJECT_ID(N'lab.WorkshopRun', N'U') IS NOT NULL THEN 1 ELSE 0 END) AS WorkshopRunPresent,
    CONVERT(bit, CASE WHEN OBJECT_ID(N'lab.WorkshopSample', N'U') IS NOT NULL THEN 1 ELSE 0 END) AS WorkshopSamplePresent,
    CONVERT(bit, CASE WHEN OBJECT_ID(N'lab.WorkshopRequestSample', N'U') IS NOT NULL THEN 1 ELSE 0 END) AS WorkshopRequestSamplePresent,
    CONVERT(bit, CASE WHEN OBJECT_ID(N'lab.WorkshopTrial', N'U') IS NOT NULL THEN 1 ELSE 0 END) AS WorkshopTrialPresent,
    validation.ValidationBatchID,
    CONVERT(bit, CASE WHEN validation.PassingCases = 11 AND validation.TotalCases = 11 THEN 1 ELSE 0 END) AS ValidationPassed,
    validation.ValidationValidatedAtUtc,
    validation.ValidationBatchHash,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max), CONCAT(
        (SELECT COUNT_BIG(*) FROM lab.FactSales), N'|',
        (SELECT STRING_AGG(CONVERT(varchar(max), CONVERT(varchar(64), ChunkHash, 2)), N'')
            WITHIN GROUP (ORDER BY ChunkID) FROM #FactSalesChunkHash)))), 2)) AS DataHash,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max),
        (SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT_WS(NCHAR(31),
                        indexDefinition.stats_id, indexDefinition.stats_name,
                        indexDefinition.auto_created, indexDefinition.user_created,
                        indexDefinition.no_recompute, indexDefinition.has_filter,
                        indexDefinition.index_id, indexDefinition.index_name, indexDefinition.type_desc,
                        indexDefinition.is_unique, indexDefinition.is_disabled, indexDefinition.is_hypothetical,
            COALESCE(indexDefinition.filter_definition, N'<NULL>'), indexDefinition.fill_factor,
                        indexDefinition.stats_column_id, indexDefinition.index_column_id, indexDefinition.key_ordinal,
            indexDefinition.is_descending_key, indexDefinition.is_included_column,
                        indexDefinition.column_name, indexDefinition.row_count, indexDefinition.rows_sampled,
            CONVERT(nvarchar(33), indexDefinition.stats_updated_at, 126),
            indexDefinition.modification_counter)), NCHAR(30))
                        WITHIN GROUP (ORDER BY indexDefinition.stats_id, indexDefinition.stats_column_id)
         FROM
         (
                         SELECT statistics.stats_id, statistics.name AS stats_name,
                                 statistics.auto_created, statistics.user_created, statistics.no_recompute,
                                 statistics.has_filter, COALESCE(i.index_id, 0) AS index_id,
                                 COALESCE(i.name, N'<STANDALONE>') AS index_name,
                                 COALESCE(i.type_desc, N'<NONE>') AS type_desc,
                                 COALESCE(i.is_unique, 0) AS is_unique,
                                 COALESCE(i.is_disabled, 0) AS is_disabled,
                                 COALESCE(i.is_hypothetical, 0) AS is_hypothetical,
                                 statistics.filter_definition, COALESCE(i.fill_factor, 0) AS fill_factor,
                                 statisticsColumn.stats_column_id,
                 COALESCE(ic.index_column_id, 0) AS index_column_id,
                 COALESCE(ic.key_ordinal, 0) AS key_ordinal,
                 COALESCE(ic.is_descending_key, 0) AS is_descending_key,
                 COALESCE(ic.is_included_column, 0) AS is_included_column,
                 COALESCE(c.name, N'<HEAP>') AS column_name,
                 COALESCE(partitions.row_count, 0) AS row_count,
                                 COALESCE(properties.rows_sampled, 0) AS rows_sampled,
                                 STATS_DATE(statistics.object_id, statistics.stats_id) AS stats_updated_at,
                 COALESCE(properties.modification_counter, 0) AS modification_counter
                         FROM sys.stats AS statistics
                         INNER JOIN sys.stats_columns AS statisticsColumn
                             ON statisticsColumn.object_id = statistics.object_id
                            AND statisticsColumn.stats_id = statistics.stats_id
                         LEFT JOIN sys.indexes AS i
                             ON i.object_id = statistics.object_id AND i.index_id = statistics.stats_id
             LEFT JOIN sys.index_columns AS ic
                             ON ic.object_id = statisticsColumn.object_id AND ic.index_id = i.index_id
                            AND ic.column_id = statisticsColumn.column_id
             LEFT JOIN sys.columns AS c
                             ON c.object_id = statisticsColumn.object_id AND c.column_id = statisticsColumn.column_id
                         OUTER APPLY sys.dm_db_stats_properties(statistics.object_id, statistics.stats_id) AS properties
             OUTER APPLY
             (
                 SELECT SUM(partition.row_count) AS row_count
                 FROM sys.dm_db_partition_stats AS partition
                 WHERE partition.object_id = statistics.object_id AND partition.index_id = i.index_id
             ) AS partitions
             WHERE statistics.object_id = OBJECT_ID(N'lab.FactSales')
         ) AS indexDefinition))), 2)) AS IndexStatisticsHash,
    LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT(OBJECT_DEFINITION(OBJECT_ID(N'lab.usp_MonthEndSalesBaseline')), OBJECT_DEFINITION(OBJECT_ID(N'lab.usp_MonthEndSalesOptimized')))), 2)) AS ProcedureHash
FROM sys.dm_os_sys_memory AS memory
CROSS JOIN sys.database_query_store_options AS queryStore
INNER JOIN sys.dm_resource_governor_resource_pools AS pool ON pool.name = N'mcp_sql_workshop_pool'
INNER JOIN sys.dm_resource_governor_workload_groups AS workloadGroup ON workloadGroup.pool_id = pool.pool_id AND workloadGroup.name = N'mcp_sql_workshop_group'
INNER JOIN sys.database_scoped_configurations AS rowFeedback ON rowFeedback.name = N'ROW_MODE_MEMORY_GRANT_FEEDBACK'
INNER JOIN sys.database_scoped_configurations AS batchFeedback ON batchFeedback.name = N'BATCH_MODE_MEMORY_GRANT_FEEDBACK'
INNER JOIN sys.configurations AS maxMemory ON maxMemory.name = N'max server memory (MB)'
INNER JOIN sys.configurations AS minMemory ON minMemory.name = N'min server memory (MB)'
INNER JOIN sys.dm_exec_sessions AS controller ON controller.session_id = @@SPID
OUTER APPLY (SELECT TOP (1) CONVERT(nvarchar(60), RowModeMemoryGrantFeedback) AS PriorMemoryGrantFeedbackState FROM WorkshopAdmin.dbo.DatabaseConfigurationBackup WHERE DatabaseName = DB_NAME() ORDER BY CapturedAtUtc DESC) AS backupState
OUTER APPLY
(
    SELECT TOP (1)
        candidate.ValidationBatchID,
        COUNT_BIG(*) AS TotalCases,
        SUM(CONVERT(bigint, candidate.Passed)) AS PassingCases,
        MIN(candidate.ValidatedAtUtc) AS ValidationValidatedAtUtc,
        LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max),
            STRING_AGG(CONVERT(nvarchar(max), CONCAT_WS(NCHAR(31),
                candidate.ValidationCaseName,
                CONVERT(char(10), candidate.StartDate, 126),
                CONVERT(char(10), candidate.EndDateExclusive, 126),
                COALESCE(CONVERT(varchar(11), candidate.TerritoryID), N'<NULL>'),
                CONVERT(varchar(11), candidate.TopCount),
                CONVERT(varchar(30), candidate.BaselineRowCount),
                CONVERT(varchar(30), candidate.OptimizedRowCount),
                CONVERT(varchar(64), candidate.BaselineHash, 2),
                CONVERT(varchar(64), candidate.OptimizedHash, 2),
                CONVERT(char(1), candidate.Passed))), NCHAR(30))
            WITHIN GROUP (ORDER BY candidate.ValidationCaseName))), 2)) AS ValidationBatchHash
    FROM lab.ValidationRun AS candidate
    GROUP BY candidate.ValidationBatchID
    HAVING COUNT_BIG(*) = 11
       AND SUM(CONVERT(bigint, candidate.Passed)) = 11
       AND SUM(CASE WHEN candidate.BaselineRunID IS NULL AND candidate.OptimizedRunID IS NULL THEN 1 ELSE 0 END) = 11
       AND MIN(candidate.ValidatedAtUtc) >= DATEADD(hour, -24, SYSUTCDATETIME())
       AND MAX(candidate.ValidatedAtUtc) <= DATEADD(minute, 5, SYSUTCDATETIME())
    ORDER BY MIN(candidate.ValidatedAtUtc) DESC, candidate.ValidationBatchID DESC
) AS validation;
'@
    $getPreflight = {
        param([int] $CommandTimeoutSeconds = 60)
        $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Preflight' $preflightSql @{} $null $CommandTimeoutSeconds)
        if ($rows.Count -ne 1) { throw 'Workshop SQL preflight did not return exactly one row.' }
        if ($null -eq $preflightSnapshot.Value) { $preflightSnapshot.Value = $rows[0] }
        return $rows[0]
    }.GetNewClosure()

    $startWorker = {
        param([guid] $RunId, [string] $Phase, [int] $Worker, [string] $ApplicationName, [object[]] $Schedule, [datetimeoffset] $Deadline)
        Write-Verbose "Starting workshop worker $Worker for $Phase."
        $runspace = $null
        $powerShell = $null
        $asyncResult = $null
        $readySignal = [Threading.ManualResetEventSlim]::new($false)
        try {
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $powerShell = [powershell]::Create()
            $powerShell.Runspace = $runspace
            [void] $powerShell.AddScript({
                param($WorkerServer, $WorkerDatabase, [pscredential] $WorkerCredential, $WorkerCertificateName,
                    $WorkerRunId, $WorkerPhase, $WorkerApplicationName, $WorkerSchedule,
                    [datetimeoffset]$WorkerDeadline, $readySignal)
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
                    $tagRemainingSeconds = ($WorkerDeadline - [datetimeoffset]::UtcNow).TotalSeconds
                    if ($tagRemainingSeconds -le 0) { throw 'The experiment deadline elapsed before worker tagging completed.' }
                    $tag.CommandTimeout = [math]::Max(1, [int][math]::Ceiling($tagRemainingSeconds))
                    [void] $tag.Parameters.Add('@RunBytes', [Data.SqlDbType]::Binary, 16)
                    $tag.Parameters['@RunBytes'].Value = ([guid] $WorkerRunId).ToByteArray()
                    [void] $tag.Parameters.Add('@RunId', [Data.SqlDbType]::UniqueIdentifier)
                    $tag.Parameters['@RunId'].Value = [guid] $WorkerRunId
                    [void] $tag.Parameters.Add('@Phase', [Data.SqlDbType]::NVarChar, 16)
                    $tag.Parameters['@Phase'].Value = $WorkerPhase
                    [void] $tag.ExecuteNonQuery()
                    $readySignal.Set()
                }
                finally { $tag.Dispose() }

                for ($iteration = 0; $iteration -lt 10000; $iteration++) {
                    if ([datetimeoffset]::UtcNow -ge $WorkerDeadline) { break }
                    $entry = $WorkerSchedule[$iteration % $WorkerSchedule.Count] | ConvertFrom-Json
                    $command = $connection.CreateCommand()
                    try {
                        $procedure = if ($WorkerPhase -eq 'Baseline') { 'lab.usp_MonthEndSalesBaseline' } else { 'lab.usp_MonthEndSalesOptimized' }
                        $command.CommandText = "EXEC $procedure @StartDate=@StartDate, @EndDateExclusive=@EndDateExclusive, @TerritoryID=@TerritoryID, @TopCount=@TopCount;"
                        $remainingSeconds = ($WorkerDeadline - [datetimeoffset]::UtcNow).TotalSeconds
                        if ($remainingSeconds -le 0) { break }
                        $command.CommandTimeout = [math]::Max(1, [int][math]::Ceiling($remainingSeconds))
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
            }).AddArgument($Server).AddArgument($Database).AddArgument($Credential).AddArgument($HostNameInCertificate).AddArgument($RunId).AddArgument($Phase).AddArgument($ApplicationName).AddArgument($Schedule).AddArgument($Deadline).AddArgument($readySignal)
            $asyncResult = $powerShell.BeginInvoke()
            if (-not $readySignal.Wait([TimeSpan]::FromSeconds(15))) {
                $details = @($powerShell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join ' '
                throw "Workshop worker failed to become tagged and ready within 15 seconds. $details".Trim()
            }
        }
        catch {
            try { if ($null -ne $powerShell -and $null -ne $asyncResult -and -not $asyncResult.IsCompleted) { $powerShell.Stop() } } catch { Write-Verbose 'Worker stop failed during setup cleanup.' }
            try { if ($null -ne $powerShell -and $null -ne $asyncResult) { [void] $powerShell.EndInvoke($asyncResult) } } catch { Write-Verbose 'Worker invocation ended during setup cleanup.' }
            if ($null -ne $powerShell) { $powerShell.Dispose() }
            if ($null -ne $runspace) { $runspace.Dispose() }
            $readySignal.Dispose()
            throw
        }
        $handle = [pscustomobject]@{
            PowerShell = $powerShell
            Runspace = $runspace
            AsyncResult = $asyncResult
            ReadySignal = $readySignal
            Disposed = $false
            EndInvoked = $false
            TerminalError = $null
        }
        $handle | Add-Member ScriptMethod TestHealth {
            if ($this.Disposed) {
                return [pscustomobject]@{ Healthy = $false; Reason = 'Worker handle is disposed.'; Terminal = $true }
            }
            if (-not $this.AsyncResult.IsCompleted) {
                return [pscustomobject]@{ Healthy = $true; Reason = $null; Terminal = $false }
            }
            if (-not $this.EndInvoked) {
                try { [void] $this.PowerShell.EndInvoke($this.AsyncResult) }
                catch { $this.TerminalError = $_.Exception.Message }
                finally { $this.EndInvoked = $true }
            }
            $reason = if ([string]::IsNullOrWhiteSpace([string]$this.TerminalError)) {
                'Worker completed unexpectedly while its phase was active.'
            }
            else { 'Worker failed while its phase was active.' }
            return [pscustomobject]@{ Healthy = $false; Reason = $reason; Terminal = $true }
        }
        $handle | Add-Member ScriptMethod Dispose {
            if ($this.Disposed) { return }
            try {
                if (-not $this.AsyncResult.IsCompleted) { $this.PowerShell.Stop() }
                if (-not $this.EndInvoked) {
                    try { [void] $this.PowerShell.EndInvoke($this.AsyncResult) } catch { Write-Verbose 'Worker ended after cancellation.' }
                    $this.EndInvoked = $true
                }
            }
            finally {
                $this.PowerShell.Dispose()
                $this.Runspace.Dispose()
                $this.ReadySignal.Dispose()
                $this.Disposed = $true
            }
        }
        return $handle
    }.GetNewClosure()

    $testWorkerHealth = {
        param([object[]] $Handles)
        foreach ($handle in @($Handles)) {
            if ($null -eq $handle -or -not $handle.psobject.Methods['TestHealth']) {
                return [pscustomobject]@{ Healthy = $false; Reason = 'Worker handle does not expose health.' }
            }
            $health = $handle.TestHealth()
            if (-not $health.Healthy) { return $health }
        }
        return [pscustomobject]@{ Healthy = $true; Reason = $null }
    }

    $sample = {
        param([guid] $RunId, [string] $Phase, [string] $Kind, [string] $TrialPhase, [string] $ScheduleEntry, [int] $RemainingSeconds)
        $commandTimeout = [math]::Max(1, $RemainingSeconds)
        if ($Kind -eq 'Fingerprint') { return (& $getPreflight $commandTimeout) }
        if ($Kind -eq 'Memory' -or $Kind -eq 'Drain') {
            $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Sample' 'EXEC lab.usp_GetMemorySnapshot;' @{} $null $commandTimeout)
            if ($rows.Count -ne 1) { throw 'Memory snapshot did not return exactly one row.' }
            $row = $rows[0]
            $totalHost = [decimal] $row.HostAvailableMemoryKB + [decimal] $row.HostUsedMemoryKB
            $requestRows = if ($Kind -eq 'Memory') {
                @(& $invokeTable 'MCP-SQL-Workshop-Controller-Sample' `
                    'EXEC lab.usp_GetActiveWorkshopGrants @Top=100, @RunID=@RunID;' `
                    @{ '@RunID' = @{ Type = [Data.SqlDbType]::UniqueIdentifier; Value = $RunId } } $null $commandTimeout)
            }
            else { @() }
            return [pscustomobject]@{
                Phase = $Phase; GrantedKb = $row.PoolGrantedMemoryKB; TotalKb = $row.PoolTotalMemoryKB
                GrantUtilizationPercent = $row.GrantUtilizationPercent
                HostUsedPercent = if ($totalHost -eq 0) { 100 } else { 100 * [decimal] $row.HostUsedMemoryKB / $totalHost }
                HostAvailableMB = [decimal] $row.HostAvailableMemoryKB / 1024
                ProcessPhysicalLow = [bool] $row.ProcessLowMemorySignal
                ProcessVirtualLow = [bool] $row.SystemLowMemorySignal
                Healthy = $true; ActiveGrantCount = [int] $row.GranteeCount + [int] $row.WaiterCount
                ManualStopRequested = Test-Path -LiteralPath ($stopRequestPath -f $RunId.ToString('D'))
                SampledAtUtc = $row.SampledAtUtc
                PoolTotalMemoryKB = $row.PoolTotalMemoryKB
                PoolGrantedMemoryKB = $row.PoolGrantedMemoryKB
                PoolUsedMemoryKB = $row.PoolUsedMemoryKB
                PoolAvailableMemoryKB = $row.PoolAvailableMemoryKB
                GranteeCount = $row.GranteeCount
                WaiterCount = $row.WaiterCount
                HostAvailableMemoryKB = $row.HostAvailableMemoryKB
                HostUsedMemoryKB = $row.HostUsedMemoryKB
                ProcessPhysicalMemoryKB = $row.ProcessPhysicalMemoryKB
                TotalServerMemoryKB = $row.TotalServerMemoryKB
                TargetServerMemoryKB = $row.TargetServerMemoryKB
                SystemLowMemorySignal = $row.SystemLowMemorySignal
                ProcessLowMemorySignal = $row.ProcessLowMemorySignal
                RequestSamples = $requestRows
            }
        }
        if ($Kind -eq 'Trial') {
            if ($null -eq $preflightSnapshot.Value) { throw 'Workshop preflight must complete before trial execution.' }
            $entry = $ScheduleEntry | ConvertFrom-Json
            $procedure = if ($TrialPhase -eq 'Baseline') { 'lab.usp_MonthEndSalesBaseline' } else { 'lab.usp_MonthEndSalesOptimized' }
            $sql = @'
SET NOCOUNT ON;
SET CONTEXT_INFO @RunBytes;
EXEC sys.sp_set_session_context @key=N'WorkshopRunId', @value=@RunId;
EXEC sys.sp_set_session_context @key=N'WorkshopPhase', @value=@Phase;
DECLARE @ProcedureObjectID int=OBJECT_ID(N'__PROCEDURE__');
CREATE TABLE #BeforeQueryStats
(
    plan_handle varbinary(64) NOT NULL,
    sql_handle varbinary(64) NOT NULL,
    statement_start_offset int NOT NULL,
    statement_end_offset int NOT NULL,
    total_grant_kb bigint NOT NULL,
    total_used_grant_kb bigint NOT NULL,
    total_spills bigint NOT NULL,
    PRIMARY KEY (plan_handle, sql_handle, statement_start_offset, statement_end_offset)
);
INSERT #BeforeQueryStats
    (plan_handle, sql_handle, statement_start_offset, statement_end_offset,
     total_grant_kb, total_used_grant_kb, total_spills)
SELECT qs.plan_handle, qs.sql_handle, qs.statement_start_offset, qs.statement_end_offset,
       qs.total_grant_kb, qs.total_used_grant_kb, qs.total_spills
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS beforeText
WHERE beforeText.objectid=@ProcedureObjectID;
CREATE TABLE #TrialResult
(
    TerritoryID int NULL, CustomerID int NOT NULL, ProductID int NOT NULL,
    OrderCount bigint NOT NULL, TotalQuantity bigint NOT NULL,
    TotalSales decimal(38,4) NOT NULL, AverageUnitPrice decimal(19,4) NOT NULL,
    SalesRank bigint NOT NULL
);
DECLARE @Started datetime2(3)=SYSUTCDATETIME(),
        @Cpu bigint=(SELECT cpu_time FROM sys.dm_exec_sessions WHERE session_id=@@SPID),
        @Reads bigint=(SELECT logical_reads FROM sys.dm_exec_sessions WHERE session_id=@@SPID),
        @Wait bigint=(SELECT COALESCE(SUM(wait_time_ms),0) FROM sys.dm_exec_session_wait_stats WHERE session_id=@@SPID);
INSERT #TrialResult EXEC __PROCEDURE__
    @StartDate=@StartDate, @EndDateExclusive=@EndDateExclusive,
    @TerritoryID=@TerritoryID, @TopCount=@TopCount;
DECLARE @Completed datetime2(3)=SYSUTCDATETIME(), @ResultRowCount bigint=(SELECT COUNT_BIG(*) FROM #TrialResult);
DECLARE @Canonical nvarchar(max)=(SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT_WS(N'|',
    COALESCE(CONVERT(nvarchar(20),TerritoryID),N'<NULL>'), CustomerID, ProductID, OrderCount,
    TotalQuantity, CONVERT(nvarchar(80),TotalSales), CONVERT(nvarchar(80),AverageUnitPrice), SalesRank)),NCHAR(10))
    WITHIN GROUP (ORDER BY SalesRank, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID)
    FROM #TrialResult);
SELECT TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank
FROM #TrialResult
ORDER BY SalesRank, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID;
SELECT
    CONVERT(bigint,DATEDIFF_BIG(millisecond,@Started,@Completed)) AS DurationMs,
    CONVERT(bigint,s.cpu_time-@Cpu) AS CpuMs,
    CONVERT(bigint,s.logical_reads-@Reads) AS LogicalReads,
    CONVERT(bigint,COALESCE(p.grant_kb,0)) AS GrantedKB,
    CONVERT(bigint,COALESCE(p.used_grant_kb,0)) AS UsedKB,
    CONVERT(bigint,COALESCE(p.spills,0)*8) AS SpillKB,
    CONVERT(bigint,(SELECT COALESCE(SUM(wait_time_ms),0) FROM sys.dm_exec_session_wait_stats WHERE session_id=@@SPID)-@Wait) AS WaitMs,
    @ResultRowCount AS ResultRowCount,
    CONVERT(varbinary(32),HASHBYTES('SHA2_256',CONVERT(varbinary(max),COALESCE(@Canonical,N'')))) AS ResultHash,
    @ResultRowCount AS ExpectedRowCount,
    @ResultRowCount AS ActualRowCount,
    CONVERT(bigint,1) AS DifferenceCount,
    CONVERT(bit,0) AS Correct,
    @ValidationBatchID AS ValidationBatchID,
    @Started AS StartedAtUtc,
    @Completed AS CompletedAtUtc
FROM sys.dm_exec_sessions AS s
OUTER APPLY
(
    SELECT SUM(qs.total_grant_kb-COALESCE(beforeStats.total_grant_kb,0)) AS grant_kb,
           SUM(qs.total_used_grant_kb-COALESCE(beforeStats.total_used_grant_kb,0)) AS used_grant_kb,
           SUM(qs.total_spills-COALESCE(beforeStats.total_spills,0)) AS spills
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS trialText
    LEFT JOIN #BeforeQueryStats AS beforeStats
      ON beforeStats.plan_handle=qs.plan_handle
     AND beforeStats.sql_handle=qs.sql_handle
     AND beforeStats.statement_start_offset=qs.statement_start_offset
     AND beforeStats.statement_end_offset=qs.statement_end_offset
    WHERE trialText.objectid=@ProcedureObjectID
      AND qs.last_execution_time >= @Started
      AND qs.last_execution_time <= @Completed
) AS p
WHERE s.session_id=@@SPID;
'@
            $sql = $sql.Replace('__PROCEDURE__', $procedure)
            $parameters = @{
                '@StartDate' = @{ Type = [Data.SqlDbType]::Date; Value = [datetime] $entry.StartDate }
                '@EndDateExclusive' = @{ Type = [Data.SqlDbType]::Date; Value = [datetime] $entry.EndDateExclusive }
                '@TerritoryID' = @{ Type = [Data.SqlDbType]::Int; Value = $entry.TerritoryID }
                '@TopCount' = @{ Type = [Data.SqlDbType]::Int; Value = [int] $entry.TopCount }
                '@RunBytes' = @{ Type = [Data.SqlDbType]::Binary; Size = 16; Value = $RunId.ToByteArray() }
                '@RunId' = @{ Type = [Data.SqlDbType]::UniqueIdentifier; Value = $RunId }
                '@Phase' = @{ Type = [Data.SqlDbType]::NVarChar; Size = 16; Value = $TrialPhase }
                '@ValidationBatchID' = @{ Type = [Data.SqlDbType]::UniqueIdentifier; Value = [guid]$preflightSnapshot.Value.ValidationBatchID }
            }
            $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase $TrialPhase -Worker 1
            $row = & $invokeTable $applicationName $sql $parameters { param($Reader) ConvertFrom-WorkshopTrialReader $Reader } $commandTimeout
            $row | Add-Member NoteProperty Phase $TrialPhase -PassThru
        }
    }.GetNewClosure()

    $stopWorker = {
        param($Handle)
        if ($null -ne $Handle -and $Handle.psobject.Methods['Dispose']) { $Handle.Dispose() }
    }

    $getKillPlan = ${function:Get-WorkshopKillPlan}
    $killTagged = {
        param([guid] $RunId)
        $sessionSql = "SELECT CONVERT(int,s.session_id) AS SessionId, CONVERT(bit,s.is_user_process) AS IsUserProcess, CONVERT(bit,CASE WHEN r.session_id IS NOT NULL THEN 1 ELSE 0 END) AS IsActive, CONVERT(nvarchar(128),s.program_name) AS ProgramName, CONVERT(varbinary(128),s.context_info) AS ContextInfo, CONVERT(int,@@SPID) AS CurrentSessionId FROM sys.dm_exec_sessions AS s LEFT JOIN sys.dm_exec_requests AS r ON r.session_id=s.session_id WHERE s.program_name LIKE @Prefix;"
        $parameters = @{ '@Prefix' = @{ Type = [Data.SqlDbType]::NVarChar; Size = 128; Value = "MCP-SQL-Workshop-$($RunId.ToString('D'))-%" } }
        $sessions = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Stop' $sessionSql $parameters)
        if ($sessions.Count -eq 0) { return @() }
        $plan = @(& $getKillPlan -RunId $RunId -Sessions $sessions -CurrentSessionId $sessions[0].CurrentSessionId)
        foreach ($entry in $plan) {
            # Persist the exact captured row before executing a KILL generated solely from a validated integer SPID.
            [void] (& $invokeTable 'MCP-SQL-Workshop-Controller-Stop' $entry.Statement @{})
        }
        return @($plan.SessionId)
    }.GetNewClosure()

    $getSha256ForPersistence = ${function:Get-Sha256}
    $getObjectEntryForPersistence = ${function:Get-ObjectEntry}
    $persist = {
        param($Record)
        $settingsJson = if ($null -eq $Record.FrozenSettingsJson) { '{}' } else { [string]$Record.FrozenSettingsJson }
        $settingsHash = if ($null -eq $Record.FrozenSettingsHash) { & $getSha256ForPersistence $settingsJson } else { [string]$Record.FrozenSettingsHash }
        $hashBytes = [Convert]::FromHexString($settingsHash)
        $sampleJson = ConvertTo-Json @($Record.Samples) -Depth 12 -Compress
        $requestJson = ConvertTo-Json @($Record.RequestSamples) -Depth 12 -Compress
        $trialJson = ConvertTo-Json @($Record.Trials | ForEach-Object {
            $copy = [ordered]@{}
            foreach ($entry in & $getObjectEntryForPersistence $_) { $copy[$entry.Name] = $entry.Value }
            if ($copy.ResultHash -is [byte[]]) { $copy.ResultHash = [Convert]::ToHexString($copy.ResultHash) }
            [pscustomobject]$copy
        }) -Depth 12 -Compress
        $sql = @'
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    IF EXISTS (SELECT 1 FROM lab.WorkshopRun WITH (UPDLOCK, HOLDLOCK) WHERE RunID=@RunId)
        BEGIN
         DECLARE @ExistingSampleCount int=(SELECT COUNT(*) FROM lab.WorkshopSample WHERE RunID=@RunId),
              @ExistingRequestSampleCount int=(SELECT COUNT(*) FROM lab.WorkshopRequestSample WHERE RunID=@RunId),
              @ExistingTrialCount int=(SELECT COUNT(*) FROM lab.WorkshopTrial WHERE RunID=@RunId);
         IF NOT EXISTS
         (
             SELECT 1 FROM lab.WorkshopRun
             WHERE RunID=@RunId AND ParentComparisonID IS NULL
            AND EvidenceClassification='LAB-MEASURED'
            AND Phase=@Phase AND RunStatus=@RunStatus AND Outcome=@Outcome
            AND StartedAtUtc=CONVERT(datetime2(3),@StartedAtUtc)
            AND CompletedAtUtc=CONVERT(datetime2(3),@CompletedAtUtc)
            AND FrozenSettingsHash=@FrozenSettingsHash
            AND FrozenSettingsJson=@FrozenSettingsJson
         )
         OR @ExistingSampleCount<>@ExpectedSampleCount
         OR @ExistingRequestSampleCount<>@ExpectedRequestSampleCount
         OR @ExistingTrialCount<>@ExpectedTrialCount
         OR EXISTS
         (
             SELECT value.SampleSequence, value.SampledAtUtc, value.Phase, value.PoolTotalMemoryKB,
                 value.PoolGrantedMemoryKB, value.PoolUsedMemoryKB, value.PoolAvailableMemoryKB,
                 value.GrantUtilizationPercent, value.GranteeCount, value.WaiterCount,
                 value.HostAvailableMemoryKB, value.HostUsedMemoryKB, value.ProcessPhysicalMemoryKB,
                 value.TotalServerMemoryKB, value.TargetServerMemoryKB,
                 value.SystemLowMemorySignal, value.ProcessLowMemorySignal
             FROM OPENJSON(@SamplesJson) WITH
             (SampleSequence int, SampledAtUtc datetime2(3), Phase varchar(16), PoolTotalMemoryKB bigint,
              PoolGrantedMemoryKB bigint, PoolUsedMemoryKB bigint, PoolAvailableMemoryKB bigint,
              GrantUtilizationPercent decimal(6,2), GranteeCount int, WaiterCount int,
              HostAvailableMemoryKB bigint, HostUsedMemoryKB bigint, ProcessPhysicalMemoryKB bigint,
              TotalServerMemoryKB bigint, TargetServerMemoryKB bigint, SystemLowMemorySignal bit,
              ProcessLowMemorySignal bit) AS value
             EXCEPT
             SELECT SampleSequence, SampledAtUtc, Phase, PoolTotalMemoryKB, PoolGrantedMemoryKB,
                 PoolUsedMemoryKB, PoolAvailableMemoryKB, GrantUtilizationPercent, GranteeCount,
                 WaiterCount, HostAvailableMemoryKB, HostUsedMemoryKB, ProcessPhysicalMemoryKB,
                 TotalServerMemoryKB, TargetServerMemoryKB, SystemLowMemorySignal, ProcessLowMemorySignal
             FROM lab.WorkshopSample WHERE RunID=@RunId
         )
         OR EXISTS
         (
             SELECT SampleSequence, SampledAtUtc, Phase, PoolTotalMemoryKB, PoolGrantedMemoryKB,
                 PoolUsedMemoryKB, PoolAvailableMemoryKB, GrantUtilizationPercent, GranteeCount,
                 WaiterCount, HostAvailableMemoryKB, HostUsedMemoryKB, ProcessPhysicalMemoryKB,
                 TotalServerMemoryKB, TargetServerMemoryKB, SystemLowMemorySignal, ProcessLowMemorySignal
             FROM lab.WorkshopSample WHERE RunID=@RunId
             EXCEPT
             SELECT value.SampleSequence, value.SampledAtUtc, value.Phase, value.PoolTotalMemoryKB,
                 value.PoolGrantedMemoryKB, value.PoolUsedMemoryKB, value.PoolAvailableMemoryKB,
                 value.GrantUtilizationPercent, value.GranteeCount, value.WaiterCount,
                 value.HostAvailableMemoryKB, value.HostUsedMemoryKB, value.ProcessPhysicalMemoryKB,
                 value.TotalServerMemoryKB, value.TargetServerMemoryKB,
                 value.SystemLowMemorySignal, value.ProcessLowMemorySignal
             FROM OPENJSON(@SamplesJson) WITH
             (SampleSequence int, SampledAtUtc datetime2(3), Phase varchar(16), PoolTotalMemoryKB bigint,
              PoolGrantedMemoryKB bigint, PoolUsedMemoryKB bigint, PoolAvailableMemoryKB bigint,
              GrantUtilizationPercent decimal(6,2), GranteeCount int, WaiterCount int,
              HostAvailableMemoryKB bigint, HostUsedMemoryKB bigint, ProcessPhysicalMemoryKB bigint,
              TotalServerMemoryKB bigint, TargetServerMemoryKB bigint, SystemLowMemorySignal bit,
              ProcessLowMemorySignal bit) AS value
         )
         OR EXISTS
         (
             SELECT value.SampleSequence, value.SessionID, value.RequestID, value.RequestedMemoryKB,
                 value.GrantedMemoryKB, value.RequiredMemoryKB, value.IdealMemoryKB,
                 value.UsedMemoryKB, value.MaxUsedMemoryKB, value.WaitOrder, value.WaitTimeMs,
                 value.QueryID, value.PlanID
             FROM OPENJSON(@RequestSamplesJson) WITH
             (SampleSequence int, SessionID smallint, RequestID int, RequestedMemoryKB bigint,
              GrantedMemoryKB bigint, RequiredMemoryKB bigint, IdealMemoryKB bigint, UsedMemoryKB bigint,
              MaxUsedMemoryKB bigint, WaitOrder int, WaitTimeMs bigint, QueryID bigint, PlanID bigint) AS value
             EXCEPT
             SELECT SampleSequence, SessionID, RequestID, RequestedMemoryKB, GrantedMemoryKB,
                 RequiredMemoryKB, IdealMemoryKB, UsedMemoryKB, MaxUsedMemoryKB, WaitOrder,
                 WaitTimeMs, QueryID, PlanID
             FROM lab.WorkshopRequestSample WHERE RunID=@RunId
         )
         OR EXISTS
         (
             SELECT SampleSequence, SessionID, RequestID, RequestedMemoryKB, GrantedMemoryKB,
                 RequiredMemoryKB, IdealMemoryKB, UsedMemoryKB, MaxUsedMemoryKB, WaitOrder,
                 WaitTimeMs, QueryID, PlanID
             FROM lab.WorkshopRequestSample WHERE RunID=@RunId
             EXCEPT
             SELECT value.SampleSequence, value.SessionID, value.RequestID, value.RequestedMemoryKB,
                 value.GrantedMemoryKB, value.RequiredMemoryKB, value.IdealMemoryKB,
                 value.UsedMemoryKB, value.MaxUsedMemoryKB, value.WaitOrder, value.WaitTimeMs,
                 value.QueryID, value.PlanID
             FROM OPENJSON(@RequestSamplesJson) WITH
             (SampleSequence int, SessionID smallint, RequestID int, RequestedMemoryKB bigint,
              GrantedMemoryKB bigint, RequiredMemoryKB bigint, IdealMemoryKB bigint, UsedMemoryKB bigint,
              MaxUsedMemoryKB bigint, WaitOrder int, WaitTimeMs bigint, QueryID bigint, PlanID bigint) AS value
         )
         OR EXISTS
         (
             SELECT value.TrialSequence, value.ParameterSlot, value.Phase, value.DurationMs,
                 value.CpuMs, value.LogicalReads, value.GrantedKB, value.UsedKB, value.SpillKB,
                 value.WaitMs, value.ResultRowCount, CONVERT(varbinary(32),value.ResultHash,2),
                 value.ExpectedRowCount, value.ActualRowCount, value.DifferenceCount, value.Correct,
                 value.ValidationBatchID, value.StartedAtUtc, value.CompletedAtUtc
             FROM OPENJSON(@TrialsJson) WITH
             (TrialSequence int, ParameterSlot int, Phase varchar(16), DurationMs bigint, CpuMs bigint,
              LogicalReads bigint, GrantedKB bigint, UsedKB bigint, SpillKB bigint, WaitMs bigint,
              ResultRowCount bigint, ResultHash varchar(64), ExpectedRowCount bigint, ActualRowCount bigint,
              DifferenceCount bigint, Correct bit, ValidationBatchID uniqueidentifier,
              StartedAtUtc datetime2(3), CompletedAtUtc datetime2(3)) AS value
             EXCEPT
             SELECT TrialSequence, ParameterSlot, Phase, DurationMs, CpuMs, LogicalReads, GrantedKB,
                 UsedKB, SpillKB, WaitMs, ResultRowCount, ResultHash, ExpectedRowCount,
                 ActualRowCount, DifferenceCount, Correct, ValidationBatchID, StartedAtUtc, CompletedAtUtc
             FROM lab.WorkshopTrial WHERE RunID=@RunId
         )
         OR EXISTS
         (
             SELECT TrialSequence, ParameterSlot, Phase, DurationMs, CpuMs, LogicalReads, GrantedKB,
                 UsedKB, SpillKB, WaitMs, ResultRowCount, ResultHash, ExpectedRowCount,
                 ActualRowCount, DifferenceCount, Correct, ValidationBatchID, StartedAtUtc, CompletedAtUtc
             FROM lab.WorkshopTrial WHERE RunID=@RunId
             EXCEPT
             SELECT value.TrialSequence, value.ParameterSlot, value.Phase, value.DurationMs,
                 value.CpuMs, value.LogicalReads, value.GrantedKB, value.UsedKB, value.SpillKB,
                 value.WaitMs, value.ResultRowCount, CONVERT(varbinary(32),value.ResultHash,2),
                 value.ExpectedRowCount, value.ActualRowCount, value.DifferenceCount, value.Correct,
                 value.ValidationBatchID, value.StartedAtUtc, value.CompletedAtUtc
             FROM OPENJSON(@TrialsJson) WITH
             (TrialSequence int, ParameterSlot int, Phase varchar(16), DurationMs bigint, CpuMs bigint,
              LogicalReads bigint, GrantedKB bigint, UsedKB bigint, SpillKB bigint, WaitMs bigint,
              ResultRowCount bigint, ResultHash varchar(64), ExpectedRowCount bigint, ActualRowCount bigint,
              DifferenceCount bigint, Correct bit, ValidationBatchID uniqueidentifier,
              StartedAtUtc datetime2(3), CompletedAtUtc datetime2(3)) AS value
         )
             THROW 51720, 'Exact persisted workshop evidence does not match this retry payload.', 1;

         COMMIT TRANSACTION;
         SELECT @ExistingSampleCount AS InsertedSampleCount,
             @ExistingRequestSampleCount AS InsertedRequestSampleCount,
             @ExistingTrialCount AS InsertedTrialCount;
         RETURN;
        END;
    INSERT lab.WorkshopRun
        (RunID, ParentComparisonID, EvidenceClassification, Phase, RunStatus, Outcome,
         StartedAtUtc, CompletedAtUtc, FrozenSettingsHash, FrozenSettingsJson)
    VALUES
        (@RunId, NULL, 'LAB-MEASURED', @Phase, @RunStatus, @Outcome,
         @StartedAtUtc, @CompletedAtUtc, @FrozenSettingsHash, @FrozenSettingsJson);

    INSERT lab.WorkshopSample
        (RunID, SampleSequence, SampledAtUtc, Phase, PoolTotalMemoryKB, PoolGrantedMemoryKB,
         PoolUsedMemoryKB, PoolAvailableMemoryKB, GrantUtilizationPercent, GranteeCount,
         WaiterCount, HostAvailableMemoryKB, HostUsedMemoryKB, ProcessPhysicalMemoryKB,
         TotalServerMemoryKB, TargetServerMemoryKB, SystemLowMemorySignal, ProcessLowMemorySignal)
    SELECT @RunId, value.SampleSequence, value.SampledAtUtc, value.Phase,
           value.PoolTotalMemoryKB, value.PoolGrantedMemoryKB, value.PoolUsedMemoryKB,
           value.PoolAvailableMemoryKB, value.GrantUtilizationPercent, value.GranteeCount,
           value.WaiterCount, value.HostAvailableMemoryKB, value.HostUsedMemoryKB,
           value.ProcessPhysicalMemoryKB, value.TotalServerMemoryKB, value.TargetServerMemoryKB,
           value.SystemLowMemorySignal, value.ProcessLowMemorySignal
    FROM OPENJSON(@SamplesJson) WITH
    (SampleSequence int, SampledAtUtc datetime2(3), Phase varchar(16), PoolTotalMemoryKB bigint,
     PoolGrantedMemoryKB bigint, PoolUsedMemoryKB bigint, PoolAvailableMemoryKB bigint,
     GrantUtilizationPercent decimal(6,2), GranteeCount int, WaiterCount int,
     HostAvailableMemoryKB bigint, HostUsedMemoryKB bigint, ProcessPhysicalMemoryKB bigint,
     TotalServerMemoryKB bigint, TargetServerMemoryKB bigint, SystemLowMemorySignal bit,
     ProcessLowMemorySignal bit) AS value;

    INSERT lab.WorkshopRequestSample
        (RunID, SampleSequence, SessionID, RequestID, RequestedMemoryKB, GrantedMemoryKB,
         RequiredMemoryKB, IdealMemoryKB, UsedMemoryKB, MaxUsedMemoryKB, WaitOrder, WaitTimeMs,
         QueryID, PlanID)
    SELECT @RunId, value.SampleSequence, value.SessionID, value.RequestID,
           value.RequestedMemoryKB, value.GrantedMemoryKB, value.RequiredMemoryKB,
           value.IdealMemoryKB, value.UsedMemoryKB, value.MaxUsedMemoryKB, value.WaitOrder,
           value.WaitTimeMs, value.QueryID, value.PlanID
    FROM OPENJSON(@RequestSamplesJson) WITH
    (SampleSequence int, SessionID smallint, RequestID int, RequestedMemoryKB bigint,
     GrantedMemoryKB bigint, RequiredMemoryKB bigint, IdealMemoryKB bigint, UsedMemoryKB bigint,
     MaxUsedMemoryKB bigint, WaitOrder int, WaitTimeMs bigint, QueryID bigint, PlanID bigint) AS value;

    INSERT lab.WorkshopTrial
        (RunID, TrialSequence, ParameterSlot, Phase, DurationMs, CpuMs, LogicalReads,
         GrantedKB, UsedKB, SpillKB, WaitMs, ResultRowCount, ResultHash, ExpectedRowCount,
         ActualRowCount, DifferenceCount, Correct, ValidationBatchID, StartedAtUtc, CompletedAtUtc)
    SELECT @RunId, value.TrialSequence, value.ParameterSlot, value.Phase, value.DurationMs,
           value.CpuMs, value.LogicalReads, value.GrantedKB, value.UsedKB, value.SpillKB,
           value.WaitMs, value.ResultRowCount, CONVERT(varbinary(32), value.ResultHash, 2),
           value.ExpectedRowCount, value.ActualRowCount, value.DifferenceCount, value.Correct,
           value.ValidationBatchID, value.StartedAtUtc, value.CompletedAtUtc
    FROM OPENJSON(@TrialsJson) WITH
    (TrialSequence int, ParameterSlot int, Phase varchar(16), DurationMs bigint, CpuMs bigint,
     LogicalReads bigint, GrantedKB bigint, UsedKB bigint, SpillKB bigint, WaitMs bigint,
     ResultRowCount bigint, ResultHash varchar(64), ExpectedRowCount bigint, ActualRowCount bigint,
     DifferenceCount bigint, Correct bit, ValidationBatchID uniqueidentifier,
     StartedAtUtc datetime2(3), CompletedAtUtc datetime2(3)) AS value;

    DECLARE @InsertedSampleCount int=(SELECT COUNT(*) FROM lab.WorkshopSample WHERE RunID=@RunId),
            @InsertedRequestSampleCount int=(SELECT COUNT(*) FROM lab.WorkshopRequestSample WHERE RunID=@RunId),
            @InsertedTrialCount int=(SELECT COUNT(*) FROM lab.WorkshopTrial WHERE RunID=@RunId);
    IF @InsertedSampleCount<>@ExpectedSampleCount
       OR @InsertedRequestSampleCount<>@ExpectedRequestSampleCount
       OR @InsertedTrialCount<>@ExpectedTrialCount
        THROW 51721, 'Workshop evidence persistence count mismatch.', 1;
    COMMIT TRANSACTION;
    SELECT @InsertedSampleCount AS InsertedSampleCount,
           @InsertedRequestSampleCount AS InsertedRequestSampleCount,
           @InsertedTrialCount AS InsertedTrialCount;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
'@
        $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Persist' $sql @{
            '@RunId' = @{ Type = [Data.SqlDbType]::UniqueIdentifier; Value = $Record.RunId }
            '@Phase' = @{ Type = [Data.SqlDbType]::VarChar; Size = 16; Value = $Record.Phase }
            '@RunStatus' = @{ Type = [Data.SqlDbType]::VarChar; Size = 16; Value = $Record.RunStatus }
            '@Outcome' = @{ Type = [Data.SqlDbType]::NVarChar; Size = 24; Value = $Record.Outcome }
            '@StartedAtUtc' = @{ Type = [Data.SqlDbType]::DateTime2; Value = [datetime]$Record.StartedAtUtc }
            '@CompletedAtUtc' = @{ Type = [Data.SqlDbType]::DateTime2; Value = [datetime]$Record.CompletedAtUtc }
            '@FrozenSettingsHash' = @{ Type = [Data.SqlDbType]::Binary; Size = 32; Value = $hashBytes }
            '@FrozenSettingsJson' = @{ Type = [Data.SqlDbType]::NVarChar; Size = 4000; Value = $settingsJson }
            '@SamplesJson' = @{ Type = [Data.SqlDbType]::NVarChar; Size = -1; Value = $sampleJson }
            '@RequestSamplesJson' = @{ Type = [Data.SqlDbType]::NVarChar; Size = -1; Value = $requestJson }
            '@TrialsJson' = @{ Type = [Data.SqlDbType]::NVarChar; Size = -1; Value = $trialJson }
            '@ExpectedSampleCount' = @{ Type = [Data.SqlDbType]::Int; Value = @($Record.Samples).Count }
            '@ExpectedRequestSampleCount' = @{ Type = [Data.SqlDbType]::Int; Value = @($Record.RequestSamples).Count }
            '@ExpectedTrialCount' = @{ Type = [Data.SqlDbType]::Int; Value = @($Record.Trials).Count }
        })
        if ($rows.Count -ne 1 -or [int]$rows[0].InsertedSampleCount -ne @($Record.Samples).Count -or
            [int]$rows[0].InsertedRequestSampleCount -ne @($Record.RequestSamples).Count -or
            [int]$rows[0].InsertedTrialCount -ne @($Record.Trials).Count) {
            throw 'Workshop evidence persistence did not verify exact inserted counts.'
        }
    }.GetNewClosure()

    return @{
        OpenConnection = { param($Purpose) Write-Verbose "Opening $Purpose controller connection."; & $getPreflight }.GetNewClosure()
        StartWorker = $startWorker
        TestWorkerHealth = $testWorkerHealth
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
    'ConvertFrom-WorkshopTrialReader',
    'Get-WorkshopTrialAssessment',
    'Test-WorkshopFingerprintMatch',
    'Test-WorkshopPreflight',
    'Invoke-WorkshopExperiment',
    'Get-WorkshopKillPlan',
    'Export-WorkshopEvidenceFile',
    'Get-WorkshopSqlOperationSet'
)
