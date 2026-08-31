:on error exit
/*
Creates the bounded evidence contract and the six least-privileged diagnostics used by
Data API Builder. The bootstrap must pre-create the fixed server login. Procedures use
EXECUTE AS OWNER as accepted by the workshop contract; no TRUSTWORTHY change is made.
*/
IF @@TRANCOUNT <> 0
    THROW 51600, 'Diagnostics setup cannot run inside an active transaction.', 1;

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupHash varbinary(32) = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B;
DECLARE @DiagnosticsSetupAuthorized bit = TRY_CONVERT(bit, SESSION_CONTEXT(N'DiagnosticsSetupAuthorized'));

IF @DiagnosticsSetupAuthorized <> 1
    THROW 51601, 'DiagnosticsSetupAuthorized session context must equal 1.', 1;
IF DB_NAME() <> N'AdventureWorks2022'
   OR OBJECT_ID(N'lab.WorkshopMarker', N'U') IS NULL
   OR NOT EXISTS
   (
       SELECT 1
       FROM lab.WorkshopMarker
       WHERE MarkerId = @WorkshopMarker
         AND SchemaVersion = @WorkshopSchemaVersion
         AND SetupName = @WorkshopSetupName
         AND SetupHash = @WorkshopSetupHash
   )
    THROW 51602, 'The workshop marker contract is invalid.', 1;

IF OBJECT_ID(N'lab.WorkshopRun', N'U') IS NULL
BEGIN
    CREATE TABLE lab.WorkshopRun
    (
        RunID uniqueidentifier NOT NULL CONSTRAINT PK_WorkshopRun PRIMARY KEY,
        ParentComparisonID uniqueidentifier NULL,
        EvidenceClassification varchar(24) NOT NULL,
        Phase varchar(16) NOT NULL,
        RunStatus varchar(16) NOT NULL,
        Outcome varchar(24) NULL,
        StartedAtUtc datetime2(3) NOT NULL,
        CompletedAtUtc datetime2(3) NULL,
        FrozenSettingsHash varbinary(32) NOT NULL,
        FrozenSettingsJson nvarchar(4000) NOT NULL,
        BaselineQueryID bigint NULL,
        BaselinePlanID bigint NULL,
        OptimizedQueryID bigint NULL,
        OptimizedPlanID bigint NULL,
        DurationMs bigint NULL,
        CpuMs bigint NULL,
        LogicalReads bigint NULL,
        Spills bigint NULL,
        WaitTimeMs bigint NULL,
        CONSTRAINT CK_WorkshopRun_EvidenceClassification CHECK
            (EvidenceClassification IN
                ('DOC-VERIFIED', 'SUBSCRIPTION-VALIDATED', 'LAB-MEASURED', 'ASSUMPTION', 'TARGET', 'ILLUSTRATIVE')),
        CONSTRAINT CK_WorkshopRun_Phase CHECK (Phase IN ('Baseline', 'Optimized', 'Comparison')),
        CONSTRAINT CK_WorkshopRun_Status CHECK (RunStatus IN ('Pending', 'Running', 'Completed', 'Failed', 'Stopped')),
        CONSTRAINT CK_WorkshopRun_Outcome CHECK
            (Outcome IS NULL OR Outcome IN ('Improved', 'Inconclusive', 'Regressed', 'Failed')),
        CONSTRAINT CK_WorkshopRun_Timestamps CHECK (CompletedAtUtc IS NULL OR CompletedAtUtc >= StartedAtUtc),
        CONSTRAINT CK_WorkshopRun_FrozenSettingsJson CHECK
            (LEN(FrozenSettingsJson) BETWEEN 2 AND 4000 AND ISJSON(FrozenSettingsJson) = 1),
        CONSTRAINT CK_WorkshopRun_BaselineIdentifiers CHECK
            ((BaselineQueryID IS NULL AND BaselinePlanID IS NULL) OR (BaselineQueryID > 0 AND BaselinePlanID > 0)),
        CONSTRAINT CK_WorkshopRun_OptimizedIdentifiers CHECK
            ((OptimizedQueryID IS NULL AND OptimizedPlanID IS NULL) OR (OptimizedQueryID > 0 AND OptimizedPlanID > 0)),
        CONSTRAINT CK_WorkshopRun_Metrics CHECK
            ((DurationMs IS NULL OR DurationMs >= 0) AND (CpuMs IS NULL OR CpuMs >= 0)
             AND (LogicalReads IS NULL OR LogicalReads >= 0) AND (Spills IS NULL OR Spills >= 0)
             AND (WaitTimeMs IS NULL OR WaitTimeMs >= 0))
    );
END;

