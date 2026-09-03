:on error exit
/*
Optional, reversible Query Store experiment for the baseline procedure only.
The caller must set ExpectedServerName, DatabaseName, and AllowOptionalHintExercise
through parameterized sys.sp_set_session_context calls. OptionalHintQueryContextSettingsId
may be supplied to explicitly select one context when Query Store contains several.
This exercise is separate from lab.usp_MonthEndSalesOptimized and always removes its hint.
*/
IF @@TRANCOUNT <> 0
    THROW 51800, 'The optional hint exercise cannot run inside an active transaction.', 1;

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExpectedServerName nvarchar(256) = NULLIF(LOWER(LTRIM(RTRIM(TRY_CONVERT(nvarchar(256), SESSION_CONTEXT(N'ExpectedServerName'))))), N'');
DECLARE @DatabaseName sysname = NULLIF(LTRIM(RTRIM(TRY_CONVERT(sysname, SESSION_CONTEXT(N'DatabaseName')))), N'');
DECLARE @AllowOptionalHintExerciseValue sql_variant = SESSION_CONTEXT(N'AllowOptionalHintExercise');
DECLARE @AllowOptionalHintExercise bit = TRY_CONVERT(bit, @AllowOptionalHintExerciseValue);
DECLARE @RequestedContextSettingsId bigint = TRY_CONVERT(bigint, SESSION_CONTEXT(N'OptionalHintQueryContextSettingsId'));
DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupHash varbinary(32) = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B;
DECLARE @ExpectedHint nvarchar(4000) = N'OPTION (MAX_GRANT_PERCENT = 10)';
DECLARE @ExpectedHintHash varbinary(32) = HASHBYTES('SHA2_256', CONVERT(varbinary(max), N'OPTION(MAX_GRANT_PERCENT=10)'));
DECLARE @ActualMachine nvarchar(256) = LOWER(LTRIM(RTRIM(CONVERT(nvarchar(256), SERVERPROPERTY('MachineName')))));
DECLARE @ActualServer nvarchar(256) = LOWER(LTRIM(RTRIM(CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')))));
DECLARE @ExpectedHost nvarchar(256) = @ExpectedServerName;

IF @ExpectedServerName IS NULL THROW 51801, 'ExpectedServerName is required.', 1;
IF @DatabaseName IS NULL OR @DatabaseName <> N'AdventureWorks2022' OR DB_NAME() <> N'AdventureWorks2022'
    THROW 51802, 'The current and requested database must be exactly AdventureWorks2022.', 1;
IF TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 16
    THROW 51803, 'SQL Server 2022 is required.', 1;
IF CHARINDEX(N'\', @ExpectedHost) > 0 SET @ExpectedHost = LEFT(@ExpectedHost, CHARINDEX(N'\', @ExpectedHost) - 1);
IF CHARINDEX(N'.', @ExpectedHost) > 0 SET @ExpectedHost = LEFT(@ExpectedHost, CHARINDEX(N'.', @ExpectedHost) - 1);
IF CHARINDEX(N'\', @ActualServer) > 0 SET @ActualServer = LEFT(@ActualServer, CHARINDEX(N'\', @ActualServer) - 1);
IF CHARINDEX(N'.', @ActualServer) > 0 SET @ActualServer = LEFT(@ActualServer, CHARINDEX(N'.', @ActualServer) - 1);
IF CHARINDEX(N'.', @ActualMachine) > 0 SET @ActualMachine = LEFT(@ActualMachine, CHARINDEX(N'.', @ActualMachine) - 1);
IF @ExpectedHost NOT IN (@ActualMachine, @ActualServer)
    THROW 51804, 'ExpectedServerName does not match this SQL Server host.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM master.sys.extended_properties
    WHERE class = 0 AND name = N'MCP_SQL_WORKSHOP'
      AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
)
    THROW 51805, 'The exact server workshop marker is absent.', 1;
IF OBJECT_ID(N'lab.WorkshopMarker', N'U') IS NULL OR NOT EXISTS
(
    SELECT 1 FROM lab.WorkshopMarker
    WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
      AND SetupName = @WorkshopSetupName AND SetupHash = @WorkshopSetupHash
)
    THROW 51806, 'The exact database workshop marker is absent.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM sys.database_query_store_options
    WHERE actual_state_desc = N'READ_WRITE' AND desired_state_desc = N'READ_WRITE'
)
    THROW 51807, 'Query Store must be READ_WRITE.', 1;
IF OBJECT_ID(N'lab.usp_MonthEndSalesBaseline', N'P') IS NULL
    THROW 51808, 'The baseline procedure is missing.', 1;
IF @RequestedContextSettingsId IS NOT NULL AND @RequestedContextSettingsId <= 0
    THROW 51809, 'OptionalHintQueryContextSettingsId must be positive when supplied.', 1;
IF @AllowOptionalHintExerciseValue IS NOT NULL
    AND (SQL_VARIANT_PROPERTY(@AllowOptionalHintExerciseValue, 'BaseType') <> N'bit'
          OR TRY_CONVERT(int, @AllowOptionalHintExerciseValue) IS NULL
        OR TRY_CONVERT(int, @AllowOptionalHintExerciseValue) NOT IN (0, 1))
    THROW 51818, 'AllowOptionalHintExercise must be exactly 0 or 1.', 1;

IF ISNULL(@AllowOptionalHintExercise, 0) <> 1
BEGIN
    SELECT N'NotRun' AS HintExerciseStatus,
           N'Set AllowOptionalHintExercise session context to 1 to permit any hint mutation.' AS Detail;
    RETURN;
END;

IF DB_ID(N'WorkshopAdmin') IS NULL OR NOT EXISTS
(
    SELECT 1 FROM WorkshopAdmin.sys.extended_properties
    WHERE class = 0 AND name = N'MCP_SQL_WORKSHOP'
      AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
)
    THROW 51810, 'The owned WorkshopAdmin database is required.', 1;

DECLARE @ApplicationLockResult int;
DECLARE @InvocationId uniqueidentifier = NEWID();
DECLARE @QueryId bigint;
DECLARE @QueryContextSettingsId bigint;
DECLARE @QueryHash binary(8);
DECLARE @QueryTextHash varbinary(32);
DECLARE @MatchCount int;
DECLARE @CreatedByThisInvocation bit = 0;
DECLARE @OwnedHintForThisInvocation bit = 0;
DECLARE @SetAttempted bit = 0;
DECLARE @OriginalRunId sql_variant = SESSION_CONTEXT(N'WorkshopRunId');
DECLARE @OriginalManualExecution sql_variant = SESSION_CONTEXT(N'WorkshopManualExecution');
DECLARE @ExerciseRunId uniqueidentifier = NEWID();
DECLARE @ExerciseRunContext sql_variant = CONVERT(sql_variant, @ExerciseRunId);
DECLARE @ExerciseManualContext sql_variant = CONVERT(sql_variant, CONVERT(int, 1));
DECLARE @DiscoveryScope nvarchar(64) = N'Exclude own diagnostic text';

EXEC @ApplicationLockResult = sys.sp_getapplock
    @Resource = N'MCP_SQL_WORKSHOP_LIFECYCLE',
    @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0;
IF @ApplicationLockResult < 0
    THROW 51811, 'Another optional hint exercise is active.', 1;

BEGIN TRY
    IF OBJECT_ID(N'WorkshopAdmin.dbo.QueryStoreHintOwnership', N'U') IS NULL
    BEGIN
        EXEC WorkshopAdmin.sys.sp_executesql N'
            CREATE TABLE dbo.QueryStoreHintOwnership
            (
                MarkerId uniqueidentifier NOT NULL,
                SchemaVersion int NOT NULL,
                DatabaseName sysname NOT NULL,
                QueryId bigint NOT NULL,
                QueryContextSettingsId bigint NOT NULL,
                QueryHash binary(8) NOT NULL,
                QueryTextHash varbinary(32) NOT NULL,
                HintText nvarchar(4000) NOT NULL,
                HintHash varbinary(32) NOT NULL,
                OwnershipState varchar(10) NOT NULL,
                InvocationId uniqueidentifier NOT NULL,
                ClaimedAtUtc datetime2(3) NOT NULL,
                ClearedAtUtc datetime2(3) NULL,
                CONSTRAINT PK_QueryStoreHintOwnership PRIMARY KEY
                    (MarkerId, SchemaVersion, DatabaseName, QueryId)
            );';
    END;

    DECLARE @Candidates table
    (
        QueryId bigint NOT NULL PRIMARY KEY,
        QueryContextSettingsId bigint NOT NULL,
        QueryHash binary(8) NOT NULL,
        QueryTextHash varbinary(32) NOT NULL
    );

    /* Exclude own diagnostic text: match only the captured baseline INSERT statement and
       explicitly reject text that inspects Query Store hint metadata. */
    INSERT @Candidates (QueryId, QueryContextSettingsId, QueryHash, QueryTextHash)
    SELECT q.query_id,
           q.context_settings_id,
           q.query_hash,
           HASHBYTES('SHA2_256', CONVERT(varbinary(max),
               UPPER(REPLACE(REPLACE(REPLACE(qt.query_sql_text, NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''))))
    FROM sys.query_store_query AS q
    INNER JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    WHERE q.object_id = OBJECT_ID(N'lab.usp_MonthEndSalesBaseline', N'P')
      AND (@RequestedContextSettingsId IS NULL OR q.context_settings_id = @RequestedContextSettingsId)
      AND UPPER(qt.query_sql_text) LIKE N'%INSERT @WIDEWORK%'
      AND UPPER(qt.query_sql_text) LIKE N'%FROM LAB.FACTSALES AS FS%'
      AND UPPER(qt.query_sql_text) LIKE N'%CONVERT(DATE, FS.ORDERDATE)%'
      AND UPPER(qt.query_sql_text) NOT LIKE N'%SYS.QUERY_STORE_QUERY_HINTS%'
      AND UPPER(qt.query_sql_text) NOT LIKE N'%SP_QUERY_STORE_SET_HINTS%';

    SELECT @MatchCount = COUNT(*) FROM @Candidates;
    IF @MatchCount <> 1
        THROW 51812, 'Exactly one baseline Query Store statement is required; use OptionalHintQueryContextSettingsId to select an explicit context.', 1;

    SELECT @QueryId = QueryId, @QueryContextSettingsId = QueryContextSettingsId,
           @QueryHash = QueryHash, @QueryTextHash = QueryTextHash
    FROM @Candidates;

        DECLARE @BeforeStatistics table
        (
         ExecutionCount bigint NOT NULL,
         TotalDurationMicroseconds decimal(38,4) NOT NULL,
         TotalCpuMicroseconds decimal(38,4) NOT NULL,
         TotalLogicalReads decimal(38,4) NOT NULL,
         LastExecutionTime datetimeoffset NULL
        );
        INSERT @BeforeStatistics
        SELECT COALESCE(SUM(CONVERT(bigint, runtime.count_executions)), 0),
            COALESCE(SUM(CONVERT(decimal(38,4), runtime.avg_duration) * runtime.count_executions), 0),
            COALESCE(SUM(CONVERT(decimal(38,4), runtime.avg_cpu_time) * runtime.count_executions), 0),
            COALESCE(SUM(CONVERT(decimal(38,4), runtime.avg_logical_io_reads) * runtime.count_executions), 0),
            MAX(plan_entry.last_execution_time)
        FROM sys.query_store_plan AS plan_entry
        LEFT JOIN sys.query_store_runtime_stats AS runtime ON runtime.plan_id = plan_entry.plan_id
        WHERE plan_entry.query_id = @QueryId;

    IF EXISTS (SELECT 1 FROM sys.query_store_query_hints WHERE query_id = @QueryId)
    BEGIN
        IF NOT EXISTS
        (
            SELECT 1
            FROM sys.query_store_query_hints AS hint
            INNER JOIN WorkshopAdmin.dbo.QueryStoreHintOwnership AS ownership
                ON ownership.QueryId = hint.query_id
            WHERE hint.query_id = @QueryId
              AND UPPER(REPLACE(REPLACE(REPLACE(REPLACE(hint.query_hint_text, N' ', N''), NCHAR(9), N''), NCHAR(10), N''), NCHAR(13), N'')) = N'OPTION(MAX_GRANT_PERCENT=10)'
              AND ownership.MarkerId = @WorkshopMarker
              AND ownership.SchemaVersion = @WorkshopSchemaVersion
              AND ownership.DatabaseName = DB_NAME()
              AND ownership.QueryContextSettingsId = @QueryContextSettingsId
              AND ownership.QueryHash = @QueryHash
              AND ownership.QueryTextHash = @QueryTextHash
              AND ownership.HintHash = @ExpectedHintHash
              AND ownership.OwnershipState = 'Active'
        )
            THROW 51813, 'A foreign or manual Query Store hint exists; it will not be overwritten.', 1;
        SET @OwnedHintForThisInvocation = 1;
    END
    ELSE
    BEGIN
        IF EXISTS
        (
            SELECT 1 FROM WorkshopAdmin.dbo.QueryStoreHintOwnership
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND DatabaseName = DB_NAME() AND QueryId = @QueryId
              AND OwnershipState IN ('Pending', 'Active')
        )
            THROW 51814, 'Stale hint ownership metadata exists without a matching Query Store hint.', 1;
        IF EXISTS
        (
            SELECT 1 FROM WorkshopAdmin.dbo.QueryStoreHintOwnership
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND DatabaseName = DB_NAME() AND QueryId = @QueryId
              AND OwnershipState = 'Cleared'
              AND QueryContextSettingsId = @QueryContextSettingsId
              AND QueryHash = @QueryHash AND QueryTextHash = @QueryTextHash
              AND HintHash = @ExpectedHintHash
        )
        BEGIN
            UPDATE WorkshopAdmin.dbo.QueryStoreHintOwnership
            SET OwnershipState = 'Pending', InvocationId = @InvocationId,
                ClaimedAtUtc = SYSUTCDATETIME(), ClearedAtUtc = NULL
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND DatabaseName = DB_NAME() AND QueryId = @QueryId
              AND OwnershipState = 'Cleared';
        END
        ELSE IF EXISTS
        (
            SELECT 1 FROM WorkshopAdmin.dbo.QueryStoreHintOwnership
            WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
              AND DatabaseName = DB_NAME() AND QueryId = @QueryId
        )
            THROW 51819, 'Cleared hint ownership fingerprints do not match the discovered baseline statement.', 1;
        ELSE
            INSERT INTO WorkshopAdmin.dbo.QueryStoreHintOwnership
                (MarkerId, SchemaVersion, DatabaseName, QueryId, QueryContextSettingsId,
                 QueryHash, QueryTextHash, HintText, HintHash, OwnershipState, InvocationId, ClaimedAtUtc)
            VALUES
                (@WorkshopMarker, @WorkshopSchemaVersion, DB_NAME(), @QueryId, @QueryContextSettingsId,
                 @QueryHash, @QueryTextHash, @ExpectedHint, @ExpectedHintHash, 'Pending', @InvocationId, SYSUTCDATETIME());
        SET @OwnedHintForThisInvocation = 1;
        SET @SetAttempted = 1;
        EXEC sys.sp_query_store_set_hints @query_id = @QueryId, @query_hints = @ExpectedHint;
        SET @CreatedByThisInvocation = 1;
        UPDATE WorkshopAdmin.dbo.QueryStoreHintOwnership
        SET OwnershipState = 'Active'
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
          AND DatabaseName = DB_NAME() AND QueryId = @QueryId
          AND InvocationId = @InvocationId AND OwnershipState = 'Pending';
        IF @@ROWCOUNT <> 1 THROW 51815, 'Hint ownership activation failed.', 1;
    END;

    IF NOT EXISTS
    (
        SELECT 1 FROM sys.query_store_query_hints
        WHERE query_id = @QueryId
          AND UPPER(REPLACE(REPLACE(REPLACE(REPLACE(query_hint_text, N' ', N''), NCHAR(9), N''), NCHAR(10), N''), NCHAR(13), N'')) = N'OPTION(MAX_GRANT_PERCENT=10)'
          AND ISNULL(last_query_hint_failure_reason, 0) = 0
    )
        THROW 51816, 'The Query Store hint was not applied successfully.', 1;

    SELECT query_id AS QueryId, query_hint_text AS QueryHintText,
           source_desc AS HintStatus, last_query_hint_failure_reason AS LastFailureReason,
           last_query_hint_failure_reason_desc AS LastFailureReasonDescription,
           query_hint_failure_count AS QueryHintFailureCount
    FROM sys.query_store_query_hints
    WHERE query_id = @QueryId;

    EXEC sys.sp_set_session_context @key = N'WorkshopRunId', @value = @ExerciseRunContext;
    EXEC sys.sp_set_session_context @key = N'WorkshopManualExecution', @value = @ExerciseManualContext;
    DECLARE @TestStartDate date = CONVERT(date, '2014-01-01');
    DECLARE @TestEndDateExclusive date = CONVERT(date, '2014-01-08');
    EXEC lab.usp_MonthEndSalesBaseline
        @StartDate = @TestStartDate,
        @EndDateExclusive = @TestEndDateExclusive,
        @TerritoryID = NULL,
        @TopCount = 10;
    EXEC sys.sp_set_session_context @key = N'WorkshopRunId', @value = @OriginalRunId;
    EXEC sys.sp_set_session_context @key = N'WorkshopManualExecution', @value = @OriginalManualExecution;

        EXEC sys.sp_query_store_flush_db;
        DECLARE @AfterStatistics table
        (
         ExecutionCount bigint NOT NULL,
         TotalDurationMicroseconds decimal(38,4) NOT NULL,
         TotalCpuMicroseconds decimal(38,4) NOT NULL,
         TotalLogicalReads decimal(38,4) NOT NULL,
         LastExecutionTime datetimeoffset NULL
        );
        INSERT @AfterStatistics
        SELECT COALESCE(SUM(CONVERT(bigint, runtime.count_executions)), 0),
            COALESCE(SUM(CONVERT(decimal(38,4), runtime.avg_duration) * runtime.count_executions), 0),
            COALESCE(SUM(CONVERT(decimal(38,4), runtime.avg_cpu_time) * runtime.count_executions), 0),
            COALESCE(SUM(CONVERT(decimal(38,4), runtime.avg_logical_io_reads) * runtime.count_executions), 0),
            MAX(plan_entry.last_execution_time)
        FROM sys.query_store_plan AS plan_entry
        LEFT JOIN sys.query_store_runtime_stats AS runtime ON runtime.plan_id = plan_entry.plan_id
        WHERE plan_entry.query_id = @QueryId;

        SELECT after_stats.ExecutionCount - before_stats.ExecutionCount AS ExerciseExecutionCount,
            after_stats.TotalDurationMicroseconds - before_stats.TotalDurationMicroseconds AS ExerciseDurationMicroseconds,
            after_stats.TotalCpuMicroseconds - before_stats.TotalCpuMicroseconds AS ExerciseCpuMicroseconds,
            after_stats.TotalLogicalReads - before_stats.TotalLogicalReads AS ExerciseLogicalReads,
            before_stats.LastExecutionTime AS BeforeLastExecutionTime,
            after_stats.LastExecutionTime AS AfterLastExecutionTime
        FROM @BeforeStatistics AS before_stats CROSS JOIN @AfterStatistics AS after_stats;

    /* Every workshop-owned hint, including an idempotently accepted prior hint, is temporary. */
    IF @OwnedHintForThisInvocation = 1
    BEGIN
        IF NOT EXISTS
        (
            SELECT 1 FROM sys.query_store_query_hints AS hint
            INNER JOIN WorkshopAdmin.dbo.QueryStoreHintOwnership AS ownership ON ownership.QueryId = hint.query_id
            WHERE hint.query_id = @QueryId
              AND UPPER(REPLACE(REPLACE(REPLACE(REPLACE(hint.query_hint_text, N' ', N''), NCHAR(9), N''), NCHAR(10), N''), NCHAR(13), N'')) = N'OPTION(MAX_GRANT_PERCENT=10)'
              AND ownership.MarkerId = @WorkshopMarker AND ownership.SchemaVersion = @WorkshopSchemaVersion
              AND ownership.DatabaseName = DB_NAME() AND ownership.HintHash = @ExpectedHintHash
              AND ownership.OwnershipState IN ('Pending', 'Active')
        )
            THROW 51820, 'Hint ownership changed before clear; refusing to clear a possibly foreign hint.', 1;
        EXEC sys.sp_query_store_clear_hints @query_id = @QueryId;
        UPDATE WorkshopAdmin.dbo.QueryStoreHintOwnership
        SET OwnershipState = 'Cleared', ClearedAtUtc = SYSUTCDATETIME()
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
          AND DatabaseName = DB_NAME() AND QueryId = @QueryId
          AND OwnershipState IN ('Pending', 'Active');
    END;
    IF EXISTS (SELECT 1 FROM sys.query_store_query_hints WHERE query_id = @QueryId)
        THROW 51817, 'The workshop Query Store hint remained after clear verification.', 1;

    EXEC sys.sp_releaseapplock @Resource = N'MCP_SQL_WORKSHOP_LIFECYCLE', @LockOwner = N'Session';
    SELECT N'Cleared' AS HintExerciseStatus, @QueryId AS QueryId,
           @QueryContextSettingsId AS QueryContextSettingsId,
           @QueryHash AS QueryHash, @QueryTextHash AS QueryTextHash,
            @CreatedByThisInvocation AS CreatedByThisInvocation,
            @DiscoveryScope AS DiscoveryScope;
END TRY
BEGIN CATCH
    DECLARE @OriginalErrorNumber int = ERROR_NUMBER();
    DECLARE @ClearAttemptError int = NULL;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'WorkshopRunId', @value = @OriginalRunId;
        EXEC sys.sp_set_session_context @key = N'WorkshopManualExecution', @value = @OriginalManualExecution;
    END TRY
    BEGIN CATCH
        PRINT CONCAT(N'Session context restore warning; error ', ERROR_NUMBER(), N'.');
    END CATCH;

    BEGIN TRY
        IF @OwnedHintForThisInvocation = 1 AND @QueryId IS NOT NULL
        BEGIN
            /* Clear attempt is limited to the query claimed by this invocation or an exact active workshop claim. */
            IF EXISTS
            (
                SELECT 1 FROM sys.query_store_query_hints AS hint
                INNER JOIN WorkshopAdmin.dbo.QueryStoreHintOwnership AS ownership ON ownership.QueryId = hint.query_id
                WHERE hint.query_id = @QueryId
                  AND UPPER(REPLACE(REPLACE(REPLACE(REPLACE(hint.query_hint_text, N' ', N''), NCHAR(9), N''), NCHAR(10), N''), NCHAR(13), N'')) = N'OPTION(MAX_GRANT_PERCENT=10)'
                  AND ownership.MarkerId = @WorkshopMarker AND ownership.SchemaVersion = @WorkshopSchemaVersion
                  AND ownership.DatabaseName = DB_NAME() AND ownership.HintHash = @ExpectedHintHash
                  AND ownership.OwnershipState IN ('Pending', 'Active')
                  AND (ownership.InvocationId = @InvocationId OR ownership.OwnershipState = 'Active')
            )
                EXEC sys.sp_query_store_clear_hints @query_id = @QueryId;
                        IF NOT EXISTS (SELECT 1 FROM sys.query_store_query_hints WHERE query_id = @QueryId)
                                UPDATE WorkshopAdmin.dbo.QueryStoreHintOwnership
                                SET OwnershipState = 'Cleared', ClearedAtUtc = SYSUTCDATETIME()
                                WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
                                    AND DatabaseName = DB_NAME() AND QueryId = @QueryId
                                    AND (InvocationId = @InvocationId OR OwnershipState = 'Active');
        END;
    END TRY
    BEGIN CATCH
        SET @ClearAttemptError = ERROR_NUMBER();
    END CATCH;

    IF @QueryId IS NOT NULL
    BEGIN
        SELECT query_id AS QueryId, query_hint_text AS QueryHintText,
               source_desc AS HintStatus, last_query_hint_failure_reason AS LastFailureReason,
               last_query_hint_failure_reason_desc AS LastFailureReasonDescription,
               query_hint_failure_count AS QueryHintFailureCount,
               @SetAttempted AS SetAttempted, @OriginalErrorNumber AS OriginalErrorNumber,
               @ClearAttemptError AS ClearAttemptError
        FROM sys.query_store_query_hints
        WHERE query_id = @QueryId;
    END;
    IF @ClearAttemptError IS NOT NULL
        PRINT CONCAT(N'Query Store hint clear attempt failed with error ', @ClearAttemptError,
                     N'; original error ', @OriginalErrorNumber, N' is preserved.');
    BEGIN TRY
        EXEC sys.sp_releaseapplock @Resource = N'MCP_SQL_WORKSHOP_LIFECYCLE', @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        PRINT CONCAT(N'Application lock release warning; error ', ERROR_NUMBER(), N'.');
    END CATCH;
    THROW;
END CATCH;
GO
