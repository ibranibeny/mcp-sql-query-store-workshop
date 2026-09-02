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
$script:WorkerOrphanLimit = 8
$script:WorkerOrphans = [Collections.Generic.List[object]]::new()
$script:WorkerReservationCount = 0

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

function ConvertTo-NonnegativeInt64 {
    param(
        [Parameter(Mandatory)][AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Name
    )

    $number = ConvertTo-FiniteDecimal $Value $Name
    if ($number -lt 0 -or $number -ne [decimal]::Truncate($number) -or
        $number -gt [decimal][long]::MaxValue) {
        throw "$Name must be a nonnegative 64-bit integer."
    }
    return [int64]$number
}

function ConvertTo-SanitizedFailureMessage {
    param([Parameter(Mandatory)][AllowNull()][object] $Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ([string]::IsNullOrWhiteSpace($text) -or
        $text -match $script:SecretAssignmentPattern -or
        $text -match $script:SecretNamePattern) {
        return 'Operational failure details were redacted.'
    }
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    return $text.Substring(0, [math]::Min(512, $text.Length))
}

function Wait-WorkshopPowerShellStop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $PowerShell,

        [Parameter(Mandatory)]
        [object] $AsyncResult,

        [Parameter(Mandatory)]
        [ref] $PendingStopResult,

        [Parameter(Mandatory)]
        [ref] $StopEnded,

        [Parameter()]
        [ValidateRange(0, 1000)]
        [int] $TimeoutMilliseconds = 1000
    )

    if ($AsyncResult.IsCompleted) { return $true }
    $stopResult = $PowerShell.BeginStop($null, $null)
    $PendingStopResult.Value = $stopResult
    $stopCompleted = $stopResult.AsyncWaitHandle.WaitOne(
        [TimeSpan]::FromMilliseconds($TimeoutMilliseconds)
    )
    if (-not $stopCompleted -or -not $AsyncResult.IsCompleted) { return $false }
    try { $PowerShell.EndStop($stopResult) }
    finally { $StopEnded.Value = $true }
    return $true
}

function Complete-WorkshopWorkerResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Handle)

    $cleanupError = $null
    try {
        if ($null -ne $Handle.PowerShell -and $null -ne $Handle.PendingStopResult -and
            -not $Handle.StopEnded) {
            try { $Handle.PowerShell.EndStop($Handle.PendingStopResult) }
            catch { $cleanupError = $_ }
            finally { $Handle.StopEnded = $true }
        }
        if ($null -ne $Handle.PowerShell -and $null -ne $Handle.AsyncResult -and
            -not $Handle.EndInvoked) {
            try { [void] $Handle.PowerShell.EndInvoke($Handle.AsyncResult) }
            catch { if ($null -eq $cleanupError) { $cleanupError = $_ } }
            finally { $Handle.EndInvoked = $true }
        }
    }
    finally {
        try {
            if ($null -ne $Handle.PowerShell -and -not $Handle.PowerShellDisposed) {
                $Handle.PowerShell.Dispose()
                $Handle.PowerShellDisposed = $true
            }
        }
        catch { if ($null -eq $cleanupError) { $cleanupError = $_ } }
        finally {
            try {
                if ($null -ne $Handle.Runspace -and -not $Handle.RunspaceDisposed) {
                    $Handle.Runspace.Dispose()
                    $Handle.RunspaceDisposed = $true
                }
            }
            catch { if ($null -eq $cleanupError) { $cleanupError = $_ } }
            finally {
                try {
                    if ($null -ne $Handle.ReadySignal -and -not $Handle.ReadySignalDisposed) {
                        $Handle.ReadySignal.Dispose()
                        $Handle.ReadySignalDisposed = $true
                    }
                }
                catch { if ($null -eq $cleanupError) { $cleanupError = $_ } }
                finally {
                    $Handle.Disposed = ($null -eq $Handle.PowerShell -or $Handle.PowerShellDisposed) -and
                        ($null -eq $Handle.Runspace -or $Handle.RunspaceDisposed) -and
                        ($null -eq $Handle.ReadySignal -or $Handle.ReadySignalDisposed)
                    if ($Handle.Disposed -and $Handle.CapacityReserved) {
                        $script:WorkerReservationCount = [math]::Max(0, $script:WorkerReservationCount - 1)
                        $Handle.CapacityReserved = $false
                    }
                }
            }
        }
    }
    if ($null -ne $cleanupError) {
        if (-not $Handle.Disposed) {
            try { Add-WorkshopWorkerOrphan -Handle $Handle }
            catch { Write-Warning 'Worker cleanup ownership could not be recorded.' }
        }
        throw $cleanupError
    }
}

function Add-WorkshopWorkerOrphan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Handle)

    if (-not $script:WorkerOrphans.Contains($Handle)) {
        if ($script:WorkerOrphans.Count -ge $script:WorkerOrphanLimit) {
            throw 'The bounded worker orphan registry is full; no additional worker may be retained.'
        }
        [void] $script:WorkerOrphans.Add($Handle)
    }
    Write-Warning 'Worker resources remain process-owned in the bounded orphan registry and will not be synchronously disposed until lifecycle completion permits safe cleanup.'
}

function Invoke-WorkshopCompletedWorkerReaping {
    [CmdletBinding()]
    param()

    for ($index = $script:WorkerOrphans.Count - 1; $index -ge 0; $index--) {
        $orphan = $script:WorkerOrphans[$index]
        if ($null -ne $orphan.AsyncResult -and -not $orphan.AsyncResult.IsCompleted) { continue }
        if ($null -ne $orphan.PendingStopResult -and -not $orphan.StopEnded -and
            -not $orphan.PendingStopResult.AsyncWaitHandle.WaitOne([TimeSpan]::Zero)) {
            continue
        }
        try { Complete-WorkshopWorkerResource -Handle $orphan }
        catch { Write-Warning 'Completed orphan worker cleanup failed; ownership remains visible until process exit.' }
        if ($orphan.Disposed) { $script:WorkerOrphans.RemoveAt($index) }
    }
}

function Assert-WorkshopWorkerCapacity {
    [CmdletBinding()]
    param()

    Invoke-WorkshopCompletedWorkerReaping
    if ($script:WorkerOrphans.Count -ge $script:WorkerOrphanLimit -or
        $script:WorkerReservationCount -ge $script:WorkerOrphanLimit) {
        throw 'The bounded worker orphan registry is full; start a new process before creating more workers.'
    }
}

function Enter-WorkshopWorkerCapacity {
    [CmdletBinding()]
    param()

    Assert-WorkshopWorkerCapacity
    $script:WorkerReservationCount++
}