IF OBJECT_ID(N'lab.WorkshopSample', N'U') IS NULL
BEGIN
    CREATE TABLE lab.WorkshopSample
    (
        RunID uniqueidentifier NOT NULL,
        SampleSequence int NOT NULL,
        SampledAtUtc datetime2(3) NOT NULL,
        Phase varchar(16) NOT NULL,
        PoolTotalMemoryKB bigint NOT NULL,
        PoolGrantedMemoryKB bigint NOT NULL,
        PoolUsedMemoryKB bigint NOT NULL,
        PoolAvailableMemoryKB bigint NOT NULL,
        GrantUtilizationPercent decimal(6,2) NOT NULL,
        GranteeCount int NOT NULL,
        WaiterCount int NOT NULL,
        HostAvailableMemoryKB bigint NOT NULL,
        HostUsedMemoryKB bigint NOT NULL,
        ProcessPhysicalMemoryKB bigint NOT NULL,
        TotalServerMemoryKB bigint NOT NULL,
        TargetServerMemoryKB bigint NOT NULL,
        SystemLowMemorySignal bit NOT NULL,
        ProcessLowMemorySignal bit NOT NULL,
        CONSTRAINT PK_WorkshopSample PRIMARY KEY (RunID, SampleSequence),
        CONSTRAINT FK_WorkshopSample_WorkshopRun FOREIGN KEY (RunID) REFERENCES lab.WorkshopRun (RunID),
        CONSTRAINT CK_WorkshopSample_Sequence CHECK (SampleSequence > 0),
        CONSTRAINT CK_WorkshopSample_Phase CHECK (Phase IN ('Baseline', 'Optimized')),
        CONSTRAINT CK_WorkshopSample_PoolMemory CHECK
            (PoolTotalMemoryKB >= 0 AND PoolGrantedMemoryKB >= 0 AND PoolUsedMemoryKB >= 0 AND PoolAvailableMemoryKB >= 0),
        CONSTRAINT CK_WorkshopSample_Utilization CHECK (GrantUtilizationPercent BETWEEN 0 AND 100),
        CONSTRAINT CK_WorkshopSample_Counts CHECK (GranteeCount >= 0 AND WaiterCount >= 0),
        CONSTRAINT CK_WorkshopSample_HostMemory CHECK (HostAvailableMemoryKB >= 0 AND HostUsedMemoryKB >= 0),
        CONSTRAINT CK_WorkshopSample_ProcessMemory CHECK (ProcessPhysicalMemoryKB >= 0),
        CONSTRAINT CK_WorkshopSample_ServerMemory CHECK (TotalServerMemoryKB >= 0 AND TargetServerMemoryKB >= 0)
    );
END;

IF OBJECT_ID(N'lab.WorkshopRequestSample', N'U') IS NULL
BEGIN
    CREATE TABLE lab.WorkshopRequestSample
    (
        RunID uniqueidentifier NOT NULL,
        SampleSequence int NOT NULL,
        SessionID smallint NOT NULL,
        RequestID int NOT NULL,
        RequestedMemoryKB bigint NOT NULL,
        GrantedMemoryKB bigint NOT NULL,
        RequiredMemoryKB bigint NOT NULL,
        IdealMemoryKB bigint NOT NULL,
        UsedMemoryKB bigint NOT NULL,
        MaxUsedMemoryKB bigint NOT NULL,
        WaitOrder int NULL,
        WaitTimeMs bigint NOT NULL,
        QueryID bigint NULL,
        PlanID bigint NULL,
        CONSTRAINT PK_WorkshopRequestSample PRIMARY KEY (RunID, SampleSequence, SessionID, RequestID),
        CONSTRAINT FK_WorkshopRequestSample_WorkshopSample FOREIGN KEY (RunID, SampleSequence)
            REFERENCES lab.WorkshopSample (RunID, SampleSequence),
        CONSTRAINT CK_WorkshopRequestSample_Identifiers CHECK
            (SampleSequence > 0 AND SessionID > 0 AND RequestID >= 0),
        CONSTRAINT CK_WorkshopRequestSample_Memory CHECK
            (RequestedMemoryKB >= 0 AND GrantedMemoryKB >= 0 AND RequiredMemoryKB >= 0
             AND IdealMemoryKB >= 0 AND UsedMemoryKB >= 0 AND MaxUsedMemoryKB >= 0),
        CONSTRAINT CK_WorkshopRequestSample_Wait CHECK
            ((WaitOrder IS NULL OR WaitOrder >= 0) AND WaitTimeMs >= 0),
        CONSTRAINT CK_WorkshopRequestSample_QueryIdentifiers CHECK
            ((QueryID IS NULL AND PlanID IS NULL) OR (QueryID > 0 AND PlanID > 0))
    );
END;

IF (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'lab.WorkshopRun')) <> 19
   OR (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'lab.WorkshopSample')) <> 18
   OR (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'lab.WorkshopRequestSample')) <> 14
   OR COL_LENGTH(N'lab.WorkshopRun', N'FrozenSettingsJson') <> 8000
   OR COL_LENGTH(N'lab.WorkshopRun', N'FrozenSettingsHash') <> 32
   OR COL_LENGTH(N'lab.WorkshopSample', N'GrantUtilizationPercent') IS NULL
   OR COL_LENGTH(N'lab.WorkshopRequestSample', N'MaxUsedMemoryKB') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID(N'lab.WorkshopRun') AND type = 'PK')
   OR NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'lab.WorkshopSample') AND referenced_object_id = OBJECT_ID(N'lab.WorkshopRun'))
   OR NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'lab.WorkshopRequestSample') AND referenced_object_id = OBJECT_ID(N'lab.WorkshopSample'))
    THROW 51604, 'Existing evidence table contract is incompatible.', 1;

