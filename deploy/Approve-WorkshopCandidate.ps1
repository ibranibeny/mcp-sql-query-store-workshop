[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ConnectionString')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Security.SecureString] $SqlConnectionString,

    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [PSCredential] $Credential,

    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $ServerInstance,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $ExpectedServerName,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $ExpectedDatabaseName,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $ConfirmationPhrase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$approvedServerName = 'sql01.mcpworkshop.internal'
$approvedServerAddress = '10.20.2.10'
$approvedDatabaseName = 'AdventureWorks2022'
$requiredPhrase = 'APPROVE AdventureWorks2022 candidate'
$sqlDirectory = Join-Path $PSScriptRoot '../sql'
$applicationLockResource = 'MCP_SQL_WORKSHOP_LIFECYCLE'
$applicationLockTimeoutMilliseconds = 15000

if ($ExpectedServerName -cne $approvedServerName) {
    throw "ExpectedServerName must exactly match the workshop private DNS name '$approvedServerName'."
}
if ($ExpectedDatabaseName -cne $approvedDatabaseName) {
    throw "ExpectedDatabaseName must exactly match '$approvedDatabaseName'."
}
if ($PSCmdlet.ParameterSetName -eq 'Credential' -and $ServerInstance -cne $ExpectedServerName) {
    throw 'ServerInstance must exactly match ExpectedServerName for certificate DNS validation.'
}
if ($ConfirmationPhrase -cne $requiredPhrase) {
    throw "Candidate approval phrase did not match exactly. Required phrase: '$requiredPhrase'."
}
if (-not $PSCmdlet.ShouldProcess(
        "$ExpectedServerName/$ExpectedDatabaseName",
        'Create the reviewed candidate and run deterministic equivalence validation')) {
    return [pscustomobject]@{
        Completed = $false
        CandidateApprovalId = $null
        ValidationStatus = 'Declined'
    }
}

$resolvedAddresses = @(Resolve-DnsName -Name $ExpectedServerName -Type A -DnsOnly -ErrorAction Stop |
    Where-Object IPAddress | ForEach-Object IPAddress | Sort-Object -Unique)
if ($resolvedAddresses.Count -ne 1 -or $resolvedAddresses[0] -cne $approvedServerAddress) {
    throw "ExpectedServerName must resolve only to the approved private address '$approvedServerAddress'."
}

$scriptNames = @('06-CreateOptimizedProcedure.sql', '07-ValidateEquivalence.sql')
foreach ($scriptName in $scriptNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $sqlDirectory $scriptName) -PathType Leaf)) {
        throw "Required candidate SQL script is missing: $scriptName"
    }
}

. (Join-Path $PSScriptRoot 'Invoke-WorkshopSqlScripts.ps1') -LoadFunctionsOnly

$clientNamespace = 'Microsoft.Data.SqlClient'
try {
    Add-Type -AssemblyName Microsoft.Data.SqlClient -ErrorAction Stop
}
catch {
    $clientNamespace = 'System.Data.SqlClient'
    Write-Warning 'Microsoft.Data.SqlClient is unavailable; using the built-in System.Data.SqlClient fallback.'
}

