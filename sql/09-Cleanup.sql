:on error exit
/*
Restores the configuration captured by 01-ConfigureInstance.sql and removes only
objects whose exact workshop ownership can be proved. The caller sets ExpectedServerName,
DatabaseName, and optional DropLabData (bit, default 0) with session context. The default
preserves lab tables and procedures for a rerun while removing temporary hints, access
identities, signatures/certificates, Resource Governor objects, and active configuration.
Public certificate export files cannot be removed by T-SQL; bootstrap cleanup must remove
the reported mcp_workshop_diagnostics_*.cer path. No operating-system command execution is used.
*/
IF @@TRANCOUNT <> 0
    THROW 51900, 'Cleanup cannot run inside an active transaction.', 1;

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExpectedServerName nvarchar(256) = NULLIF(LOWER(LTRIM(RTRIM(TRY_CONVERT(nvarchar(256), SESSION_CONTEXT(N'ExpectedServerName'))))), N'');
DECLARE @DatabaseName sysname = NULLIF(LTRIM(RTRIM(TRY_CONVERT(sysname, SESSION_CONTEXT(N'DatabaseName')))), N'');
DECLARE @DropLabDataValue sql_variant = SESSION_CONTEXT(N'DropLabData');
DECLARE @DropLabData bit = COALESCE(TRY_CONVERT(bit, @DropLabDataValue), 0);
DECLARE @CleanupRunIdValue sql_variant = SESSION_CONTEXT(N'CleanupRunId');
DECLARE @CleanupRunId uniqueidentifier = TRY_CONVERT(uniqueidentifier, @CleanupRunIdValue);
DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupHash varbinary(32) = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B;
DECLARE @ActualMachine nvarchar(256) = LOWER(LTRIM(RTRIM(CONVERT(nvarchar(256), SERVERPROPERTY('MachineName')))));
DECLARE @ActualServer nvarchar(256) = LOWER(LTRIM(RTRIM(CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')))));
DECLARE @ExpectedHost nvarchar(256) = @ExpectedServerName;
DECLARE @ApplicationLockResult int;
DECLARE @LockHeld bit = 0;
DECLARE @CleanupAuditId bigint = NULL;
DECLARE @RestorationErrors nvarchar(max) = N'';

IF @ExpectedServerName IS NULL THROW 51901, 'ExpectedServerName is required.', 1;
IF @DatabaseName IS NULL OR @DatabaseName <> N'AdventureWorks2022' OR DB_NAME() <> N'AdventureWorks2022'
    THROW 51902, 'The current and requested database must be exactly AdventureWorks2022.', 1;
IF TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 16
    THROW 51903, 'SQL Server 2022 is required.', 1;
IF @DropLabDataValue IS NOT NULL
    AND (SQL_VARIANT_PROPERTY(@DropLabDataValue, 'BaseType') <> N'bit'
          OR TRY_CONVERT(int, @DropLabDataValue) IS NULL
        OR TRY_CONVERT(int, @DropLabDataValue) NOT IN (0, 1))
    THROW 51904, 'DropLabData must be exactly 0 or 1.', 1;
IF @DropLabData NOT IN (0, 1)
    THROW 51905, 'DropLabData must be 0 or 1.', 1;
IF @CleanupRunIdValue IS NOT NULL
   AND (SQL_VARIANT_PROPERTY(@CleanupRunIdValue, 'BaseType') <> N'uniqueidentifier'
        OR @CleanupRunId IS NULL)
    THROW 51932, 'CleanupRunId must be an exact uniqueidentifier session-context value.', 1;
IF CHARINDEX(N'\', @ExpectedHost) > 0 SET @ExpectedHost = LEFT(@ExpectedHost, CHARINDEX(N'\', @ExpectedHost) - 1);
IF CHARINDEX(N'.', @ExpectedHost) > 0 SET @ExpectedHost = LEFT(@ExpectedHost, CHARINDEX(N'.', @ExpectedHost) - 1);
IF CHARINDEX(N'\', @ActualServer) > 0 SET @ActualServer = LEFT(@ActualServer, CHARINDEX(N'\', @ActualServer) - 1);
IF CHARINDEX(N'.', @ActualServer) > 0 SET @ActualServer = LEFT(@ActualServer, CHARINDEX(N'.', @ActualServer) - 1);
IF CHARINDEX(N'.', @ActualMachine) > 0 SET @ActualMachine = LEFT(@ActualMachine, CHARINDEX(N'.', @ActualMachine) - 1);
IF @ExpectedHost NOT IN (@ActualMachine, @ActualServer)
    THROW 51906, 'ExpectedServerName does not match this SQL Server host.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM master.sys.extended_properties
    WHERE class = 0 AND name = N'MCP_SQL_WORKSHOP'
      AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
)
    THROW 51907, 'The exact server workshop marker is absent.', 1;
IF OBJECT_ID(N'lab.WorkshopMarker', N'U') IS NULL OR NOT EXISTS
(
    SELECT 1 FROM lab.WorkshopMarker
    WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
      AND SetupName = @WorkshopSetupName AND SetupHash = @WorkshopSetupHash
)
    THROW 51908, 'The exact database workshop marker is absent.', 1;
IF DB_ID(N'WorkshopAdmin') IS NULL OR NOT EXISTS
(
    SELECT 1 FROM WorkshopAdmin.sys.extended_properties
    WHERE class = 0 AND name = N'MCP_SQL_WORKSHOP'
      AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
)
    THROW 51909, 'The exact WorkshopAdmin ownership marker is absent.', 1;
IF OBJECT_ID(N'WorkshopAdmin.dbo.ConfigurationBackup', N'U') IS NULL
   OR OBJECT_ID(N'WorkshopAdmin.dbo.DatabaseConfigurationBackup', N'U') IS NULL
   OR OBJECT_ID(N'WorkshopAdmin.dbo.ResourceGovernorObjectOwnership', N'U') IS NULL
    THROW 51910, 'Required configuration backup metadata is absent.', 1;
IF (SELECT COUNT(*) FROM WorkshopAdmin.dbo.ConfigurationBackup
    WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion) <> 1
   OR (SELECT COUNT(*) FROM WorkshopAdmin.dbo.DatabaseConfigurationBackup
       WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
         AND DatabaseName = @DatabaseName) <> 1
    THROW 51911, 'Exactly one server and database configuration backup is required.', 1;
DECLARE @QueryStoreIsReadWrite bit = CASE WHEN EXISTS
(
    SELECT 1 FROM sys.database_query_store_options
    WHERE actual_state_desc = N'READ_WRITE' AND desired_state_desc = N'READ_WRITE'
) THEN 1 ELSE 0 END;
DECLARE @OwnedActiveHintCount int = 0;
IF OBJECT_ID(N'WorkshopAdmin.dbo.QueryStoreHintOwnership', N'U') IS NOT NULL
    SELECT @OwnedActiveHintCount = COUNT(*)
    FROM WorkshopAdmin.dbo.QueryStoreHintOwnership
    WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
      AND DatabaseName = DB_NAME() AND OwnershipState IN ('Pending', 'Active');
IF @OwnedActiveHintCount > 0 AND @QueryStoreIsReadWrite <> 1
    THROW 51924, 'Query Store must be READ_WRITE while a workshop-owned hint requires clearing.', 1;

EXEC @ApplicationLockResult = sys.sp_getapplock
    @Resource = N'MCP_SQL_WORKSHOP_LIFECYCLE',
    @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0;
IF @ApplicationLockResult < 0
    THROW 51912, 'Another workshop cleanup is active.', 1;
SET @LockHeld = 1;

BEGIN TRY

IF OBJECT_ID(N'WorkshopAdmin.dbo.CleanupAudit', N'U') IS NULL
BEGIN
    EXEC WorkshopAdmin.sys.sp_executesql N'
        CREATE TABLE dbo.CleanupAudit
        (
            CleanupAuditId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_CleanupAudit PRIMARY KEY,
            MarkerId uniqueidentifier NOT NULL,
            SchemaVersion int NOT NULL,
            DatabaseName sysname NOT NULL,
            DropLabData bit NOT NULL,
            StartedAtUtc datetime2(3) NOT NULL,
            CompletedAtUtc datetime2(3) NULL,
            Outcome varchar(16) NOT NULL,
            ErrorNumber int NULL
        );';
END;

INSERT WorkshopAdmin.dbo.CleanupAudit
    (MarkerId, SchemaVersion, DatabaseName, DropLabData, StartedAtUtc, Outcome)
VALUES
    (@WorkshopMarker, @WorkshopSchemaVersion, @DatabaseName, @DropLabData, SYSUTCDATETIME(), 'Running');
SET @CleanupAuditId = SCOPE_IDENTITY();

DECLARE @BackupShowAdvancedOptions int;
DECLARE @BackupMaxServerMemoryMB int;
DECLARE @BackupMinServerMemoryMB int;
DECLARE @BackupResourceGovernorEnabled bit;
DECLARE @BackupClassifierFunctionId int;
DECLARE @BackupClassifierSchema sysname;
DECLARE @BackupClassifierName sysname;
DECLARE @BackupQueryStoreActualStateDesc nvarchar(60);
DECLARE @BackupQueryStoreDesiredStateDesc nvarchar(60);
DECLARE @BackupQueryStoreMaxStorageSizeMB bigint;
DECLARE @BackupQueryStoreCaptureModeDesc nvarchar(60);
DECLARE @BackupQueryStoreStaleQueryThresholdDays bigint;
DECLARE @BackupQueryStoreFlushIntervalSeconds bigint;
DECLARE @BackupQueryStoreIntervalLengthMinutes bigint;
DECLARE @BackupQueryStoreSizeBasedCleanupModeDesc nvarchar(60);
DECLARE @BackupQueryStoreWaitStatsCaptureModeDesc nvarchar(60);
DECLARE @BackupCompatibilityLevel tinyint;
DECLARE @BackupRowModeMemoryGrantFeedback int;
DECLARE @BackupRowModeMemoryGrantFeedbackForSecondary int;
DECLARE @BackupBatchModeMemoryGrantFeedback int;
DECLARE @BackupBatchModeMemoryGrantFeedbackForSecondary int;
DECLARE @BackupMemoryGrantFeedbackPercentileGrant int;
DECLARE @BackupMemoryGrantFeedbackPercentileGrantForSecondary int;
DECLARE @BackupMemoryGrantFeedbackPersistence int;
DECLARE @BackupMemoryGrantFeedbackPersistenceForSecondary int;

SELECT @BackupShowAdvancedOptions = ShowAdvancedOptions,
       @BackupMaxServerMemoryMB = MaxServerMemoryMB,
       @BackupMinServerMemoryMB = MinServerMemoryMB,
       @BackupResourceGovernorEnabled = ResourceGovernorEnabled,
       @BackupClassifierFunctionId = ClassifierFunctionId,
       @BackupClassifierSchema = ClassifierFunctionSchema,
       @BackupClassifierName = ClassifierFunctionName
FROM WorkshopAdmin.dbo.ConfigurationBackup
WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion;

SELECT @BackupQueryStoreActualStateDesc = QueryStoreActualStateDesc,
       @BackupQueryStoreDesiredStateDesc = QueryStoreDesiredStateDesc,
       @BackupQueryStoreMaxStorageSizeMB = QueryStoreMaxStorageSizeMB,
       @BackupQueryStoreCaptureModeDesc = QueryStoreCaptureModeDesc,
    @BackupQueryStoreStaleQueryThresholdDays = QueryStoreStaleQueryThresholdDays,
    @BackupQueryStoreFlushIntervalSeconds = QueryStoreFlushIntervalSeconds,
    @BackupQueryStoreIntervalLengthMinutes = QueryStoreIntervalLengthMinutes,
    @BackupQueryStoreSizeBasedCleanupModeDesc = QueryStoreSizeBasedCleanupModeDesc,
    @BackupQueryStoreWaitStatsCaptureModeDesc = QueryStoreWaitStatsCaptureModeDesc,
    @BackupCompatibilityLevel = CompatibilityLevel,
       @BackupRowModeMemoryGrantFeedback = RowModeMemoryGrantFeedback,
       @BackupRowModeMemoryGrantFeedbackForSecondary = RowModeMemoryGrantFeedbackForSecondary,
       @BackupBatchModeMemoryGrantFeedback = BatchModeMemoryGrantFeedback,
       @BackupBatchModeMemoryGrantFeedbackForSecondary = BatchModeMemoryGrantFeedbackForSecondary,
       @BackupMemoryGrantFeedbackPercentileGrant = MemoryGrantFeedbackPercentileGrant,
       @BackupMemoryGrantFeedbackPercentileGrantForSecondary = MemoryGrantFeedbackPercentileGrantForSecondary,
       @BackupMemoryGrantFeedbackPersistence = MemoryGrantFeedbackPersistence,
       @BackupMemoryGrantFeedbackPersistenceForSecondary = MemoryGrantFeedbackPersistenceForSecondary
FROM WorkshopAdmin.dbo.DatabaseConfigurationBackup
WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
  AND DatabaseName = @DatabaseName;

     /* Snapshot only active, known workshop runs. An explicit CleanupRunId restricts the
         snapshot to one run; otherwise only persisted Running runs are eligible. */
    DECLARE @SessionsToKill table
    (
        KillOrdinal int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        SessionId smallint NOT NULL UNIQUE,
        RunId uniqueidentifier NOT NULL
    );
    INSERT @SessionsToKill (SessionId, RunId)
        SELECT session.session_id, runMarker.RunId
    FROM sys.dm_exec_sessions AS session
        INNER JOIN sys.dm_exec_requests AS request ON request.session_id = session.session_id
    CROSS APPLY
    (
        SELECT TRY_CONVERT(uniqueidentifier,
            CONVERT(binary(16), SUBSTRING(session.context_info, 1, 16))) AS RunId
    ) AS runMarker
    WHERE session.is_user_process = 1
      AND session.session_id <> @@SPID
      AND runMarker.RunId IS NOT NULL
            AND (@CleanupRunId IS NULL OR runMarker.RunId = @CleanupRunId)
            AND EXISTS
            (
                    SELECT 1 FROM lab.WorkshopRun AS known_run
                    WHERE known_run.RunID = runMarker.RunId
                        AND (@CleanupRunId IS NOT NULL OR known_run.RunStatus = 'Running')
            )
            AND
            (
                    session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Baseline-1'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Baseline-2'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Baseline-3'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Baseline-4'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Optimized-1'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Optimized-2'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Optimized-3'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Optimized-4'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Comparison-1'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Comparison-2'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Comparison-3'
                    OR session.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), runMarker.RunId) + N'-Comparison-4'
            )
    ORDER BY session.session_id;

    DECLARE @KillOrdinal int = 1;
    DECLARE @KillCount int = (SELECT COUNT(*) FROM @SessionsToKill);
        IF @KillCount > 100
                THROW 51933, 'Cleanup refuses to terminate more than 100 candidate sessions.', 1;
    DECLARE @KillSessionId smallint;
    DECLARE @KillRunId uniqueidentifier;
    WHILE @KillOrdinal <= @KillCount
    BEGIN
        SELECT @KillSessionId = SessionId, @KillRunId = RunId
        FROM @SessionsToKill WHERE KillOrdinal = @KillOrdinal;
        IF EXISTS
        (
            SELECT 1 FROM sys.dm_exec_sessions AS currentSession
            INNER JOIN sys.dm_exec_requests AS currentRequest
                ON currentRequest.session_id = currentSession.session_id
            CROSS APPLY
            (
                SELECT TRY_CONVERT(uniqueidentifier,
                    CONVERT(binary(16), SUBSTRING(currentSession.context_info, 1, 16))) AS RunId
            ) AS currentMarker
            WHERE currentSession.session_id = @KillSessionId
              AND currentSession.session_id <> @@SPID
              AND currentSession.is_user_process = 1
              AND currentMarker.RunId IS NOT NULL
              AND currentMarker.RunId = @KillRunId
              AND (@CleanupRunId IS NULL OR currentMarker.RunId = @CleanupRunId)
              AND EXISTS
              (
                  SELECT 1 FROM lab.WorkshopRun AS current_known_run
                  WHERE current_known_run.RunID = currentMarker.RunId
                    AND (@CleanupRunId IS NOT NULL OR current_known_run.RunStatus = 'Running')
              )
              AND
              (
                  currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Baseline-1'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Baseline-2'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Baseline-3'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Baseline-4'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Optimized-1'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Optimized-2'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Optimized-3'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Optimized-4'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Comparison-1'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Comparison-2'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Comparison-3'
                  OR currentSession.program_name COLLATE Latin1_General_100_BIN2 = N'MCP-SQL-Workshop-' + CONVERT(nvarchar(36), currentMarker.RunId) + N'-Comparison-4'
              )
        )
        BEGIN
            DECLARE @KillSql nvarchar(32) = N'KILL ' + CONVERT(nvarchar(11), @KillSessionId) + N';';
            EXEC sys.sp_executesql @KillSql;
        END;
        SET @KillOrdinal += 1;
    END;

    /* Clear only exact Query Store hints recorded under the workshop marker. */
    IF OBJECT_ID(N'WorkshopAdmin.dbo.QueryStoreHintOwnership', N'U') IS NOT NULL
    BEGIN
        DECLARE @OwnedHints table
        (
            HintOrdinal int IDENTITY(1,1) NOT NULL PRIMARY KEY,
            QueryId bigint NOT NULL UNIQUE
        );
        INSERT @OwnedHints (QueryId)
        SELECT TOP (100) ownership.QueryId
        FROM WorkshopAdmin.dbo.QueryStoreHintOwnership AS ownership
        INNER JOIN sys.query_store_query_hints AS hint ON hint.query_id = ownership.QueryId
        WHERE ownership.MarkerId = @WorkshopMarker
          AND ownership.SchemaVersion = @WorkshopSchemaVersion
          AND ownership.DatabaseName = DB_NAME()
          AND ownership.OwnershipState IN ('Pending', 'Active')
          AND ownership.HintHash = HASHBYTES('SHA2_256', CONVERT(varbinary(max), N'OPTION(MAX_GRANT_PERCENT=10)'))
          AND UPPER(REPLACE(REPLACE(REPLACE(REPLACE(hint.query_hint_text, N' ', N''), NCHAR(9), N''), NCHAR(10), N''), NCHAR(13), N'')) = N'OPTION(MAX_GRANT_PERCENT=10)'
        ORDER BY ownership.QueryId;

        DECLARE @HintOrdinal int = 1;
        DECLARE @HintCount int = (SELECT COUNT(*) FROM @OwnedHints);
        DECLARE @OwnedQueryId bigint;
        WHILE @HintOrdinal <= @HintCount
        BEGIN
            SELECT @OwnedQueryId = QueryId FROM @OwnedHints WHERE HintOrdinal = @HintOrdinal;
            IF NOT EXISTS
            (
                SELECT 1 FROM sys.query_store_query_hints AS hint
                INNER JOIN WorkshopAdmin.dbo.QueryStoreHintOwnership AS ownership
                    ON ownership.QueryId = hint.query_id
                INNER JOIN sys.query_store_query AS stored_query
                    ON stored_query.query_id = hint.query_id
                INNER JOIN sys.query_store_query_text AS stored_text
                    ON stored_text.query_text_id = stored_query.query_text_id
                WHERE hint.query_id = @OwnedQueryId
                  AND ownership.MarkerId = @WorkshopMarker
                  AND ownership.SchemaVersion = @WorkshopSchemaVersion
                  AND ownership.DatabaseName = DB_NAME()
                  AND ownership.OwnershipState IN ('Pending', 'Active')
                  AND ownership.QueryContextSettingsId = stored_query.query_context_settings_id
                  AND ownership.QueryHash = stored_query.query_hash
                  AND ownership.QueryTextHash = HASHBYTES('SHA2_256', CONVERT(varbinary(max),
                      UPPER(REPLACE(REPLACE(REPLACE(stored_text.query_sql_text, NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''))))
                  AND ownership.HintHash = HASHBYTES('SHA2_256', CONVERT(varbinary(max), N'OPTION(MAX_GRANT_PERCENT=10)'))
                  AND UPPER(REPLACE(REPLACE(REPLACE(REPLACE(hint.query_hint_text, N' ', N''), NCHAR(9), N''), NCHAR(10), N''), NCHAR(13), N'')) = N'OPTION(MAX_GRANT_PERCENT=10)'
            )
                THROW 51925, 'Hint ownership changed before clear; refusing to clear a possibly foreign hint.', 1;
            EXEC sys.sp_query_store_clear_hints @query_id = @OwnedQueryId;
            UPDATE WorkshopAdmin.dbo.QueryStoreHintOwnership
            SET OwnershipState = 'Cleared', ClearedAtUtc = SYSUTCDATETIME()
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND DatabaseName = DB_NAME() AND QueryId = @OwnedQueryId
              AND OwnershipState IN ('Pending', 'Active');
            SET @HintOrdinal += 1;
        END;
        IF EXISTS
        (
            SELECT 1 FROM WorkshopAdmin.dbo.QueryStoreHintOwnership AS ownership
            INNER JOIN sys.query_store_query_hints AS hint ON hint.query_id = ownership.QueryId
            WHERE ownership.MarkerId = @WorkshopMarker AND ownership.SchemaVersion = @WorkshopSchemaVersion
              AND ownership.DatabaseName = DB_NAME() AND ownership.OwnershipState IN ('Pending', 'Active')
        )
            THROW 51913, 'A workshop-owned Query Store hint remained after cleanup.', 1;
    END;

    /* Restore database-scoped configuration from first-capture metadata. */
     IF @BackupRowModeMemoryGrantFeedback IS NULL OR @BackupRowModeMemoryGrantFeedback NOT IN (0, 1)
         OR @BackupBatchModeMemoryGrantFeedback IS NULL OR @BackupBatchModeMemoryGrantFeedback NOT IN (0, 1)
         OR @BackupMemoryGrantFeedbackPercentileGrant IS NULL OR @BackupMemoryGrantFeedbackPercentileGrant NOT IN (0, 1)
         OR @BackupMemoryGrantFeedbackPersistence IS NULL OR @BackupMemoryGrantFeedbackPersistence NOT IN (0, 1)
         OR (@BackupRowModeMemoryGrantFeedbackForSecondary IS NOT NULL AND @BackupRowModeMemoryGrantFeedbackForSecondary NOT IN (0, 1))
         OR (@BackupBatchModeMemoryGrantFeedbackForSecondary IS NOT NULL AND @BackupBatchModeMemoryGrantFeedbackForSecondary NOT IN (0, 1))
         OR (@BackupMemoryGrantFeedbackPercentileGrantForSecondary IS NOT NULL AND @BackupMemoryGrantFeedbackPercentileGrantForSecondary NOT IN (0, 1))
         OR (@BackupMemoryGrantFeedbackPersistenceForSecondary IS NOT NULL AND @BackupMemoryGrantFeedbackPersistenceForSecondary NOT IN (0, 1))
        THROW 51914, 'Captured memory grant feedback values are invalid.', 1;

    DECLARE @RestoreDatabaseConfigurationSql nvarchar(max) =
        N'ALTER DATABASE SCOPED CONFIGURATION SET ROW_MODE_MEMORY_GRANT_FEEDBACK = '
        + CASE @BackupRowModeMemoryGrantFeedback WHEN 1 THEN N'ON' ELSE N'OFF' END + N';'
        + N' ALTER DATABASE SCOPED CONFIGURATION SET BATCH_MODE_MEMORY_GRANT_FEEDBACK = '
        + CASE @BackupBatchModeMemoryGrantFeedback WHEN 1 THEN N'ON' ELSE N'OFF' END + N';';
    SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT = '
        + CASE @BackupMemoryGrantFeedbackPercentileGrant WHEN 1 THEN N'ON' ELSE N'OFF' END + N';';
    SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = '
        + CASE @BackupMemoryGrantFeedbackPersistence WHEN 1 THEN N'ON' ELSE N'OFF' END + N';';
    IF @BackupRowModeMemoryGrantFeedbackForSecondary IN (0, 1)
        SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET ROW_MODE_MEMORY_GRANT_FEEDBACK = '
            + CASE @BackupRowModeMemoryGrantFeedbackForSecondary WHEN 1 THEN N'ON' ELSE N'OFF' END + N';';
    ELSE IF @BackupRowModeMemoryGrantFeedbackForSecondary IS NULL
        SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET ROW_MODE_MEMORY_GRANT_FEEDBACK = PRIMARY;';
    IF @BackupBatchModeMemoryGrantFeedbackForSecondary IN (0, 1)
        SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET BATCH_MODE_MEMORY_GRANT_FEEDBACK = '
            + CASE @BackupBatchModeMemoryGrantFeedbackForSecondary WHEN 1 THEN N'ON' ELSE N'OFF' END + N';';
    ELSE IF @BackupBatchModeMemoryGrantFeedbackForSecondary IS NULL
        SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET BATCH_MODE_MEMORY_GRANT_FEEDBACK = PRIMARY;';
    IF @BackupMemoryGrantFeedbackPercentileGrantForSecondary IN (0, 1)
        SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT = '
            + CASE @BackupMemoryGrantFeedbackPercentileGrantForSecondary WHEN 1 THEN N'ON' ELSE N'OFF' END + N';';
    ELSE IF @BackupMemoryGrantFeedbackPercentileGrantForSecondary IS NULL
        SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT = PRIMARY;';
    IF @BackupMemoryGrantFeedbackPersistenceForSecondary IN (0, 1)
        SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = '
            + CASE @BackupMemoryGrantFeedbackPersistenceForSecondary WHEN 1 THEN N'ON' ELSE N'OFF' END + N';';
    ELSE IF @BackupMemoryGrantFeedbackPersistenceForSecondary IS NULL
        SET @RestoreDatabaseConfigurationSql += N' ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = PRIMARY;';
    EXEC sys.sp_executesql @RestoreDatabaseConfigurationSql;

    DECLARE @RestoreQueryStoreSql nvarchar(max);
    IF @BackupQueryStoreDesiredStateDesc NOT IN (N'OFF', N'READ_ONLY', N'READ_WRITE')
       OR @BackupQueryStoreMaxStorageSizeMB NOT BETWEEN 1 AND 2147483647
       OR @BackupQueryStoreCaptureModeDesc NOT IN (N'ALL', N'AUTO', N'CUSTOM', N'NONE')
       OR @BackupQueryStoreStaleQueryThresholdDays NOT BETWEEN 0 AND 367
       OR @BackupQueryStoreFlushIntervalSeconds NOT BETWEEN 1 AND 86400
       OR @BackupQueryStoreIntervalLengthMinutes NOT BETWEEN 1 AND 1440
       OR @BackupQueryStoreSizeBasedCleanupModeDesc NOT IN (N'AUTO', N'OFF')
       OR @BackupQueryStoreWaitStatsCaptureModeDesc NOT IN (N'ON', N'OFF')
        THROW 51915, 'Captured Query Store settings are invalid.', 1;
    SET @RestoreQueryStoreSql = N'ALTER DATABASE [AdventureWorks2022] SET QUERY_STORE = ON; ALTER DATABASE [AdventureWorks2022] SET QUERY_STORE (OPERATION_MODE = READ_WRITE, MAX_STORAGE_SIZE_MB = '
        + CONVERT(nvarchar(20), @BackupQueryStoreMaxStorageSizeMB) + N', QUERY_CAPTURE_MODE = '
        + @BackupQueryStoreCaptureModeDesc + N', CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = '
        + CONVERT(nvarchar(20), @BackupQueryStoreStaleQueryThresholdDays) + N'), DATA_FLUSH_INTERVAL_SECONDS = '
        + CONVERT(nvarchar(20), @BackupQueryStoreFlushIntervalSeconds) + N', INTERVAL_LENGTH_MINUTES = '
        + CONVERT(nvarchar(20), @BackupQueryStoreIntervalLengthMinutes) + N', SIZE_BASED_CLEANUP_MODE = '
        + @BackupQueryStoreSizeBasedCleanupModeDesc + N', WAIT_STATS_CAPTURE_MODE = '
        + @BackupQueryStoreWaitStatsCaptureModeDesc + N');';
    IF @BackupQueryStoreDesiredStateDesc = N'READ_ONLY'
        SET @RestoreQueryStoreSql += N' ALTER DATABASE [AdventureWorks2022] SET QUERY_STORE (OPERATION_MODE = READ_ONLY);';
    ELSE IF @BackupQueryStoreDesiredStateDesc = N'OFF'
        SET @RestoreQueryStoreSql += N' ALTER DATABASE [AdventureWorks2022] SET QUERY_STORE = OFF;';
    EXEC sys.sp_executesql @RestoreQueryStoreSql;
    IF @BackupCompatibilityLevel NOT BETWEEN 100 AND 160 OR @BackupCompatibilityLevel % 10 <> 0
        THROW 51928, 'Captured database compatibility level is invalid.', 1;
    DECLARE @RestoreCompatibilitySql nvarchar(max) = N'ALTER DATABASE [AdventureWorks2022] SET COMPATIBILITY_LEVEL = '
        + CONVERT(nvarchar(3), @BackupCompatibilityLevel) + N';';
    EXEC sys.sp_executesql @RestoreCompatibilitySql;
    IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND compatibility_level = @BackupCompatibilityLevel)
        THROW 51929, 'Database compatibility level restoration could not be verified.', 1;

    /* Prove exact Resource Governor ownership and settings before detaching or dropping. */
    DECLARE @ExpectedClassifierCreateSql nvarchar(max) = N'CREATE FUNCTION dbo.mcp_sql_workshop_classifier()
RETURNS sysname
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN APP_NAME() LIKE N''MCP-SQL-Workshop%''
            THEN N''mcp_sql_workshop_group''
        ELSE NULL
    END;
END;';
    DECLARE @ExpectedClassifierHash varbinary(32) = HASHBYTES('SHA2_256', CONVERT(varbinary(max),
        UPPER(REPLACE(REPLACE(REPLACE(REPLACE(@ExpectedClassifierCreateSql, NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''), N' ', N''))));
        DECLARE @WorkshopClassifierId int;
        DECLARE @WorkshopClassifierDefinition nvarchar(max);
        SELECT @WorkshopClassifierId = object_entry.object_id,
                     @WorkshopClassifierDefinition = module.definition
        FROM master.sys.objects AS object_entry
        INNER JOIN master.sys.schemas AS object_schema ON object_schema.schema_id = object_entry.schema_id
        INNER JOIN master.sys.sql_modules AS module ON module.object_id = object_entry.object_id
        WHERE object_schema.name = N'dbo' AND object_entry.name = N'mcp_sql_workshop_classifier'
            AND object_entry.type = 'FN';
        DECLARE @ActualClassifierHash varbinary(32) = HASHBYTES('SHA2_256', CONVERT(varbinary(max),
                UPPER(REPLACE(REPLACE(REPLACE(REPLACE(@WorkshopClassifierDefinition, NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''), N' ', N''))));
    DECLARE @ClassifierRestoreAction nvarchar(64) = N'Restore the prior classifier exactly';
        DECLARE @CurrentClassifierId int = (SELECT classifier_function_id FROM sys.resource_governor_configuration);
        IF @CurrentClassifierId NOT IN (COALESCE(@WorkshopClassifierId, -1), @BackupClassifierFunctionId)
            THROW 51927, 'A foreign classifier became active during cleanup; refusing to replace it.', 1;

    IF EXISTS (SELECT 1 FROM sys.resource_governor_workload_groups WHERE name = N'mcp_sql_workshop_group')
       AND NOT EXISTS
       (
           SELECT 1
           FROM sys.resource_governor_workload_groups AS workload_group
           INNER JOIN sys.resource_governor_resource_pools AS resource_pool ON resource_pool.pool_id = workload_group.pool_id
           INNER JOIN WorkshopAdmin.dbo.ResourceGovernorObjectOwnership AS ownership
             ON ownership.ObjectName = workload_group.name AND ownership.ObjectType = 'GROUP'
           WHERE ownership.MarkerId = @WorkshopMarker AND ownership.SchemaVersion = @WorkshopSchemaVersion
             AND ownership.OwnershipState = 'Active' AND workload_group.name = N'mcp_sql_workshop_group'
             AND workload_group.request_max_memory_grant_percent = 40 AND workload_group.max_dop = 4
             AND workload_group.group_max_requests = 4 AND resource_pool.name = N'mcp_sql_workshop_pool'
       )
        THROW 51916, 'Foreign or drifted workshop-named workload group found; refusing to drop it.', 1;
    IF EXISTS (SELECT 1 FROM sys.resource_governor_resource_pools WHERE name = N'mcp_sql_workshop_pool')
       AND NOT EXISTS
       (
           SELECT 1
           FROM sys.resource_governor_resource_pools AS resource_pool
           INNER JOIN WorkshopAdmin.dbo.ResourceGovernorObjectOwnership AS ownership
             ON ownership.ObjectName = resource_pool.name AND ownership.ObjectType = 'POOL'
           WHERE ownership.MarkerId = @WorkshopMarker AND ownership.SchemaVersion = @WorkshopSchemaVersion
             AND ownership.OwnershipState = 'Active' AND resource_pool.name = N'mcp_sql_workshop_pool'
             AND resource_pool.min_memory_percent = 0 AND resource_pool.max_memory_percent = 50
       )
        THROW 51917, 'Foreign or drifted workshop-named resource pool found; refusing to drop it.', 1;
    IF @WorkshopClassifierId IS NOT NULL
       AND NOT EXISTS
       (
           SELECT 1 FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership AS ownership
           WHERE ownership.MarkerId = @WorkshopMarker AND ownership.SchemaVersion = @WorkshopSchemaVersion
             AND ownership.ObjectType = 'CLASSIFIER' AND ownership.ObjectName = N'mcp_sql_workshop_classifier'
             AND ownership.OwnershipState = 'Active' AND ownership.DefinitionHash = @ExpectedClassifierHash
             AND @ActualClassifierHash = @ExpectedClassifierHash
             AND EXISTS
             (
                 SELECT 1 FROM master.sys.extended_properties
                 WHERE class = 1 AND major_id = @WorkshopClassifierId AND minor_id = 0
                   AND name = N'MCP_SQL_WORKSHOP' AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
             )
       )
        THROW 51918, 'Foreign or drifted workshop-named classifier found; refusing to drop it.', 1;

    /* Restore the prior classifier exactly before removing the workshop group and pool. */
    IF @BackupClassifierFunctionId = 0
        EXEC master.sys.sp_executesql N'USE [master]; ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);';
    ELSE
    BEGIN
        IF NOT EXISTS
        (
            SELECT 1 FROM master.sys.objects AS object_entry
            INNER JOIN master.sys.schemas AS object_schema ON object_schema.schema_id = object_entry.schema_id
            WHERE object_entry.object_id = @BackupClassifierFunctionId
              AND object_entry.type = 'FN'
              AND object_schema.name = @BackupClassifierSchema
              AND object_entry.name = @BackupClassifierName
        )
            THROW 51919, 'The captured prior classifier no longer resolves to its original object.', 1;
        DECLARE @RestoreClassifierSql nvarchar(max) = N'USE [master]; ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = '
            + QUOTENAME(@BackupClassifierSchema) + N'.' + QUOTENAME(@BackupClassifierName) + N');';
        EXEC master.sys.sp_executesql @RestoreClassifierSql;
    END;
    EXEC master.sys.sp_executesql N'USE [master]; ALTER RESOURCE GOVERNOR RECONFIGURE;';
    SET @ClassifierRestoreAction = @ClassifierRestoreAction;

    IF EXISTS (SELECT 1 FROM sys.resource_governor_workload_groups WHERE name = N'mcp_sql_workshop_group')
    BEGIN
        EXEC master.sys.sp_executesql N'USE [master]; DROP WORKLOAD GROUP [mcp_sql_workshop_group]; ALTER RESOURCE GOVERNOR RECONFIGURE;';
        DELETE WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
          AND ObjectType = 'GROUP' AND ObjectName = N'mcp_sql_workshop_group' AND OwnershipState = 'Active';
    END;
    IF EXISTS (SELECT 1 FROM sys.resource_governor_resource_pools WHERE name = N'mcp_sql_workshop_pool')
    BEGIN
        EXEC master.sys.sp_executesql N'USE [master]; DROP RESOURCE POOL [mcp_sql_workshop_pool]; ALTER RESOURCE GOVERNOR RECONFIGURE;';
        DELETE WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
          AND ObjectType = 'POOL' AND ObjectName = N'mcp_sql_workshop_pool' AND OwnershipState = 'Active';
    END;
    IF @WorkshopClassifierId IS NOT NULL
    BEGIN
        EXEC master.sys.sp_executesql N'USE [master]; DROP FUNCTION dbo.mcp_sql_workshop_classifier;';
        DELETE WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
          AND ObjectType = 'CLASSIFIER' AND ObjectName = N'mcp_sql_workshop_classifier'
          AND OwnershipState = 'Active' AND DefinitionHash = @ExpectedClassifierHash;
    END;
    IF @BackupResourceGovernorEnabled = 0
        EXEC master.sys.sp_executesql N'USE [master]; ALTER RESOURCE GOVERNOR DISABLE;';
    ELSE
        EXEC master.sys.sp_executesql N'USE [master]; ALTER RESOURCE GOVERNOR RECONFIGURE;';

    /* Relationship-safe memory restoration: lower min, restore max, then restore min. */
    DECLARE @RestoreMemorySql nvarchar(max) = N'';
    EXEC sys.sp_configure N'show advanced options', 1;
    RECONFIGURE;
    EXEC sys.sp_configure N'min server memory (MB)', 0;
    RECONFIGURE;
    EXEC sys.sp_configure N'max server memory (MB)', @BackupMaxServerMemoryMB;
    RECONFIGURE;
    EXEC sys.sp_configure N'min server memory (MB)', @BackupMinServerMemoryMB;
    RECONFIGURE;
    EXEC sys.sp_configure N'show advanced options', @BackupShowAdvancedOptions;
    RECONFIGURE;
    SET @RestoreMemorySql = N'Restored';

    /* Remove the SQL reader only when the database user and exact SQL login share one SID. */
    DECLARE @ReaderSid varbinary(85) = SUSER_SID(N'mcp_workshop_reader');
    IF USER_ID(N'mcp_workshop_reader') IS NOT NULL
    BEGIN
        IF @ReaderSid IS NULL OR NOT EXISTS
        (
            SELECT 1 FROM sys.database_principals
            WHERE name = N'mcp_workshop_reader' AND type = 'S' AND sid = @ReaderSid
        )
        OR NOT EXISTS
        (
            SELECT 1 FROM WorkshopAdmin.dbo.IdentityOwnership
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND PrincipalType = 'DATABASE_USER' AND PrincipalName = N'mcp_workshop_reader'
              AND PrincipalSid = @ReaderSid AND CreatedByWorkshop = 1
        )
            THROW 51920, 'The mcp_workshop_reader SID ownership contract is invalid.', 1;
        DROP USER [mcp_workshop_reader];
    END;
        IF USER_ID(N'mcp_workshop_reader') IS NULL
                DELETE WorkshopAdmin.dbo.IdentityOwnership
                WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
                    AND PrincipalType = 'DATABASE_USER' AND PrincipalName = N'mcp_workshop_reader'
                    AND CreatedByWorkshop = 1;
    IF SUSER_ID(N'mcp_workshop_reader') IS NOT NULL
    BEGIN
        IF @ReaderSid IS NULL OR NOT EXISTS
        (
            SELECT 1 FROM master.sys.sql_logins
            WHERE name = N'mcp_workshop_reader' AND sid = @ReaderSid
              AND default_database_name = N'AdventureWorks2022'
              AND is_policy_checked = 1 AND is_expiration_checked = 0
        )
        OR NOT EXISTS
        (
            SELECT 1 FROM WorkshopAdmin.dbo.IdentityOwnership
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND PrincipalType = 'SQL_LOGIN' AND PrincipalName = N'mcp_workshop_reader'
              AND PrincipalSid = @ReaderSid AND CreatedByWorkshop = 1
        )
            THROW 51921, 'The mcp_workshop_reader login is foreign or drifted.', 1;
        DROP LOGIN [mcp_workshop_reader];
    END;
        IF SUSER_ID(N'mcp_workshop_reader') IS NULL
                DELETE WorkshopAdmin.dbo.IdentityOwnership
                WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
                    AND PrincipalType = 'SQL_LOGIN' AND PrincipalName = N'mcp_workshop_reader'
                    AND CreatedByWorkshop = 1;

    DECLARE @DatabaseCertificateThumbprint varbinary(32) =
        (SELECT thumbprint FROM sys.certificates
         WHERE name = N'mcp_workshop_diagnostics_certificate'
           AND subject = N'MCP workshop server DMV module signing');
    IF SUSER_ID(N'mcp_workshop_diagnostics_certificate_login') IS NOT NULL
    BEGIN
        IF @DatabaseCertificateThumbprint IS NULL OR NOT EXISTS
        (
            SELECT 1 FROM master.sys.server_principals AS principal
            INNER JOIN master.sys.certificates AS certificate ON certificate.sid = principal.sid
            WHERE principal.name = N'mcp_workshop_diagnostics_certificate_login'
              AND certificate.name = N'mcp_workshop_diagnostics_certificate'
              AND certificate.thumbprint = @DatabaseCertificateThumbprint
              AND certificate.subject = N'MCP workshop server DMV module signing'
        )
            THROW 51922, 'The diagnostics certificate login ownership contract is invalid.', 1;
        IF EXISTS
        (
            SELECT 1 FROM WorkshopAdmin.dbo.IdentityOwnership
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND PrincipalType = 'CERT_LOGIN' AND PrincipalName = N'mcp_workshop_diagnostics_certificate_login'
              AND PrincipalSid = SUSER_SID(N'mcp_workshop_diagnostics_certificate_login')
              AND CreatedByWorkshop = 1
        )
            DROP LOGIN [mcp_workshop_diagnostics_certificate_login];
    END;
        IF SUSER_ID(N'mcp_workshop_diagnostics_certificate_login') IS NULL
                DELETE WorkshopAdmin.dbo.IdentityOwnership
                WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
                    AND PrincipalType = 'CERT_LOGIN' AND PrincipalName = N'mcp_workshop_diagnostics_certificate_login'
                    AND CreatedByWorkshop = 1;
    IF EXISTS (SELECT 1 FROM master.sys.certificates
               WHERE name = N'mcp_workshop_diagnostics_certificate'
                 AND thumbprint = @DatabaseCertificateThumbprint
                 AND subject = N'MCP workshop server DMV module signing')
        IF EXISTS (SELECT 1 FROM WorkshopAdmin.dbo.IdentityOwnership WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion AND PrincipalType = 'CERTIFICATE_MASTER' AND PrincipalName = N'mcp_workshop_diagnostics_certificate' AND PrincipalSid = @DatabaseCertificateThumbprint AND CreatedByWorkshop = 1)
            EXEC master.sys.sp_executesql N'DROP CERTIFICATE [mcp_workshop_diagnostics_certificate];';
        IF NOT EXISTS (SELECT 1 FROM master.sys.certificates WHERE name = N'mcp_workshop_diagnostics_certificate')
                DELETE WorkshopAdmin.dbo.IdentityOwnership
                WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
                    AND PrincipalType = 'CERTIFICATE_MASTER' AND PrincipalName = N'mcp_workshop_diagnostics_certificate'
                    AND CreatedByWorkshop = 1;
    IF EXISTS (SELECT 1 FROM sys.certificates
               WHERE name = N'mcp_workshop_diagnostics_certificate'
                 AND thumbprint = @DatabaseCertificateThumbprint
                 AND subject = N'MCP workshop server DMV module signing')
        IF EXISTS (SELECT 1 FROM WorkshopAdmin.dbo.IdentityOwnership WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion AND PrincipalType = 'CERTIFICATE_DB' AND PrincipalName = N'mcp_workshop_diagnostics_certificate' AND PrincipalSid = @DatabaseCertificateThumbprint AND CreatedByWorkshop = 1)
            DROP CERTIFICATE [mcp_workshop_diagnostics_certificate];
        IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'mcp_workshop_diagnostics_certificate')
                DELETE WorkshopAdmin.dbo.IdentityOwnership
                WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
                    AND PrincipalType = 'CERTIFICATE_DB' AND PrincipalName = N'mcp_workshop_diagnostics_certificate'
                    AND CreatedByWorkshop = 1;
    PRINT N'Certificate export cleanup is external: bootstrap cleanup must delete mcp_workshop_diagnostics_*.cer from the SQL backup path.';
    IF EXISTS (SELECT 1 FROM sys.openkeys WHERE key_name = N'##MS_DatabaseMasterKey##')
        CLOSE MASTER KEY;

    /* DropLabData=0 intentionally preserves lab data, procedures, and evidence for reruns. */
    IF @DropLabData = 1
    BEGIN
        IF NOT EXISTS
        (
            SELECT 1 FROM lab.WorkshopMarker
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND SetupName = @WorkshopSetupName AND SetupHash = @WorkshopSetupHash
        )
            THROW 51923, 'The lab ownership marker changed before optional data removal.', 1;

        /* Snapshot every eligible database before inventorying anything for optional deletion.
           Access is a safety prerequisite, never an eligibility filter. */
        DECLARE @CrossDatabaseScan table
        (
            DatabaseOrdinal int IDENTITY(1,1) NOT NULL PRIMARY KEY,
            DatabaseId int NOT NULL UNIQUE,
            DatabaseName sysname NOT NULL UNIQUE
        );
        INSERT @CrossDatabaseScan (DatabaseId, DatabaseName)
        SELECT database_id, name
        FROM sys.databases
        WHERE state_desc = N'ONLINE'
          AND source_database_id IS NULL
          AND name <> N'tempdb'
          AND (database_id > 4 OR name IN (N'master', N'model', N'msdb'))
        ORDER BY database_id;

        DECLARE @CrossDatabaseCount int = (SELECT COUNT(*) FROM @CrossDatabaseScan);
        IF @CrossDatabaseCount > 256
            THROW 51946, 'More than 256 online databases prevent a bounded optional lab deletion safety scan.', 1;

        DECLARE @InaccessibleDatabaseCount int =
        (
            SELECT COUNT(*)
            FROM @CrossDatabaseScan
            WHERE COALESCE(HAS_DBACCESS(DatabaseName), 0) = 0
        );
        DECLARE @InaccessibleDatabaseList nvarchar(1600);
        DECLARE @CrossDatabaseError nvarchar(2048);
        IF @InaccessibleDatabaseCount > 0
        BEGIN
            SELECT @InaccessibleDatabaseList = STRING_AGG(CONVERT(nvarchar(max), sanitized.DatabaseName), N', ')
                WITHIN GROUP (ORDER BY inaccessible.DatabaseId)
            FROM
            (
                SELECT TOP (8) DatabaseId, DatabaseName
                FROM @CrossDatabaseScan
                WHERE COALESCE(HAS_DBACCESS(DatabaseName), 0) = 0
                ORDER BY DatabaseId
            ) AS inaccessible
            CROSS APPLY
            (
                SELECT QUOTENAME(LEFT(REPLACE(REPLACE(REPLACE(inaccessible.DatabaseName,
                    NCHAR(13), N'?'), NCHAR(10), N'?'), NCHAR(9), N'?'), 120)) AS DatabaseName
            ) AS sanitized;

            SET @CrossDatabaseError = N'Cannot prove optional lab deletion safe; inaccessible database count '
                + CONVERT(nvarchar(10), @InaccessibleDatabaseCount) + N'; first up to 8: '
                + COALESCE(@InaccessibleDatabaseList, N'(name unavailable)') + N'.';
            THROW 51951, @CrossDatabaseError, 1;
        END;

        DECLARE @ExpectedLabObjects table
        (
            ObjectName sysname NOT NULL PRIMARY KEY,
            ObjectType char(2) NOT NULL
        );
        INSERT @ExpectedLabObjects (ObjectName, ObjectType) VALUES
            (N'vw_WorkshopSampleSummary', 'V'), (N'vw_WorkshopRunSummary', 'V'),
            (N'usp_CompareWorkshopRuns', 'P'), (N'usp_GetProcedurePlanSummary', 'P'),
            (N'usp_GetQueryStoreWaits', 'P'), (N'usp_GetQueryStoreTopQueries', 'P'),
            (N'usp_GetActiveWorkshopGrants', 'P'), (N'usp_GetMemorySnapshot', 'P'),
            (N'usp_MonthEndSalesOptimized', 'P'), (N'usp_MonthEndSalesBaseline', 'P'),
            (N'WorkshopRequestSample', 'U'), (N'WorkshopTrial', 'U'),
            (N'ValidationRun', 'U'), (N'WorkshopSample', 'U'), (N'WorkshopRun', 'U'),
            (N'DataGenerationLog', 'U'), (N'FactSales', 'U'), (N'Numbers', 'U'),
            (N'WorkshopMarker', 'U');

           /* Inventory every user-created top-level object in lab, not merely the types this
             workshop happens to create. Constraints and triggers are verified separately as
             children of exact owned tables. S and IT are engine-owned/internal object types. */
        IF EXISTS
        (
            SELECT object_entry.name, object_entry.type
            FROM sys.objects AS object_entry
            INNER JOIN sys.schemas AS object_schema ON object_schema.schema_id = object_entry.schema_id
            WHERE object_schema.name = N'lab' AND object_entry.is_ms_shipped = 0
                            AND object_entry.parent_object_id = 0
                            AND object_entry.type NOT IN ('S', 'IT')
            EXCEPT SELECT ObjectName, ObjectType FROM @ExpectedLabObjects
        )
        OR EXISTS
        (
            SELECT ObjectName, ObjectType FROM @ExpectedLabObjects
            EXCEPT
            SELECT object_entry.name, object_entry.type
            FROM sys.objects AS object_entry
            INNER JOIN sys.schemas AS object_schema ON object_schema.schema_id = object_entry.schema_id
            WHERE object_schema.name = N'lab' AND object_entry.is_ms_shipped = 0
              AND object_entry.parent_object_id = 0
              AND object_entry.type NOT IN ('S', 'IT')
        )
                OR EXISTS
                (
            SELECT 1
            FROM sys.objects AS object_entry
            INNER JOIN sys.schemas AS object_schema ON object_schema.schema_id = object_entry.schema_id
            WHERE object_schema.name = N'lab' AND object_entry.is_ms_shipped = 0
              AND object_entry.parent_object_id <> 0
              AND object_entry.type NOT IN ('PK', 'UQ', 'C', 'D', 'F', 'TR')
                )
            THROW 51926, 'Unrecognized lab schema-scoped object found; refusing optional lab deletion.', 1;

        DECLARE @OwnedLabObjectIds table
        (
            ObjectId int NOT NULL PRIMARY KEY,
            ObjectName sysname NOT NULL,
            ObjectType char(2) NOT NULL
        );
        INSERT @OwnedLabObjectIds (ObjectId, ObjectName, ObjectType)
        SELECT object_entry.object_id, object_entry.name, object_entry.type
        FROM sys.objects AS object_entry
        INNER JOIN @ExpectedLabObjects AS expected
            ON expected.ObjectName = object_entry.name AND expected.ObjectType = object_entry.type
        WHERE object_entry.schema_id = SCHEMA_ID(N'lab')
          AND object_entry.is_ms_shipped = 0;

          /* Synonyms do not reliably appear in the dependency DMV. Reject every lab synonym,
              plus synonyms in any schema whose base target names an owned lab object. */
        IF EXISTS
        (
            SELECT 1
            FROM sys.synonyms AS synonym_entry
            WHERE synonym_entry.schema_id = SCHEMA_ID(N'lab')
               OR
               (
                (PARSENAME(synonym_entry.base_object_name, 3) IS NULL
                OR PARSENAME(synonym_entry.base_object_name, 3) = DB_NAME())
                   AND PARSENAME(synonym_entry.base_object_name, 2) = N'lab'
                   AND EXISTS
                   (
                       SELECT 1 FROM @OwnedLabObjectIds AS owned
                       WHERE owned.ObjectName = PARSENAME(synonym_entry.base_object_name, 1)
                   )
               )
        )
            THROW 51944, 'Unrecognized lab synonym or synonym targeting an owned lab object found; refusing optional lab deletion.', 1;

        /* These schema-scoped catalogs are checked explicitly because not every entry is
           represented consistently by sys.objects across SQL Server feature families. */
        IF EXISTS (SELECT 1 FROM sys.sequences WHERE schema_id = SCHEMA_ID(N'lab'))
           OR EXISTS (SELECT 1 FROM sys.types WHERE schema_id = SCHEMA_ID(N'lab') AND is_user_defined = 1)
           OR EXISTS
              (
                  SELECT 1 FROM sys.xml_schema_collections
                  WHERE schema_id = SCHEMA_ID(N'lab') AND xml_collection_id <> 1
              )
           OR EXISTS
              (
                  SELECT 1 FROM sys.fulltext_indexes AS fulltext_index
                  INNER JOIN sys.tables AS parent_table ON parent_table.object_id = fulltext_index.object_id
                  WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
              )
           OR EXISTS (SELECT 1 FROM sys.service_queues WHERE schema_id = SCHEMA_ID(N'lab'))
            THROW 51945, 'Unrecognized lab sequence, type, XML schema collection, fulltext, or Service Broker object found; refusing optional lab deletion.', 1;

        IF OBJECT_ID(N'WorkshopAdmin.dbo.LabObjectOwnership', N'U') IS NULL
            THROW 51930, 'Lab object ownership fingerprints are absent; refusing optional lab deletion.', 1;
        DECLARE @CurrentLabObjects table
        (
            ObjectName sysname NOT NULL PRIMARY KEY,
            ObjectType char(2) NOT NULL,
            DefinitionHash varbinary(32) NULL,
            SchemaHash varbinary(32) NULL
        );
        INSERT @CurrentLabObjects (ObjectName, ObjectType, DefinitionHash, SchemaHash)
        SELECT object_entry.name, object_entry.type,
               CASE WHEN module.definition IS NULL THEN NULL
                    ELSE HASHBYTES('SHA2_256', CONVERT(varbinary(max), module.definition COLLATE Latin1_General_100_BIN2)) END,
               CASE WHEN object_entry.type <> 'U' THEN NULL ELSE
                    HASHBYTES('SHA2_256', CONVERT(varbinary(max), columns_shape.SchemaDefinition COLLATE Latin1_General_100_BIN2)) END
        FROM sys.objects AS object_entry
        INNER JOIN sys.schemas AS object_schema ON object_schema.schema_id = object_entry.schema_id
        LEFT JOIN sys.sql_modules AS module ON module.object_id = object_entry.object_id
        OUTER APPLY
        (
            SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(column_entry.column_id, N'|', column_entry.name, N'|',
                       TYPE_NAME(column_entry.user_type_id), N'|', column_entry.max_length, N'|',
                       column_entry.precision, N'|', column_entry.scale, N'|', column_entry.is_nullable,
                       N'|', column_entry.is_identity)), N';')
                   WITHIN GROUP (ORDER BY column_entry.column_id) AS SchemaDefinition
            FROM sys.columns AS column_entry
            WHERE column_entry.object_id = object_entry.object_id
        ) AS columns_shape
        WHERE object_schema.name = N'lab' AND object_entry.is_ms_shipped = 0
          AND object_entry.type IN ('U', 'V', 'P');
        IF EXISTS
        (
            SELECT ObjectName, ObjectType, DefinitionHash, SchemaHash FROM @CurrentLabObjects
            EXCEPT
            SELECT ObjectName, ObjectType, DefinitionHash, SchemaHash
            FROM WorkshopAdmin.dbo.LabObjectOwnership
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND DatabaseName = DB_NAME()
        )
        OR EXISTS
        (
            SELECT ObjectName, ObjectType, DefinitionHash, SchemaHash
            FROM WorkshopAdmin.dbo.LabObjectOwnership
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND DatabaseName = DB_NAME()
            EXCEPT
            SELECT ObjectName, ObjectType, DefinitionHash, SchemaHash FROM @CurrentLabObjects
        )
            THROW 51931, 'Unexpected or drifted lab object fingerprint found; refusing optional lab deletion.', 1;

        DECLARE @ExpectedLabConstraints table
        (
            TableName sysname NOT NULL,
            ConstraintName sysname NOT NULL PRIMARY KEY,
            ConstraintType char(2) NOT NULL
        );
        INSERT @ExpectedLabConstraints (TableName, ConstraintName, ConstraintType) VALUES
            (N'WorkshopMarker', N'PK_WorkshopMarker', 'PK'),
            (N'Numbers', N'PK_Numbers', 'PK'),
            (N'FactSales', N'PK_FactSales', 'PK'),
            (N'FactSales', N'CK_FactSales_Positive', 'C'),
            (N'DataGenerationLog', N'PK_DataGenerationLog', 'PK'),
            (N'WorkshopRun', N'PK_WorkshopRun', 'PK'),
            (N'WorkshopRun', N'CK_WorkshopRun_EvidenceClassification', 'C'),
            (N'WorkshopRun', N'CK_WorkshopRun_Phase', 'C'),
            (N'WorkshopRun', N'CK_WorkshopRun_Status', 'C'),
            (N'WorkshopRun', N'CK_WorkshopRun_Outcome', 'C'),
            (N'WorkshopRun', N'CK_WorkshopRun_Timestamps', 'C'),
            (N'WorkshopRun', N'CK_WorkshopRun_FrozenSettingsJson', 'C'),
            (N'WorkshopRun', N'CK_WorkshopRun_BaselineIdentifiers', 'C'),
            (N'WorkshopRun', N'CK_WorkshopRun_OptimizedIdentifiers', 'C'),
            (N'WorkshopRun', N'CK_WorkshopRun_Metrics', 'C'),
            (N'WorkshopSample', N'PK_WorkshopSample', 'PK'),
            (N'WorkshopSample', N'FK_WorkshopSample_WorkshopRun', 'F'),
            (N'WorkshopSample', N'CK_WorkshopSample_Sequence', 'C'),
            (N'WorkshopSample', N'CK_WorkshopSample_Phase', 'C'),
            (N'WorkshopSample', N'CK_WorkshopSample_PoolMemory', 'C'),
            (N'WorkshopSample', N'CK_WorkshopSample_Utilization', 'C'),
            (N'WorkshopSample', N'CK_WorkshopSample_Counts', 'C'),
            (N'WorkshopSample', N'CK_WorkshopSample_HostMemory', 'C'),
            (N'WorkshopSample', N'CK_WorkshopSample_ProcessMemory', 'C'),
            (N'WorkshopSample', N'CK_WorkshopSample_ServerMemory', 'C'),
            (N'WorkshopRequestSample', N'PK_WorkshopRequestSample', 'PK'),
            (N'WorkshopRequestSample', N'FK_WorkshopRequestSample_WorkshopSample', 'F'),
            (N'WorkshopRequestSample', N'CK_WorkshopRequestSample_Identifiers', 'C'),
            (N'WorkshopRequestSample', N'CK_WorkshopRequestSample_Memory', 'C'),
            (N'WorkshopRequestSample', N'CK_WorkshopRequestSample_Wait', 'C'),
            (N'WorkshopRequestSample', N'CK_WorkshopRequestSample_QueryIdentifiers', 'C'),
            (N'WorkshopTrial', N'PK_WorkshopTrial', 'PK'),
            (N'WorkshopTrial', N'FK_WorkshopTrial_WorkshopRun', 'F'),
            (N'WorkshopTrial', N'CK_WorkshopTrial_Sequence', 'C'),
            (N'WorkshopTrial', N'CK_WorkshopTrial_ParameterSlot', 'C'),
            (N'WorkshopTrial', N'CK_WorkshopTrial_Phase', 'C'),
            (N'WorkshopTrial', N'CK_WorkshopTrial_Schedule', 'C'),
            (N'WorkshopTrial', N'CK_WorkshopTrial_Metrics', 'C'),
            (N'WorkshopTrial', N'CK_WorkshopTrial_Validation', 'C'),
            (N'WorkshopTrial', N'CK_WorkshopTrial_Timestamps', 'C'),
            (N'ValidationRun', N'PK_ValidationRun', 'PK'),
            (N'ValidationRun', N'UQ_ValidationRun_BatchCase', 'UQ'),
            (N'ValidationRun', N'FK_ValidationRun_BaselineWorkshopRun', 'F'),
            (N'ValidationRun', N'FK_ValidationRun_OptimizedWorkshopRun', 'F'),
            (N'ValidationRun', N'CK_ValidationRun_Linkage', 'C');

        DECLARE @ExpectedLabTriggers table
        (
            ParentObjectName sysname NOT NULL,
            TriggerName sysname NOT NULL PRIMARY KEY
        );

        IF EXISTS
        (
            SELECT OBJECT_NAME(constraint_entry.parent_object_id), constraint_entry.name, constraint_entry.type
            FROM sys.objects AS constraint_entry
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = constraint_entry.parent_object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
              AND constraint_entry.type IN ('PK', 'UQ', 'C', 'D', 'F')
            EXCEPT SELECT TableName, ConstraintName, ConstraintType FROM @ExpectedLabConstraints
        )
        OR EXISTS
        (
            SELECT TableName, ConstraintName, ConstraintType FROM @ExpectedLabConstraints
            EXCEPT
            SELECT OBJECT_NAME(constraint_entry.parent_object_id), constraint_entry.name, constraint_entry.type
            FROM sys.objects AS constraint_entry
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = constraint_entry.parent_object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
              AND constraint_entry.type IN ('PK', 'UQ', 'C', 'D', 'F')
        )
            THROW 51934, 'Unrecognized lab constraint found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.default_constraints AS default_constraint
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = default_constraint.parent_object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
        )
            THROW 51934, 'Unrecognized lab constraint found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.check_constraints AS check_constraint
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = check_constraint.parent_object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
              AND (check_constraint.is_disabled <> 0 OR check_constraint.is_not_trusted <> 0
                   OR check_constraint.is_not_for_replication <> 0
                   OR NOT EXISTS
                      (SELECT 1 FROM @ExpectedLabConstraints AS expected
                       WHERE expected.ConstraintType = 'C'
                         AND expected.ConstraintName = check_constraint.name
                         AND expected.TableName = parent_table.name))
        )
            THROW 51934, 'Unrecognized lab constraint found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.key_constraints AS key_constraint
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = key_constraint.parent_object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
              AND NOT EXISTS
                  (SELECT 1 FROM @ExpectedLabConstraints AS expected
                   WHERE expected.ConstraintType = key_constraint.type
                     AND expected.ConstraintName = key_constraint.name
                     AND expected.TableName = parent_table.name)
        )
            THROW 51934, 'Unrecognized lab constraint found; refusing optional lab deletion.', 1;

        DECLARE @ExpectedLabIndexes table
        (
            TableName sysname NOT NULL,
            IndexName sysname NOT NULL PRIMARY KEY,
            TypeDesc nvarchar(60) NOT NULL,
            IsUnique bit NOT NULL,
            IsPrimaryKey bit NOT NULL,
            IsUniqueConstraint bit NOT NULL
        );
        INSERT @ExpectedLabIndexes VALUES
            (N'WorkshopMarker', N'PK_WorkshopMarker', N'CLUSTERED', 1, 1, 0),
            (N'Numbers', N'PK_Numbers', N'CLUSTERED', 1, 1, 0),
            (N'FactSales', N'PK_FactSales', N'CLUSTERED', 1, 1, 0),
            (N'FactSales', N'IX_FactSales_OrderDate_Territory', N'NONCLUSTERED', 0, 0, 0),
            (N'DataGenerationLog', N'PK_DataGenerationLog', N'CLUSTERED', 1, 1, 0),
            (N'WorkshopRun', N'PK_WorkshopRun', N'CLUSTERED', 1, 1, 0),
            (N'WorkshopSample', N'PK_WorkshopSample', N'CLUSTERED', 1, 1, 0),
            (N'WorkshopRequestSample', N'PK_WorkshopRequestSample', N'CLUSTERED', 1, 1, 0),
            (N'WorkshopTrial', N'PK_WorkshopTrial', N'CLUSTERED', 1, 1, 0),
            (N'WorkshopTrial', N'IX_WorkshopTrial_ValidationBatchID', N'NONCLUSTERED', 0, 0, 0),
            (N'ValidationRun', N'PK_ValidationRun', N'CLUSTERED', 1, 1, 0),
            (N'ValidationRun', N'UQ_ValidationRun_BatchCase', N'NONCLUSTERED', 1, 0, 1);

        DECLARE @ExpectedLabIndexColumns table
        (
            IndexName sysname NOT NULL,
            ColumnName sysname NOT NULL,
            IndexColumnId int NOT NULL,
            KeyOrdinal tinyint NOT NULL,
            IsDescendingKey bit NOT NULL,
            IsIncludedColumn bit NOT NULL,
            PRIMARY KEY (IndexName, IndexColumnId)
        );
        INSERT @ExpectedLabIndexColumns VALUES
            (N'PK_WorkshopMarker', N'MarkerId', 1, 1, 0, 0),
            (N'PK_WorkshopMarker', N'SchemaVersion', 2, 2, 0, 0),
            (N'PK_Numbers', N'Number', 1, 1, 0, 0),
            (N'PK_FactSales', N'SyntheticSalesID', 1, 1, 0, 0),
            (N'IX_FactSales_OrderDate_Territory', N'OrderDate', 1, 1, 0, 0),
            (N'IX_FactSales_OrderDate_Territory', N'TerritoryID', 2, 2, 0, 0),
            (N'IX_FactSales_OrderDate_Territory', N'CustomerID', 3, 0, 0, 1),
            (N'IX_FactSales_OrderDate_Territory', N'ProductID', 4, 0, 0, 1),
            (N'IX_FactSales_OrderDate_Territory', N'OrderQty', 5, 0, 0, 1),
            (N'IX_FactSales_OrderDate_Territory', N'UnitPrice', 6, 0, 0, 1),
            (N'IX_FactSales_OrderDate_Territory', N'SalesAmount', 7, 0, 0, 1),
            (N'PK_DataGenerationLog', N'BatchStartSyntheticSalesID', 1, 1, 0, 0),
            (N'PK_DataGenerationLog', N'BatchEndSyntheticSalesID', 2, 2, 0, 0),
            (N'PK_WorkshopRun', N'RunID', 1, 1, 0, 0),
            (N'PK_WorkshopSample', N'RunID', 1, 1, 0, 0),
            (N'PK_WorkshopSample', N'SampleSequence', 2, 2, 0, 0),
            (N'PK_WorkshopRequestSample', N'RunID', 1, 1, 0, 0),
            (N'PK_WorkshopRequestSample', N'SampleSequence', 2, 2, 0, 0),
            (N'PK_WorkshopRequestSample', N'SessionID', 3, 3, 0, 0),
            (N'PK_WorkshopRequestSample', N'RequestID', 4, 4, 0, 0),
            (N'PK_WorkshopTrial', N'RunID', 1, 1, 0, 0),
            (N'PK_WorkshopTrial', N'TrialSequence', 2, 2, 0, 0),
            (N'IX_WorkshopTrial_ValidationBatchID', N'ValidationBatchID', 1, 1, 0, 0),
            (N'IX_WorkshopTrial_ValidationBatchID', N'RunID', 2, 2, 0, 0),
            (N'PK_ValidationRun', N'ValidationRunID', 1, 1, 0, 0),
            (N'UQ_ValidationRun_BatchCase', N'ValidationBatchID', 1, 1, 0, 0),
            (N'UQ_ValidationRun_BatchCase', N'ValidationCaseName', 2, 2, 0, 0);
        IF EXISTS
        (
            SELECT OBJECT_NAME(index_entry.object_id), index_entry.name, index_entry.type_desc,
                   index_entry.is_unique, index_entry.is_primary_key, index_entry.is_unique_constraint
            FROM sys.indexes AS index_entry
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = index_entry.object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab') AND index_entry.index_id > 0
              AND index_entry.is_disabled = 0 AND index_entry.is_hypothetical = 0
              AND index_entry.has_filter = 0 AND index_entry.fill_factor = 0
              AND index_entry.is_padded = 0 AND index_entry.ignore_dup_key = 0
              AND index_entry.allow_row_locks = 1 AND index_entry.allow_page_locks = 1
              AND index_entry.optimize_for_sequential_key = 0
            EXCEPT SELECT * FROM @ExpectedLabIndexes
        )
        OR EXISTS
        (
            SELECT * FROM @ExpectedLabIndexes
            EXCEPT
            SELECT OBJECT_NAME(index_entry.object_id), index_entry.name, index_entry.type_desc,
                   index_entry.is_unique, index_entry.is_primary_key, index_entry.is_unique_constraint
            FROM sys.indexes AS index_entry
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = index_entry.object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab') AND index_entry.index_id > 0
              AND index_entry.is_disabled = 0 AND index_entry.is_hypothetical = 0
              AND index_entry.has_filter = 0 AND index_entry.fill_factor = 0
              AND index_entry.is_padded = 0 AND index_entry.ignore_dup_key = 0
              AND index_entry.allow_row_locks = 1 AND index_entry.allow_page_locks = 1
              AND index_entry.optimize_for_sequential_key = 0
        )
            THROW 51935, 'Unrecognized lab index found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT index_entry.name, column_entry.name, index_column.index_column_id,
                   CONVERT(tinyint, index_column.key_ordinal), index_column.is_descending_key,
                   index_column.is_included_column
            FROM sys.indexes AS index_entry
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = index_entry.object_id
            INNER JOIN sys.index_columns AS index_column
                ON index_column.object_id = index_entry.object_id AND index_column.index_id = index_entry.index_id
            INNER JOIN sys.columns AS column_entry
                ON column_entry.object_id = index_column.object_id AND column_entry.column_id = index_column.column_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab') AND index_entry.index_id > 0
              AND (index_column.key_ordinal > 0 OR index_column.is_included_column = 1)
            EXCEPT SELECT * FROM @ExpectedLabIndexColumns
        )
        OR EXISTS
        (
            SELECT * FROM @ExpectedLabIndexColumns
            EXCEPT
            SELECT index_entry.name, column_entry.name, index_column.index_column_id,
                   CONVERT(tinyint, index_column.key_ordinal), index_column.is_descending_key,
                   index_column.is_included_column
            FROM sys.indexes AS index_entry
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = index_entry.object_id
            INNER JOIN sys.index_columns AS index_column
                ON index_column.object_id = index_entry.object_id AND index_column.index_id = index_entry.index_id
            INNER JOIN sys.columns AS column_entry
                ON column_entry.object_id = index_column.object_id AND column_entry.column_id = index_column.column_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab') AND index_entry.index_id > 0
              AND (index_column.key_ordinal > 0 OR index_column.is_included_column = 1)
        )
            THROW 51935, 'Unrecognized lab index found; refusing optional lab deletion.', 1;

                IF EXISTS
                (
                        SELECT OBJECT_NAME(trigger_entry.parent_id), trigger_entry.name
                        FROM sys.triggers AS trigger_entry
                        WHERE trigger_entry.parent_class = 1
                            AND OBJECT_SCHEMA_NAME(trigger_entry.parent_id) = N'lab'
                        EXCEPT SELECT ParentObjectName, TriggerName FROM @ExpectedLabTriggers
                )
                OR EXISTS
                (
                        SELECT ParentObjectName, TriggerName FROM @ExpectedLabTriggers
                        EXCEPT
                        SELECT OBJECT_NAME(trigger_entry.parent_id), trigger_entry.name
                        FROM sys.triggers AS trigger_entry
                        WHERE trigger_entry.parent_class = 1
                            AND OBJECT_SCHEMA_NAME(trigger_entry.parent_id) = N'lab'
                )
            THROW 51936, 'Unrecognized lab trigger found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.stats AS statistic
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = statistic.object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
              AND NOT EXISTS
              (
                  SELECT 1 FROM sys.indexes AS matching_index
                  WHERE matching_index.object_id = statistic.object_id
                    AND matching_index.index_id = statistic.stats_id
                    AND matching_index.name = statistic.name
              )
        )
            THROW 51937, 'Unrecognized lab statistic found; refusing optional lab deletion.', 1;
        DECLARE @ExpectedLabForeignKeyColumns table
        (
            ConstraintName sysname NOT NULL,
            ParentTable sysname NOT NULL,
            ParentColumn sysname NOT NULL,
            ReferencedTable sysname NOT NULL,
            ReferencedColumn sysname NOT NULL,
            ConstraintColumnId int NOT NULL,
            PRIMARY KEY (ConstraintName, ConstraintColumnId)
        );
        INSERT @ExpectedLabForeignKeyColumns VALUES
            (N'FK_WorkshopSample_WorkshopRun', N'WorkshopSample', N'RunID', N'WorkshopRun', N'RunID', 1),
            (N'FK_WorkshopRequestSample_WorkshopSample', N'WorkshopRequestSample', N'RunID', N'WorkshopSample', N'RunID', 1),
            (N'FK_WorkshopRequestSample_WorkshopSample', N'WorkshopRequestSample', N'SampleSequence', N'WorkshopSample', N'SampleSequence', 2),
            (N'FK_WorkshopTrial_WorkshopRun', N'WorkshopTrial', N'RunID', N'WorkshopRun', N'RunID', 1),
            (N'FK_ValidationRun_BaselineWorkshopRun', N'ValidationRun', N'BaselineRunID', N'WorkshopRun', N'RunID', 1),
            (N'FK_ValidationRun_OptimizedWorkshopRun', N'ValidationRun', N'OptimizedRunID', N'WorkshopRun', N'RunID', 1);
        IF EXISTS
        (
            SELECT foreign_key.name, parent_table.name, parent_column.name,
                   referenced_table.name, referenced_column.name, foreign_key_column.constraint_column_id
            FROM sys.foreign_keys AS foreign_key
            INNER JOIN sys.foreign_key_columns AS foreign_key_column
                ON foreign_key_column.constraint_object_id = foreign_key.object_id
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = foreign_key.parent_object_id
            INNER JOIN sys.tables AS referenced_table ON referenced_table.object_id = foreign_key.referenced_object_id
            INNER JOIN sys.columns AS parent_column
                ON parent_column.object_id = foreign_key_column.parent_object_id
               AND parent_column.column_id = foreign_key_column.parent_column_id
            INNER JOIN sys.columns AS referenced_column
                ON referenced_column.object_id = foreign_key_column.referenced_object_id
               AND referenced_column.column_id = foreign_key_column.referenced_column_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab') OR referenced_table.schema_id = SCHEMA_ID(N'lab')
            EXCEPT SELECT * FROM @ExpectedLabForeignKeyColumns
        )
        OR EXISTS
        (
            SELECT * FROM @ExpectedLabForeignKeyColumns
            EXCEPT
            SELECT foreign_key.name, parent_table.name, parent_column.name,
                   referenced_table.name, referenced_column.name, foreign_key_column.constraint_column_id
            FROM sys.foreign_keys AS foreign_key
            INNER JOIN sys.foreign_key_columns AS foreign_key_column
                ON foreign_key_column.constraint_object_id = foreign_key.object_id
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = foreign_key.parent_object_id
            INNER JOIN sys.tables AS referenced_table ON referenced_table.object_id = foreign_key.referenced_object_id
            INNER JOIN sys.columns AS parent_column
                ON parent_column.object_id = foreign_key_column.parent_object_id
               AND parent_column.column_id = foreign_key_column.parent_column_id
            INNER JOIN sys.columns AS referenced_column
                ON referenced_column.object_id = foreign_key_column.referenced_object_id
               AND referenced_column.column_id = foreign_key_column.referenced_column_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab') OR referenced_table.schema_id = SCHEMA_ID(N'lab')
        )
            THROW 51938, 'Unrecognized lab foreign key found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.foreign_keys AS foreign_key
            INNER JOIN sys.tables AS referenced_table ON referenced_table.object_id = foreign_key.referenced_object_id
            WHERE referenced_table.schema_id = SCHEMA_ID(N'lab')
                            AND (foreign_key.is_disabled <> 0 OR foreign_key.is_not_trusted <> 0
                                     OR foreign_key.is_not_for_replication <> 0
                                     OR foreign_key.delete_referential_action <> 0
                                     OR foreign_key.update_referential_action <> 0
                                     OR NOT EXISTS
                                            (
                                                    SELECT 1 FROM @ExpectedLabConstraints AS expected
                                                    WHERE expected.ConstraintType = 'F' AND expected.ConstraintName = foreign_key.name
                                                        AND expected.TableName = OBJECT_NAME(foreign_key.parent_object_id)
                                                        AND OBJECT_SCHEMA_NAME(foreign_key.parent_object_id) = N'lab'
                                            ))
        )
            THROW 51938, 'Unrecognized lab foreign key found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.database_permissions AS permission_entry
            WHERE (permission_entry.class = 3 AND permission_entry.major_id = SCHEMA_ID(N'lab'))
               OR (permission_entry.class = 1 AND permission_entry.major_id IN
                   (SELECT object_id FROM sys.objects WHERE schema_id = SCHEMA_ID(N'lab')))
        )
            THROW 51939, 'Unrecognized lab permission found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.extended_properties AS property_entry
            WHERE (property_entry.class = 3 AND property_entry.major_id = SCHEMA_ID(N'lab'))
               OR (property_entry.class = 1 AND property_entry.major_id IN
                   (SELECT object_id FROM sys.objects WHERE schema_id = SCHEMA_ID(N'lab')))
        )
            THROW 51940, 'Unrecognized lab extended property found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.computed_columns AS computed_column
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = computed_column.object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
        )
            THROW 51941, 'Unrecognized lab computed column found; refusing optional lab deletion.', 1;
        IF EXISTS
        (
            SELECT 1 FROM sys.tables AS parent_table
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
              AND (parent_table.temporal_type <> 0 OR parent_table.is_tracked_by_cdc <> 0)
        )
        OR EXISTS
        (
            SELECT 1 FROM sys.fulltext_indexes AS fulltext_index
            INNER JOIN sys.tables AS parent_table ON parent_table.object_id = fulltext_index.object_id
            WHERE parent_table.schema_id = SCHEMA_ID(N'lab')
        )
            THROW 51942, 'Unrecognized lab temporal, CDC, or fulltext feature found; refusing optional lab deletion.', 1;
        /* Constraints are owned only as exact children of allowlisted tables. Add those
           verified child IDs before checking dependencies so their normal expressions do
           not look like foreign incoming references. The workshop owns no lab triggers. */
        INSERT @OwnedLabObjectIds (ObjectId, ObjectName, ObjectType)
        SELECT constraint_entry.object_id, constraint_entry.name, constraint_entry.type
        FROM sys.objects AS constraint_entry
        INNER JOIN sys.tables AS parent_table ON parent_table.object_id = constraint_entry.parent_object_id
        INNER JOIN @ExpectedLabConstraints AS expected
            ON expected.TableName = parent_table.name
           AND expected.ConstraintName = constraint_entry.name
           AND expected.ConstraintType = constraint_entry.type
        WHERE parent_table.schema_id = SCHEMA_ID(N'lab');

        IF EXISTS
        (
            SELECT 1
            FROM sys.sql_expression_dependencies AS dependency
            WHERE
                (
                    dependency.referenced_id IN (SELECT ObjectId FROM @OwnedLabObjectIds)
                    AND (dependency.referencing_id IS NULL
                         OR dependency.referencing_id NOT IN (SELECT ObjectId FROM @OwnedLabObjectIds))
                )
                OR
                (
                    dependency.referencing_id IN (SELECT ObjectId FROM @OwnedLabObjectIds)
                    AND dependency.referenced_id IS NOT NULL
                    AND OBJECT_SCHEMA_NAME(dependency.referenced_id) = N'lab'
                    AND dependency.referenced_id NOT IN (SELECT ObjectId FROM @OwnedLabObjectIds)
                )
                OR
                (
                    dependency.referencing_id NOT IN (SELECT ObjectId FROM @OwnedLabObjectIds)
                    AND dependency.referenced_schema_name = N'lab'
                    AND EXISTS
                    (
                        SELECT 1 FROM @ExpectedLabObjects AS expected
                        WHERE expected.ObjectName = dependency.referenced_entity_name
                    )
                    AND (dependency.referenced_database_name IS NULL
                         OR dependency.referenced_database_name = DB_NAME())
                )
                OR
                (
                    dependency.referencing_id IN (SELECT ObjectId FROM @OwnedLabObjectIds)
                    AND dependency.referenced_schema_name = N'lab'
                    AND NOT EXISTS
                    (
                        SELECT 1 FROM @ExpectedLabObjects AS expected
                        WHERE expected.ObjectName = dependency.referenced_entity_name
                    )
                    AND (dependency.referenced_database_name IS NULL
                         OR dependency.referenced_database_name = DB_NAME())
                )
        )
            THROW 51943, 'Unrecognized lab dependency found; refusing optional lab deletion.', 1;

        IF NOT EXISTS
        (
            SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID(N'lab.WorkshopMarker', N'U')
              AND name = N'MarkerId' AND system_type_id = TYPE_ID(N'uniqueidentifier')
        )
        OR EXISTS
        (
            SELECT 1 FROM sys.sql_modules
            WHERE object_id IN (OBJECT_ID(N'lab.usp_MonthEndSalesBaseline', N'P'),
                                OBJECT_ID(N'lab.usp_MonthEndSalesOptimized', N'P'))
              AND definition NOT LIKE N'%68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C%'
        )
            THROW 51926, 'Unexpected or drifted lab object definition found; refusing optional lab deletion.', 1;

        /* Recheck all databases immediately before destructive DDL. The lifecycle application
           lock serializes workshop setup and cleanup, but SQL Server cannot lock arbitrary DDL
           in every database. A cross-database DDL race remains possible; metadata uncertainty,
           access loss, or a detected reference therefore fails closed. */
        SET @InaccessibleDatabaseCount =
        (
            SELECT COUNT(*)
            FROM @CrossDatabaseScan
            WHERE COALESCE(HAS_DBACCESS(DatabaseName), 0) <> 1
        );
        IF @InaccessibleDatabaseCount > 0
        BEGIN
            SET @CrossDatabaseError = N'Database accessibility changed before optional lab deletion; inaccessible count '
                + CONVERT(nvarchar(10), @InaccessibleDatabaseCount) + N'.';
            THROW 51952, @CrossDatabaseError, 1;
        END;

        IF EXISTS
        (
            SELECT database_id, name
            FROM sys.databases
            WHERE state_desc = N'ONLINE'
              AND source_database_id IS NULL
              AND name <> N'tempdb'
              AND (database_id > 4 OR name IN (N'master', N'model', N'msdb'))
            EXCEPT
            SELECT DatabaseId, DatabaseName FROM @CrossDatabaseScan
        )
        OR EXISTS
        (
            SELECT DatabaseId, DatabaseName FROM @CrossDatabaseScan
            EXCEPT
            SELECT database_id, name
            FROM sys.databases
            WHERE state_desc = N'ONLINE'
              AND source_database_id IS NULL
              AND name <> N'tempdb'
              AND (database_id > 4 OR name IN (N'master', N'model', N'msdb'))
        )
            THROW 51953, 'The eligible database set changed during optional lab deletion safety checks.', 1;

        CREATE TABLE #OwnedLabObjects
        (
            ObjectId int NOT NULL PRIMARY KEY,
            ObjectName sysname NOT NULL,
            ObjectType char(2) NOT NULL
        );
        INSERT #OwnedLabObjects (ObjectId, ObjectName, ObjectType)
        SELECT ObjectId, ObjectName, ObjectType FROM @OwnedLabObjectIds;

        CREATE TABLE #CrossDatabaseFindings
        (
            FindingType char(1) NOT NULL,
            DatabaseName sysname NOT NULL
        );

        DECLARE @CrossDatabaseOrdinal int = 1;
        DECLARE @CrossDatabaseName sysname;
        DECLARE @CrossDatabaseSql nvarchar(max);
        WHILE @CrossDatabaseOrdinal <= @CrossDatabaseCount
        BEGIN
            SELECT @CrossDatabaseName = DatabaseName
            FROM @CrossDatabaseScan
            WHERE DatabaseOrdinal = @CrossDatabaseOrdinal;

            SET @CrossDatabaseSql = N'USE ' + QUOTENAME(@CrossDatabaseName) + N';