/* Task 9 owns the same exact contract. Create it only when absent, then compare metadata exactly. */
IF OBJECT_ID(N'lab.ValidationRun', N'U') IS NULL
BEGIN
    CREATE TABLE lab.ValidationRun
    (
        ValidationRunID bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ValidationRun PRIMARY KEY,
        RunID nvarchar(128) NOT NULL,
        ValidationCaseName sysname NOT NULL,
        StartDate date NOT NULL,
        EndDateExclusive date NOT NULL,
        TerritoryID int NULL,
        TopCount int NOT NULL,
        BaselineRowCount bigint NOT NULL,
        OptimizedRowCount bigint NOT NULL,
        BaselineHash varbinary(32) NOT NULL,
        OptimizedHash varbinary(32) NOT NULL,
        Passed bit NOT NULL,
        ValidatedAtUtc datetime2(0) NOT NULL
    );
END;

DECLARE @ExpectedValidationColumns table
(
    column_id int NOT NULL,
    name sysname NOT NULL,
    type_name sysname NOT NULL,
    max_length smallint NOT NULL,
    precision tinyint NOT NULL,
    scale tinyint NOT NULL,
    is_nullable bit NOT NULL,
    is_identity bit NOT NULL
);
INSERT @ExpectedValidationColumns
    (column_id, name, type_name, max_length, precision, scale, is_nullable, is_identity)
VALUES
    (1, N'ValidationRunID', N'bigint', 8, 19, 0, 0, 1),
    (2, N'RunID', N'nvarchar', 256, 0, 0, 0, 0),
    (3, N'ValidationCaseName', N'nvarchar', 256, 0, 0, 0, 0),
    (4, N'StartDate', N'date', 3, 10, 0, 0, 0),
    (5, N'EndDateExclusive', N'date', 3, 10, 0, 0, 0),
    (6, N'TerritoryID', N'int', 4, 10, 0, 1, 0),
    (7, N'TopCount', N'int', 4, 10, 0, 0, 0),
    (8, N'BaselineRowCount', N'bigint', 8, 19, 0, 0, 0),
    (9, N'OptimizedRowCount', N'bigint', 8, 19, 0, 0, 0),
    (10, N'BaselineHash', N'varbinary', 32, 0, 0, 0, 0),
    (11, N'OptimizedHash', N'varbinary', 32, 0, 0, 0, 0),
    (12, N'Passed', N'bit', 1, 1, 0, 0, 0),
    (13, N'ValidatedAtUtc', N'datetime2', 6, 19, 0, 0, 0);

IF EXISTS
(
    SELECT column_id, name, type_name, max_length, precision, scale, is_nullable, is_identity
    FROM @ExpectedValidationColumns
    EXCEPT
    SELECT column_id, name, TYPE_NAME(system_type_id), max_length, precision, scale, is_nullable, is_identity
    FROM sys.columns WHERE object_id = OBJECT_ID(N'lab.ValidationRun')
)
OR EXISTS
(
    SELECT column_id, name, TYPE_NAME(system_type_id), max_length, precision, scale, is_nullable, is_identity
    FROM sys.columns WHERE object_id = OBJECT_ID(N'lab.ValidationRun')
    EXCEPT
    SELECT column_id, name, type_name, max_length, precision, scale, is_nullable, is_identity
    FROM @ExpectedValidationColumns
)
    THROW 51603, 'ValidationRun table does not match the Task 9 contract.', 1;
GO

CREATE OR ALTER VIEW lab.vw_WorkshopRunSummary
AS
SELECT
    RunID,
    ParentComparisonID,
    EvidenceClassification,
    Phase,
    RunStatus,
    Outcome,
    StartedAtUtc,
    CompletedAtUtc,
    BaselineQueryID,
    BaselinePlanID,
    OptimizedQueryID,
    OptimizedPlanID,
    DurationMs,
    CpuMs,
    LogicalReads,
    Spills,
    WaitTimeMs
FROM lab.WorkshopRun;
GO

CREATE OR ALTER VIEW lab.vw_WorkshopSampleSummary
AS
SELECT
    RunID,
    SampleSequence,
    SampledAtUtc,
    Phase,
    PoolTotalMemoryKB,
    PoolGrantedMemoryKB,
    PoolUsedMemoryKB,
    PoolAvailableMemoryKB,
    GrantUtilizationPercent,
    GranteeCount,
    WaiterCount,
    HostAvailableMemoryKB,
    ProcessPhysicalMemoryKB,
    TotalServerMemoryKB,
    TargetServerMemoryKB,
    SystemLowMemorySignal,
    ProcessLowMemorySignal
FROM lab.WorkshopSample;
GO