$builder = $null
$connection = $null
$candidateApprovalId = [guid]::NewGuid()
$candidateChangesStarted = $false
$applicationLockAcquired = $false
$expectedCandidateDefinitionHash = $null
$expectedCandidateIndexSchemaHash = $null
try {
    $builderType = "$clientNamespace.SqlConnectionStringBuilder"
    if ($PSCmdlet.ParameterSetName -eq 'ConnectionString') {
        if ($SqlConnectionString.Length -eq 0) {
            throw 'SqlConnectionString must be a nonempty SecureString.'
        }
        $pointer = [IntPtr]::Zero
        $plainConnectionString = $null
        try {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlConnectionString)
            $plainConnectionString = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            $builder = New-Object -TypeName $builderType -ArgumentList $plainConnectionString
            $plainConnectionString = $null
        }
        finally {
            $plainConnectionString = $null
            if ($pointer -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
            }
        }
    }
    else {
        if ($null -eq $Credential -or [string]::IsNullOrWhiteSpace($Credential.UserName) -or
            $Credential.Password.Length -eq 0) {
            throw 'A nonempty DBA SQL credential is required.'
        }
        $builder = New-Object -TypeName $builderType
        $builder.DataSource = $ServerInstance
        $builder.InitialCatalog = $ExpectedDatabaseName
        $builder.UserID = $Credential.UserName
        $builder.IntegratedSecurity = $false
        $builder.Encrypt = $true
        $builder.TrustServerCertificate = $false
        if ($clientNamespace -eq 'Microsoft.Data.SqlClient') {
            $builder.HostNameInCertificate = $ExpectedServerName
        }
        $passwordPointer = [IntPtr]::Zero
        $plainPassword = $null
        try {
            $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
            $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
            $builder.Password = $plainPassword
            $plainPassword = $null
        }
        finally {
            $plainPassword = $null
            if ($passwordPointer -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
            }
        }
    }

    if ([string]$builder.DataSource -cne $ExpectedServerName) {
        throw 'The SQL connection DataSource must exactly match ExpectedServerName.'
    }
    if ([string]$builder.InitialCatalog -cne $ExpectedDatabaseName) {
        throw 'The SQL connection InitialCatalog must exactly match ExpectedDatabaseName.'
    }
    if (-not $builder.Encrypt -or $builder.TrustServerCertificate) {
        throw 'The SQL connection must specify Encrypt=True and TrustServerCertificate=False.'
    }
    if ($clientNamespace -eq 'Microsoft.Data.SqlClient') {
        if ([string]::IsNullOrWhiteSpace($builder.HostNameInCertificate)) {
            $builder.HostNameInCertificate = $ExpectedServerName
        }
        if ($builder.HostNameInCertificate -cne $ExpectedServerName) {
            throw 'HostNameInCertificate must exactly match ExpectedServerName.'
        }
    }
    $builder.ApplicationName = 'MCP-SQL-Workshop-Candidate-Approval'

    $connectionType = "$clientNamespace.SqlConnection"
    $connection = New-Object -TypeName $connectionType -ArgumentList $builder.ConnectionString
    $builder.Clear()
    $builder = $null
    $connection.Open()

    $precondition = [string](Invoke-WorkshopSqlCommand -Connection $connection -Scalar -CommandText @'
SELECT CONCAT(
    DB_NAME(), N'|',
    (SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID), N'|',
    CASE WHEN OBJECT_ID(N'lab.WorkshopMarker', N'U') IS NOT NULL
          AND EXISTS
          (
              SELECT 1 FROM lab.WorkshopMarker
              WHERE MarkerId = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C'
                AND SchemaVersion = 1
                AND SetupName = N'MCP SQL Query Store Workshop'
                AND SetupHash = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B
          ) THEN N'1' ELSE N'0' END, N'|',
    CASE WHEN OBJECT_ID(N'lab.usp_MonthEndSalesBaseline', N'P') IS NOT NULL THEN N'1' ELSE N'0' END
);
'@)
    if ($precondition -cne "$ExpectedDatabaseName|TRUE|1|1") {
        throw 'The encrypted target database, workshop marker, and baseline procedure preconditions were not verified.'
    }

    $applicationLockResult = [int](Invoke-WorkshopSqlCommand -Connection $connection -Scalar -CommandText @"
DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'$applicationLockResource',
    @LockMode = N'Exclusive',
    @LockOwner = N'Session',
    @LockTimeout = $applicationLockTimeoutMilliseconds,
    @DbPrincipal = N'public';
SELECT @LockResult;
"@)
    if ($applicationLockResult -lt 0) {
        throw "Exclusive candidate approval lock acquisition failed with result $applicationLockResult."
    }
    $applicationLockAcquired = $true

    $existingCandidateObjectCount = [long](Invoke-WorkshopSqlCommand -Connection $connection -Scalar -CommandText @'
SELECT
    CASE WHEN OBJECT_ID(N'lab.usp_MonthEndSalesOptimized', N'P') IS NULL THEN 0 ELSE 1 END
  + CASE WHEN INDEXPROPERTY(OBJECT_ID(N'lab.FactSales'), N'IX_FactSales_OrderDate_Territory', 'IndexId') IS NULL THEN 0 ELSE 1 END;
'@)
    if ($existingCandidateObjectCount -ne 0) {
        throw 'One or more candidate objects already exist; explicit review or cleanup is required before approval.'
    }

    Write-WorkshopSessionContext -Connection $connection -Key 'CandidateApprovalId' `
        -Value $candidateApprovalId.ToString('D') -ReadOnly
    Write-WorkshopSessionContext -Connection $connection -Key 'CandidateApprovalGranted' -Value 1 -ReadOnly

    $candidateChangesStarted = $true
    $scriptName = $scriptNames[0]
    $sqlText = Get-Content -LiteralPath (Join-Path $sqlDirectory $scriptName) -Raw -Encoding UTF8
    $sqlText = [regex]::Replace($sqlText, '(?im)^\s*:on\s+error\s+exit\s*(?:\r?\n|$)', '')
    foreach ($batch in @(Split-WorkshopSqlBatch -SqlText $sqlText)) {
        Invoke-WorkshopSqlCommand -Connection $connection -CommandText $batch
    }

    $candidateFingerprint = [string](Invoke-WorkshopSqlCommand -Connection $connection -Scalar -CommandText @'
DECLARE @CandidateProcedureId int = OBJECT_ID(N'lab.usp_MonthEndSalesOptimized', N'P');
DECLARE @CandidateIndexId int = INDEXPROPERTY(
    OBJECT_ID(N'lab.FactSales'), N'IX_FactSales_OrderDate_Territory', 'IndexId');
DECLARE @ExpectedCandidateDefinitionHash varbinary(32) = HASHBYTES(
    'SHA2_256',
    CONVERT(varbinary(max), OBJECT_DEFINITION(@CandidateProcedureId) COLLATE Latin1_General_100_BIN2)
);
DECLARE @CandidateIndexSchema nvarchar(max);
SELECT @CandidateIndexSchema = CONCAT(
    OBJECT_SCHEMA_NAME(index_entry.object_id), N'|', OBJECT_NAME(index_entry.object_id), N'|',
    index_entry.name, N'|', index_entry.type, N'|', index_entry.is_unique, N'|',
    index_entry.ignore_dup_key, N'|', index_entry.is_primary_key, N'|',
    index_entry.is_unique_constraint, N'|', index_entry.fill_factor, N'|', index_entry.is_padded, N'|',
    index_entry.is_disabled, N'|', index_entry.is_hypothetical, N'|', index_entry.allow_row_locks, N'|',
    index_entry.allow_page_locks, N'|', index_entry.has_filter, N'|',
    COALESCE(index_entry.filter_definition, N'<NULL>'), N'|', index_entry.data_space_id, N'|',
    COALESCE(CONVERT(nvarchar(20), index_entry.compression_delay), N'<NULL>'), N'|',
    index_entry.suppress_dup_key_messages, N'|', index_entry.optimize_for_sequential_key, N'|',
    STRING_AGG(CONVERT(nvarchar(max), CONCAT(
        index_column.index_column_id, N':', column_entry.column_id, N':', column_entry.name, N':',
        index_column.key_ordinal, N':', index_column.partition_ordinal, N':',
        index_column.is_descending_key, N':', index_column.is_included_column
    )), N';') WITHIN GROUP (ORDER BY index_column.index_column_id)
)
FROM sys.indexes AS index_entry
INNER JOIN sys.index_columns AS index_column
    ON index_column.object_id = index_entry.object_id AND index_column.index_id = index_entry.index_id
INNER JOIN sys.columns AS column_entry
    ON column_entry.object_id = index_column.object_id AND column_entry.column_id = index_column.column_id
WHERE index_entry.object_id = OBJECT_ID(N'lab.FactSales') AND index_entry.index_id = @CandidateIndexId
GROUP BY index_entry.object_id, index_entry.name, index_entry.type, index_entry.is_unique,
    index_entry.ignore_dup_key, index_entry.is_primary_key, index_entry.is_unique_constraint,
    index_entry.fill_factor, index_entry.is_padded, index_entry.is_disabled, index_entry.is_hypothetical,
    index_entry.allow_row_locks, index_entry.allow_page_locks, index_entry.has_filter,
    index_entry.filter_definition, index_entry.data_space_id, index_entry.compression_delay,
    index_entry.suppress_dup_key_messages, index_entry.optimize_for_sequential_key;
DECLARE @ExpectedCandidateIndexSchemaHash varbinary(32) = HASHBYTES(
    'SHA2_256', CONVERT(varbinary(max), @CandidateIndexSchema COLLATE Latin1_General_100_BIN2));
IF @ExpectedCandidateDefinitionHash IS NULL OR @ExpectedCandidateIndexSchemaHash IS NULL
    THROW 51702, 'Candidate fingerprints are unavailable immediately after creation.', 1;
SELECT CONCAT(
    CONVERT(varchar(64), @ExpectedCandidateDefinitionHash, 2), N'|',
    CONVERT(varchar(64), @ExpectedCandidateIndexSchemaHash, 2));
'@)
    $candidateFingerprintParts = @($candidateFingerprint -split '\|')
    if ($candidateFingerprintParts.Count -ne 2 -or
        $candidateFingerprintParts[0] -cnotmatch '^[0-9A-F]{64}$' -or
        $candidateFingerprintParts[1] -cnotmatch '^[0-9A-F]{64}$') {
        throw 'Candidate procedure or index fingerprint was not captured exactly after creation.'
    }
    $expectedCandidateDefinitionHash = $candidateFingerprintParts[0].ToUpperInvariant()
    $expectedCandidateIndexSchemaHash = $candidateFingerprintParts[1].ToUpperInvariant()

    $scriptName = $scriptNames[1]
    $sqlText = Get-Content -LiteralPath (Join-Path $sqlDirectory $scriptName) -Raw -Encoding UTF8
    $sqlText = [regex]::Replace($sqlText, '(?im)^\s*:on\s+error\s+exit\s*(?:\r?\n|$)', '')
    foreach ($batch in @(Split-WorkshopSqlBatch -SqlText $sqlText)) {
        Invoke-WorkshopSqlCommand -Connection $connection -CommandText $batch
    }

    # PassingCaseCount and ValidationPassed are bound to this connection's read-only CandidateApprovalId.
    $verification = [string](Invoke-WorkshopSqlCommand -Connection $connection -Scalar -CommandText @"
SELECT CONCAT(
    CASE WHEN OBJECT_ID(N'lab.usp_MonthEndSalesOptimized', N'P') IS NOT NULL THEN N'1' ELSE N'0' END, N'|',
    CASE WHEN INDEXPROPERTY(OBJECT_ID(N'lab.FactSales'), N'IX_FactSales_OrderDate_Territory', 'IndexId') IS NOT NULL THEN N'1' ELSE N'0' END, N'|',
    (SELECT CONVERT(nvarchar(20), COUNT_BIG(*)) FROM lab.ValidationRun WHERE ValidationBatchID = '$($candidateApprovalId.ToString('D'))'), N'|',
    (SELECT CONVERT(nvarchar(20), COUNT_BIG(*)) FROM lab.ValidationRun WHERE ValidationBatchID = '$($candidateApprovalId.ToString('D'))' AND Passed <> 1)
);
"@)
    $verificationParts = @($verification -split '\|')
    if ($verificationParts.Count -ne 4 -or $verificationParts[0] -cne '1' -or
        $verificationParts[1] -cne '1' -or [int]$verificationParts[2] -ne 11 -or
        [int]$verificationParts[3] -ne 0) {
        throw 'Candidate creation or equivalence ValidationPassed evidence was not positively verified.'
    }

    Invoke-WorkshopSqlCommand -Connection $connection -CommandText @"
DECLARE @MarkerId uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @DefinitionHash varbinary(32) = 0x$expectedCandidateDefinitionHash;
IF @DefinitionHash IS NULL
    THROW 51702, 'Candidate procedure ownership fingerprint is unavailable.', 1;
IF EXISTS
(
    SELECT 1 FROM WorkshopAdmin.dbo.LabObjectOwnership
    WHERE MarkerId = @MarkerId AND SchemaVersion = 1 AND DatabaseName = DB_NAME()
      AND ObjectName = N'usp_MonthEndSalesOptimized'
      AND (ObjectType <> 'P' OR DefinitionHash <> @DefinitionHash OR SchemaHash IS NOT NULL)
)
    THROW 51703, 'Candidate procedure ownership fingerprint does not match.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM WorkshopAdmin.dbo.LabObjectOwnership
    WHERE MarkerId = @MarkerId AND SchemaVersion = 1 AND DatabaseName = DB_NAME()
      AND ObjectName = N'usp_MonthEndSalesOptimized'
)
BEGIN
    INSERT WorkshopAdmin.dbo.LabObjectOwnership
        (MarkerId, SchemaVersion, DatabaseName, ObjectName, ObjectType, DefinitionHash, SchemaHash, RecordedAtUtc)
    VALUES
        (@MarkerId, 1, DB_NAME(), N'usp_MonthEndSalesOptimized', 'P', @DefinitionHash, NULL, SYSUTCDATETIME());
END;
"@

    [pscustomobject]@{
        Completed = $true
        CandidateApprovalId = $candidateApprovalId.ToString('D')
        Server = $ExpectedServerName
        Database = $ExpectedDatabaseName
        Scripts = $scriptNames
        CandidateExists = $true
        IndexExists = $true
        PassingCaseCount = [int]$verificationParts[2]
        ValidationStatus = 'ValidationPassed'
    }
}
catch {
    $approvalFailure = $_
    if ($candidateChangesStarted -and $null -ne $connection) {
        try {
            if ($expectedCandidateDefinitionHash -notmatch '^[0-9A-F]{64}$' -or
                $expectedCandidateIndexSchemaHash -notmatch '^[0-9A-F]{64}$') {
                throw 'Exact candidate fingerprints were not captured; cleanup ownership cannot be proven.'
            }
            Invoke-WorkshopSqlCommand -Connection $connection -CommandText @"
DECLARE @CandidateProcedureId int = OBJECT_ID(N'lab.usp_MonthEndSalesOptimized', N'P');
DECLARE @CandidateIndexId int = INDEXPROPERTY(OBJECT_ID(N'lab.FactSales'), N'IX_FactSales_OrderDate_Territory', 'IndexId');
DECLARE @ExpectedCandidateDefinitionHash varbinary(32) = 0x$expectedCandidateDefinitionHash;
DECLARE @ExpectedCandidateIndexSchemaHash varbinary(32) = 0x$expectedCandidateIndexSchemaHash;
DECLARE @CurrentCandidateDefinitionHash varbinary(32) = HASHBYTES(
    'SHA2_256',
    CONVERT(varbinary(max), OBJECT_DEFINITION(@CandidateProcedureId) COLLATE Latin1_General_100_BIN2)
);
DECLARE @CurrentCandidateIndexSchema nvarchar(max);
SELECT @CurrentCandidateIndexSchema = CONCAT(
    OBJECT_SCHEMA_NAME(index_entry.object_id), N'|', OBJECT_NAME(index_entry.object_id), N'|',
    index_entry.name, N'|', index_entry.type, N'|', index_entry.is_unique, N'|',
    index_entry.ignore_dup_key, N'|', index_entry.is_primary_key, N'|',
    index_entry.is_unique_constraint, N'|', index_entry.fill_factor, N'|', index_entry.is_padded, N'|',
    index_entry.is_disabled, N'|', index_entry.is_hypothetical, N'|', index_entry.allow_row_locks, N'|',
    index_entry.allow_page_locks, N'|', index_entry.has_filter, N'|',
    COALESCE(index_entry.filter_definition, N'<NULL>'), N'|', index_entry.data_space_id, N'|',
    COALESCE(CONVERT(nvarchar(20), index_entry.compression_delay), N'<NULL>'), N'|',
    index_entry.suppress_dup_key_messages, N'|', index_entry.optimize_for_sequential_key, N'|',
    STRING_AGG(CONVERT(nvarchar(max), CONCAT(
        index_column.index_column_id, N':', column_entry.column_id, N':', column_entry.name, N':',
        index_column.key_ordinal, N':', index_column.partition_ordinal, N':',
        index_column.is_descending_key, N':', index_column.is_included_column
    )), N';') WITHIN GROUP (ORDER BY index_column.index_column_id)
)
FROM sys.indexes AS index_entry
INNER JOIN sys.index_columns AS index_column
    ON index_column.object_id = index_entry.object_id AND index_column.index_id = index_entry.index_id
INNER JOIN sys.columns AS column_entry
    ON column_entry.object_id = index_column.object_id AND column_entry.column_id = index_column.column_id
WHERE index_entry.object_id = OBJECT_ID(N'lab.FactSales') AND index_entry.index_id = @CandidateIndexId
GROUP BY index_entry.object_id, index_entry.name, index_entry.type, index_entry.is_unique,
    index_entry.ignore_dup_key, index_entry.is_primary_key, index_entry.is_unique_constraint,
    index_entry.fill_factor, index_entry.is_padded, index_entry.is_disabled, index_entry.is_hypothetical,
    index_entry.allow_row_locks, index_entry.allow_page_locks, index_entry.has_filter,
    index_entry.filter_definition, index_entry.data_space_id, index_entry.compression_delay,
    index_entry.suppress_dup_key_messages, index_entry.optimize_for_sequential_key;
DECLARE @CurrentCandidateIndexSchemaHash varbinary(32) = HASHBYTES(
    'SHA2_256', CONVERT(varbinary(max), @CurrentCandidateIndexSchema COLLATE Latin1_General_100_BIN2));
IF @CandidateProcedureId IS NOT NULL
   AND (@CurrentCandidateDefinitionHash IS NULL
        OR @CurrentCandidateDefinitionHash <> @ExpectedCandidateDefinitionHash)
    THROW 51704, 'Candidate procedure drift detected; refusing compensating cleanup.', 1;
IF @CandidateIndexId IS NOT NULL
   AND (@CurrentCandidateIndexSchemaHash IS NULL
        OR @CurrentCandidateIndexSchemaHash <> @ExpectedCandidateIndexSchemaHash)
    THROW 51705, 'Candidate index drift detected; refusing compensating cleanup.', 1;
IF OBJECT_ID(N'lab.ValidationRun', N'U') IS NOT NULL
    DELETE lab.ValidationRun WHERE ValidationBatchID = '$($candidateApprovalId.ToString('D'))';
IF @CandidateProcedureId IS NOT NULL
    DROP PROCEDURE lab.usp_MonthEndSalesOptimized;
IF @CandidateIndexId IS NOT NULL
    DROP INDEX IX_FactSales_OrderDate_Territory ON lab.FactSales;
"@
        }
        catch {
            throw "Candidate approval failed and the script is refusing compensating cleanup: $($_.Exception.Message) Original failure: $($approvalFailure.Exception.Message)"
        }
    }
    throw $approvalFailure
}
finally {
    if ($null -ne $builder) { $builder.Clear() }
    if ($null -ne $connection) {
        $applicationLockReleaseFailure = $null
        if ($applicationLockAcquired) {
            $applicationLockAcquired = $false
            try {
                $applicationLockReleaseResult = [int](Invoke-WorkshopSqlCommand -Connection $connection -Scalar -CommandText @"
DECLARE @LockResult int;
EXEC @LockResult = sys.sp_releaseapplock
    @Resource = N'$applicationLockResource',
    @LockOwner = N'Session',
    @DbPrincipal = N'public';
SELECT @LockResult;
"@)
                if ($applicationLockReleaseResult -lt 0) {
                    throw "Exclusive candidate approval lock release failed with result $applicationLockReleaseResult."
                }
            }
            catch {
                $applicationLockReleaseFailure = $_
            }
        }
        $connection.Close()
        $connection.Dispose()
        if ($null -ne $applicationLockReleaseFailure) {
            throw $applicationLockReleaseFailure
        }
    }
}