function ConvertTo-WorkshopWorkerHandle {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object] $PowerShell,
        [Parameter()][AllowNull()][object] $Runspace,
        [Parameter()][AllowNull()][object] $AsyncResult,
        [Parameter()][AllowNull()][object] $ReadySignal,
        [Parameter()][bool] $CapacityReserved = $false
    )

    $handle = [pscustomobject]@{
        PowerShell = $PowerShell
        Runspace = $Runspace
        AsyncResult = $AsyncResult
        ReadySignal = $ReadySignal
        Disposed = $false
        EndInvoked = $false
        PowerShellDisposed = $false
        RunspaceDisposed = $false
        ReadySignalDisposed = $false
        CapacityReserved = $CapacityReserved
        PendingStopResult = $null
        StopEnded = $false
        TerminalTimeout = $false
        TerminalError = $null
    }
    $handle | Add-Member ScriptMethod TestHealth {
        if ($this.Disposed) {
            return [pscustomobject]@{ Healthy = $false; Reason = 'Worker handle is disposed.'; Terminal = $true }
        }
        if ($this.TerminalTimeout) {
            return [pscustomobject]@{ Healthy = $false; Reason = $this.TerminalError; Terminal = $true }
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
    $handle | Add-Member ScriptMethod StopWithinMilliseconds {
        param([int] $TimeoutMilliseconds)
        if ($this.Disposed) { return }
        if ($this.TerminalTimeout) { throw [TimeoutException]::new($this.TerminalError) }

        $stopCompleted = $false
        $stopError = $null
        $pendingStopResult = $this.PendingStopResult
        $stopEnded = $this.StopEnded
        try {
            $stopCompleted = Wait-WorkshopPowerShellStop -PowerShell $this.PowerShell `
            -AsyncResult $this.AsyncResult -PendingStopResult ([ref]$pendingStopResult) `
            -StopEnded ([ref]$stopEnded) -TimeoutMilliseconds $TimeoutMilliseconds
            if (-not $stopCompleted) {
                $this.TerminalTimeout = $true
                $this.TerminalError = 'Worker cancellation did not complete within its bounded one-second cleanup budget.'
            }
        }
        catch {
            $stopError = $_
            $this.TerminalError = $_.Exception.Message
        }
        finally {
            $this.PendingStopResult = $pendingStopResult
            $this.StopEnded = $stopEnded
            $stopCanEnd = $null -eq $this.PendingStopResult -or $this.StopEnded -or
                $this.PendingStopResult.AsyncWaitHandle.WaitOne([TimeSpan]::Zero)
            if ($this.AsyncResult.IsCompleted -and $stopCanEnd) {
                try { Complete-WorkshopWorkerResource -Handle $this }
                catch {
                    if ($null -eq $stopError) { $stopError = $_ }
                    else { Write-Warning 'Worker cleanup also failed after the cancellation error.' }
                }
            }
            else {
                try { Add-WorkshopWorkerOrphan -Handle $this }
                catch {
                    if ($null -eq $stopError -and -not $this.TerminalTimeout) { $stopError = $_ }
                    else { Write-Warning 'Worker orphan ownership could not be recorded.' }
                }
            }
        }
        if ($null -ne $stopError) { throw $stopError }
        if ($this.TerminalTimeout) { throw [TimeoutException]::new($this.TerminalError) }
    }
    $handle | Add-Member ScriptMethod StopWithin {
        param([int] $TimeoutSeconds)
        if ($TimeoutSeconds -lt 1) { throw 'Worker cleanup requires a positive timeout.' }
        $this.StopWithinMilliseconds([math]::Min(1000, $TimeoutSeconds * 1000))
    }
    $handle | Add-Member ScriptMethod Dispose {
        if ($this.Disposed) { return }
        $this.StopWithinMilliseconds(1000)
    }
    return $handle
}

function Invoke-WorkshopWorkerSetupCleanup {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object] $PowerShell,
        [Parameter()][AllowNull()][object] $Runspace,
        [Parameter()][AllowNull()][object] $AsyncResult,
        [Parameter()][AllowNull()][object] $ReadySignal,
        [Parameter(Mandatory)][object] $SetupError,
        [Parameter()][bool] $CapacityReserved = $false,
        [Parameter()][ValidateRange(0, 1000)][int] $TimeoutMilliseconds = 1000
    )

    $handle = ConvertTo-WorkshopWorkerHandle -PowerShell $PowerShell -Runspace $Runspace `
        -AsyncResult $AsyncResult -ReadySignal $ReadySignal -CapacityReserved $CapacityReserved
    try {
        if ($null -eq $AsyncResult) { Complete-WorkshopWorkerResource -Handle $handle }
        else { $handle.StopWithinMilliseconds($TimeoutMilliseconds) }
    }
    catch { Write-Warning 'Worker setup cleanup was incomplete; the original setup failure is preserved.' }
    throw $SetupError
}

function ConvertTo-WorkshopFailureEvidence {
    param(
        [Parameter(Mandatory)][string] $Code,
        [Parameter(Mandatory)][string] $Stage,
        [Parameter(Mandatory)][AllowNull()][object] $Message,
        [Parameter(Mandatory)][bool] $StartupFailure
    )

    return [ordered]@{
        code = $Code
        stage = $Stage
        message = ConvertTo-SanitizedFailureMessage $Message
        startupFailure = $StartupFailure
    }
}

function Copy-WorkshopFailureEvidence {
    param(
        [Parameter(Mandatory)][object] $Target,
        [Parameter(Mandatory)][object] $Failure
    )

    if ($Target -is [System.Collections.IDictionary]) {
        $Target['failure'] = $Failure
    }
    else {
        $Target | Add-Member NoteProperty failure $Failure -Force
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
        $items = [object[]]@($InputObject | ForEach-Object { ConvertTo-CanonicalValue -InputObject $_ })
        Write-Output -InputObject $items -NoEnumerate
        return
    }

    $ordered = [ordered]@{}
    $entries = @(Get-ObjectEntry -InputObject $InputObject)
    $names = [string[]]@($entries | ForEach-Object Name)
    [array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) {
        $entry = @($entries | Where-Object { $_.Name -ceq $name })[0]
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
        Write-Output -InputObject ([System.Array]::AsReadOnly($items)) -NoEnumerate
        return
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
        'databaseScopedConfigurationHash', 'dataHash', 'indexStatisticsHash', 'procedureHash',
        'validationBatchHash',
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
    if ($ramp -ne [math]::Truncate($ramp) -or $ramp -lt 20 -or $ramp -gt 60) {
        throw 'workerRampSeconds must be an integer from 20 through 60.'
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
    foreach ($name in @(
        'databaseScopedConfigurationHash', 'dataHash', 'indexStatisticsHash', 'procedureHash',
        'validationBatchHash', 'parameterScheduleHash'
    )) {
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
    $actualNames = @(Get-ObjectEntry -InputObject $Environment | ForEach-Object Name)
    if ('sqlClientProvider' -in $actualNames -or 'warnings' -in $actualNames) {
        $names += @('sqlClientProvider', 'warnings')
    }
    $markerNames = @(
        'markerId', 'markerSchemaVersion', 'markerSetupName', 'markerSetupHash',
        'serverMarkerId', 'configurationFingerprint'
    )
    if (@($actualNames | Where-Object { $_ -in $markerNames }).Count -gt 0) {
        $names += $markerNames
    }
    if ('captureStatus' -in $actualNames) { $names += 'captureStatus' }
    if ('runIsolation' -in $actualNames) { $names += 'runIsolation' }
    Assert-ExactProperty -InputObject $Environment -RequiredNames $names -Context 'Environment fingerprint'
    Assert-NoSecretField -InputObject $Environment
    foreach ($name in @('sqlVersion', 'sqlEdition')) {
        $value = Get-ObjectValue $Environment $name -Required
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Environment field '$name' must be a nonempty string."
        }
    }
    $memory = ConvertTo-FiniteDecimal `
        (Get-ObjectValue $Environment physicalMemoryMB -Required) 'physicalMemoryMB'
    if ($memory -lt 1 -or $memory -ne [decimal]::Truncate($memory) -or $memory -gt 4294967296) {
        throw "Environment field 'physicalMemoryMB' must be a positive integer no greater than 4 PB."
    }
    if ('runIsolation' -in $names) {
        [void](Resolve-CanonicalEnum (Get-ObjectValue $Environment runIsolation -Required) `
            @('ExclusiveDatabaseApplicationLock','ExclusiveDatabaseApplicationLockRejected','Unavailable') `
            'run isolation')
    }
    if ('sqlClientProvider' -in $names) {
        [void](Resolve-CanonicalEnum (Get-ObjectValue $Environment sqlClientProvider -Required) `
            @('Microsoft.Data.SqlClient', 'System.Data.SqlClient') 'SQL client provider')
        $warningValue = @(
            Get-ObjectEntry -InputObject $Environment | Where-Object Name -ceq 'warnings'
        )[0].Value
        if ($warningValue -is [string] -or $warningValue -isnot [System.Collections.IEnumerable]) {
            throw 'Environment warnings must be an array of strings.'
        }
        $warnings = @($warningValue)
        if ($warnings.Count -gt 4) { throw 'Environment warnings cannot contain more than four entries.' }
        foreach ($warning in $warnings) {
            if ($warning -isnot [string] -or [string]::IsNullOrWhiteSpace($warning) -or $warning.Length -gt 256) {
                throw 'Environment warnings must be nonempty strings no longer than 256 characters.'
            }
        }
    }
    if ('captureStatus' -in $names -and
        (Get-ObjectValue $Environment captureStatus -Required) -cnotin @('Captured', 'Unavailable')) {
        throw 'Environment captureStatus must be Captured or Unavailable.'
    }
    if ($markerNames[0] -in $names) {
        foreach ($name in @('markerId', 'serverMarkerId')) {
            $marker = [guid]::Empty
            if (-not [guid]::TryParseExact([string](Get-ObjectValue $Environment $name -Required), 'D', [ref]$marker)) {
                throw "Environment field '$name' must be a canonical GUID."
            }
        }
        if ((Get-ObjectValue $Environment markerSchemaVersion -Required) -ne 1 -or
            (Get-ObjectValue $Environment markerSetupName -Required) -cne 'MCP SQL Query Store Workshop') {
            throw 'Environment marker version and setup name are invalid.'
        }
        foreach ($name in @('markerSetupHash', 'configurationFingerprint')) {
            if ((Get-ObjectValue $Environment $name -Required) -cnotmatch '^[a-f0-9]{64}$') {
                throw "Environment field '$name' must be a lowercase SHA-256 hash."
            }
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
        [switch] $Request,

        [Parameter()]
        [object[]] $BaseSamples = @(),

        [Parameter()]
        [AllowNull()]
        [object] $RunId
    )

    $previousSample = $null
    $requestIdentities = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    for ($index = 0; $index -lt $Samples.Count; $index++) {
        $sample = $Samples[$index]
        $expectedNames = if ($Request) {
                        @('sampleSequence','timestampUtc','phase','sessionId','requestId','requestedMemoryKB','grantedMemoryKB',
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
        if ($Request -and $null -ne (Get-ObjectValue $sample runId)) { $expectedNames += 'runId' }
        Assert-ExactProperty -InputObject $sample -RequiredNames $expectedNames -Context 'Sample'
        Assert-NoSecretField -InputObject $sample
        if ($Request) {
            foreach ($name in @('sampleSequence','sessionId','requestId','requestedMemoryKB','grantedMemoryKB',
                'requiredMemoryKB','idealMemoryKB','usedMemoryKB','maxUsedMemoryKB','waitTimeMs')) {
                $metric = ConvertTo-FiniteDecimal (Get-ObjectValue $sample $name -Required) $name
                if ($metric -lt 0) { throw "$name cannot be negative." }
            }
            $prefix = "requestSamples[$index]"
            $timestampText = Get-ObjectValue $sample timestampUtc -Required
            $timestamp = ConvertFrom-UtcText $timestampText "$prefix.timestampUtc"
            if ($timestamp -lt $StartUtc -or ($null -ne $EndUtc -and $timestamp -gt ([datetimeoffset]$EndUtc))) {
                throw "$prefix.timestampUtc must fall within the run interval."
            }
            $phase = Resolve-CanonicalEnum `
                (Get-ObjectValue $sample phase -Required) @('Baseline','Optimized') "$prefix.phase"
            $sequence = [int](Get-ObjectValue $sample sampleSequence -Required)
            $linked = @($BaseSamples | Where-Object {
                [int](Get-ObjectValue $_ sequence -Required) -eq $sequence -and
                [string](Get-ObjectValue $_ phase -Required) -ceq $phase
            })
            if ($linked.Count -ne 1) {
                $sequenceMatches = @($BaseSamples | Where-Object {
                    [int](Get-ObjectValue $_ sequence -Required) -eq $sequence
                })
                if ($sequenceMatches.Count -gt 0) {
                    throw "$prefix.phase must match its linked sample phase."
                }
                throw "$prefix.sampleSequence must link to one existing sample with the same phase."
            }
            if ([string](Get-ObjectValue $linked[0] timestampUtc -Required) -cne [string]$timestampText) {
                throw "$prefix.timestampUtc must match its linked sample timestamp."
            }
            $representedRunId = Get-ObjectValue $sample runId
            if ($null -ne $representedRunId -and [string]$representedRunId -cne [string]$RunId) {
                throw "$prefix.runId must match the evidence run ID."
            }
            $requestIdentity = '{0}|{1}|{2}|{3}' -f $phase, $sequence,
                [int](Get-ObjectValue $sample sessionId -Required),
                [int](Get-ObjectValue $sample requestId -Required)
            if (-not $requestIdentities.Add($requestIdentity)) {
                throw "$prefix has a duplicate request sample identity."
            }
            continue
        }
        $sequence = [int](Get-ObjectValue $sample sequence -Required)
        if ($sequence -ne ($index + 1)) {
            throw 'Sample sequence must start at 1 and be contiguous.'
        }
        $timestampPath = "samples[$index].timestampUtc"
        $timestamp = ConvertFrom-UtcText (Get-ObjectValue $sample timestampUtc -Required) $timestampPath
        if ($timestamp -lt $StartUtc -or ($null -ne $EndUtc -and $timestamp -gt ([datetimeoffset] $EndUtc))) {
            throw "$timestampPath must fall within the run interval."
        }
        $phase = Resolve-CanonicalEnum `
            (Get-ObjectValue $sample phase -Required) @('Baseline', 'Optimized') "samples[$index].phase"
        if ($null -ne $previousSample) {
            if ($timestamp -le $previousSample.Timestamp) {
                throw "$timestampPath must be strictly later than samples[$($previousSample.Index)].timestampUtc in document sequence."
            }
        }
        $previousSample = [pscustomobject]@{
            Index = $index
            Timestamp = $timestamp
        }

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
        $request = [ordered]@{
            sampleSequence = [int](Get-ObjectValue $_ sampleSequence -Required)
            timestampUtc = [string](Get-ObjectValue $_ timestampUtc -Required)
            phase = Resolve-CanonicalEnum (Get-ObjectValue $_ phase -Required) @('Baseline','Optimized') 'request sample phase'
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
        $representedRunId = Get-ObjectValue $_ runId
        if ($null -ne $representedRunId) {
            $withRunId = [ordered]@{}
            foreach ($entry in $request.GetEnumerator()) {
                $withRunId[$entry.Key] = $entry.Value
                if ($entry.Key -ceq 'phase') { $withRunId.runId = [string]$representedRunId }
            }
            $request = $withRunId
        }
        $request
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
            finalizationOverrunMs = 0
            warnings = @()
        }
    }

    $terminationNames = @('manualStopRequested', 'safetyStopTriggered', 'safetyReasons', 'timeout')
    foreach ($optionalName in @('finalizationOverrunMs','warnings')) {
        if ($null -ne (Get-ObjectValue $TerminationEvidence $optionalName)) { $terminationNames += $optionalName }
    }
    $failure = Get-ObjectValue $TerminationEvidence failure
    if ($null -ne $failure) { $terminationNames += 'failure' }
    Assert-ExactProperty -InputObject $TerminationEvidence -RequiredNames $terminationNames -Context 'Termination evidence'
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

    $warningValue = Get-ObjectValue $TerminationEvidence warnings
    $warnings = [string[]]@()
    if ($null -ne $warningValue) { $warnings = [string[]]@($warningValue) }
    foreach ($warning in $warnings) {
        if ($warning -isnot [string] -or [string]::IsNullOrWhiteSpace($warning) -or $warning.Length -gt 256) {
            throw 'Termination warnings must be bounded nonempty strings.'
        }
    }
    $finalizationOverrunMs = Get-ObjectValue $TerminationEvidence finalizationOverrunMs
    if ($null -eq $finalizationOverrunMs) { $finalizationOverrunMs = 0 }
    $finalizationOverrunMs = ConvertTo-NonnegativeInt64 $finalizationOverrunMs 'finalizationOverrunMs'

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

    if ($null -ne $failure) {
        Assert-ExactProperty $failure @('code','stage','message','startupFailure') 'Failure evidence'
        Assert-NoSecretField $failure
        if ((Get-ObjectValue $failure code -Required) -cnotmatch '^[A-Z][A-Z0-9_]{2,63}$') {
            throw 'Failure code must be a bounded canonical identifier.'
        }
        if ((Get-ObjectValue $failure stage -Required) -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,63}$') {
            throw 'Failure stage must be a bounded canonical identifier.'
        }
        $message = Get-ObjectValue $failure message -Required
        if ($message -isnot [string] -or [string]::IsNullOrWhiteSpace($message) -or $message.Length -gt 512) {
            throw 'Failure message must be a bounded nonempty sanitized string.'
        }
        if ((Get-ObjectValue $failure startupFailure -Required) -isnot [bool]) {
            throw 'Failure startupFailure must be Boolean.'
        }
    }

    $result = [ordered]@{
        manualStopRequested = $manual
        safetyStopTriggered = $safety
        safetyReasons = $reasons
        timeout = Get-ObjectValue $TerminationEvidence timeout -Required
        finalizationOverrunMs = $finalizationOverrunMs
        warnings = $warnings
    }
    if ($null -ne $failure) { $result.failure = ConvertTo-CanonicalValue $failure }
    return $result
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
        $sequence = ConvertTo-NonnegativeInt64 `
            (Get-ObjectValue $trial TrialSequence -Required) 'TrialSequence'
        if ($sequence -lt 1 -or $sequence -gt 12) {
            throw 'TrialSequence must be from one through twelve.'
        }
        if ($sequence -ne $index + 1) {
            throw 'TrialSequence must be contiguous from one.'
        }
        $slot = [int](Get-ObjectValue $trial ParameterSlot -Required)
        if ($slot -lt 1 -or $slot -gt 6) { throw 'ParameterSlot must be from one through six.' }
        $phase = Resolve-CanonicalEnum (Get-ObjectValue $trial Phase -Required) @('Baseline','Optimized') 'trial phase'
        $expectedPhases = @(
            'Baseline','Optimized','Optimized','Baseline','Optimized','Baseline',
            'Baseline','Optimized','Baseline','Optimized','Optimized','Baseline'
        )
        if ($slot -ne ([math]::Floor(($sequence - 1) / 2) + 1) -or
            $phase -cne $expectedPhases[$sequence - 1]) {
            throw 'Every trial must match its deterministic sequence, parameter slot, and ABBA phase mapping.'
        }
        foreach ($name in @('DurationMs','CpuMs','LogicalReads','GrantedKB','UsedKB','SpillKB','WaitMs',
            'ResultRowCount','ExpectedRowCount','ActualRowCount','DifferenceCount')) {
            [void](ConvertTo-NonnegativeInt64 (Get-ObjectValue $trial $name -Required) $name)
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
            trialSequence = [int]$sequence
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
    Assert-SampleCollection -Samples $RequestSamples -StartUtc $start -EndUtc $end -Request `
        -BaseSamples $Samples -RunId $runId
    $termination = ConvertTo-TerminationEvidence $TerminationEvidence
    if ($Trials.Count -eq 0 -and $RunRecord.psobject.Properties['Trials']) {
        $Trials = @($RunRecord.Trials)
    }
    $trialEvidence = @(ConvertTo-WorkshopTrialEvidence $Trials)
    foreach ($trial in $trialEvidence) {
        $trialStarted = ConvertFrom-UtcText $trial.startedAtUtc 'trial StartedAtUtc'
        $trialCompleted = ConvertFrom-UtcText $trial.completedAtUtc 'trial CompletedAtUtc'
        if ($null -eq $end -or $trialStarted -lt $start -or $trialCompleted -gt $end) {
            throw 'Every trial interval must fall within the run interval.'
        }
    }

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
        $failure = Get-ObjectValue $termination failure
        $startupFailure = $Samples.Count -eq 0 -and $status -ceq 'Failed' -and
            $null -ne $failure -and (Get-ObjectValue $failure startupFailure -Required)
        if ($startupFailure) {
            if ($RequestSamples.Count -ne 0 -or $trialEvidence.Count -ne 0 -or $null -ne $Validation -or
                $null -eq $end -or $Outcome -cne 'Failed') {
                throw 'A startup failure requires empty measurements, null correctness, EndUtc, and Failed outcome.'
            }
            $Outcome = Resolve-CanonicalEnum $Outcome $script:OutcomeValues 'outcome'
        }
        elseif ($Samples.Count -eq 0 -or $null -eq $Validation -or $null -eq $end -or
            [string]::IsNullOrEmpty($Outcome)) {
            throw 'LAB-MEASURED evidence requires samples, validation, EndUtc, and outcome.'
        }
        if (-not $startupFailure) {
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
        $trialLinkage = @($trialEvidence | ForEach-Object {
            [ordered]@{
                sequence = [int]$_.trialSequence
                slot = [int]$_.parameterSlot
                phase = [string]$_.phase
                resultRowCount = [int64]$_.resultRowCount
                resultHash = [string]$_.resultHash
                expectedRowCount = [int64]$_.expectedRowCount
                actualRowCount = [int64]$_.actualRowCount
                differenceCount = [int64]$_.differenceCount
                correct = [bool]$_.correct
                validationBatchId = [string]$_.validationBatchId
            }
        })
        $derivedPassed = $false
        $derivedMaterialRegression = $false
        $derivedAdditionalMetricImproved = $false
        if ($trialEvidence.Count -eq 12) {
            $expectedPhases = @('Baseline','Optimized','Optimized','Baseline','Optimized','Baseline','Baseline','Optimized','Baseline','Optimized','Optimized','Baseline')
            $batchIds = @($trialEvidence.validationBatchId | Select-Object -Unique)
            if ($batchIds.Count -ne 1) {
                throw 'Completed comparison trials must use one ValidationBatchId.'
            }
            $derivedPassed = $true
            for ($index = 0; $index -lt 12; $index++) {
                $trial = $trialEvidence[$index]
                if ($trial.trialSequence -ne ($index + 1) -or
                    $trial.parameterSlot -ne ([math]::Floor($index / 2) + 1) -or
                    $trial.phase -cne $expectedPhases[$index]) {
                    throw 'Completed comparison trials must be contiguous ABBA BAAB ABBA pairs across six parameter slots.'
                }
            }
            foreach ($slot in 1..6) {
                $pair = @($trialEvidence | Where-Object parameterSlot -eq $slot)
                $baselinePair = @($pair | Where-Object phase -ceq 'Baseline')
                $optimizedPair = @($pair | Where-Object phase -ceq 'Optimized')
                if ($pair.Count -ne 2 -or $baselinePair.Count -ne 1 -or $optimizedPair.Count -ne 1) {
                    throw "Parameter slot $slot must have exactly one Baseline and one Optimized trial."
                }
                $expectedCount = [int64]$baselinePair[0].resultRowCount
                $actualCount = [int64]$optimizedPair[0].resultRowCount
                $pairCorrect = $expectedCount -eq $actualCount -and
                    $baselinePair[0].resultHash -ceq $optimizedPair[0].resultHash
                foreach ($trial in $pair) {
                    if (-not $trial.correct -or
                        $trial.expectedRowCount -ne $expectedCount -or
                        $trial.actualRowCount -ne $actualCount -or
                        $trial.expectedRowCount -ne $trial.actualRowCount -or
                        $trial.differenceCount -ne 0) {
                        $pairCorrect = $false
                    }
                }
                if (-not $pairCorrect) { $derivedPassed = $false }
            }

            $baselineTrials = @($trialEvidence | Where-Object phase -ceq 'Baseline')
            $optimizedTrials = @($trialEvidence | Where-Object phase -ceq 'Optimized')
            foreach ($metric in @('durationMs', 'cpuMs', 'logicalReads', 'spillKB', 'waitMs')) {
                [decimal]$baselineTotal = 0
                [decimal]$optimizedTotal = 0
                foreach ($trial in $baselineTrials) { $baselineTotal += [decimal]$trial.$metric }
                foreach ($trial in $optimizedTrials) { $optimizedTotal += [decimal]$trial.$metric }
                $baselineAverage = $baselineTotal / [decimal]$baselineTrials.Count
                $optimizedAverage = $optimizedTotal / [decimal]$optimizedTrials.Count
                if ($baselineAverage -gt 0 -and $optimizedAverage -le ($baselineAverage * [decimal]'0.90')) {
                    $derivedAdditionalMetricImproved = $true
                }
                if (($baselineAverage -eq 0 -and $optimizedAverage -gt 0) -or
                    ($baselineAverage -gt 0 -and $optimizedAverage -gt ($baselineAverage * [decimal]'1.10'))) {
                    $derivedMaterialRegression = $true
                }
            }
        }
        $derivedValidation = [ordered]@{
            passed = $derivedPassed
            materialRegression = $derivedMaterialRegression
            additionalMetricImproved = $derivedAdditionalMetricImproved
            validationHash = Get-Sha256 (ConvertTo-Json $trialLinkage -Depth 8 -Compress)
        }
        foreach ($name in @('passed', 'materialRegression', 'additionalMetricImproved', 'validationHash')) {
            if ((Get-ObjectValue $Validation $name -Required) -cne $derivedValidation[$name]) {
                throw 'Validation does not match values derived from trials.'
            }
        }
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
        if ($Outcome -ceq 'TargetMet' -and $termination.timeout) {
            throw "Outcome '$Outcome' cannot claim a timeout."
        }
        $expectedOutcome = if ($status -ceq 'Failed') {
            'Failed'
        }
        else {
            Get-WorkshopOutcome -BaselinePeak $baselinePeak `
                -OptimizedPeak $optimizedPeak `
                -CorrectnessPassed $derivedValidation.passed `
                -MaterialRegression $derivedValidation.materialRegression `
                -AdditionalMetricImproved $derivedValidation.additionalMetricImproved `
                -SafetyStopped $termination.safetyStopTriggered `
                -ManualStopped $termination.manualStopRequested
        }
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
            $correctness = ConvertTo-CanonicalValue $derivedValidation
        }
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

function Get-WorkshopComparisonBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(60, 600)][int] $MaximumDurationSeconds,
        [Parameter(Mandatory)][ValidateRange(1, 60)][int] $CommandTimeoutSeconds,
        [Parameter(Mandatory)][ValidateRange(5, 30)][int] $SampleIntervalSeconds,
        [Parameter(Mandatory)][ValidateRange(1, 4)][int] $MaximumWorkers
    )

    $trialCount = 12
    $cleanupMarginSeconds = 2
    $ancillary = @(
        [pscustomobject]@{ Name = 'OptimizedWorkerCleanup'; Count = $MaximumWorkers; SecondsEach = 1 }
        [pscustomobject]@{ Name = 'CurrentFingerprint'; Count = 1; SecondsEach = 1 }
        [pscustomobject]@{ Name = 'PreTrialSnapshot'; Count = $trialCount; SecondsEach = 1 }
        [pscustomobject]@{ Name = 'PostTrialSnapshot'; Count = $trialCount; SecondsEach = 1 }
        [pscustomobject]@{ Name = 'FinalFingerprint'; Count = 1; SecondsEach = 1 }
        [pscustomobject]@{ Name = 'CorrectnessLinkage'; Count = 1; SecondsEach = 1 }
        [pscustomobject]@{ Name = 'Persistence'; Count = 1; SecondsEach = 1 }
        [pscustomobject]@{ Name = 'Export'; Count = 1; SecondsEach = 1 }
        [pscustomobject]@{ Name = 'RunLockRelease'; Count = 1; SecondsEach = 1 }
    )
    $ancillarySeconds = [int](($ancillary | ForEach-Object {
        $_.Count * $_.SecondsEach
    } | Measure-Object -Sum).Sum)
    $minimumBaselineObservationSeconds = 3 + (2 * $SampleIntervalSeconds)
    $optimizedPreparationAndObservationSeconds = $MaximumWorkers + 3 + (2 * $SampleIntervalSeconds)
    $postBaselineMinimumSeconds = $MaximumWorkers + 1 + 1 + $optimizedPreparationAndObservationSeconds
    $preComparisonMinimumSeconds = 4 + $minimumBaselineObservationSeconds + $postBaselineMinimumSeconds
    $availableForTrials = $MaximumDurationSeconds - $preComparisonMinimumSeconds - `
        $ancillarySeconds - $cleanupMarginSeconds
    $trialSeconds = [math]::Min(
        $CommandTimeoutSeconds,
        [int][math]::Floor($availableForTrials / $trialCount)
    )
    if ($trialSeconds -lt 1) {
        $minimumRequired = $preComparisonMinimumSeconds + $ancillarySeconds + `
            $cleanupMarginSeconds + $trialCount
        throw "MaximumDurationSeconds must be at least $minimumRequired seconds for the minimum complete comparison budget."
    }

    $trialBudgets = [int[]]@(1..$trialCount | ForEach-Object { $trialSeconds })
    $comparisonReserve = $ancillarySeconds + $cleanupMarginSeconds + `
        [int](($trialBudgets | Measure-Object -Sum).Sum)
    return [pscustomobject][ordered]@{
        MaximumDurationSeconds = $MaximumDurationSeconds
        CommandTimeoutCapSeconds = $CommandTimeoutSeconds
        TrialBudgets = $trialBudgets
        AncillaryOperations = $ancillary
        AncillaryReservedSeconds = $ancillarySeconds
        CleanupMarginSeconds = $cleanupMarginSeconds
        PreComparisonMinimumSeconds = $preComparisonMinimumSeconds
        PostBaselineMinimumSeconds = $postBaselineMinimumSeconds
        OptimizedPreparationAndObservationSeconds = $optimizedPreparationAndObservationSeconds
        TotalReservedSeconds = $comparisonReserve
    }
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
        [void](ConvertTo-NonnegativeInt64 (Get-ObjectValue $metricRow $name -Required) $name)
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
        MarkerId = [string] $Snapshot.MarkerId
        SchemaVersion = [int] $Snapshot.SchemaVersion
        SetupName = [string] $Snapshot.SetupName
        SetupHash = [string] $Snapshot.SetupHash
        ServerMarkerId = [string] $Snapshot.ServerMarkerId
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
    $expectedMarker = '68a70d6e-62d8-4a77-8f0a-9da7934dba7c'
    $expectedSetupHash = 'ada06f206d3db321527a5aab390fc814e28ebb59791967eb99841bf669e1b16b'
    try {
        if (-not (Get-ObjectValue $Snapshot MarkerValid -Required) -or
            [string](Get-ObjectValue $Snapshot MarkerId -Required) -cne $expectedMarker -or
            [int](Get-ObjectValue $Snapshot SchemaVersion -Required) -ne 1 -or
            [string](Get-ObjectValue $Snapshot SetupName -Required) -cne 'MCP SQL Query Store Workshop' -or
            [string](Get-ObjectValue $Snapshot SetupHash -Required) -cne $expectedSetupHash -or
            [string](Get-ObjectValue $Snapshot ServerMarkerId -Required) -cne $expectedMarker) {
            $failures.Add('The complete workshop marker contract is invalid.')
        }
    }
    catch { $failures.Add('The complete workshop marker contract is missing or invalid.') }
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

    $required = @('AcquireRunLock', 'ReleaseRunLock', 'OpenConnection', 'CaptureEnvironment', 'InitializePersistence', 'StartWorker', 'TestWorkerHealth', 'Sample', 'StopWorker', 'KillTagged', 'Persist', 'Delay', 'Clock', 'Export')
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
        if ([string] $Expected.$name -cnotmatch '^[a-f0-9]{64}$' -or
            [string] $Actual.$name -cnotmatch '^[a-f0-9]{64}$' -or
            [string] $Expected.$name -cne [string] $Actual.$name) { return $false }
    }
    return $true
}

function Get-WorkshopTrialAssessment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]] $Trials)

    if ($Trials.Count -ne 12) { throw 'Exactly twelve trials are required.' }
    foreach ($trial in $Trials) {
        foreach ($name in @(
            'DurationMs', 'CpuMs', 'LogicalReads', 'GrantedKB', 'UsedKB', 'SpillKB', 'WaitMs',
            'ResultRowCount', 'ExpectedRowCount', 'ActualRowCount', 'DifferenceCount'
        )) {
            [void](ConvertTo-NonnegativeInt64 (Get-ObjectValue $trial $name -Required) $name)
        }
    }
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
    foreach ($metric in $metrics) {
        [decimal]$baselineTotal = 0
        [decimal]$optimizedTotal = 0
        foreach ($trial in $baseline) { $baselineTotal += [decimal]$trial.$metric }
        foreach ($trial in $optimized) { $optimizedTotal += [decimal]$trial.$metric }
        $baselineAverage = $baselineTotal / [decimal]$baseline.Count
        $optimizedAverage = $optimizedTotal / [decimal]$optimized.Count
        if ($baselineAverage -gt 0 -and $optimizedAverage -le ($baselineAverage * [decimal]'0.90')) {
            $improved = $true
        }
        if (($baselineAverage -eq 0 -and $optimizedAverage -gt 0) -or
            ($baselineAverage -gt 0 -and $optimizedAverage -gt ($baselineAverage * [decimal]'1.10'))) {
            $materialRegression = $true
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
        [int]$SampleIntervalSeconds, [int]$WorkerRampSeconds,
        [AllowNull()][object]$Failure
    )

    if ($null -eq $FrozenSettings) {
        $scheduleJson = ConvertTo-Json $Schedule -Compress
        $FrozenSettings = [ordered]@{
            workers = [int][math]::Max(1, $Workers)
            maximumDurationSeconds = $MaximumDurationSeconds
            sampleIntervalSeconds = $SampleIntervalSeconds
            workerRampSeconds = $WorkerRampSeconds
            resourcePool = 'mcp_sql_workshop_pool'
            workloadGroup = 'mcp_sql_workshop_group'
            maxServerMemoryMB = 49152
            databaseScopedConfigurationHash = Get-WorkshopConfigurationFingerprint $Preflight
            dataHash = [string]$Preflight.DataHash
            indexStatisticsHash = [string]$Preflight.IndexStatisticsHash
            procedureHash = [string]$Preflight.ProcedureHash
            validationBatchHash = [string]$Preflight.ValidationBatchHash
            parameterSchedule = $Schedule
            parameterScheduleHash = Get-Sha256 $scheduleJson
        }
    }
    $status = if ($Outcome -in @('TargetMet','ImprovedOutsideTarget','NoMaterialImprovement')) { 'Completed' } else { $Outcome }
    $environment = [ordered]@{
        sqlVersion = [string]$Preflight.SqlProductVersion
        sqlEdition = [string]$Preflight.SqlEdition
        physicalMemoryMB = [int64]$Preflight.PhysicalMemoryMB
        captureStatus = 'Captured'
        markerId = [string]$Preflight.MarkerId
        markerSchemaVersion = [int]$Preflight.SchemaVersion
        markerSetupName = [string]$Preflight.SetupName
        markerSetupHash = [string]$Preflight.SetupHash
        serverMarkerId = [string]$Preflight.ServerMarkerId
        configurationFingerprint = [string]$Preflight.CanonicalConfigurationFingerprint
        runIsolation = 'ExclusiveDatabaseApplicationLock'
    }
    if ($Preflight.psobject.Properties['SqlClientProvider'] -or
        $Preflight.psobject.Properties['EnvironmentWarnings']) {
        if (-not $Preflight.psobject.Properties['SqlClientProvider'] -or
            -not $Preflight.psobject.Properties['EnvironmentWarnings']) {
            throw 'SQL client provider readiness metadata must include both provider and warnings.'
        }
        $environment.sqlClientProvider = [string]$Preflight.SqlClientProvider
        $environment.warnings = [System.Array]::AsReadOnly([string[]]@($Preflight.EnvironmentWarnings))
    }
    $runRecord = New-WorkshopRunRecord -RunId $RunId -Phase $TerminalPhase -Status $status `
        -EvidenceClassification LAB-MEASURED -FrozenSettings $FrozenSettings `
        -EnvironmentFingerprint $environment -TargetBands ([ordered]@{
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
            validationBatchId = ([guid]$_.ValidationBatchID).ToString('D')
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
        finalizationOverrunMs = 0
        warnings = @()
    }
    if ($null -ne $Failure) { $termination.failure = $Failure }
    $evidenceValidation = if ($Samples.Count -eq 0 -and $null -ne $Failure -and
        (Get-ObjectValue $Failure startupFailure -Required)) { $null } else { $validation }
    $evidence = ConvertTo-WorkshopEvidence -RunRecord $runRecord -Samples $Samples `
        -RequestSamples $RequestSamples -Trials $Trials -Validation $evidenceValidation `
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
        Validation = if ($null -eq $evidenceValidation) { $null } else { [pscustomobject]$validation }
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
        [int] $WorkerRampSeconds = 20,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int] $CommandTimeoutSeconds = 1,

        [Parameter()]
        [ValidateRange(0.10, 0.80)]
        [decimal] $BaselineCalibrationFraction = [decimal]'0.60'
    )

    Assert-WorkshopOperationSet $OperationSet
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Run bounded workshop memory-grant experiment')) { return }

    $scheduleObjects = @(Get-WorkshopParameterSchedule)
    $schedule = @($scheduleObjects | ForEach-Object { ConvertTo-Json $_ -Compress })
    $scheduleJson = ConvertTo-Json $schedule -Compress
    $workers = [System.Collections.Generic.List[object]]::new()
    $samples = [System.Collections.Generic.List[object]]::new()
    $requestSamples = [System.Collections.Generic.List[object]]::new()
    $trials = [System.Collections.Generic.List[object]]::new()
    $start = [datetimeoffset]::UtcNow
    $lastRamp = $null
    $consecutive = 0
    $outcome = $null
    $frozen = $null
    $terminalPhase = 'Baseline'
    $manualStopRequested = $false
    $safetyStopTriggered = $false
    $safetyReasons = @()
    $timeout = $false
    $failure = $null
    $result = $null
    $finalizationState = [pscustomobject]@{ RunLockHeld = $false; Attempted = $false }
    $finalizationWarnings = [System.Collections.Generic.List[string]]::new()
    $emergencyFinalizationBudgetSeconds = 5
    $operationState = [pscustomobject]@{ Stage = 'OpenConnection' }
    $sampleClockState = [pscustomobject]@{ Last = $start.AddTicks(-1) }
    $workerCountStarted = 0
    $healthState = [pscustomobject]@{ ConsecutiveFailures = 0 }
    $deadline = $null
    $baselineDeadline = $null
    $optimizedObservationDeadline = $null
    $preflight = $null
    $runtimeState = [pscustomobject]@{ Deadline = $deadline; Preflight = $null }
    $getRemainingSeconds = {
        $remaining = ($runtimeState.Deadline - [datetimeoffset] (& $OperationSet.Clock)).TotalSeconds
        if ($remaining -le 0) { return 0 }
        return [math]::Max(0, [int][math]::Floor($remaining))
    }.GetNewClosure()
    $testActiveWorkers = {
        if ($workers.Count -eq 0) { return $true }
        $health = & $OperationSet.TestWorkerHealth $workers.ToArray()
        return $null -ne $health -and [bool]$health.Healthy
    }.GetNewClosure()
    $addFinalizationWarning = {
        param([string]$Warning)
        if ($finalizationWarnings.Count -lt 4 -and -not $finalizationWarnings.Contains($Warning)) {
            $finalizationWarnings.Add($Warning.Substring(0, [math]::Min(160, $Warning.Length)))
        }
    }.GetNewClosure()
    $appendFinalizationWarnings = {
        param([AllowNull()][object]$TargetResult)
        if ($null -eq $TargetResult -or $finalizationWarnings.Count -eq 0) { return }
        $warnings = [string[]]@($finalizationWarnings)
        $TargetResult.TerminationEvidence.warnings = $warnings
        $TargetResult.Evidence.terminationEvidence.warnings = $warnings
    }.GetNewClosure()
    $invokeFinalization = {
        param([string]$CaughtStage)
        if ($finalizationState.Attempted) { return }
        $finalizationState.Attempted = $true
        try {
            foreach ($worker in @($workers)) {
                try { & $OperationSet.StopWorker $worker 1 }
                catch { & $addFinalizationWarning 'Worker cleanup failed during finalization.' }
            }
            $workers.Clear()
            if ($CaughtStage -and $CaughtStage -ne 'ConcurrentRunRejected') {
                $cleanupBudget = if ((& $getRemainingSeconds) -gt 0) {
                    [math]::Min(1, (& $getRemainingSeconds))
                }
                else { $emergencyFinalizationBudgetSeconds }
                try { [void] (& $OperationSet.KillTagged $RunId $cleanupBudget) }
                catch { & $addFinalizationWarning 'Tagged-session cancellation failed during finalization.' }
            }
        }
        finally {
            if ($finalizationState.RunLockHeld) {
                $finalizationState.RunLockHeld = $false
                $releaseBudget = if ((& $getRemainingSeconds) -gt 0) {
                    [math]::Min(1, (& $getRemainingSeconds))
                }
                else { $emergencyFinalizationBudgetSeconds }
                try { & $OperationSet.ReleaseRunLock $releaseBudget }
                catch { & $addFinalizationWarning 'Exclusive workshop run lock release failed during finalization.' }
            }
        }
    }.GetNewClosure()
    $updateHealthFailures = {
        param([bool]$Healthy)
        if ($Healthy) { $healthState.ConsecutiveFailures = 0 }
        else { $healthState.ConsecutiveFailures++ }
        return $healthState.ConsecutiveFailures
    }.GetNewClosure()
    $invokeBoundedSample = {
        param(
            [string]$Phase,
            [string]$Kind,
            [AllowNull()][string]$TrialPhase,
            [AllowNull()][string]$ScheduleEntry,
            [int]$MaximumOperationSeconds = $CommandTimeoutSeconds,
            [datetimeoffset]$OperationDeadline = $runtimeState.Deadline
        )
        $activeDeadline = @($runtimeState.Deadline, $OperationDeadline | Sort-Object)[0]
        $remaining = ($activeDeadline - [datetimeoffset](& $OperationSet.Clock)).TotalSeconds
        if ($remaining -le 0) { throw "The $Phase $Kind operation deadline elapsed before execution." }
        $remaining = [math]::Min($MaximumOperationSeconds, [math]::Max(1, [int][math]::Ceiling($remaining)))
        $operationState.Stage = if ($Kind -in @('Memory','Drain')) { 'Sample' } else { $Kind }
        $value = & $OperationSet.Sample $RunId $Phase $Kind $TrialPhase $ScheduleEntry `
            $remaining $activeDeadline
        if ([datetimeoffset](& $OperationSet.Clock) -gt $activeDeadline) {
            $operationState.Stage = 'PhaseDeadline'
            throw "The $Phase $Kind operation exceeded its dedicated deadline."
        }
        return $value
    }.GetNewClosure()
    $assertFrozenFingerprint = {
        param([datetimeoffset]$OperationDeadline = $runtimeState.Deadline)
        $actual = & $invokeBoundedSample 'Optimized' 'Fingerprint' $null $null `
            $CommandTimeoutSeconds $OperationDeadline
        if ($null -eq $actual -or -not (Test-WorkshopFingerprintMatch -Expected $runtimeState.Preflight -Actual $actual)) {
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
                $copy | Add-Member NoteProperty TimestampUtc `
                    ($timestamp.UtcDateTime.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)) -Force
                $copy | Add-Member NoteProperty Phase ([string]$sample.Phase) -Force
                $copy | Add-Member NoteProperty RunId $RunId.ToString('D') -Force
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
        $start = [datetimeoffset] (& $OperationSet.Clock)
        $sampleClockState.Last = $start.AddTicks(-1)
        $deadline = $start.AddSeconds($MaximumDurationSeconds)
        $runtimeState.Deadline = $deadline
        try {
            $comparisonBudget = Get-WorkshopComparisonBudget `
                -MaximumDurationSeconds $MaximumDurationSeconds `
                -CommandTimeoutSeconds $CommandTimeoutSeconds `
                -SampleIntervalSeconds $SampleIntervalSeconds `
                -MaximumWorkers $MaximumWorkers
        }
        catch {
            $failure = ConvertTo-WorkshopFailureEvidence -Code 'COMPARISON_BUDGET_INSUFFICIENT' `
                -Stage 'ComparisonBudgetValidation' -Message $_.Exception.Message -StartupFailure $true
            $result = Build-WorkshopStartupFailureResult -RunId $RunId -Failure $failure `
                -StartedAtUtc $start -CompletedAtUtc $start -MaximumWorkers $MaximumWorkers `
                -MaximumDurationSeconds $MaximumDurationSeconds `
                -SampleIntervalSeconds $SampleIntervalSeconds -WorkerRampSeconds $WorkerRampSeconds
            $startupExportBudget = [math]::Min(1, (& $getRemainingSeconds))
            if ($startupExportBudget -lt 1) { $startupExportBudget = $emergencyFinalizationBudgetSeconds }
            $operationState.Stage = 'Export'
            & $OperationSet.Export $result $startupExportBudget
            return $result
        }
        $comparisonReserveSeconds = $comparisonBudget.TotalReservedSeconds
        $optimizedObservationDeadline = $deadline.AddSeconds(-$comparisonReserveSeconds)
        $baselineFractionDeadline = $start.AddSeconds([math]::Floor($MaximumDurationSeconds * $BaselineCalibrationFraction))
        $baselineReserveDeadline = $optimizedObservationDeadline.AddSeconds(-$comparisonBudget.PostBaselineMinimumSeconds)
        $baselineDeadline = @($baselineFractionDeadline, $baselineReserveDeadline | Sort-Object)[0]
        $operationState.Stage = 'RunLockAcquisition'
        try {
            $lockResult = [int](& $OperationSet.AcquireRunLock ([math]::Min($CommandTimeoutSeconds, (& $getRemainingSeconds))))
        }
        catch {
            throw [InvalidOperationException]::new('Exclusive workshop run lock could not be acquired.')
        }
        if ($lockResult -lt 0) {
            $operationState.Stage = 'ConcurrentRunRejected'
            throw [InvalidOperationException]::new('Another workshop experiment is already active.')
        }
        $finalizationState.RunLockHeld = $true
        $operationState.Stage = 'OpenConnection'
        [void](& $OperationSet.OpenConnection 'Preflight' ([math]::Min($CommandTimeoutSeconds, (& $getRemainingSeconds))))
        $operationState.Stage = 'CaptureEnvironment'
        $preflight = & $OperationSet.CaptureEnvironment ([math]::Min($CommandTimeoutSeconds, (& $getRemainingSeconds)))
        $runtimeState.Preflight = $preflight
        $operationState.Stage = 'Preflight'
        [void] (Test-WorkshopPreflight -Snapshot $preflight)
        $operationState.Stage = 'InitializePersistence'
        [void](& $OperationSet.InitializePersistence ([math]::Min($CommandTimeoutSeconds, (& $getRemainingSeconds))))
        if (([datetimeoffset] (& $OperationSet.Clock)) -ge $baselineDeadline -or (& $getRemainingSeconds) -le 0) {
            $outcome = 'BaselineTargetNotReached'
            $timeout = $true
        }
        $operationState.Stage = 'StartWorker'
        if ($null -eq $outcome) {
            $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase Baseline -Worker 1
            $workerHandle = & $OperationSet.StartWorker $RunId 'Baseline' 1 $applicationName $schedule $baselineDeadline
            $workers.Add($workerHandle)
            $workerCountStarted = 1
            $lastRamp = [datetimeoffset] (& $OperationSet.Clock)
        }
        while ($null -eq $outcome -and $null -eq $frozen) {
            $now = [datetimeoffset] (& $OperationSet.Clock)
            if ($now -ge $baselineDeadline -or (& $getRemainingSeconds) -le 0) {
                $outcome = 'BaselineTargetNotReached'
                $timeout = $true
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            $elapsed = ($now - $start).TotalSeconds
            $sample = & $recordSample `
                (& $invokeBoundedSample 'Baseline' 'Memory' $null $null `
                    $CommandTimeoutSeconds $baselineDeadline) $now
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
                    dataHash = [string]$preflight.DataHash
                    indexStatisticsHash = [string]$preflight.IndexStatisticsHash
                    procedureHash = [string]$preflight.ProcedureHash
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
                $operationState.Stage = 'StartWorker'
                if (([datetimeoffset] (& $OperationSet.Clock)) -ge $baselineDeadline -or (& $getRemainingSeconds) -le 0) {
                    $outcome = 'BaselineTargetNotReached'
                    $timeout = $true
                    [void](& $OperationSet.KillTagged $RunId)
                    break
                }
                $workerHandle = & $OperationSet.StartWorker $RunId 'Baseline' $workerNumber $applicationName $schedule $baselineDeadline
                $workers.Add($workerHandle)
                $workerCountStarted = [math]::Max($workerCountStarted, $workerNumber)
                $lastRamp = [datetimeoffset] (& $OperationSet.Clock)
            }
            $remaining = & $getRemainingSeconds
            if ($remaining -gt 0) {
                $baselineRemaining = [math]::Max(0, [int][math]::Floor(($baselineDeadline - [datetimeoffset] (& $OperationSet.Clock)).TotalSeconds))
                if ($baselineRemaining -gt 0) {
                    & $OperationSet.Delay ([math]::Min($SampleIntervalSeconds, [math]::Min($remaining, $baselineRemaining)))
                }
            }
        }

        foreach ($worker in @($workers)) { & $OperationSet.StopWorker $worker 1 }
        $workers.Clear()

        if ($null -ne $outcome) {
            $result = Build-WorkshopExperimentResult -RunId $RunId -Outcome $outcome `
                -TerminalPhase Baseline -FrozenSettings $null -Preflight $preflight `
                -Samples $samples.ToArray() -RequestSamples $requestSamples.ToArray() -Trials @() `
                -StartedAtUtc $start -CompletedAtUtc $(if ($sampleClockState.Last -lt $start) { $start } else { $sampleClockState.Last }) `
                -ManualStopRequested $manualStopRequested -SafetyStopTriggered $safetyStopTriggered `
                -SafetyReasons $safetyReasons -Timeout $timeout -Workers $workerCountStarted -Schedule $schedule `
                -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
                -WorkerRampSeconds $WorkerRampSeconds
            $persistenceBudget = [math]::Min(1, (& $getRemainingSeconds))
            if ($persistenceBudget -lt 1) { throw 'The global deadline elapsed before SQL persistence.' }
            & $OperationSet.Persist $result $persistenceBudget
            $exportBudget = [math]::Min(1, (& $getRemainingSeconds))
            if ($exportBudget -lt 1) { throw 'The global deadline elapsed before local evidence export.' }
            $operationState.Stage = 'Export'
            & $OperationSet.Export $result $exportBudget
            return $result
        }

        $drainDeadline = ([datetimeoffset](& $OperationSet.Clock)).AddSeconds(1)
        $drain = & $invokeBoundedSample 'Baseline' 'Drain' $null $null 1 $drainDeadline
        if ([int] $drain.ActiveGrantCount -ne 0) {
            throw 'Baseline grants did not drain within the dedicated bounded operation.'
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
            $persistenceBudget = [math]::Min(1, (& $getRemainingSeconds))
            if ($persistenceBudget -lt 1) { throw 'The global deadline elapsed before SQL persistence.' }
            & $OperationSet.Persist $result $persistenceBudget
            $exportBudget = [math]::Min(1, (& $getRemainingSeconds))
            if ($exportBudget -lt 1) { throw 'The global deadline elapsed before local evidence export.' }
            $operationState.Stage = 'Export'
            & $OperationSet.Export $result $exportBudget
            return $result
        }

        $terminalPhase = 'Optimized'
        & $assertFrozenFingerprint $optimizedObservationDeadline

        $consecutive = 0
        for ($index = 1; $index -le [int] $frozen.workers; $index++) {
            if (([datetimeoffset] (& $OperationSet.Clock)) -ge $optimizedObservationDeadline -or
                (& $getRemainingSeconds) -le 0) {
                $outcome = 'Failed'
                $timeout = $true
                $failure = ConvertTo-WorkshopFailureEvidence -Code 'GLOBAL_DEADLINE_BEFORE_COMPARISON_COMPLETE' `
                    -Stage 'GlobalDeadlineBeforeComparisonComplete' `
                    -Message 'The global deadline elapsed before comparison could complete.' -StartupFailure $false
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            $applicationName = Get-WorkshopApplicationName -RunId $RunId -Phase Optimized -Worker $index
            $operationState.Stage = 'StartWorker'
            $workers.Add((& $OperationSet.StartWorker $RunId 'Optimized' $index $applicationName $schedule $optimizedObservationDeadline))
        }
        while ($null -eq $outcome) {
            $now = [datetimeoffset] (& $OperationSet.Clock)
            if ($now -ge $optimizedObservationDeadline) {
                $timeout = $true
                break
            }
            $sample = & $recordSample `
                (& $invokeBoundedSample 'Optimized' 'Memory' $null $null `
                    $CommandTimeoutSeconds $optimizedObservationDeadline) $now
            & $assertFrozenFingerprint $optimizedObservationDeadline
            $now = [datetimeoffset] (& $OperationSet.Clock)
            if ($now -ge $deadline) {
                $outcome = 'Failed'
                $timeout = $true
                $failure = ConvertTo-WorkshopFailureEvidence -Code 'GLOBAL_DEADLINE_BEFORE_COMPARISON_COMPLETE' `
                    -Stage 'GlobalDeadlineBeforeComparisonComplete' `
                    -Message 'The global deadline elapsed before comparison could complete.' -StartupFailure $false
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
                $terminalPhase = 'Optimized'
                $manualStopRequested = $safety.Outcome -eq 'ManualStop'
                $safetyStopTriggered = $safety.Outcome -eq 'SafetyStop'
                $safetyReasons = if ($safetyStopTriggered) { @($safety.Reasons) } else { @() }
                if ($manualStopRequested -or $safetyStopTriggered) {
                    $outcome = $safety.Outcome
                }
                else {
                    $timeout = $true
                }
                [void](& $OperationSet.KillTagged $RunId)
                break
            }
            if (Test-TargetBand $sample.GrantUtilizationPercent Optimized) { $consecutive++ } else { $consecutive = 0 }
            if ($consecutive -ge 3) { break }
            if ($now -ge $optimizedObservationDeadline) {
                $timeout = $true
                break
            }
            $remaining = & $getRemainingSeconds
            if ($remaining -gt 0) {
                $observationRemaining = [math]::Max(0, [int][math]::Floor(($optimizedObservationDeadline - $now).TotalSeconds))
                if ($observationRemaining -gt 0) {
                    & $OperationSet.Delay ([math]::Min($SampleIntervalSeconds, [math]::Min($remaining, $observationRemaining)))
                }
            }
        }

        $comparisonOperations = [System.Collections.Generic.List[object]]::new()
        if ($null -eq $outcome) {
            foreach ($worker in @($workers)) {
                $comparisonOperations.Add([pscustomobject]@{ Name = 'OptimizedWorkerCleanup'; Seconds = 1 })
            }
            $comparisonOperations.Add([pscustomobject]@{ Name = 'CurrentFingerprint'; Seconds = 1 })
            for ($budgetIndex = 0; $budgetIndex -lt 12; $budgetIndex++) {
                $comparisonOperations.Add([pscustomobject]@{ Name = 'PreTrialSnapshot'; Seconds = 1 })
                $comparisonOperations.Add([pscustomobject]@{
                    Name = 'Trial'
                    Seconds = [int]$comparisonBudget.TrialBudgets[$budgetIndex]
                })
                $comparisonOperations.Add([pscustomobject]@{ Name = 'PostTrialSnapshot'; Seconds = 1 })
            }
            $comparisonOperations.Add([pscustomobject]@{ Name = 'FinalFingerprint'; Seconds = 1 })
            $comparisonOperations.Add([pscustomobject]@{ Name = 'CorrectnessLinkage'; Seconds = 1 })
            $comparisonOperations.Add([pscustomobject]@{ Name = 'Persistence'; Seconds = 1 })
            $comparisonOperations.Add([pscustomobject]@{ Name = 'Export'; Seconds = 1 })
            $comparisonOperations.Add([pscustomobject]@{ Name = 'RunLockRelease'; Seconds = 1 })
        }
        $comparisonState = [pscustomobject]@{
            Index = 0
            FutureReservedSeconds = [int](($comparisonOperations | Measure-Object Seconds -Sum).Sum)
        }
        $beginComparisonOperation = {
            param([string]$ExpectedName)
            $operationState.Stage = 'ComparisonDeadline'
            if ($comparisonState.Index -ge $comparisonOperations.Count) {
                throw "Comparison operation '$ExpectedName' was not budgeted."
            }
            $operation = $comparisonOperations[$comparisonState.Index]
            if ($operation.Name -cne $ExpectedName) {
                throw "Comparison operation '$ExpectedName' was scheduled out of order."
            }
            $comparisonState.FutureReservedSeconds -= [int]$operation.Seconds
            $remainingAfterFuture = [math]::Floor(
                ($deadline - [datetimeoffset](& $OperationSet.Clock)).TotalSeconds
            ) - $comparisonState.FutureReservedSeconds - $comparisonBudget.CleanupMarginSeconds
            if ($remainingAfterFuture -lt 1) {
                throw "Insufficient reserved time to start comparison operation '$ExpectedName'."
            }
            $comparisonState.Index++
            return [math]::Min([int]$operation.Seconds, [int]$remainingAfterFuture)
        }.GetNewClosure()
        $completeComparisonOperation = {
            param([string]$Name)
            $operationState.Stage = 'ComparisonDeadline'
            $mustRemain = $comparisonState.FutureReservedSeconds + $comparisonBudget.CleanupMarginSeconds
            if (($deadline - [datetimeoffset](& $OperationSet.Clock)).TotalSeconds -lt $mustRemain) {
                throw "Comparison operation '$Name' consumed time reserved for later work."
            }
        }.GetNewClosure()

        foreach ($worker in @($workers)) {
            if ($null -eq $outcome) {
                $stopBudget = & $beginComparisonOperation 'OptimizedWorkerCleanup'
                & $OperationSet.StopWorker $worker $stopBudget
                & $completeComparisonOperation 'OptimizedWorkerCleanup'
            }
            else {
                & $OperationSet.StopWorker $worker 1
            }
        }
        $workers.Clear()

        if ($null -eq $outcome) {
            $fingerprintBudget = & $beginComparisonOperation 'CurrentFingerprint'
            $actualFingerprint = & $invokeBoundedSample 'Optimized' 'Fingerprint' $null $null $fingerprintBudget
            if ($null -eq $actualFingerprint -or
                -not (Test-WorkshopFingerprintMatch -Expected $runtimeState.Preflight -Actual $actualFingerprint)) {
                throw 'Comparison rejected because configuration or data drift was detected.'
            }
            & $completeComparisonOperation 'CurrentFingerprint'
        }

        if ($null -eq $outcome) {
            $terminalPhase = 'Comparison'
            $sequence = @(Get-WorkshopTrialSequence)
            for ($index = 0; $index -lt $sequence.Count; $index++) {
                if ((& $getRemainingSeconds) -le 0) {
                    $outcome = 'Failed'
                    $timeout = $true
                    $failure = ConvertTo-WorkshopFailureEvidence -Code 'GLOBAL_DEADLINE_BEFORE_COMPARISON_COMPLETE' `
                        -Stage 'GlobalDeadlineBeforeComparisonComplete' `
                        -Message 'The global deadline elapsed before all twelve trials completed.' -StartupFailure $false
                    [void](& $OperationSet.KillTagged $RunId)
                    break
                }
                $trialPhase = if ($sequence[$index] -eq 'A') { 'Baseline' } else { 'Optimized' }
                $slot = [math]::Floor($index / 2) + 1
                $entry = $schedule[$slot - 1]
                foreach ($position in @('Before','After')) {
                    if ($position -eq 'After') {
                        $trialBudget = & $beginComparisonOperation 'Trial'
                        $trial = & $invokeBoundedSample 'Comparison' 'Trial' $trialPhase $entry $trialBudget
                        if ($null -eq $trial -or ([datetimeoffset] (& $OperationSet.Clock)) -ge $deadline) {
                            $outcome = 'Failed'
                            $timeout = $true
                            $failure = ConvertTo-WorkshopFailureEvidence -Code 'GLOBAL_DEADLINE_BEFORE_COMPARISON_COMPLETE' `
                                -Stage 'GlobalDeadlineBeforeComparisonComplete' `
                                -Message 'The global deadline elapsed before all twelve trials completed.' -StartupFailure $false
                            [void](& $OperationSet.KillTagged $RunId)
                            break
                        }
                        & $completeComparisonOperation 'Trial'
                        $trial | Add-Member NoteProperty TrialSequence ($index + 1) -Force
                        $trial | Add-Member NoteProperty ParameterSlot $slot -Force
                        $trial | Add-Member NoteProperty Phase $trialPhase -Force
                        $trials.Add($trial)
                    }
                    $safetyNow = [datetimeoffset](& $OperationSet.Clock)
                    if ($safetyNow -ge $deadline) {
                        $outcome = 'Failed'
                        $timeout = $true
                        $failure = ConvertTo-WorkshopFailureEvidence -Code 'GLOBAL_DEADLINE_BEFORE_COMPARISON_COMPLETE' `
                            -Stage 'GlobalDeadlineBeforeComparisonComplete' `
                            -Message 'The global deadline elapsed before all twelve trials completed.' -StartupFailure $false
                        [void](& $OperationSet.KillTagged $RunId)
                        break
                    }
                    $snapshotName = if ($position -eq 'Before') { 'PreTrialSnapshot' } else { 'PostTrialSnapshot' }
                    $snapshotBudget = & $beginComparisonOperation $snapshotName
                    $safetySample = & $recordSample `
                        (& $invokeBoundedSample $trialPhase 'Memory' $null $null $snapshotBudget) $safetyNow
                    & $completeComparisonOperation $snapshotName
                    $safetyNow = [datetimeoffset](& $OperationSet.Clock)
                    if ($safetyNow -ge $deadline) {
                        $outcome = 'Failed'
                        $timeout = $true
                        $failure = ConvertTo-WorkshopFailureEvidence -Code 'GLOBAL_DEADLINE_BEFORE_COMPARISON_COMPLETE' `
                            -Stage 'GlobalDeadlineBeforeComparisonComplete' `
                            -Message 'The global deadline elapsed before all twelve trials completed.' -StartupFailure $false
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
            }
            if ($null -eq $outcome -and $trials.Count -ne 12) { $outcome = 'Failed' }
            if ($null -eq $outcome) {
                $finalFingerprintBudget = & $beginComparisonOperation 'FinalFingerprint'
                $finalFingerprint = & $invokeBoundedSample 'Optimized' 'Fingerprint' $null $null $finalFingerprintBudget
                if ($null -eq $finalFingerprint -or
                    -not (Test-WorkshopFingerprintMatch -Expected $runtimeState.Preflight -Actual $finalFingerprint)) {
                    throw 'Comparison rejected because configuration or data drift was detected.'
                }
                & $completeComparisonOperation 'FinalFingerprint'
                [void](& $beginComparisonOperation 'CorrectnessLinkage')
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
                    & $completeComparisonOperation 'CorrectnessLinkage'
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
            -WorkerRampSeconds $WorkerRampSeconds -Failure $failure
        if ($comparisonState.Index -lt $comparisonOperations.Count -and
            $comparisonOperations[$comparisonState.Index].Name -ceq 'Persistence') {
            $persistenceBudget = & $beginComparisonOperation 'Persistence'
            try {
                $operationState.Stage = 'Persistence'
                & $OperationSet.Persist $result $persistenceBudget
                & $completeComparisonOperation 'Persistence'
            }
            catch {
                $result = $null
                $operationState.Stage = 'Persistence'
                throw
            }
        }
        else {
            $persistenceBudget = [math]::Min(1, (& $getRemainingSeconds))
            if ($persistenceBudget -lt 1) { throw 'The global deadline elapsed before SQL persistence.' }
            & $OperationSet.Persist $result $persistenceBudget
        }
        if ($comparisonState.Index -lt $comparisonOperations.Count -and
            $comparisonOperations[$comparisonState.Index].Name -ceq 'Export') {
            $exportBudget = & $beginComparisonOperation 'Export'
            $operationState.Stage = 'Export'
            & $OperationSet.Export $result $exportBudget
            & $completeComparisonOperation 'Export'
        }
        else {
            $exportBudget = [math]::Min(1, (& $getRemainingSeconds))
            if ($exportBudget -lt 1) { throw 'The global deadline elapsed before local evidence export.' }
            $operationState.Stage = 'Export'
            & $OperationSet.Export $result $exportBudget
        }
        return $result
    }
    catch {
        $originalError = $_
        $caughtStage = [string]$operationState.Stage
        $originalText = ConvertTo-SanitizedFailureMessage $originalError.Exception.Message
        & $invokeFinalization $caughtStage

        if ($null -ne $result -and $caughtStage -eq 'Export') {
            $failure = ConvertTo-WorkshopFailureEvidence -Code 'EXPORT_FAILED' -Stage 'Export' `
                -Message $originalText -StartupFailure ($samples.Count -eq 0)
            $result.Outcome = 'Failed'
            $result.RunStatus = 'Failed'
            $result.Evidence.outcome = 'Failed'
            Copy-WorkshopFailureEvidence $result.TerminationEvidence $failure
            Copy-WorkshopFailureEvidence $result.Evidence.terminationEvidence $failure
        }

        if ($null -eq $result) {
            try {
                $completedAt = [datetimeoffset] (& $OperationSet.Clock)
                if ($completedAt -lt $start) { $completedAt = $start }
                if ($completedAt -lt $sampleClockState.Last) { $completedAt = $sampleClockState.Last }
                $failureCode = switch ($caughtStage) {
                    'RunLockAcquisition' { 'RUN_LOCK_ACQUISITION_FAILED' }
                    'ConcurrentRunRejected' { 'CONCURRENT_RUN_REJECTED' }
                    'OpenConnection' { 'CONNECTION_OPEN_FAILED' }
                    'CaptureEnvironment' { 'ENVIRONMENT_CAPTURE_FAILED' }
                    'Preflight' { 'PREFLIGHT_FAILED' }
                    'InitializePersistence' { 'PERSISTENCE_INITIALIZATION_FAILED' }
                    'StartWorker' { 'WORKER_START_FAILED' }
                    'Persistence' { 'PERSISTENCE_FAILED' }
                    'ComparisonDeadline' { 'GLOBAL_DEADLINE_BEFORE_COMPARISON_COMPLETE' }
                    'PhaseDeadline' { 'GLOBAL_DEADLINE_BEFORE_COMPARISON_COMPLETE' }
                    default { 'WORKSHOP_OPERATION_FAILED' }
                }
                $failureStage = if ($caughtStage -in @('ComparisonDeadline','PhaseDeadline')) {
                    'GlobalDeadlineBeforeComparisonComplete'
                }
                elseif ($caughtStage -eq 'ConcurrentRunRejected') { 'ConcurrentRunRejected' }
                else {
                    $caughtStage
                }
                $failure = ConvertTo-WorkshopFailureEvidence -Code $failureCode `
                    -Stage $failureStage -Message $originalText `
                    -StartupFailure ($samples.Count -eq 0)
                if ($null -eq $preflight -or
                    ($samples.Count -eq 0 -and $caughtStage -in @('RunLockAcquisition','ConcurrentRunRejected','OpenConnection','CaptureEnvironment','Preflight','InitializePersistence'))) {
                    $result = Build-WorkshopStartupFailureResult -RunId $RunId -Failure $failure `
                        -StartedAtUtc $start -CompletedAtUtc $completedAt -MaximumWorkers $MaximumWorkers `
                        -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
                        -WorkerRampSeconds $WorkerRampSeconds
                }
                else {
                    $result = Build-WorkshopExperimentResult -RunId $RunId -Outcome Failed `
                        -TerminalPhase $terminalPhase -FrozenSettings $frozen -Preflight $preflight `
                        -Samples $samples.ToArray() -RequestSamples $requestSamples.ToArray() -Trials $trials.ToArray() `
                        -StartedAtUtc $start -CompletedAtUtc $completedAt `
                        -ManualStopRequested $false -SafetyStopTriggered $false -SafetyReasons @() `
                        -Timeout ($caughtStage -in @('ComparisonDeadline','PhaseDeadline')) `
                        -Workers $workerCountStarted -Schedule $schedule `
                        -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
                        -WorkerRampSeconds $WorkerRampSeconds -Failure $failure
                }
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
            & $appendFinalizationWarnings $result
            $emergencyStarted = [datetimeoffset](& $OperationSet.Clock)
            $normalPersistenceRemaining = & $getRemainingSeconds
            if ($caughtStage -ne 'ConcurrentRunRejected' -and $normalPersistenceRemaining -gt 0) {
                try {
                    $operationState.Stage = 'Persistence'
                    $persistenceBudget = [math]::Min(1, $normalPersistenceRemaining)
                    [void](& $OperationSet.Persist $result $persistenceBudget)
                }
                catch {
                    $persistenceFailure = ConvertTo-WorkshopFailureEvidence -Code 'PERSISTENCE_FAILED' `
                        -Stage 'Persistence' -Message $_.Exception.Message `
                        -StartupFailure ($samples.Count -eq 0)
                    if ($samples.Count -gt 0) {
                        Copy-WorkshopFailureEvidence $result.TerminationEvidence $persistenceFailure
                        Copy-WorkshopFailureEvidence $result.Evidence.terminationEvidence $persistenceFailure
                    }
                }
            }
            if ($caughtStage -eq 'Export') {
                return $result
            }
            try {
                $operationState.Stage = 'Export'
                $normalRemaining = & $getRemainingSeconds
                $emergencyElapsed = ([datetimeoffset](& $OperationSet.Clock) - $emergencyStarted).TotalSeconds
                $exportBudget = if ($normalRemaining -gt 0) { [math]::Min(1, $normalRemaining) }
                    else { [math]::Max(1, [int][math]::Ceiling($emergencyFinalizationBudgetSeconds - $emergencyElapsed)) }
                $overrunMs = [math]::Max(0L, [int64][math]::Ceiling(
                    (([datetimeoffset](& $OperationSet.Clock) - $deadline).TotalMilliseconds)))
                if ($overrunMs -gt 0) {
                    $warning = 'Emergency finalization exceeded the workload wall-clock deadline.'
                    $result.TerminationEvidence.finalizationOverrunMs = $overrunMs
                    $result.TerminationEvidence.warnings = @($warning)
                    $result.Evidence.terminationEvidence.finalizationOverrunMs = $overrunMs
                    $result.Evidence.terminationEvidence.warnings = @($warning)
                }
                [void](& $OperationSet.Export $result $exportBudget)
            }
            catch {
                $finalizationText = ConvertTo-SanitizedFailureMessage $_.Exception.Message
                throw [InvalidOperationException]::new(
                    "Workshop operational failure: $originalText; local evidence export failure: $finalizationText.",
                    $originalError.Exception)
            }
            return $result
        }
        throw
    }
    finally {
        & $invokeFinalization ''
        & $appendFinalizationWarnings $result
    }
}

function Build-WorkshopStartupFailureResult {
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [Parameter(Mandatory)][object]$Failure,
        [Parameter(Mandatory)][datetimeoffset]$StartedAtUtc,
        [Parameter(Mandatory)][datetimeoffset]$CompletedAtUtc,
        [Parameter(Mandatory)][int]$MaximumWorkers,
        [Parameter(Mandatory)][int]$MaximumDurationSeconds,
        [Parameter(Mandatory)][int]$SampleIntervalSeconds,
        [Parameter(Mandatory)][int]$WorkerRampSeconds
    )

    $schedule = @(Get-WorkshopParameterSchedule | ForEach-Object { ConvertTo-Json $_ -Compress })
    $scheduleJson = ConvertTo-Json $schedule -Compress
    $unavailableHash = Get-Sha256 'UNAVAILABLE-BEFORE-SQL-ENVIRONMENT-CAPTURE'
    $settings = [ordered]@{
        workers = [math]::Max(1, $MaximumWorkers)
        maximumDurationSeconds = $MaximumDurationSeconds
        sampleIntervalSeconds = $SampleIntervalSeconds
        workerRampSeconds = $WorkerRampSeconds
        resourcePool = 'mcp_sql_workshop_pool'
        workloadGroup = 'mcp_sql_workshop_group'
        maxServerMemoryMB = 49152
        databaseScopedConfigurationHash = $unavailableHash
        dataHash = $unavailableHash
        indexStatisticsHash = $unavailableHash
        procedureHash = $unavailableHash
        validationBatchHash = $unavailableHash
        parameterSchedule = $schedule
        parameterScheduleHash = Get-Sha256 $scheduleJson
    }
    $environment = [ordered]@{
        sqlVersion = 'Unavailable before SQL environment capture'
        sqlEdition = 'Unavailable before SQL environment capture'
        physicalMemoryMB = 1
        captureStatus = 'Unavailable'
        runIsolation = if ($Failure.stage -eq 'ConcurrentRunRejected') {
            'ExclusiveDatabaseApplicationLockRejected'
        }
        else { 'Unavailable' }
    }
    $runRecord = New-WorkshopRunRecord -RunId $RunId -Phase Baseline -Status Failed `
        -EvidenceClassification LAB-MEASURED -FrozenSettings $settings `
        -EnvironmentFingerprint $environment -TargetBands ([ordered]@{
            baseline = [ordered]@{ minimum = 75; maximum = 85 }
            optimized = [ordered]@{ minimum = 35; maximum = 45 }
        }) -StartUtc $StartedAtUtc -EndUtc $CompletedAtUtc
    $termination = [ordered]@{
        manualStopRequested = $false
        safetyStopTriggered = $false
        safetyReasons = @()
        timeout = $false
        finalizationOverrunMs = 0
        warnings = @()
        failure = $Failure
    }
    $evidence = ConvertTo-WorkshopEvidence -RunRecord $runRecord -Samples @() -RequestSamples @() `
        -Trials @() -Validation $null -Outcome Failed -TerminationEvidence $termination
    return [pscustomobject]@{
        RunId = $RunId
        Outcome = 'Failed'
        Phase = 'Baseline'
        RunStatus = 'Failed'
        StartedAtUtc = $StartedAtUtc
        CompletedAtUtc = $CompletedAtUtc
        FrozenSettings = [pscustomobject]$settings
        Samples = @()
        RequestSamples = @()
        Trials = @()
        Validation = $null
        TerminationEvidence = [pscustomobject]$termination
        Evidence = $evidence
    }
}

function Invoke-WorkshopStartup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [Parameter()][string]$Server,
        [Parameter()][string]$Database = 'AdventureWorks2022',
        [Parameter()][pscredential]$Credential,
        [Parameter()][string]$HostNameInCertificate = $Server,
        [Parameter()][ValidateRange(1,4)][int]$MaximumWorkers = 4,
        [Parameter()][ValidateRange(60,600)][int]$MaximumDurationSeconds = 600,
        [Parameter()][ValidateRange(5,30)][int]$SampleIntervalSeconds = 5,
        [Parameter()][ValidateRange(20,60)][int]$WorkerRampSeconds = 20,
        [Parameter()][ValidateRange(1,60)][int]$CommandTimeoutSeconds = 1,
        [Parameter()][ValidateRange(0.10,0.80)][decimal]$BaselineCalibrationFraction = [decimal]'0.60',
        [Parameter()][string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
        [Parameter()][scriptblock]$OperationFactory,
        [Parameter()][scriptblock]$SemanticValidator
    )

    $startedAt = [datetimeoffset]::UtcNow
    try {
        [void](Get-WorkshopComparisonBudget -MaximumDurationSeconds $MaximumDurationSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -SampleIntervalSeconds $SampleIntervalSeconds -MaximumWorkers $MaximumWorkers)
    }
    catch {
        $completedAt = [datetimeoffset]::UtcNow
        $failure = ConvertTo-WorkshopFailureEvidence -Code 'COMPARISON_BUDGET_INSUFFICIENT' `
            -Stage 'ComparisonBudgetValidation' -Message $_.Exception.Message -StartupFailure $true
        $result = Build-WorkshopStartupFailureResult -RunId $RunId -Failure $failure `
            -StartedAtUtc $startedAt -CompletedAtUtc $completedAt -MaximumWorkers $MaximumWorkers `
            -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
            -WorkerRampSeconds $WorkerRampSeconds
        Export-WorkshopEvidenceFile -RunId $RunId.ToString('D') -Evidence $result.Evidence `
            -RepositoryRoot $RepositoryRoot -SemanticValidator $SemanticValidator -Confirm:$false | Out-Null
        return $result
    }
    try {
        if ($null -eq $OperationFactory) {
            $operationSet = Get-WorkshopSqlOperationSet -Server $Server -Database $Database `
                -Credential $Credential -HostNameInCertificate $HostNameInCertificate
        }
        else {
            $operationSet = & $OperationFactory
        }
    }
    catch {
        $completedAt = [datetimeoffset]::UtcNow
        $failure = ConvertTo-WorkshopFailureEvidence -Code 'PROVIDER_RESOLUTION_FAILED' `
            -Stage 'ProviderResolution' -Message $_.Exception.Message -StartupFailure $true
        $result = Build-WorkshopStartupFailureResult -RunId $RunId -Failure $failure `
            -StartedAtUtc $startedAt -CompletedAtUtc $completedAt -MaximumWorkers $MaximumWorkers `
            -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
            -WorkerRampSeconds $WorkerRampSeconds
        Export-WorkshopEvidenceFile -RunId $RunId.ToString('D') -Evidence $result.Evidence `
            -RepositoryRoot $RepositoryRoot -SemanticValidator $SemanticValidator -Confirm:$false | Out-Null
        return $result
    }

    try {
        return Invoke-WorkshopExperiment -RunId $RunId -OperationSet $operationSet `
            -MaximumWorkers $MaximumWorkers -MaximumDurationSeconds $MaximumDurationSeconds `
            -SampleIntervalSeconds $SampleIntervalSeconds -WorkerRampSeconds $WorkerRampSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -BaselineCalibrationFraction $BaselineCalibrationFraction -Confirm:$false
    }
    catch {
        $completedAt = [datetimeoffset]::UtcNow
        $failureCode = 'UNEXPECTED_EXPERIMENT_FAILURE'
        $failureStage = 'UnexpectedExperimentFailure'
        if ($_.Exception.Data.Contains('WorkshopFailureCode') -and
            -not [string]::IsNullOrWhiteSpace([string]$_.Exception.Data['WorkshopFailureCode'])) {
            $failureCode = [string]$_.Exception.Data['WorkshopFailureCode']
        }
        if ($_.Exception.Data.Contains('WorkshopFailureStage') -and
            -not [string]::IsNullOrWhiteSpace([string]$_.Exception.Data['WorkshopFailureStage'])) {
            $failureStage = [string]$_.Exception.Data['WorkshopFailureStage']
        }
        $failure = ConvertTo-WorkshopFailureEvidence -Code $failureCode -Stage $failureStage `
            -Message $_.Exception.Message -StartupFailure $true
        $result = Build-WorkshopStartupFailureResult -RunId $RunId -Failure $failure `
            -StartedAtUtc $startedAt -CompletedAtUtc $completedAt -MaximumWorkers $MaximumWorkers `
            -MaximumDurationSeconds $MaximumDurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
            -WorkerRampSeconds $WorkerRampSeconds
        Export-WorkshopEvidenceFile -RunId $RunId.ToString('D') -Evidence $result.Evidence `
            -RepositoryRoot $RepositoryRoot -SemanticValidator $SemanticValidator -Confirm:$false | Out-Null
        return $result
    }
    finally {
        Write-Verbose "Startup envelope completed for run $($RunId.ToString('D'))."
    }
}