CREATE OR ALTER PROCEDURE lab.usp_GetMemorySnapshot
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.dm_resource_governor_resource_pools AS rp
        WHERE rp.name = N'mcp_sql_workshop_pool'
    )
        THROW 51610, 'The mcp_sql_workshop_pool resource pool is missing.', 1;
    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.dm_resource_governor_resource_pools AS rp
        INNER JOIN sys.dm_exec_query_resource_semaphores AS rs ON rs.pool_id = rp.pool_id
        WHERE rp.name = N'mcp_sql_workshop_pool' AND rs.resource_semaphore_id = 0
    )
       OR NOT EXISTS
       (
           SELECT 1
           FROM sys.dm_os_performance_counters
           WHERE object_name LIKE N'%Memory Manager%'
             AND counter_name = N'Total Server Memory (KB)'
       )
       OR NOT EXISTS
       (
           SELECT 1
           FROM sys.dm_os_performance_counters
           WHERE object_name LIKE N'%Memory Manager%'
             AND counter_name = N'Target Server Memory (KB)'
       )
        THROW 51611, 'Memory snapshot sources are unavailable.', 1;

    SELECT TOP (1)
        rp.pool_id AS ResourcePoolID,
        CONVERT(sysname, rp.name) AS ResourcePoolName,
        CONVERT(tinyint, rs.resource_semaphore_id) AS ResourceSemaphoreID,
        CONVERT(bigint, rs.total_memory_kb) AS PoolTotalMemoryKB,
        CONVERT(bigint, rs.granted_memory_kb) AS PoolGrantedMemoryKB,
        CONVERT(bigint, rs.used_memory_kb) AS PoolUsedMemoryKB,
        CONVERT(bigint, CASE WHEN rs.total_memory_kb >= rs.granted_memory_kb
            THEN rs.total_memory_kb - rs.granted_memory_kb ELSE 0 END) AS PoolAvailableMemoryKB,
        CAST(100.0 * rs.granted_memory_kb / NULLIF(rs.total_memory_kb, 0) AS decimal(6,2)) AS GrantUtilizationPercent,
        CONVERT(int, rs.grantee_count) AS GranteeCount,
        CONVERT(int, rs.waiter_count) AS WaiterCount,
        CONVERT(bigint, host.available_physical_memory_kb) AS HostAvailableMemoryKB,
        CONVERT(bigint, host.total_physical_memory_kb - host.available_physical_memory_kb) AS HostUsedMemoryKB,
        CONVERT(bigint, process.physical_memory_in_use_kb) AS ProcessPhysicalMemoryKB,
        CONVERT(bigint, counters.TotalServerMemoryKB) AS TotalServerMemoryKB,
        CONVERT(bigint, counters.TargetServerMemoryKB) AS TargetServerMemoryKB,
        CONVERT(bit, host.system_low_memory_signal_state) AS SystemLowMemorySignal,
        CONVERT(bit, process.process_physical_memory_low) AS ProcessLowMemorySignal,
        SYSUTCDATETIME() AS SampledAtUtc
    FROM sys.dm_resource_governor_resource_pools AS rp
    INNER JOIN sys.dm_exec_query_resource_semaphores AS rs
        ON rs.pool_id = rp.pool_id
       AND rs.resource_semaphore_id = 0
    CROSS JOIN sys.dm_os_sys_memory AS host
    CROSS JOIN sys.dm_os_process_memory AS process
    CROSS JOIN
    (
        SELECT
            MAX(CASE WHEN counter_name = N'Total Server Memory (KB)' THEN cntr_value END) AS TotalServerMemoryKB,
            MAX(CASE WHEN counter_name = N'Target Server Memory (KB)' THEN cntr_value END) AS TargetServerMemoryKB
        FROM sys.dm_os_performance_counters
        WHERE object_name LIKE N'%Memory Manager%'
          AND counter_name IN (N'Total Server Memory (KB)', N'Target Server Memory (KB)')
    ) AS counters
    WHERE rp.name = N'mcp_sql_workshop_pool'
      AND rs.resource_semaphore_id = 0
    ORDER BY rp.pool_id;
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_GetActiveWorkshopGrants
    @Top int = 20
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    IF @Top IS NULL OR @Top NOT BETWEEN 1 AND 100
        THROW 51620, 'Top must be between 1 and 100.', 1;

    DECLARE @RunID uniqueidentifier = TRY_CONVERT(uniqueidentifier, SESSION_CONTEXT(N'WorkshopRunId'));

    SELECT TOP (@Top)
        CONVERT(uniqueidentifier, sessionRun.RunID) AS RunID,
        CONVERT(smallint, mg.session_id) AS SessionID,
        CONVERT(int, COALESCE(r.request_id, mg.request_id)) AS RequestID,
        CONVERT(varchar(16), r.status) AS RequestStatus,
        CONVERT(varchar(60), r.command) AS RequestCommand,
        CONVERT(bigint, mg.requested_memory_kb) AS RequestedMemoryKB,
        CONVERT(bigint, mg.granted_memory_kb) AS GrantedMemoryKB,
        CONVERT(bigint, mg.required_memory_kb) AS RequiredMemoryKB,
        CONVERT(bigint, mg.ideal_memory_kb) AS IdealMemoryKB,
        CONVERT(bigint, mg.used_memory_kb) AS UsedMemoryKB,
        CONVERT(bigint, mg.max_used_memory_kb) AS MaxUsedMemoryKB,
        CONVERT(int, mg.queue_id) AS QueueID,
        CONVERT(int, mg.wait_order) AS WaitOrder,
        CONVERT(bigint, mg.wait_time_ms) AS WaitTimeMs,
        CONVERT(bigint, mg.query_cost) AS QueryCost,
        CONVERT(int, mg.dop) AS DegreeOfParallelism
    FROM sys.dm_exec_query_memory_grants AS mg
    INNER JOIN sys.dm_exec_sessions AS s ON s.session_id = mg.session_id
    LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = mg.session_id AND r.request_id = mg.request_id
        CROSS APPLY
        (
                SELECT TOP (1) wrs.RunID
                FROM lab.WorkshopRequestSample AS wrs
                WHERE wrs.SessionID = mg.session_id
                    AND wrs.RequestID = COALESCE(r.request_id, mg.request_id)
                    AND (@RunID IS NULL OR wrs.RunID = @RunID)
                ORDER BY wrs.SampleSequence DESC
        ) AS sessionRun
    WHERE s.program_name LIKE N'MCP-SQL-Workshop%'
      AND (@RunID IS NULL OR sessionRun.RunID = @RunID)
    ORDER BY mg.wait_time_ms DESC, mg.requested_memory_kb DESC, mg.session_id, mg.request_id;
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_GetQueryStoreTopQueries
    @StartUtc datetime2(0),
    @EndUtc datetime2(0),
    @Top int = 20
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    IF @StartUtc IS NULL OR @EndUtc IS NULL OR @EndUtc <= @StartUtc
       OR DATEDIFF(minute, @StartUtc, @EndUtc) > 1440
        THROW 51630, 'The UTC window must be positive and no longer than 24 hours.', 1;
    IF @Top IS NULL OR @Top NOT BETWEEN 1 AND 100
        THROW 51631, 'Top must be between 1 and 100.', 1;

    SELECT TOP (@Top)
        q.query_id AS QueryID,
        p.plan_id AS PlanID,
        CASE q.object_id
            WHEN OBJECT_ID(N'lab.usp_MonthEndSalesBaseline') THEN N'Baseline'
            WHEN OBJECT_ID(N'lab.usp_MonthEndSalesOptimized') THEN N'Optimized'
        END AS ProcedurePhase,
        SUM(CONVERT(bigint, rs.count_executions)) AS ExecutionCount,
        CAST(SUM(CONVERT(decimal(38,4), rs.avg_duration) * rs.count_executions)
            / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0) AS decimal(19,2)) AS AverageDurationMicroseconds,
        CAST(SUM(CONVERT(decimal(38,4), rs.avg_cpu_time) * rs.count_executions)
            / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0) AS decimal(19,2)) AS AverageCpuMicroseconds,
        CAST(SUM(CONVERT(decimal(38,4), rs.avg_logical_io_reads) * rs.count_executions)
            / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0) AS decimal(19,2)) AS AverageLogicalReads,
        CAST(SUM(CONVERT(decimal(38,4), rs.avg_query_max_used_memory) * rs.count_executions)
            / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0) AS decimal(19,2)) AS AverageQueryMaxUsedMemoryPages,
        CAST(SUM(CONVERT(decimal(38,4), rs.avg_num_physical_io_reads) * rs.count_executions)
            / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0) AS decimal(19,2)) AS AveragePhysicalReads,
        CAST(SUM(CONVERT(decimal(38,4), rs.avg_log_bytes_used) * rs.count_executions)
            / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0) AS decimal(19,2)) AS AverageLogBytesUsed,
        CAST(SUM(CONVERT(decimal(38,4), rs.avg_tempdb_space_used) * rs.count_executions)
            / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0) AS decimal(19,2)) AS AverageTempdbSpaceUsedPages
    FROM sys.query_store_query AS q
    INNER JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
    INNER JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval AS rsi
        ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE q.object_id IN
        (OBJECT_ID(N'lab.usp_MonthEndSalesBaseline'), OBJECT_ID(N'lab.usp_MonthEndSalesOptimized'))
      AND rsi.start_time < @EndUtc
      AND rsi.end_time > @StartUtc
    GROUP BY q.query_id, p.plan_id, q.object_id
    ORDER BY AverageDurationMicroseconds DESC, q.query_id, p.plan_id;
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_GetQueryStoreWaits
    @StartUtc datetime2(0),
    @EndUtc datetime2(0),
    @Top int = 20
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    IF @StartUtc IS NULL OR @EndUtc IS NULL OR @EndUtc <= @StartUtc
       OR DATEDIFF(minute, @StartUtc, @EndUtc) > 1440
        THROW 51640, 'The UTC window must be positive and no longer than 24 hours.', 1;
    IF @Top IS NULL OR @Top NOT BETWEEN 1 AND 100
        THROW 51641, 'Top must be between 1 and 100.', 1;

    ;WITH RuntimeExecutions AS
    (
        SELECT
            rs.plan_id,
            rs.runtime_stats_interval_id,
            rs.execution_type,
            SUM(CONVERT(bigint, rs.count_executions)) AS ExecutionCount
        FROM sys.query_store_runtime_stats AS rs
        GROUP BY rs.plan_id, rs.runtime_stats_interval_id, rs.execution_type
    )
    SELECT TOP (@Top)
        q.query_id AS QueryID,
        p.plan_id AS PlanID,
        CASE q.object_id
            WHEN OBJECT_ID(N'lab.usp_MonthEndSalesBaseline') THEN N'Baseline'
            WHEN OBJECT_ID(N'lab.usp_MonthEndSalesOptimized') THEN N'Optimized'
        END AS ProcedurePhase,
        CONVERT(varchar(60), ws.wait_category_desc) AS WaitCategory,
        SUM(CONVERT(bigint, ws.total_query_wait_time_ms)) AS TotalQueryWaitTimeMs,
        CAST(SUM(CONVERT(decimal(38,4), ws.total_query_wait_time_ms))
            / NULLIF(SUM(CONVERT(decimal(38,4), executions.ExecutionCount)), 0) AS decimal(19,2)) AS AverageQueryWaitTimeMs
    FROM sys.query_store_query AS q
    INNER JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
    INNER JOIN sys.query_store_wait_stats AS ws ON ws.plan_id = p.plan_id
    INNER JOIN RuntimeExecutions AS executions
        ON executions.plan_id = ws.plan_id
       AND executions.runtime_stats_interval_id = ws.runtime_stats_interval_id
       AND executions.execution_type = ws.execution_type
    INNER JOIN sys.query_store_runtime_stats_interval AS rsi
        ON rsi.runtime_stats_interval_id = ws.runtime_stats_interval_id
    WHERE q.object_id IN
        (OBJECT_ID(N'lab.usp_MonthEndSalesBaseline'), OBJECT_ID(N'lab.usp_MonthEndSalesOptimized'))
      AND rsi.start_time < @EndUtc
      AND rsi.end_time > @StartUtc
    GROUP BY q.query_id, p.plan_id, q.object_id, ws.wait_category_desc
    ORDER BY TotalQueryWaitTimeMs DESC, q.query_id, p.plan_id, WaitCategory;
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_GetProcedurePlanSummary
    @ProcedureName sysname,
    @Top int = 20
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    IF @ProcedureName NOT IN (N'lab.usp_MonthEndSalesBaseline', N'lab.usp_MonthEndSalesOptimized')
        THROW 51650, 'ProcedureName must identify the baseline or optimized workshop procedure.', 1;
    IF @Top IS NULL OR @Top NOT BETWEEN 1 AND 100
        THROW 51651, 'Top must be between 1 and 100.', 1;

    DECLARE @ObjectID int = OBJECT_ID(@ProcedureName, N'P');
    IF @ObjectID IS NULL
        THROW 51652, 'The selected workshop procedure is missing.', 1;

    SELECT TOP (@Top)
        q.query_id AS QueryID,
        p.plan_id AS PlanID,
        CONVERT(bit, p.is_forced_plan) AS IsForcedPlan,
        CONVERT(bit, p.force_failure_count) AS HasForceFailures,
        CONVERT(varchar(60), p.last_force_failure_reason_desc) AS LastForceFailureReason,
        CONVERT(bit, p.is_parallel_plan) AS IsParallelPlan,
        CONVERT(datetimeoffset(0), p.last_execution_time) AS LastExecutionTime,
        CONVERT(varbinary(32), HASHBYTES('SHA2_256', CONVERT(varbinary(max), p.query_plan))) AS PlanHash,
        CONVERT(int, DATALENGTH(CONVERT(varbinary(max), p.query_plan))) AS PlanSizeBytes
    FROM sys.query_store_query AS q
    INNER JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
    WHERE q.object_id = @ObjectID
    ORDER BY p.last_execution_time DESC, q.query_id, p.plan_id;
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_CompareWorkshopRuns
    @BaselineRunID uniqueidentifier = NULL,
    @OptimizedRunID uniqueidentifier = NULL,
    @ParentComparisonID uniqueidentifier = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF @ParentComparisonID IS NULL AND (@BaselineRunID IS NULL OR @OptimizedRunID IS NULL)
        THROW 51660, 'Supply two run IDs or one parent comparison ID.', 1;
    IF @ParentComparisonID IS NOT NULL AND (@BaselineRunID IS NOT NULL OR @OptimizedRunID IS NOT NULL)
        THROW 51661, 'Parent comparison mode cannot be combined with explicit run IDs.', 1;

    IF @ParentComparisonID IS NOT NULL
    BEGIN
        IF (SELECT COUNT(*) FROM lab.WorkshopRun WHERE ParentComparisonID = @ParentComparisonID AND Phase = 'Baseline') <> 1
           OR (SELECT COUNT(*) FROM lab.WorkshopRun WHERE ParentComparisonID = @ParentComparisonID AND Phase = 'Optimized') <> 1
            THROW 51663, 'A comparison must contain exactly one baseline and one optimized run.', 1;
        SELECT @BaselineRunID = MIN(CASE WHEN Phase = 'Baseline' THEN RunID END),
               @OptimizedRunID = MIN(CASE WHEN Phase = 'Optimized' THEN RunID END)
        FROM lab.WorkshopRun
        WHERE ParentComparisonID = @ParentComparisonID;
    END;

    IF NOT EXISTS (SELECT 1 FROM lab.WorkshopRun WHERE RunID = @BaselineRunID AND Phase = 'Baseline' AND RunStatus = 'Completed')
       OR NOT EXISTS (SELECT 1 FROM lab.WorkshopRun WHERE RunID = @OptimizedRunID AND Phase = 'Optimized' AND RunStatus = 'Completed')
        THROW 51662, 'The selected baseline and optimized runs do not exist with the required phases.', 1;
    IF EXISTS
    (
        SELECT 1
        FROM lab.WorkshopRun AS baseline
        INNER JOIN lab.WorkshopRun AS optimized ON optimized.RunID = @OptimizedRunID
        WHERE baseline.RunID = @BaselineRunID
          AND (baseline.FrozenSettingsHash <> optimized.FrozenSettingsHash
               OR baseline.DurationMs IS NULL OR optimized.DurationMs IS NULL
               OR baseline.CpuMs IS NULL OR optimized.CpuMs IS NULL
               OR baseline.LogicalReads IS NULL OR optimized.LogicalReads IS NULL
               OR baseline.Spills IS NULL OR optimized.Spills IS NULL
               OR baseline.WaitTimeMs IS NULL OR optimized.WaitTimeMs IS NULL)
    )
        THROW 51664, 'Completed runs require identical frozen settings and complete measurements.', 1;
    IF NOT EXISTS (SELECT 1 FROM lab.WorkshopSample WHERE RunID = @BaselineRunID)
       OR NOT EXISTS (SELECT 1 FROM lab.WorkshopSample WHERE RunID = @OptimizedRunID)
        THROW 51665, 'No memory samples are available for one or both runs.', 1;

    ;WITH RankedSamples AS
    (
        SELECT
            s.RunID,
            s.GrantUtilizationPercent,
            ROW_NUMBER() OVER (PARTITION BY s.RunID ORDER BY s.GrantUtilizationPercent, s.SampleSequence) AS ValueRowNumber,
            COUNT_BIG(*) OVER (PARTITION BY s.RunID) AS ValueCount
        FROM lab.WorkshopSample AS s
        WHERE s.RunID IN (@BaselineRunID, @OptimizedRunID)
    ), SampleMetrics AS
    (
        SELECT
            RunID,
            MAX(GrantUtilizationPercent) AS PeakGrantUtilizationPercent,
            CAST(AVG(CASE WHEN ValueRowNumber IN ((ValueCount + 1) / 2, (ValueCount + 2) / 2)
                THEN GrantUtilizationPercent END) AS decimal(6,2)) AS MedianGrantUtilizationPercent
        FROM RankedSamples
        GROUP BY RunID
    ), Comparison AS
    (
        SELECT
            baseline.RunID AS BaselineRunID,
            optimized.RunID AS OptimizedRunID,
            baselineSample.PeakGrantUtilizationPercent AS BaselinePeakGrantUtilizationPercent,
            optimizedSample.PeakGrantUtilizationPercent AS OptimizedPeakGrantUtilizationPercent,
            baselineSample.MedianGrantUtilizationPercent AS BaselineMedianGrantUtilizationPercent,
            optimizedSample.MedianGrantUtilizationPercent AS OptimizedMedianGrantUtilizationPercent,
            baseline.DurationMs AS BaselineDurationMs,
            optimized.DurationMs AS OptimizedDurationMs,
            baseline.CpuMs AS BaselineCpuMs,
            optimized.CpuMs AS OptimizedCpuMs,
            baseline.LogicalReads AS BaselineLogicalReads,
            optimized.LogicalReads AS OptimizedLogicalReads,
            baseline.Spills AS BaselineSpills,
            optimized.Spills AS OptimizedSpills,
            baseline.WaitTimeMs AS BaselineWaitTimeMs,
            optimized.WaitTimeMs AS OptimizedWaitTimeMs
        FROM lab.WorkshopRun AS baseline
        INNER JOIN lab.WorkshopRun AS optimized ON optimized.RunID = @OptimizedRunID
        LEFT JOIN SampleMetrics AS baselineSample ON baselineSample.RunID = baseline.RunID
        LEFT JOIN SampleMetrics AS optimizedSample ON optimizedSample.RunID = optimized.RunID
        WHERE baseline.RunID = @BaselineRunID
    )
    SELECT
        BaselineRunID,
        OptimizedRunID,
        BaselinePeakGrantUtilizationPercent,
        OptimizedPeakGrantUtilizationPercent,
        BaselineMedianGrantUtilizationPercent,
        OptimizedMedianGrantUtilizationPercent,
        BaselineDurationMs,
        OptimizedDurationMs,
        BaselineCpuMs,
        OptimizedCpuMs,
        BaselineLogicalReads,
        OptimizedLogicalReads,
        BaselineSpills,
        OptimizedSpills,
        BaselineWaitTimeMs,
        OptimizedWaitTimeMs,
        CONVERT(decimal(6,2), BaselineMedianGrantUtilizationPercent - OptimizedMedianGrantUtilizationPercent)
            AS MedianUtilizationReductionPoints,
        CONVERT(varchar(16), CASE
            WHEN OptimizedMedianGrantUtilizationPercent <= BaselineMedianGrantUtilizationPercent - 10.00
             AND (OptimizedDurationMs IS NULL OR BaselineDurationMs IS NULL OR OptimizedDurationMs <= BaselineDurationMs * 1.10)
             AND (OptimizedCpuMs IS NULL OR BaselineCpuMs IS NULL OR OptimizedCpuMs <= BaselineCpuMs * 1.10)
                THEN N'Improved'
            WHEN OptimizedMedianGrantUtilizationPercent > BaselineMedianGrantUtilizationPercent + 5.00
              OR (OptimizedDurationMs IS NOT NULL AND BaselineDurationMs IS NOT NULL AND OptimizedDurationMs > BaselineDurationMs * 1.10)
              OR (OptimizedCpuMs IS NOT NULL AND BaselineCpuMs IS NOT NULL AND OptimizedCpuMs > BaselineCpuMs * 1.10)
                THEN N'Regressed'
            ELSE N'Inconclusive'
        END) AS OutcomeBand
    FROM Comparison;
