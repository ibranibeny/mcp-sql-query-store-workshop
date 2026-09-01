[CmdletBinding(DefaultParameterSetName = 'ConnectionString')]
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

    [Parameter(ParameterSetName = 'ConnectionString')]
    [Parameter(ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $DatabaseName = 'AdventureWorks2022',

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $BackupPath,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $DataPath,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $LogPath,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [Security.SecureString] $DatabaseMasterKeyPassword,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [Security.SecureString] $McpReaderPassword,

    [Parameter(ParameterSetName = 'ConnectionString')]
    [Parameter(ParameterSetName = 'Credential')]
    [ValidateRange(63000, 66000)]
    [long] $ExpectedPhysicalMemoryMB = 65536,

    [Parameter(ParameterSetName = 'ConnectionString')]
    [Parameter(ParameterSetName = 'Credential')]
    [ValidateRange(0, 2147483647)]
    [int] $MinimumFreeSpaceMB = 65536,

    [Parameter(ParameterSetName = 'ConnectionString')]
    [Parameter(ParameterSetName = 'Credential')]
    [ValidateNotNullOrEmpty()]
    [string] $SqlDirectory = (Join-Path $PSScriptRoot '../sql'),

    [Parameter(ParameterSetName = 'Functions')]
    [switch] $LoadFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Split-WorkshopSqlBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $SqlText
    )

    $batches = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $insideString = $false
    $insideBlockComment = $false
    $lines = [regex]::Matches($SqlText, '(?s).*?(?:\r\n|\n|\r|$)')

    foreach ($lineMatch in $lines) {
        $lineWithEnding = $lineMatch.Value
        if ($lineWithEnding.Length -eq 0) { continue }
        $line = $lineWithEnding.TrimEnd("`r", "`n")
        $separator = $null
        if (-not $insideString -and -not $insideBlockComment) {
            $separator = [regex]::Match(
                $line,
                '^\s*GO(?:\s+(?<count>\d+))?\s*(?:(?:--.*)|(?:/\*.*\*/\s*))?$',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }

        if ($null -ne $separator -and $separator.Success) {
            $batch = $current.ToString().Trim()
            $null = $current.Clear()
            if ($batch.Length -gt 0) {
                $repeatCount = if ($separator.Groups['count'].Success) {
                    [int] $separator.Groups['count'].Value
                }
                else { 1 }
                if ($repeatCount -lt 1 -or $repeatCount -gt 1000) {
                    throw 'GO repeat count must be between 1 and 1000.'
                }
                for ($repeat = 0; $repeat -lt $repeatCount; $repeat++) {
                    $batches.Add($batch)
                }
            }
            continue
        }

        $null = $current.Append($lineWithEnding)
        for ($index = 0; $index -lt $line.Length; $index++) {
            $character = $line[$index]
            $next = if ($index + 1 -lt $line.Length) { $line[$index + 1] } else { [char] 0 }
            if ($insideString) {
                if ($character -eq "'") {
                    if ($next -eq "'") { $index++ } else { $insideString = $false }
                }
                continue
            }
            if ($insideBlockComment) {
                if ($character -eq '*' -and $next -eq '/') {
                    $insideBlockComment = $false
                    $index++
                }
                continue
            }
            if ($character -eq '-' -and $next -eq '-') { break }
            if ($character -eq '/' -and $next -eq '*') {
                $insideBlockComment = $true
                $index++
                continue
            }
            if ($character -eq "'") { $insideString = $true }
        }
    }

    if ($insideString -or $insideBlockComment) {
        throw 'SQL text ends inside an unterminated string or block comment.'
    }
    $lastBatch = $current.ToString().Trim()
    if ($lastBatch.Length -gt 0) { $batches.Add($lastBatch) }
    return $batches.ToArray()
}

function Write-WorkshopSessionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Connection,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Key,
        [Parameter(Mandatory)] [AllowNull()] [object] $Value
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = 'EXEC sys.sp_set_session_context @key = @ContextKey, @value = @ContextValue, @read_only = 0;'
        $null = $command.Parameters.Add('@ContextKey', [System.Data.SqlDbType]::NVarChar, 128)
        $command.Parameters['@ContextKey'].Value = $Key
        if ($Value -is [Security.SecureString]) {
            $pointer = [IntPtr]::Zero
            $plainText = $null
            try {
                $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
                $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
                $null = $command.Parameters.Add('@ContextValue', [System.Data.SqlDbType]::NVarChar, 4000)
                $command.Parameters['@ContextValue'].Value = $plainText
                $plainText = $null
            }
            finally {
                $plainText = $null
                if ($pointer -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
                }
            }
        }
        else {
            $parameter = $command.Parameters.AddWithValue('@ContextValue', $Value)
            if ($null -eq $Value) { $parameter.Value = [DBNull]::Value }
        }
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-WorkshopSqlCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Connection,
        [Parameter(Mandatory)] [string] $CommandText,
        [switch] $Scalar
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $CommandText
        $command.CommandTimeout = 0
        if ($Scalar) { return $command.ExecuteScalar() }
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

if ($LoadFunctionsOnly) { return }

$scriptNames = @(
    '00-Preflight.sql',
    '01-ConfigureInstance.sql',
    '02-RestoreAndConfigureDatabase.sql',
    '03-CreateScaledLabData.sql',
    '04-CreateBaselineProcedure.sql',
    '05-CreateDiagnostics.sql',
    '06-CreateOptimizedProcedure.sql',
    '07-ValidateEquivalence.sql'
)
foreach ($scriptName in $scriptNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $SqlDirectory $scriptName) -PathType Leaf)) {
        throw "Required workshop SQL script is missing: $scriptName"
    }
}
if ($DatabaseMasterKeyPassword.Length -eq 0 -or $McpReaderPassword.Length -eq 0) {
    throw 'Database master key and MCP reader passwords must be nonempty SecureString values.'
}

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
try {
    if ($PSCmdlet.ParameterSetName -eq 'ConnectionString') {
        $pointer = [IntPtr]::Zero
        $plainConnectionString = $null
        try {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlConnectionString)
            $plainConnectionString = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            $builderType = "$clientNamespace.SqlConnectionStringBuilder"
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
        if ($null -eq $Credential -or [string]::IsNullOrWhiteSpace($Credential.UserName) -or $Credential.Password.Length -eq 0) {
            throw 'A nonempty SQL credential is required.'
        }
        $builderType = "$clientNamespace.SqlConnectionStringBuilder"
        $builder = New-Object -TypeName $builderType
        $builder.DataSource = $ServerInstance
        $builder.InitialCatalog = 'master'
        $builder.UserID = $Credential.UserName
        $builder.IntegratedSecurity = $false
        $builder.Encrypt = $true
        $builder.TrustServerCertificate = $false
        if ($clientNamespace -eq 'Microsoft.Data.SqlClient') {
            $builder.HostNameInCertificate = $ExpectedServerName
        }
        $builder.ApplicationName = 'MCP-SQL-Workshop-Setup'
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
    else {
        $serverName = ([string]$builder.DataSource -split ',')[0].Trim()
        if ($serverName -cne $ExpectedServerName) {
            throw 'System.Data.SqlClient fallback requires DataSource to exactly match ExpectedServerName for certificate DNS validation.'
        }
    }
    $builder.InitialCatalog = 'master'

    $connectionType = "$clientNamespace.SqlConnection"
    $connection = New-Object -TypeName $connectionType -ArgumentList $builder.ConnectionString
    $builder.Clear()
    $builder = $null
    $connection.Open()

    Write-WorkshopSessionContext -Connection $connection -Key 'ExpectedServerName' -Value $ExpectedServerName
    Write-WorkshopSessionContext -Connection $connection -Key 'DatabaseName' -Value $DatabaseName
    Write-WorkshopSessionContext -Connection $connection -Key 'PreflightPhase' -Value 'Infrastructure'
    Write-WorkshopSessionContext -Connection $connection -Key 'ExpectedPhysicalMemoryMB' -Value $ExpectedPhysicalMemoryMB
    Write-WorkshopSessionContext -Connection $connection -Key 'PlannedRestorePath' -Value $BackupPath
    Write-WorkshopSessionContext -Connection $connection -Key 'PlannedDataPath' -Value $DataPath
    Write-WorkshopSessionContext -Connection $connection -Key 'MinimumFreeSpaceMB' -Value $MinimumFreeSpaceMB
    Write-WorkshopSessionContext -Connection $connection -Key 'BackupPath' -Value $BackupPath
    Write-WorkshopSessionContext -Connection $connection -Key 'DataPath' -Value $DataPath
    Write-WorkshopSessionContext -Connection $connection -Key 'LogPath' -Value $LogPath

    $escapedBackupPath = $BackupPath.Replace("'", "''")
    Invoke-WorkshopSqlCommand -Connection $connection `
        -CommandText "RESTORE VERIFYONLY FROM DISK = N'$escapedBackupPath' WITH CHECKSUM;"

    foreach ($scriptName in $scriptNames) {
        $sqlText = Get-Content -LiteralPath (Join-Path $SqlDirectory $scriptName) -Raw -Encoding UTF8
        $scriptBatches = @(Split-WorkshopSqlBatch -SqlText $sqlText)
        if ($scriptName -eq '03-CreateScaledLabData.sql') {
            $connection.ChangeDatabase($DatabaseName)
        }
        if ($scriptName -eq '05-CreateDiagnostics.sql') {
            Write-WorkshopSessionContext -Connection $connection -Key 'DiagnosticsSetupAuthorized' -Value 1
            Write-WorkshopSessionContext -Connection $connection -Key 'DatabaseMasterKeyPassword' -Value $DatabaseMasterKeyPassword
            $masterKeyCommand = @'
DECLARE @MasterKeyPassword nvarchar(4000) =
    TRY_CONVERT(nvarchar(4000), SESSION_CONTEXT(N'DatabaseMasterKeyPassword'));
IF @MasterKeyPassword IS NULL OR LEN(@MasterKeyPassword) NOT BETWEEN 20 AND 128
    THROW 51700, 'A valid database master key password is required.', 1;
BEGIN TRY
    DECLARE @MasterKeySql nvarchar(max);
    IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
        SET @MasterKeySql = N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'''
            + REPLACE(@MasterKeyPassword, N'''', N'''''') + N'''';
    ELSE IF NOT EXISTS (SELECT 1 FROM sys.openkeys WHERE key_name = N'##MS_DatabaseMasterKey##')
        SET @MasterKeySql = N'OPEN MASTER KEY DECRYPTION BY PASSWORD = N'''
            + REPLACE(@MasterKeyPassword, N'''', N'''''') + N'''';
    IF @MasterKeySql IS NOT NULL EXEC sys.sp_executesql @MasterKeySql;
    SET @MasterKeySql = NULL;
    SET @MasterKeyPassword = NULL;
    EXEC sys.sp_set_session_context @key = N'DatabaseMasterKeyPassword', @value = NULL, @read_only = 0;
END TRY
BEGIN CATCH
    SET @MasterKeySql = NULL;
    SET @MasterKeyPassword = NULL;
    EXEC sys.sp_set_session_context @key = N'DatabaseMasterKeyPassword', @value = NULL, @read_only = 0;
    THROW;
END CATCH;
'@
            Invoke-WorkshopSqlCommand -Connection $connection -CommandText $masterKeyCommand
            $masterKeyCount = Invoke-WorkshopSqlCommand -Connection $connection -Scalar -CommandText "SELECT COUNT_BIG(*) FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##';"
            if ([long] $masterKeyCount -ne 1) {
                throw 'Database master key creation or opening could not be verified.'
            }
            Write-WorkshopSessionContext -Connection $connection -Key 'DatabaseMasterKeyReady' -Value 1
            Write-WorkshopSessionContext -Connection $connection -Key 'McpReaderPassword' -Value $McpReaderPassword
        }

        foreach ($batch in $scriptBatches) {
            Invoke-WorkshopSqlCommand -Connection $connection -CommandText $batch
        }
    }

    $finalizeLabOwnershipCommand = @'
DECLARE @MarkerId uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @SchemaVersion int = 1;
DECLARE @CurrentLabObjects table
(
    ObjectName sysname NOT NULL PRIMARY KEY, ObjectType char(2) NOT NULL,
    DefinitionHash varbinary(32) NULL, SchemaHash varbinary(32) NULL
);
INSERT @CurrentLabObjects (ObjectName, ObjectType, DefinitionHash, SchemaHash)
SELECT object_entry.name, object_entry.type,
       CASE WHEN module.definition IS NULL THEN NULL ELSE HASHBYTES('SHA2_256', CONVERT(varbinary(max), module.definition COLLATE Latin1_General_100_BIN2)) END,
       CASE WHEN object_entry.type <> 'U' THEN NULL ELSE HASHBYTES('SHA2_256', CONVERT(varbinary(max), columns_shape.SchemaDefinition COLLATE Latin1_General_100_BIN2)) END
FROM sys.objects AS object_entry
INNER JOIN sys.schemas AS object_schema ON object_schema.schema_id = object_entry.schema_id
LEFT JOIN sys.sql_modules AS module ON module.object_id = object_entry.object_id
OUTER APPLY
(
    SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(column_entry.column_id, N'|', column_entry.name, N'|', TYPE_NAME(column_entry.user_type_id), N'|', column_entry.max_length, N'|', column_entry.precision, N'|', column_entry.scale, N'|', column_entry.is_nullable, N'|', column_entry.is_identity)), N';') WITHIN GROUP (ORDER BY column_entry.column_id) AS SchemaDefinition
    FROM sys.columns AS column_entry WHERE column_entry.object_id = object_entry.object_id
) AS columns_shape
WHERE object_schema.name = N'lab' AND object_entry.is_ms_shipped = 0 AND object_entry.type IN ('U', 'V', 'P');
IF EXISTS
(
    SELECT ObjectName, ObjectType, DefinitionHash, SchemaHash FROM @CurrentLabObjects
    EXCEPT
    SELECT ObjectName, ObjectType, DefinitionHash, SchemaHash FROM WorkshopAdmin.dbo.LabObjectOwnership
    WHERE MarkerId = @MarkerId AND SchemaVersion = @SchemaVersion AND DatabaseName = DB_NAME()
)
AND EXISTS (SELECT 1 FROM WorkshopAdmin.dbo.LabObjectOwnership WHERE MarkerId = @MarkerId AND SchemaVersion = @SchemaVersion AND DatabaseName = DB_NAME())
    THROW 51701, 'Existing lab object ownership fingerprints do not match finalized objects.', 1;
INSERT WorkshopAdmin.dbo.LabObjectOwnership
    (MarkerId, SchemaVersion, DatabaseName, ObjectName, ObjectType, DefinitionHash, SchemaHash, RecordedAtUtc)
SELECT @MarkerId, @SchemaVersion, DB_NAME(), current_object.ObjectName, current_object.ObjectType,
       current_object.DefinitionHash, current_object.SchemaHash, SYSUTCDATETIME()
FROM @CurrentLabObjects AS current_object
WHERE NOT EXISTS
(
    SELECT 1 FROM WorkshopAdmin.dbo.LabObjectOwnership AS ownership
    WHERE ownership.MarkerId = @MarkerId AND ownership.SchemaVersion = @SchemaVersion
      AND ownership.DatabaseName = DB_NAME() AND ownership.ObjectName = current_object.ObjectName
);
'@
    Invoke-WorkshopSqlCommand -Connection $connection -CommandText $finalizeLabOwnershipCommand
}
finally {
    if ($null -ne $builder) { $builder.Clear() }
    if ($null -ne $connection) {
        $connection.Close()
        $connection.Dispose()
    }
}