function Get-WorkshopKillPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid] $RunId,
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][ValidateRange(1, 32767)][int] $CurrentSessionId
    )

    $namePattern = '^MCP-SQL-Workshop-' + [regex]::Escape($RunId.ToString('D')) + '-(?:Baseline|Optimized|Comparison)-[1-4]$'
    $expectedBytes = $RunId.ToByteArray()
    $candidates = @($Sessions | Where-Object {
        $sessionId = 0
        $validId = [int]::TryParse([string] $_.SessionId, [ref] $sessionId)
        $context = [byte[]] $_.ContextInfo
        $contextMatches = $context.Length -ge $expectedBytes.Length -and
            [Convert]::ToHexString($context, 0, 16) -ceq [Convert]::ToHexString($expectedBytes)
        $validId -and $sessionId -gt 0 -and $sessionId -ne $CurrentSessionId -and
            $_.IsUserProcess -and $_.IsActive -and
            ([string] $_.ProgramName) -cmatch $namePattern -and
            $contextMatches
    })
    if ($candidates.Count -gt 100) {
        throw 'Workshop session termination refuses more than 100 candidates.'
    }
    return @($candidates | Sort-Object SessionId | ForEach-Object {
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
        [Parameter()][ValidateRange(1, 60)][int] $TimeoutSeconds = 30,
        [Parameter(DontShow)][scriptblock] $Clock = { [datetimeoffset]::UtcNow },
        [Parameter(DontShow)][System.Collections.IDictionary] $FileOperations
    )

    $exportDeadline = ([datetimeoffset](& $Clock)).AddSeconds($TimeoutSeconds)
    $assertExportDeadline = {
        if ([datetimeoffset](& $Clock) -gt $exportDeadline) {
            throw 'The evidence export deadline elapsed.'
        }
    }.GetNewClosure()
    $getExportRemaining = {
        $remaining = $exportDeadline - [datetimeoffset](& $Clock)
        if ($remaining -le [TimeSpan]::Zero) { throw 'The evidence export deadline elapsed.' }
        return $remaining
    }.GetNewClosure()
    & $assertExportDeadline
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
        WriteText = {
            param($Path, $Text, $Encoding)
            $cancellation = [Threading.CancellationTokenSource]::new((& $getExportRemaining))
            try {
                [void][IO.File]::WriteAllTextAsync(
                    $Path, $Text, $Encoding, $cancellation.Token
                ).GetAwaiter().GetResult()
            }
            finally { $cancellation.Dispose() }
        }.GetNewClosure()
        WriteLines = {
            param($Path, $Lines, $Encoding)
            $cancellation = [Threading.CancellationTokenSource]::new((& $getExportRemaining))
            try {
                [void][IO.File]::WriteAllLinesAsync(
                    $Path, [string[]]$Lines, $Encoding, $cancellation.Token
                ).GetAwaiter().GetResult()
            }
            finally { $cancellation.Dispose() }
        }.GetNewClosure()
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
    & $assertExportDeadline
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
    $python = if ($SemanticValidator) { $null } else { Join-Path $RepositoryRoot '.venv/Scripts/python.exe' }
    $validator = Join-Path $RepositoryRoot 'evidence/validate_evidence.py'
    $schema = Join-Path $RepositoryRoot 'evidence/evidence-schema.json'
    $invokePythonValidator = {
        param([string]$EvidencePath, [string]$FailureMessage)
        $remaining = & $getExportRemaining
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $python
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        [void]$startInfo.ArgumentList.Add($validator)
        [void]$startInfo.ArgumentList.Add('--schema')
        [void]$startInfo.ArgumentList.Add($schema)
        [void]$startInfo.ArgumentList.Add($EvidencePath)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) { throw $FailureMessage }
            $waitMilliseconds = [math]::Max(1, [int][math]::Floor($remaining.TotalMilliseconds))
            if (-not $process.WaitForExit($waitMilliseconds)) {
                $process.Kill($true)
                [void]$process.WaitForExit(1000)
                throw 'The evidence export deadline elapsed during semantic validation.'
            }
            if ($process.ExitCode -ne 0) { throw $FailureMessage }
        }
        finally { $process.Dispose() }
    }.GetNewClosure()
    try {
        & $FileOperations.WriteText $jsonTemp (ConvertTo-Json $Evidence -Depth 30) $utf8
        & $assertExportDeadline
        if ($SemanticValidator) {
            if (-not (& $SemanticValidator $jsonTemp)) { throw 'Canonical semantic evidence validation failed.' }
        }
        else {
            & $invokePythonValidator $jsonTemp 'Canonical semantic evidence validation failed.'
        }
        & $assertExportDeadline
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
        & $assertExportDeadline
        & $assertNoReparseAncestor $stagingDirectory
        & $assertNoReparseAncestor $backupDirectory
        & $assertNoReparseAncestor $directory
        if (& $FileOperations.TestPath $directory) {
            if (-not $AllowReplaceCompletedRun) { throw 'A completed run cannot be overwritten without the explicit safe replace flag.' }
            & $assertNoReparseAncestor $directory
            & $assertNoReparseAncestor $backupDirectory
            & $FileOperations.MoveDirectory $directory $backupDirectory
            & $assertExportDeadline
            $backupCreated = (& $FileOperations.TestPath $backupDirectory) -and -not (& $FileOperations.TestPath $directory)
        }
        & $assertNoReparseAncestor $stagingDirectory
        & $assertNoReparseAncestor $directory
        & $FileOperations.MoveDirectory $stagingDirectory $directory
        & $assertExportDeadline
        if ($SemanticValidator) {
            if (-not (& $SemanticValidator $jsonPath)) { throw 'Canonical semantic evidence validation failed after promotion.' }
        }
        else {
            & $invokePythonValidator $jsonPath `
                'Canonical semantic evidence validation failed after promotion.'
        }
        & $assertExportDeadline
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

function Get-WorkshopSqlProviderCapability {
    param([Parameter(Mandatory)][string] $ProviderName)

    $resolveType = {
        param([string] $TypeName)
        $qualifiedName = "$TypeName, $ProviderName"
        $type = [Type]::GetType($qualifiedName, $false)
        if ($null -eq $type) {
            try { Add-Type -AssemblyName $ProviderName -ErrorAction Stop }
            catch { return $null }
            $type = [Type]::GetType($qualifiedName, $false)
        }
        return $type
    }.GetNewClosure()

    $connectionType = & $resolveType "$ProviderName.SqlConnection"
    $builderType = & $resolveType "$ProviderName.SqlConnectionStringBuilder"
    $commandType = & $resolveType "$ProviderName.SqlCommand"
    if ($null -eq $connectionType -or $null -eq $builderType -or $null -eq $commandType) {
        return $null
    }
    $cancellationTokenType = [Threading.CancellationToken]
    return [pscustomobject]@{
        ProviderName = $ProviderName
        ConnectionType = $connectionType
        ConnectionStringBuilderType = $builderType
        CommandType = $commandType
        SupportsEncrypt = $null -ne $builderType.GetProperty('Encrypt')
        SupportsTrustServerCertificate = $null -ne $builderType.GetProperty('TrustServerCertificate')
        SupportsHostNameInCertificate = $null -ne $builderType.GetProperty('HostNameInCertificate')
        SupportsConnectionConstruction = $null -ne $connectionType.GetConstructor([type[]]@([string]))
        SupportsCommands = $null -ne $connectionType.GetMethod('CreateCommand', [type[]]@())
        SupportsAsync = $null -ne $connectionType.GetMethod('OpenAsync', [type[]]@($cancellationTokenType)) -and
            $null -ne $commandType.GetMethod('ExecuteReaderAsync', [type[]]@($cancellationTokenType)) -and
            $null -ne $commandType.GetMethod('ExecuteNonQueryAsync', [type[]]@($cancellationTokenType))
    }
}

function Resolve-WorkshopSqlClientProvider {
    [CmdletBinding()]
    param(
        [Parameter()]
        [scriptblock] $ProviderProbe = ${function:Get-WorkshopSqlProviderCapability}
    )

    foreach ($providerName in @('Microsoft.Data.SqlClient', 'System.Data.SqlClient')) {
        $capability = & $ProviderProbe $providerName
        if ($null -eq $capability) { continue }
        if ([string]$capability.ProviderName -cne $providerName) {
            throw "SQL client provider probe returned noncanonical metadata for '$providerName'."
        }
        $expectedTypeNames = @{
            ConnectionType = "$providerName.SqlConnection"
            ConnectionStringBuilderType = "$providerName.SqlConnectionStringBuilder"
            CommandType = "$providerName.SqlCommand"
        }
        $canonicalTypes = $true
        foreach ($typeProperty in @($expectedTypeNames.Keys)) {
            $resolvedType = $capability.$typeProperty
            if ($null -eq $resolvedType -or $resolvedType.FullName -cne $expectedTypeNames[$typeProperty] -or
                $resolvedType.Assembly.GetName().Name -cne $providerName) {
                $canonicalTypes = $false
            }
        }
        if (-not $canonicalTypes -or
            -not $capability.SupportsEncrypt -or -not $capability.SupportsTrustServerCertificate -or
            -not $capability.SupportsConnectionConstruction -or -not $capability.SupportsCommands -or
            -not $capability.SupportsAsync) {
            continue
        }
        $warnings = [System.Collections.Generic.List[string]]::new()
        if ($providerName -eq 'System.Data.SqlClient') {
            $warnings.Add('System.Data.SqlClient fallback active; install Microsoft.Data.SqlClient before production use.')
            $warnings.Add('System.Data.SqlClient does not support HostNameInCertificate; the server connection name must match the certificate DNS name.')
        }
        return [pscustomobject][ordered]@{
            Name = $providerName
            ConnectionType = [type]$capability.ConnectionType
            ConnectionStringBuilderType = [type]$capability.ConnectionStringBuilderType
            CommandType = if ($null -eq $capability.CommandType) { $null } else { [type]$capability.CommandType }
            SupportsHostNameInCertificate = $providerName -eq 'Microsoft.Data.SqlClient' -and
                [bool]$capability.SupportsHostNameInCertificate
            Warnings = [string[]]$warnings.ToArray()
        }
    }
    throw 'No supported SQL client provider is available. Install Microsoft.Data.SqlClient before running the workshop.'
}

function Get-WorkshopSqlConnectionBuilder {
    param(
        [Parameter(Mandatory)][object] $Provider,
        [Parameter(Mandatory)][string] $Server,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][string] $ApplicationName,
        [Parameter(Mandatory)][string] $UserName,
        [Parameter(Mandatory)][string] $HostNameInCertificate
    )

    $builder = [Activator]::CreateInstance([type]$Provider.ConnectionStringBuilderType)
    $builder.DataSource = $Server
    $builder.InitialCatalog = $Database
    $builder.Encrypt = $true
    $builder.TrustServerCertificate = $false
    if ($Provider.SupportsHostNameInCertificate) {
        $builder.HostNameInCertificate = $HostNameInCertificate
    }
    elseif ($HostNameInCertificate -cne $Server) {
        throw 'System.Data.SqlClient cannot apply a HostNameInCertificate override; the server connection name must match the certificate DNS name.'
    }
    if (-not [bool]$builder.Encrypt -or [bool]$builder.TrustServerCertificate) {
        throw 'SQL client encryption settings could not be proven safe.'
    }
    $builder.ApplicationName = $ApplicationName
    $builder.UserID = $UserName
    return $builder
}

function Get-WorkshopSqlConnection {
    param(
        [Parameter(Mandatory)][type] $ConnectionType,
        [Parameter(Mandatory)][string] $ConnectionString
    )

    return [Activator]::CreateInstance($ConnectionType, [object[]]@($ConnectionString))
}

function Get-WorkshopSqlOperationSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Server,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][pscredential] $Credential,
        [Parameter(Mandatory)][string] $HostNameInCertificate,
        [Parameter()][scriptblock] $ProviderProbe = ${function:Get-WorkshopSqlProviderCapability}
    )

    $provider = Resolve-WorkshopSqlClientProvider -ProviderProbe $ProviderProbe
    if ($Server -match '^\s*(?:localhost|\.|\d{1,3}(?:\.\d{1,3}){3})(?:,\d+)?\s*$' -or $Server -notmatch '\.') {
        throw 'Server must be the SQL VM private DNS name.'
    }
    if (-not $provider.SupportsHostNameInCertificate -and $HostNameInCertificate -cne $Server) {
        throw 'System.Data.SqlClient cannot apply a HostNameInCertificate override; the server connection name must match the certificate DNS name.'
    }
    $preflightSnapshot = [pscustomobject]@{ Value = $null }
    $runLockState = [pscustomobject]@{ Connection = $null; Held = $false }
    Write-Verbose "Preparing SQL operations for database '$Database' and credential user '$($Credential.UserName)'."

    $invokeTable = {
        param(
            [string] $ApplicationName,
            [string] $CommandText,
            [hashtable] $Parameters,
            [scriptblock] $ReaderParser,
            [int] $CommandTimeoutSeconds = 60,
            [datetimeoffset] $OperationDeadline = [datetimeoffset]::MaxValue
        )
        $builder = Get-WorkshopSqlConnectionBuilder -Provider $provider -Server $Server -Database $Database `
            -ApplicationName $ApplicationName -UserName $Credential.UserName `
            -HostNameInCertificate $HostNameInCertificate
        $bstr = [IntPtr]::Zero
        $connection = $null
        $command = $null
        $reader = $null
        $cancellation = $null
        try {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
            $builder.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $connection = Get-WorkshopSqlConnection -ConnectionType $provider.ConnectionType `
                -ConnectionString $builder.ConnectionString
            $timeout = [TimeSpan]::FromSeconds([math]::Max(1, $CommandTimeoutSeconds))
            if ($OperationDeadline -ne [datetimeoffset]::MaxValue) {
                $deadlineRemaining = $OperationDeadline - [datetimeoffset]::UtcNow
                if ($deadlineRemaining -le [TimeSpan]::Zero) {
                    throw 'The bounded SQL operation deadline elapsed before execution.'
                }
                if ($deadlineRemaining -lt $timeout) { $timeout = $deadlineRemaining }
            }
            $cancellation = [Threading.CancellationTokenSource]::new($timeout)
            $connection.OpenAsync($cancellation.Token).GetAwaiter().GetResult()
            $command = $connection.CreateCommand()
            $command.CommandText = $CommandText
            $command.CommandTimeout = [math]::Max(1, [int][math]::Ceiling($timeout.TotalSeconds))
            foreach ($name in @($Parameters.Keys)) {
                $specification = $Parameters[$name]
                $parameter = $command.Parameters.Add($name, $specification.Type)
                if ($specification.ContainsKey('Size')) { $parameter.Size = $specification.Size }
                $parameter.Value = if ($null -eq $specification.Value) { [DBNull]::Value } else { $specification.Value }
            }
            $reader = $command.ExecuteReaderAsync($cancellation.Token).GetAwaiter().GetResult()
            if ($null -ne $ReaderParser) {
                return & $ReaderParser $reader
            }
            $rows = [System.Collections.Generic.List[object]]::new()
            while ($reader.ReadAsync($cancellation.Token).GetAwaiter().GetResult()) {
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
            if ($null -ne $cancellation) { $cancellation.Dispose() }
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
    CONVERT(bit, CASE WHEN DB_NAME() = N'AdventureWorks2022'
        AND marker.MarkerId = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C'
        AND marker.SchemaVersion = 1
        AND marker.SetupName = N'MCP SQL Query Store Workshop'
        AND marker.SetupHash = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B
        AND serverMarker.ServerMarkerId = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C'
        THEN 1 ELSE 0 END) AS MarkerValid,
    LOWER(CONVERT(char(36), marker.MarkerId)) AS MarkerId,
    CONVERT(int, marker.SchemaVersion) AS SchemaVersion,
    CONVERT(nvarchar(128), marker.SetupName) AS SetupName,
    LOWER(CONVERT(varchar(64), marker.SetupHash, 2)) AS SetupHash,
    LOWER(CONVERT(char(36), serverMarker.ServerMarkerId)) AS ServerMarkerId,
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
OUTER APPLY
(
    SELECT TOP (1) MarkerId, SchemaVersion, SetupName, SetupHash
    FROM lab.WorkshopMarker
    ORDER BY MarkerId, SchemaVersion, SetupName, SetupHash
) AS marker
OUTER APPLY
(
    SELECT TRY_CONVERT(uniqueidentifier, value) AS ServerMarkerId
    FROM master.sys.extended_properties
    WHERE class = 0 AND name = N'MCP_SQL_WORKSHOP'
) AS serverMarker
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
        $rows[0] | Add-Member NoteProperty SqlClientProvider $provider.Name -Force
        $rows[0] | Add-Member NoteProperty EnvironmentWarnings ([string[]]$provider.Warnings) -Force
        if ($null -eq $preflightSnapshot.Value) { $preflightSnapshot.Value = $rows[0] }
        return $rows[0]
    }.GetNewClosure()

    $startWorker = {
        param([guid] $RunId, [string] $Phase, [int] $Worker, [string] $ApplicationName, [object[]] $Schedule, [datetimeoffset] $Deadline)
        Write-Verbose "Starting workshop worker $Worker for $Phase."
        Enter-WorkshopWorkerCapacity
        $capacityReserved = $true
        $runspace = $null
        $powerShell = $null
        $asyncResult = $null
        $readySignal = $null
        try {
            $readySignal = [Threading.ManualResetEventSlim]::new($false)
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $powerShell = [powershell]::Create()
            $powerShell.Runspace = $runspace
            [void] $powerShell.AddScript({
                param($WorkerServer, $WorkerDatabase, [pscredential] $WorkerCredential, $WorkerCertificateName,
                    $WorkerRunId, $WorkerPhase, $WorkerApplicationName, $WorkerSchedule,
                    [datetimeoffset]$WorkerDeadline, $readySignal, $WorkerConnectionTypeName,
                    $WorkerBuilderTypeName, [bool]$WorkerSupportsHostNameInCertificate)
            $connectionType = [Type]::GetType($WorkerConnectionTypeName, $true)
            $builderType = [Type]::GetType($WorkerBuilderTypeName, $true)
            $builder = [Activator]::CreateInstance($builderType)
            $builder.DataSource = $WorkerServer
            $builder.InitialCatalog = $WorkerDatabase
            $builder.Encrypt = $true
            $builder.TrustServerCertificate = $false
            if ($WorkerSupportsHostNameInCertificate) {
                $builder.HostNameInCertificate = $WorkerCertificateName
            }
            elseif ($WorkerCertificateName -cne $WorkerServer) {
                throw 'The server connection name must match the certificate DNS name.'
            }
            if (-not [bool]$builder.Encrypt -or [bool]$builder.TrustServerCertificate) {
                throw 'SQL client encryption settings could not be proven safe.'
            }
            $builder.ApplicationName = $WorkerApplicationName
            $builder.UserID = $WorkerCredential.UserName
            $bstr = [IntPtr]::Zero
            $connection = $null
            $setupCancellation = $null
            $workerCancellation = $null
            try {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($WorkerCredential.Password)
                $builder.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $connection = [Activator]::CreateInstance($connectionType, [object[]]@($builder.ConnectionString))
                if ($WorkerDeadline -le [datetimeoffset]::UtcNow) {
                    throw 'The experiment deadline elapsed before the worker connection opened.'
                }
                $setupRemaining = $WorkerDeadline - [datetimeoffset]::UtcNow
                $setupTimeout = @([TimeSpan]::FromSeconds(15), $setupRemaining | Sort-Object)[0]
                $setupCancellation = [Threading.CancellationTokenSource]::new($setupTimeout)
                $connection.OpenAsync($setupCancellation.Token).GetAwaiter().GetResult()
                $tag = $connection.CreateCommand()
                try {
                    $phaseTag = if ($WorkerPhase -ceq 'Baseline') { [byte]1 } else { [byte]2 }
                    $runContextBytes = [byte[]]::new(17)
                    ([guid] $WorkerRunId).ToByteArray().CopyTo($runContextBytes, 0)
                    $runContextBytes[16] = $phaseTag
                    $tag.CommandText = "SET CONTEXT_INFO @RunContextBytes; EXEC sys.sp_set_session_context @key=N'WorkshopRunId', @value=@RunId; EXEC sys.sp_set_session_context @key=N'WorkshopPhase', @value=@Phase;"
                    $tagRemainingSeconds = ($WorkerDeadline - [datetimeoffset]::UtcNow).TotalSeconds
                    if ($tagRemainingSeconds -le 0) { throw 'The experiment deadline elapsed before worker tagging completed.' }
                    $tag.CommandTimeout = [math]::Max(1, [int][math]::Ceiling($tagRemainingSeconds))
                    [void] $tag.Parameters.Add('@RunContextBytes', [Data.SqlDbType]::Binary, 17)
                    $tag.Parameters['@RunContextBytes'].Value = $runContextBytes
                    [void] $tag.Parameters.Add('@RunId', [Data.SqlDbType]::UniqueIdentifier)
                    $tag.Parameters['@RunId'].Value = [guid] $WorkerRunId
                    [void] $tag.Parameters.Add('@Phase', [Data.SqlDbType]::NVarChar, 16)
                    $tag.Parameters['@Phase'].Value = $WorkerPhase
                    [void] $tag.ExecuteNonQueryAsync($setupCancellation.Token).GetAwaiter().GetResult()
                    $workerRemaining = $WorkerDeadline - [datetimeoffset]::UtcNow
                    if ($workerRemaining -le [TimeSpan]::Zero) {
                        throw 'The experiment deadline elapsed before worker readiness completed.'
                    }
                    $workerCancellation = [Threading.CancellationTokenSource]::new($workerRemaining)
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
                        [void] $command.ExecuteNonQueryAsync($workerCancellation.Token).GetAwaiter().GetResult()
                    }
                    finally { $command.Dispose() }
                }
            }
            finally {
                $builder.Password = [string]::Empty
                if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                if ($null -ne $connection) { $connection.Dispose() }
                if ($null -ne $setupCancellation) { $setupCancellation.Dispose() }
                if ($null -ne $workerCancellation) { $workerCancellation.Dispose() }
            }
            }).AddArgument($Server).AddArgument($Database).AddArgument($Credential).AddArgument($HostNameInCertificate).AddArgument($RunId).AddArgument($Phase).AddArgument($ApplicationName).AddArgument($Schedule).AddArgument($Deadline).AddArgument($readySignal).AddArgument($provider.ConnectionType.AssemblyQualifiedName).AddArgument($provider.ConnectionStringBuilderType.AssemblyQualifiedName).AddArgument($provider.SupportsHostNameInCertificate)
            $asyncResult = $powerShell.BeginInvoke()
            $readinessRemaining = $Deadline - [datetimeoffset]::UtcNow
            if ($readinessRemaining -le [TimeSpan]::Zero -or
                -not $readySignal.Wait(@([TimeSpan]::FromSeconds(15), $readinessRemaining | Sort-Object)[0])) {
                $details = @($powerShell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join ' '
                throw "Workshop worker failed to become tagged and ready within 15 seconds. $details".Trim()
            }
        }
        catch {
            $setupError = $_
            $remainingMilliseconds = [int] [math]::Max(
                0,
                [math]::Min(1000, [math]::Floor(($Deadline - [datetimeoffset]::UtcNow).TotalMilliseconds))
            )
            Invoke-WorkshopWorkerSetupCleanup -PowerShell $powerShell -Runspace $runspace `
                -AsyncResult $asyncResult -ReadySignal $readySignal -SetupError $setupError `
                -CapacityReserved $capacityReserved -TimeoutMilliseconds $remainingMilliseconds
        }
        return ConvertTo-WorkshopWorkerHandle -PowerShell $powerShell -Runspace $runspace `
            -AsyncResult $asyncResult -ReadySignal $readySignal -CapacityReserved $capacityReserved
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
        param(
            [guid] $RunId,
            [string] $Phase,
            [string] $Kind,
            [string] $TrialPhase,
            [string] $ScheduleEntry,
            [int] $RemainingSeconds,
            [datetimeoffset] $OperationDeadline = [datetimeoffset]::MaxValue
        )
        $commandTimeout = [math]::Max(1, $RemainingSeconds)
        $timeoutDeadline = [datetimeoffset]::UtcNow.AddSeconds($commandTimeout)
        $operationDeadline = @($OperationDeadline, $timeoutDeadline | Sort-Object)[0]
        if ($Kind -eq 'Fingerprint') {
            $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Preflight' $preflightSql @{} $null `
                $commandTimeout $operationDeadline)
            if ($rows.Count -ne 1) { throw 'Workshop SQL fingerprint did not return exactly one row.' }
            return $rows[0]
        }
        if ($Kind -eq 'Memory' -or $Kind -eq 'Drain') {
            $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Sample' `
                'EXEC lab.usp_GetMemorySnapshot;' @{} $null $commandTimeout $operationDeadline)
            if ($rows.Count -ne 1) { throw 'Memory snapshot did not return exactly one row.' }
            $row = $rows[0]
            $totalHost = [decimal] $row.HostAvailableMemoryKB + [decimal] $row.HostUsedMemoryKB
            $requestRows = if ($Kind -eq 'Memory') {
                @(& $invokeTable 'MCP-SQL-Workshop-Controller-Sample' `
                    'EXEC lab.usp_GetActiveWorkshopGrants @Top=100, @RunID=@RunID, @Phase=@Phase;' `
                    @{
                        '@RunID' = @{ Type = [Data.SqlDbType]::UniqueIdentifier; Value = $RunId }
                        '@Phase' = @{ Type = [Data.SqlDbType]::VarChar; Size = 16; Value = $Phase }
                    } `
                    $null $commandTimeout $operationDeadline)
            }
            else { @() }
            return [pscustomobject]@{
                Phase = $Phase; GrantedKb = $row.PoolGrantedMemoryKB; TotalKb = $row.PoolTotalMemoryKB
                GrantUtilizationPercent = $row.GrantUtilizationPercent
                HostUsedPercent = if ($totalHost -eq 0) { 100 } else { 100 * [decimal] $row.HostUsedMemoryKB / $totalHost }
                HostAvailableMB = [decimal] $row.HostAvailableMemoryKB / 1024
                ProcessPhysicalLow = [bool] $row.ProcessPhysicalMemoryLow
                ProcessVirtualLow = [bool] $row.ProcessVirtualMemoryLow
                SystemPhysicalMemoryLow = [bool] $row.SystemPhysicalMemoryLow
                SystemPhysicalMemoryHigh = [bool] $row.SystemPhysicalMemoryHigh
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
            $row = & $invokeTable $applicationName $sql $parameters `
                { param($Reader) ConvertFrom-WorkshopTrialReader $Reader } `
                $commandTimeout $operationDeadline
            $row | Add-Member NoteProperty Phase $TrialPhase -PassThru
        }
    }.GetNewClosure()

    $stopWorker = {
        param($Handle, [int] $RemainingSeconds = 1)
        if ($RemainingSeconds -lt 1) { throw 'Worker cleanup requires a positive timeout.' }
        if ($null -ne $Handle -and $Handle.psobject.Methods['StopWithin']) {
            $Handle.StopWithin($RemainingSeconds)
        }
        elseif ($null -ne $Handle -and $Handle.psobject.Methods['Dispose']) {
            $Handle.Dispose()
        }
    }

    $getKillPlan = ${function:Get-WorkshopKillPlan}
    $killTagged = {
        param([guid] $RunId, [int] $RemainingSeconds = 5)
        $operationDeadline = [datetimeoffset]::UtcNow.AddSeconds([math]::Max(1, $RemainingSeconds))
        $sessionSql = "SELECT CONVERT(int,s.session_id) AS SessionId, CONVERT(bit,s.is_user_process) AS IsUserProcess, CONVERT(bit,1) AS IsActive, CONVERT(nvarchar(128),s.program_name) AS ProgramName, CONVERT(varbinary(128),s.context_info) AS ContextInfo, CONVERT(int,@@SPID) AS CurrentSessionId FROM sys.dm_exec_sessions AS s INNER JOIN sys.dm_exec_requests AS r ON r.session_id=s.session_id WHERE CONVERT(binary(16),SUBSTRING(s.context_info,1,16))=@RunBytes AND s.session_id<>@@SPID;"
        $parameters = @{ '@RunBytes' = @{ Type = [Data.SqlDbType]::Binary; Size = 16; Value = $RunId.ToByteArray() } }
        $sessions = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Stop' $sessionSql $parameters `
            $null $RemainingSeconds $operationDeadline)
        if ($sessions.Count -eq 0) { return @() }
        $plan = @(& $getKillPlan -RunId $RunId -Sessions $sessions -CurrentSessionId $sessions[0].CurrentSessionId)
        $killed = [System.Collections.Generic.List[int]]::new()
        foreach ($entry in $plan) {
            $revalidationSql = "SELECT CONVERT(int,s.session_id) AS SessionId, CONVERT(bit,s.is_user_process) AS IsUserProcess, CONVERT(bit,1) AS IsActive, CONVERT(nvarchar(128),s.program_name) AS ProgramName, CONVERT(varbinary(128),s.context_info) AS ContextInfo, CONVERT(int,@@SPID) AS CurrentSessionId FROM sys.dm_exec_sessions AS s INNER JOIN sys.dm_exec_requests AS r ON r.session_id=s.session_id WHERE s.session_id=@SessionId AND s.session_id<>@@SPID AND CONVERT(binary(16),SUBSTRING(s.context_info,1,16))=@RunBytes;"
            $revalidationParameters = @{
                '@SessionId' = @{ Type = [Data.SqlDbType]::Int; Value = [int]$entry.SessionId }
                '@RunBytes' = @{ Type = [Data.SqlDbType]::Binary; Size = 16; Value = $RunId.ToByteArray() }
            }
            $current = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Stop' $revalidationSql `
                $revalidationParameters $null $RemainingSeconds $operationDeadline)
            if ($current.Count -ne 1) { continue }
            $revalidatedPlan = @(& $getKillPlan -RunId $RunId -Sessions $current `
                -CurrentSessionId $current[0].CurrentSessionId)
            if ($revalidatedPlan.Count -ne 1 -or $revalidatedPlan[0].SessionId -ne $entry.SessionId) { continue }
            [void] (& $invokeTable 'MCP-SQL-Workshop-Controller-Stop' $entry.Statement @{} `
                $null $RemainingSeconds $operationDeadline)
            $killed.Add([int]$entry.SessionId)
        }
        return @($killed)
    }.GetNewClosure()

    $getSha256ForPersistence = ${function:Get-Sha256}
    $getObjectEntryForPersistence = ${function:Get-ObjectEntry}
    $persist = {
        param($Record, [int] $RemainingSeconds = 5)
        $operationDeadline = [datetimeoffset]::UtcNow.AddSeconds([math]::Max(1, $RemainingSeconds))
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
              GrantUtilizationPercent decimal(9,6), GranteeCount int, WaiterCount int,
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
              GrantUtilizationPercent decimal(9,6), GranteeCount int, WaiterCount int,
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
    GrantUtilizationPercent decimal(9,6), GranteeCount int, WaiterCount int,
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
        } $null $RemainingSeconds $operationDeadline)
        if ($rows.Count -ne 1 -or [int]$rows[0].InsertedSampleCount -ne @($Record.Samples).Count -or
            [int]$rows[0].InsertedRequestSampleCount -ne @($Record.RequestSamples).Count -or
            [int]$rows[0].InsertedTrialCount -ne @($Record.Trials).Count) {
            throw 'Workshop evidence persistence did not verify exact inserted counts.'
        }
    }.GetNewClosure()

    $acquireRunLock = {
        param([int]$RemainingSeconds = 1)
        $builder = Get-WorkshopSqlConnectionBuilder -Provider $provider -Server $Server -Database $Database `
            -ApplicationName 'MCP-SQL-Workshop-Controller-Lock' -UserName $Credential.UserName `
            -HostNameInCertificate $HostNameInCertificate
        $bstr = [IntPtr]::Zero
        $connection = $null
        $command = $null
        $cancellation = $null
        try {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
            $builder.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $connection = Get-WorkshopSqlConnection -ConnectionType $provider.ConnectionType `
                -ConnectionString $builder.ConnectionString
            $cancellation = [Threading.CancellationTokenSource]::new(
                [TimeSpan]::FromSeconds([math]::Max(1, $RemainingSeconds)))
            $connection.OpenAsync($cancellation.Token).GetAwaiter().GetResult()
            $command = $connection.CreateCommand()
            $command.CommandText = @'
DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'MCP-SQL-Workshop-Exclusive-Run',
    @LockMode = N'Exclusive',
    @LockOwner = N'Session',
    @LockTimeout = 0,
    @DbPrincipal = N'public';
SELECT @LockResult;
'@
            $command.CommandTimeout = [math]::Max(1, $RemainingSeconds)
            $lockResult = [int]$command.ExecuteScalarAsync($cancellation.Token).GetAwaiter().GetResult()
            if ($lockResult -ge 0) {
                $runLockState.Connection = $connection
                $runLockState.Held = $true
                $connection = $null
            }
            return $lockResult
        }
        catch {
            throw [InvalidOperationException]::new('Exclusive workshop run lock could not be acquired.')
        }
        finally {
            $builder.Password = [string]::Empty
            if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ($null -ne $command) { $command.Dispose() }
            if ($null -ne $connection) { $connection.Dispose() }
            if ($null -ne $cancellation) { $cancellation.Dispose() }
        }
    }.GetNewClosure()

    $releaseRunLock = {
        param([int]$RemainingSeconds = 1)
        $connection = $runLockState.Connection
        $command = $null
        $cancellation = $null
        try {
            if ($null -eq $connection) { return }
            $cancellation = [Threading.CancellationTokenSource]::new(
                [TimeSpan]::FromSeconds([math]::Max(1, $RemainingSeconds)))
            $command = $connection.CreateCommand()
            $command.CommandText = @'
DECLARE @ReleaseResult int;
EXEC @ReleaseResult = sys.sp_releaseapplock
    @Resource = N'MCP-SQL-Workshop-Exclusive-Run',
    @LockOwner = N'Session',
    @DbPrincipal = N'public';
SELECT @ReleaseResult;
'@
            $command.CommandTimeout = [math]::Max(1, $RemainingSeconds)
            $releaseResult = [int]$command.ExecuteScalarAsync($cancellation.Token).GetAwaiter().GetResult()
            if ($releaseResult -lt 0) { throw 'Exclusive workshop run lock release failed.' }
        }
        finally {
            $runLockState.Held = $false
            $runLockState.Connection = $null
            if ($null -ne $command) { $command.Dispose() }
            if ($null -ne $connection) { $connection.Dispose() }
            if ($null -ne $cancellation) { $cancellation.Dispose() }
        }
    }.GetNewClosure()

    return @{
        Readiness = [pscustomobject][ordered]@{
            SqlClientProvider = $provider.Name
            Warnings = [string[]]$provider.Warnings
            RunIsolation = 'ExclusiveDatabaseApplicationLock'
        }
        AcquireRunLock = $acquireRunLock
        ReleaseRunLock = $releaseRunLock
        OpenConnection = {
            param($Purpose, [int]$RemainingSeconds = 60)
            Write-Verbose "Opening $Purpose controller connection."
            $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Open' `
                'SELECT CONVERT(bit,1) AS ConnectionReady;' @{} $null $RemainingSeconds)
            if ($rows.Count -ne 1 -or -not [bool]$rows[0].ConnectionReady) {
                throw 'Workshop SQL connection readiness check failed.'
            }
        }.GetNewClosure()
        CaptureEnvironment = { param([int]$RemainingSeconds = 60) & $getPreflight $RemainingSeconds }.GetNewClosure()
        InitializePersistence = {
            param([int]$RemainingSeconds = 60)
            $persistenceReadinessSql = @'
SELECT CONVERT(bit, CASE WHEN
    OBJECT_ID(N'lab.WorkshopRun', N'U') IS NOT NULL
    AND OBJECT_ID(N'lab.WorkshopSample', N'U') IS NOT NULL
    AND OBJECT_ID(N'lab.WorkshopRequestSample', N'U') IS NOT NULL
    AND OBJECT_ID(N'lab.WorkshopTrial', N'U') IS NOT NULL
    THEN 1 ELSE 0 END) AS PersistenceReady;
'@
            $rows = @(& $invokeTable 'MCP-SQL-Workshop-Controller-Persistence' `
                $persistenceReadinessSql @{} $null $RemainingSeconds)
            if ($rows.Count -ne 1 -or -not [bool]$rows[0].PersistenceReady) {
                throw 'Workshop SQL persistence initialization failed.'
            }
        }.GetNewClosure()
        StartWorker = $startWorker
        TestWorkerHealth = $testWorkerHealth
        Sample = $sample
        StopWorker = $stopWorker
        KillTagged = $killTagged
        Persist = $persist
        Delay = { param([int] $Seconds) [Threading.Tasks.Task]::Delay([TimeSpan]::FromSeconds($Seconds)).GetAwaiter().GetResult() }
        Clock = { [datetimeoffset]::UtcNow }
        Export = {
            param($Result, [int] $RemainingSeconds = 5)
            if ($RemainingSeconds -lt 1) { throw 'Evidence export requires a positive timeout.' }
            if ($Result.psobject.Properties['Evidence']) {
                Export-WorkshopEvidenceFile -RunId $Result.RunId.ToString('D') `
                    -Evidence $Result.Evidence -RepositoryRoot (Split-Path -Parent $PSScriptRoot) `
                    -TimeoutSeconds $RemainingSeconds -Confirm:$false
            }
            else {
                Write-Verbose "Run $($Result.RunId) persisted; canonical evidence is exported after evidence conversion."
            }
        }
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
    'Get-WorkshopComparisonBudget',
    'ConvertFrom-WorkshopTrialReader',
    'Get-WorkshopTrialAssessment',
    'Test-WorkshopFingerprintMatch',
    'Test-WorkshopPreflight',
    'Invoke-WorkshopExperiment',
    'Invoke-WorkshopStartup',
    'Get-WorkshopKillPlan',
    'Export-WorkshopEvidenceFile',
    'Resolve-WorkshopSqlClientProvider',
    'Get-WorkshopSqlOperationSet'
)