END;
GO

IF SUSER_ID(N'mcp_workshop_reader') IS NULL
    THROW 51670, 'The bootstrap must provision server principal mcp_workshop_reader.', 1;
IF USER_ID(N'mcp_workshop_reader') IS NULL
    CREATE USER [mcp_workshop_reader] FOR LOGIN [mcp_workshop_reader];
IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_principals
    WHERE name = N'mcp_workshop_reader'
      AND sid = SUSER_SID(N'mcp_workshop_reader')
      AND type = 'S'
)
    THROW 51672, 'The database user is not mapped to the expected server principal.', 1;
IF IS_ROLEMEMBER(N'db_owner', N'mcp_workshop_reader') = 1
   OR IS_ROLEMEMBER(N'db_securityadmin', N'mcp_workshop_reader') = 1
   OR IS_ROLEMEMBER(N'db_accessadmin', N'mcp_workshop_reader') = 1
   OR IS_ROLEMEMBER(N'db_ddladmin', N'mcp_workshop_reader') = 1
   OR IS_ROLEMEMBER(N'db_datareader', N'mcp_workshop_reader') = 1
   OR IS_ROLEMEMBER(N'db_datawriter', N'mcp_workshop_reader') = 1
    THROW 51673, 'The reader must not belong to a privileged database role.', 1;