IF HAS_PERMS_BY_NAME(@ScannedDatabase, N''DATABASE'', N''VIEW DEFINITION'') <> 1
    THROW 51947, N''Database metadata visibility is insufficient.'', 1;

INSERT #CrossDatabaseFindings (FindingType, DatabaseName)
SELECT DISTINCT N''D'', @ScannedDatabase
FROM sys.sql_expression_dependencies AS dependency
WHERE
    (
        LOWER(dependency.referenced_schema_name) COLLATE Latin1_General_100_BIN2 =
            LOWER(@TargetSchema) COLLATE Latin1_General_100_BIN2
        AND EXISTS
        (
            SELECT 1 FROM #OwnedLabObjects AS owned
            WHERE LOWER(owned.ObjectName) COLLATE Latin1_General_100_BIN2 =
                LOWER(dependency.referenced_entity_name) COLLATE Latin1_General_100_BIN2
        )
        AND
        (
            LOWER(dependency.referenced_database_name) COLLATE Latin1_General_100_BIN2 =
                LOWER(@TargetDatabase) COLLATE Latin1_General_100_BIN2
            OR
            (
                LOWER(@ScannedDatabase) COLLATE Latin1_General_100_BIN2 =
                    LOWER(@TargetDatabase) COLLATE Latin1_General_100_BIN2
                AND dependency.referenced_database_name IS NULL
            )
        )
        AND NOT
        (
            LOWER(@ScannedDatabase) COLLATE Latin1_General_100_BIN2 =
                LOWER(@TargetDatabase) COLLATE Latin1_General_100_BIN2
            AND dependency.referencing_id IN
                (SELECT owned.ObjectId FROM #OwnedLabObjects AS owned)
        )
    )
    OR
    (
        LOWER(@ScannedDatabase) COLLATE Latin1_General_100_BIN2 =
            LOWER(@TargetDatabase) COLLATE Latin1_General_100_BIN2
        AND dependency.referenced_id IN
            (SELECT owned.ObjectId FROM #OwnedLabObjects AS owned)
        AND
        (
            dependency.referencing_id IS NULL
            OR dependency.referencing_id NOT IN
                (SELECT owned.ObjectId FROM #OwnedLabObjects AS owned)
        )
    );

INSERT #CrossDatabaseFindings (FindingType, DatabaseName)
SELECT DISTINCT N''S'', @ScannedDatabase
FROM sys.synonyms AS synonym_entry
CROSS APPLY
(
    SELECT LOWER(REPLACE(REPLACE(synonym_entry.base_object_name, N''['', N''''), N'']'', N''''))
        COLLATE Latin1_General_100_BIN2 AS NormalizedBaseObjectName
) AS normalized
WHERE
    (
        PARSENAME(normalized.NormalizedBaseObjectName, 3) =
            LOWER(@TargetDatabase) COLLATE Latin1_General_100_BIN2
        AND PARSENAME(normalized.NormalizedBaseObjectName, 2) =
            LOWER(@TargetSchema) COLLATE Latin1_General_100_BIN2
        AND EXISTS
        (
            SELECT 1 FROM #OwnedLabObjects AS owned
            WHERE LOWER(owned.ObjectName) COLLATE Latin1_General_100_BIN2 =
                  PARSENAME(normalized.NormalizedBaseObjectName, 1)
        )
    )
    OR normalized.NormalizedBaseObjectName LIKE
        N''%'' + LOWER(@TargetDatabase) COLLATE Latin1_General_100_BIN2 + N''%''
    OR
    (
        LOWER(@ScannedDatabase) COLLATE Latin1_General_100_BIN2 =
            LOWER(@TargetDatabase) COLLATE Latin1_General_100_BIN2
        AND PARSENAME(normalized.NormalizedBaseObjectName, 3) IS NULL
        AND PARSENAME(normalized.NormalizedBaseObjectName, 2) =
            LOWER(@TargetSchema) COLLATE Latin1_General_100_BIN2
        AND EXISTS
        (
            SELECT 1 FROM #OwnedLabObjects AS owned
            WHERE LOWER(owned.ObjectName) COLLATE Latin1_General_100_BIN2 =
                  PARSENAME(normalized.NormalizedBaseObjectName, 1)
        )
    );';
            BEGIN TRY
                EXEC sys.sp_executesql @CrossDatabaseSql,
                    N'@TargetDatabase sysname, @TargetSchema sysname, @ScannedDatabase sysname',
                    @TargetDatabase = @DatabaseName,
                    @TargetSchema = N'lab',
                    @ScannedDatabase = @CrossDatabaseName;
            END TRY
            BEGIN CATCH
                SET @CrossDatabaseError = N'Cannot prove optional lab deletion safe in database '
                    + QUOTENAME(@CrossDatabaseName) + N'.';
                THROW 51948, @CrossDatabaseError, 1;
            END CATCH;

            SET @CrossDatabaseOrdinal += 1;
        END;

        IF EXISTS (SELECT 1 FROM #CrossDatabaseFindings WHERE FindingType = 'D')
            THROW 51949, 'Unrecognized cross-database lab dependency found; refusing optional lab deletion.', 1;
        IF EXISTS (SELECT 1 FROM #CrossDatabaseFindings WHERE FindingType = 'S')
            THROW 51950, 'Unrecognized cross-database lab synonym found; refusing optional lab deletion.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM @CrossDatabaseScan
            WHERE COALESCE(HAS_DBACCESS(DatabaseName), 0) <> 1
        )
            THROW 51954, 'Database accessibility changed immediately before optional lab deletion.', 1;

        /* The application lock narrows workshop lifecycle races; unrelated cross-database DDL races
           cannot be fully locked, so the safest behavior is to abort on every uncertain scan. */

        DROP VIEW IF EXISTS lab.vw_WorkshopSampleSummary;
        DROP VIEW IF EXISTS lab.vw_WorkshopRunSummary;
        DROP PROCEDURE IF EXISTS lab.usp_CompareWorkshopRuns;
        DROP PROCEDURE IF EXISTS lab.usp_GetProcedurePlanSummary;
        DROP PROCEDURE IF EXISTS lab.usp_GetQueryStoreWaits;
        DROP PROCEDURE IF EXISTS lab.usp_GetQueryStoreTopQueries;
        DROP PROCEDURE IF EXISTS lab.usp_GetActiveWorkshopGrants;
        DROP PROCEDURE IF EXISTS lab.usp_GetMemorySnapshot;
        DROP PROCEDURE IF EXISTS lab.usp_MonthEndSalesOptimized;
        DROP PROCEDURE IF EXISTS lab.usp_MonthEndSalesBaseline;

        ALTER TABLE lab.WorkshopRequestSample DROP CONSTRAINT FK_WorkshopRequestSample_WorkshopSample;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT FK_WorkshopSample_WorkshopRun;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT FK_WorkshopTrial_WorkshopRun;
        ALTER TABLE lab.ValidationRun DROP CONSTRAINT FK_ValidationRun_BaselineWorkshopRun;
        ALTER TABLE lab.ValidationRun DROP CONSTRAINT FK_ValidationRun_OptimizedWorkshopRun;
        DROP INDEX IX_FactSales_OrderDate_Territory ON lab.FactSales;
        DROP INDEX IX_WorkshopTrial_ValidationBatchID ON lab.WorkshopTrial;

        ALTER TABLE lab.FactSales DROP CONSTRAINT CK_FactSales_Positive;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_EvidenceClassification;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_Phase;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_Status;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_Outcome;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_Timestamps;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_FrozenSettingsJson;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_BaselineIdentifiers;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_OptimizedIdentifiers;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT CK_WorkshopRun_Metrics;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT CK_WorkshopSample_Sequence;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT CK_WorkshopSample_Phase;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT CK_WorkshopSample_PoolMemory;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT CK_WorkshopSample_Utilization;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT CK_WorkshopSample_Counts;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT CK_WorkshopSample_HostMemory;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT CK_WorkshopSample_ProcessMemory;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT CK_WorkshopSample_ServerMemory;
        ALTER TABLE lab.WorkshopRequestSample DROP CONSTRAINT CK_WorkshopRequestSample_Identifiers;
        ALTER TABLE lab.WorkshopRequestSample DROP CONSTRAINT CK_WorkshopRequestSample_Memory;
        ALTER TABLE lab.WorkshopRequestSample DROP CONSTRAINT CK_WorkshopRequestSample_Wait;
        ALTER TABLE lab.WorkshopRequestSample DROP CONSTRAINT CK_WorkshopRequestSample_QueryIdentifiers;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT CK_WorkshopTrial_Sequence;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT CK_WorkshopTrial_ParameterSlot;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT CK_WorkshopTrial_Phase;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT CK_WorkshopTrial_Schedule;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT CK_WorkshopTrial_Metrics;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT CK_WorkshopTrial_Validation;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT CK_WorkshopTrial_Timestamps;
        ALTER TABLE lab.ValidationRun DROP CONSTRAINT CK_ValidationRun_Linkage;
        ALTER TABLE lab.ValidationRun DROP CONSTRAINT UQ_ValidationRun_BatchCase;

        ALTER TABLE lab.WorkshopRequestSample DROP CONSTRAINT PK_WorkshopRequestSample;
        ALTER TABLE lab.WorkshopTrial DROP CONSTRAINT PK_WorkshopTrial;
        ALTER TABLE lab.ValidationRun DROP CONSTRAINT PK_ValidationRun;
        ALTER TABLE lab.WorkshopSample DROP CONSTRAINT PK_WorkshopSample;
        ALTER TABLE lab.WorkshopRun DROP CONSTRAINT PK_WorkshopRun;
        ALTER TABLE lab.DataGenerationLog DROP CONSTRAINT PK_DataGenerationLog;
        ALTER TABLE lab.FactSales DROP CONSTRAINT PK_FactSales;
        ALTER TABLE lab.Numbers DROP CONSTRAINT PK_Numbers;
        ALTER TABLE lab.WorkshopMarker DROP CONSTRAINT PK_WorkshopMarker;

        DROP TABLE IF EXISTS lab.WorkshopRequestSample;
        DROP TABLE IF EXISTS lab.WorkshopTrial;
        DROP TABLE IF EXISTS lab.ValidationRun;
        DROP TABLE IF EXISTS lab.WorkshopSample;
        DROP TABLE IF EXISTS lab.WorkshopRun;
        DROP TABLE IF EXISTS lab.DataGenerationLog;
        DROP TABLE IF EXISTS lab.FactSales;
        DROP TABLE IF EXISTS lab.Numbers;
        DROP TABLE IF EXISTS lab.WorkshopMarker;
                DELETE WorkshopAdmin.dbo.LabObjectOwnership
                WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
                    AND DatabaseName = DB_NAME();
        IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE schema_id = SCHEMA_ID(N'lab'))
            DROP SCHEMA lab;
        ELSE
            PRINT N'Foreign objects remain in lab schema; preserving the schema and those objects.';
    END;

    UPDATE WorkshopAdmin.dbo.CleanupAudit
    SET CompletedAtUtc = SYSUTCDATETIME(), Outcome = 'Completed', ErrorNumber = NULL
    WHERE CleanupAuditId = @CleanupAuditId;

    EXEC sys.sp_releaseapplock @Resource = N'MCP_SQL_WORKSHOP_LIFECYCLE', @LockOwner = N'Session';
    SET @LockHeld = 0;

    SELECT N'CleanupCompleted' AS CleanupStatus, @DropLabData AS DropLabData,
           CASE WHEN @DropLabData = 0 THEN N'Lab data and procedures preserved for rerun.'
                ELSE N'Exact marker-owned lab objects removed.' END AS LabDataDisposition;
END TRY
BEGIN CATCH
    DECLARE @OriginalErrorNumber int = ERROR_NUMBER();
    /* Best-effort restore after a partial cleanup; retain the original error with bare THROW. */
    BEGIN TRY
        EXEC sys.sp_configure N'show advanced options', 1;
        RECONFIGURE;
        DECLARE @CatchCurrentMinServerMemoryMB int =
            (SELECT CONVERT(int, value_in_use) FROM sys.configurations WHERE name = N'min server memory (MB)');
        IF @CatchCurrentMinServerMemoryMB > @BackupMaxServerMemoryMB
        BEGIN
            EXEC sys.sp_configure N'min server memory (MB)', 0;
            RECONFIGURE;
        END;
        EXEC sys.sp_configure N'max server memory (MB)', @BackupMaxServerMemoryMB;
        RECONFIGURE;
        EXEC sys.sp_configure N'min server memory (MB)', @BackupMinServerMemoryMB;
        RECONFIGURE;
        EXEC sys.sp_configure N'show advanced options', @BackupShowAdvancedOptions;
        RECONFIGURE;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += CONCAT(N' server memory error ', ERROR_NUMBER(), N';');
    END CATCH;

    BEGIN TRY
        IF @BackupResourceGovernorEnabled = 0
            EXEC master.sys.sp_executesql N'USE [master]; ALTER RESOURCE GOVERNOR DISABLE;';
        ELSE
            EXEC master.sys.sp_executesql N'USE [master]; ALTER RESOURCE GOVERNOR RECONFIGURE;';
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += CONCAT(N' Resource Governor error ', ERROR_NUMBER(), N';');
    END CATCH;

    BEGIN TRY
        IF @CleanupAuditId IS NOT NULL
            UPDATE WorkshopAdmin.dbo.CleanupAudit
            SET CompletedAtUtc = SYSUTCDATETIME(), Outcome = 'Failed', ErrorNumber = @OriginalErrorNumber
            WHERE CleanupAuditId = @CleanupAuditId;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += CONCAT(N' cleanup audit error ', ERROR_NUMBER(), N';');
    END CATCH;

    BEGIN TRY
        IF @LockHeld = 1
        BEGIN
            EXEC sys.sp_releaseapplock @Resource = N'MCP_SQL_WORKSHOP_LIFECYCLE', @LockOwner = N'Session';
            SET @LockHeld = 0;
        END;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += CONCAT(N' application lock error ', ERROR_NUMBER(), N';');
    END CATCH;

    IF @RestorationErrors <> N''
        PRINT N'Best-effort restore warnings (original error preserved): '
            + LEFT(REPLACE(REPLACE(@RestorationErrors, NCHAR(13), N' '), NCHAR(10), N' '), 1800);
    THROW;
END CATCH;
GO