IF IS_SRVROLEMEMBER(N'sysadmin', N'mcp_workshop_reader') = 1
   OR IS_SRVROLEMEMBER(N'securityadmin', N'mcp_workshop_reader') = 1
   OR IS_SRVROLEMEMBER(N'serveradmin', N'mcp_workshop_reader') = 1
   OR IS_SRVROLEMEMBER(N'setupadmin', N'mcp_workshop_reader') = 1
   OR IS_SRVROLEMEMBER(N'processadmin', N'mcp_workshop_reader') = 1
   OR IS_SRVROLEMEMBER(N'diskadmin', N'mcp_workshop_reader') = 1
   OR IS_SRVROLEMEMBER(N'dbcreator', N'mcp_workshop_reader') = 1
   OR IS_SRVROLEMEMBER(N'bulkadmin', N'mcp_workshop_reader') = 1
    THROW 51674, 'The reader must not belong to a privileged server role.', 1;

GRANT CONNECT TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetMemorySnapshot TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetActiveWorkshopGrants TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetQueryStoreTopQueries TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetQueryStoreWaits TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetProcedurePlanSummary TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_CompareWorkshopRuns TO [mcp_workshop_reader];
GRANT SELECT ON OBJECT::lab.vw_WorkshopRunSummary TO [mcp_workshop_reader];
GRANT SELECT ON OBJECT::lab.vw_WorkshopSampleSummary TO [mcp_workshop_reader];
DENY INSERT ON SCHEMA::lab TO [mcp_workshop_reader];
DENY UPDATE ON SCHEMA::lab TO [mcp_workshop_reader];
DENY DELETE ON SCHEMA::lab TO [mcp_workshop_reader];
DENY ALTER ON SCHEMA::lab TO [mcp_workshop_reader];
DENY CONTROL ON SCHEMA::lab TO [mcp_workshop_reader];
DENY ALTER ON DATABASE::[AdventureWorks2022] TO [mcp_workshop_reader];
DENY CONTROL ON DATABASE::[AdventureWorks2022] TO [mcp_workshop_reader];

DECLARE @PermissionFailure nvarchar(2048) = N'';
BEGIN TRY
    EXECUTE AS USER = N'mcp_workshop_reader';
    IF HAS_PERMS_BY_NAME(N'lab.WorkshopRun', N'OBJECT', N'INSERT') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopRun', N'OBJECT', N'UPDATE') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopRun', N'OBJECT', N'DELETE') <> 0
       OR HAS_PERMS_BY_NAME(N'lab', N'SCHEMA', N'ALTER') <> 0
       OR HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CONTROL') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.vw_WorkshopRunSummary', N'OBJECT', N'SELECT') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.usp_GetMemorySnapshot', N'OBJECT', N'EXECUTE') <> 1
        SET @PermissionFailure = N'Least-privilege verification failed for mcp_workshop_reader.';
    REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = N'mcp_workshop_reader'
        REVERT;
    THROW;
END CATCH;
IF @PermissionFailure <> N''
    THROW 51671, @PermissionFailure, 1;
GO
