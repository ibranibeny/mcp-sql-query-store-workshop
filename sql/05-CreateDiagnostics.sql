:on error exit
/*
Creates the bounded evidence contract and the six least-privileged diagnostics used by
Data API Builder. The bootstrap must pre-create the fixed server login and database
master key. Server-scoped DMV access is conveyed only through signed modules.
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
DECLARE @DatabaseMasterKeyReady bit = TRY_CONVERT(bit, SESSION_CONTEXT(N'DatabaseMasterKeyReady'));

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
IF @DatabaseMasterKeyReady <> 1
   OR NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
    THROW 51605, 'Bootstrap must create the database master key and set DatabaseMasterKeyReady session context to 1.', 1;
IF CONVERT(int, DATABASEPROPERTYEX(DB_NAME(), N'IsTrustworthyOn')) <> 0
    THROW 51606, 'AdventureWorks2022 TRUSTWORTHY must remain OFF.', 1;

IF (OBJECT_ID(N'lab.WorkshopRun') IS NOT NULL AND OBJECT_ID(N'lab.WorkshopRun', N'U') IS NULL)
   OR (OBJECT_ID(N'lab.WorkshopSample') IS NOT NULL AND OBJECT_ID(N'lab.WorkshopSample', N'U') IS NULL)
   OR (OBJECT_ID(N'lab.WorkshopRequestSample') IS NOT NULL AND OBJECT_ID(N'lab.WorkshopRequestSample', N'U') IS NULL)
   OR (OBJECT_ID(N'lab.ValidationRun') IS NOT NULL AND OBJECT_ID(N'lab.ValidationRun', N'U') IS NULL)
    THROW 51604, 'Existing evidence object is not a compatible table.', 1;

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
            (Outcome IS NULL OR Outcome IN ('TargetMet', 'ImprovedOutsideTarget', 'NoMaterialImprovement',
                'BaselineTargetNotReached', 'SafetyStop', 'ManualStop', 'Failed')),
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

/* Task 9 owns the same exact contract. Create it only when absent, then compare metadata exactly. */
IF OBJECT_ID(N'lab.ValidationRun', N'U') IS NULL
BEGIN
    CREATE TABLE lab.ValidationRun
    (
        ValidationRunID bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ValidationRun PRIMARY KEY,
        ValidationBatchID uniqueidentifier NOT NULL,
        BaselineRunID uniqueidentifier NULL,
        OptimizedRunID uniqueidentifier NULL,
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
        ValidatedAtUtc datetime2(0) NOT NULL,
        CONSTRAINT UQ_ValidationRun_BatchCase UNIQUE (ValidationBatchID, ValidationCaseName),
        CONSTRAINT FK_ValidationRun_BaselineWorkshopRun FOREIGN KEY (BaselineRunID)
            REFERENCES lab.WorkshopRun (RunID),
        CONSTRAINT FK_ValidationRun_OptimizedWorkshopRun FOREIGN KEY (OptimizedRunID)
            REFERENCES lab.WorkshopRun (RunID),
        CONSTRAINT CK_ValidationRun_Linkage CHECK
            ((BaselineRunID IS NULL AND OptimizedRunID IS NULL)
             OR (BaselineRunID IS NOT NULL AND OptimizedRunID IS NOT NULL))
    );
END;

DECLARE @ExpectedColumns table
(
    table_name sysname NOT NULL,
    column_id int NOT NULL,
    column_name sysname NOT NULL,
    type_name sysname NOT NULL,
    max_length smallint NOT NULL,
    precision tinyint NOT NULL,
    scale tinyint NOT NULL,
    is_nullable bit NOT NULL,
    is_identity bit NOT NULL
);
INSERT @ExpectedColumns
    (table_name, column_id, column_name, type_name, max_length, precision, scale, is_nullable, is_identity)
VALUES
    (N'WorkshopRun', 1, N'RunID', N'uniqueidentifier', 16, 0, 0, 0, 0),
    (N'WorkshopRun', 2, N'ParentComparisonID', N'uniqueidentifier', 16, 0, 0, 1, 0),
    (N'WorkshopRun', 3, N'EvidenceClassification', N'varchar', 24, 0, 0, 0, 0),
    (N'WorkshopRun', 4, N'Phase', N'varchar', 16, 0, 0, 0, 0),
    (N'WorkshopRun', 5, N'RunStatus', N'varchar', 16, 0, 0, 0, 0),
    (N'WorkshopRun', 6, N'Outcome', N'varchar', 24, 0, 0, 1, 0),
    (N'WorkshopRun', 7, N'StartedAtUtc', N'datetime2', 7, 23, 3, 0, 0),
    (N'WorkshopRun', 8, N'CompletedAtUtc', N'datetime2', 7, 23, 3, 1, 0),
    (N'WorkshopRun', 9, N'FrozenSettingsHash', N'varbinary', 32, 0, 0, 0, 0),
    (N'WorkshopRun', 10, N'FrozenSettingsJson', N'nvarchar', 8000, 0, 0, 0, 0),
    (N'WorkshopRun', 11, N'BaselineQueryID', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRun', 12, N'BaselinePlanID', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRun', 13, N'OptimizedQueryID', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRun', 14, N'OptimizedPlanID', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRun', 15, N'DurationMs', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRun', 16, N'CpuMs', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRun', 17, N'LogicalReads', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRun', 18, N'Spills', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRun', 19, N'WaitTimeMs', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopSample', 1, N'RunID', N'uniqueidentifier', 16, 0, 0, 0, 0),
    (N'WorkshopSample', 2, N'SampleSequence', N'int', 4, 10, 0, 0, 0),
    (N'WorkshopSample', 3, N'SampledAtUtc', N'datetime2', 7, 23, 3, 0, 0),
    (N'WorkshopSample', 4, N'Phase', N'varchar', 16, 0, 0, 0, 0),
    (N'WorkshopSample', 5, N'PoolTotalMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 6, N'PoolGrantedMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 7, N'PoolUsedMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 8, N'PoolAvailableMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 9, N'GrantUtilizationPercent', N'decimal', 5, 6, 2, 0, 0),
    (N'WorkshopSample', 10, N'GranteeCount', N'int', 4, 10, 0, 0, 0),
    (N'WorkshopSample', 11, N'WaiterCount', N'int', 4, 10, 0, 0, 0),
    (N'WorkshopSample', 12, N'HostAvailableMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 13, N'HostUsedMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 14, N'ProcessPhysicalMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 15, N'TotalServerMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 16, N'TargetServerMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopSample', 17, N'SystemLowMemorySignal', N'bit', 1, 1, 0, 0, 0),
    (N'WorkshopSample', 18, N'ProcessLowMemorySignal', N'bit', 1, 1, 0, 0, 0),
    (N'WorkshopRequestSample', 1, N'RunID', N'uniqueidentifier', 16, 0, 0, 0, 0),
    (N'WorkshopRequestSample', 2, N'SampleSequence', N'int', 4, 10, 0, 0, 0),
    (N'WorkshopRequestSample', 3, N'SessionID', N'smallint', 2, 5, 0, 0, 0),
    (N'WorkshopRequestSample', 4, N'RequestID', N'int', 4, 10, 0, 0, 0),
    (N'WorkshopRequestSample', 5, N'RequestedMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopRequestSample', 6, N'GrantedMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopRequestSample', 7, N'RequiredMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopRequestSample', 8, N'IdealMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopRequestSample', 9, N'UsedMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopRequestSample', 10, N'MaxUsedMemoryKB', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopRequestSample', 11, N'WaitOrder', N'int', 4, 10, 0, 1, 0),
    (N'WorkshopRequestSample', 12, N'WaitTimeMs', N'bigint', 8, 19, 0, 0, 0),
    (N'WorkshopRequestSample', 13, N'QueryID', N'bigint', 8, 19, 0, 1, 0),
    (N'WorkshopRequestSample', 14, N'PlanID', N'bigint', 8, 19, 0, 1, 0),
    (N'ValidationRun', 1, N'ValidationRunID', N'bigint', 8, 19, 0, 0, 1),
    (N'ValidationRun', 2, N'ValidationBatchID', N'uniqueidentifier', 16, 0, 0, 0, 0),
    (N'ValidationRun', 3, N'BaselineRunID', N'uniqueidentifier', 16, 0, 0, 1, 0),
    (N'ValidationRun', 4, N'OptimizedRunID', N'uniqueidentifier', 16, 0, 0, 1, 0),
    (N'ValidationRun', 5, N'ValidationCaseName', N'sysname', 256, 0, 0, 0, 0),
    (N'ValidationRun', 6, N'StartDate', N'date', 3, 10, 0, 0, 0),
    (N'ValidationRun', 7, N'EndDateExclusive', N'date', 3, 10, 0, 0, 0),
    (N'ValidationRun', 8, N'TerritoryID', N'int', 4, 10, 0, 1, 0),
    (N'ValidationRun', 9, N'TopCount', N'int', 4, 10, 0, 0, 0),
    (N'ValidationRun', 10, N'BaselineRowCount', N'bigint', 8, 19, 0, 0, 0),
    (N'ValidationRun', 11, N'OptimizedRowCount', N'bigint', 8, 19, 0, 0, 0),
    (N'ValidationRun', 12, N'BaselineHash', N'varbinary', 32, 0, 0, 0, 0),
    (N'ValidationRun', 13, N'OptimizedHash', N'varbinary', 32, 0, 0, 0, 0),
    (N'ValidationRun', 14, N'Passed', N'bit', 1, 1, 0, 0, 0),
    (N'ValidationRun', 15, N'ValidatedAtUtc', N'datetime2', 6, 19, 0, 0, 0);

IF EXISTS
(
    SELECT table_name, column_id, column_name, type_name, max_length, precision, scale, is_nullable, is_identity
    FROM @ExpectedColumns
    EXCEPT
    SELECT OBJECT_NAME(c.object_id), c.column_id, c.name, TYPE_NAME(c.user_type_id),
           c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity
    FROM sys.columns AS c
    WHERE c.object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                          OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
)
OR EXISTS
(
    SELECT OBJECT_NAME(c.object_id), c.column_id, c.name, TYPE_NAME(c.user_type_id),
           c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity
    FROM sys.columns AS c
    WHERE c.object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                          OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
    EXCEPT
    SELECT table_name, column_id, column_name, type_name, max_length, precision, scale, is_nullable, is_identity
    FROM @ExpectedColumns
)
    THROW 51604, 'Existing evidence table column contract is incompatible.', 1;

DECLARE @ExpectedIdentityColumns table
(
    table_name sysname NOT NULL, column_name sysname NOT NULL,
    identity_seed decimal(38,0) NOT NULL, identity_increment decimal(38,0) NOT NULL
);
INSERT @ExpectedIdentityColumns VALUES
    (N'ValidationRun', N'ValidationRunID', CONVERT(decimal(38,0), 1), CONVERT(decimal(38,0), 1));
IF EXISTS
(
    SELECT * FROM @ExpectedIdentityColumns
    EXCEPT
    SELECT OBJECT_NAME(identity_column.object_id), identity_column.name,
           CONVERT(decimal(38,0), identity_column.seed_value),
           CONVERT(decimal(38,0), identity_column.increment_value)
    FROM sys.identity_columns AS identity_column
    WHERE identity_column.object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                        OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
)
OR EXISTS
(
    SELECT OBJECT_NAME(identity_column.object_id), identity_column.name,
           CONVERT(decimal(38,0), identity_column.seed_value),
           CONVERT(decimal(38,0), identity_column.increment_value)
    FROM sys.identity_columns AS identity_column
    WHERE identity_column.object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                        OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
    EXCEPT SELECT * FROM @ExpectedIdentityColumns
)
    THROW 51604, 'Existing evidence table identity contract is incompatible.', 1;

DECLARE @ExpectedPrimaryKeyColumns table
(
    constraint_name sysname NOT NULL, table_name sysname NOT NULL,
    column_name sysname NOT NULL, key_ordinal tinyint NOT NULL
);
INSERT @ExpectedPrimaryKeyColumns VALUES
    (N'PK_WorkshopRun', N'WorkshopRun', N'RunID', 1),
    (N'PK_WorkshopSample', N'WorkshopSample', N'RunID', 1),
    (N'PK_WorkshopSample', N'WorkshopSample', N'SampleSequence', 2),
    (N'PK_WorkshopRequestSample', N'WorkshopRequestSample', N'RunID', 1),
    (N'PK_WorkshopRequestSample', N'WorkshopRequestSample', N'SampleSequence', 2),
    (N'PK_WorkshopRequestSample', N'WorkshopRequestSample', N'SessionID', 3),
    (N'PK_WorkshopRequestSample', N'WorkshopRequestSample', N'RequestID', 4),
    (N'PK_ValidationRun', N'ValidationRun', N'ValidationRunID', 1);

IF EXISTS
(
    SELECT constraint_name, table_name, column_name, key_ordinal FROM @ExpectedPrimaryKeyColumns
    EXCEPT
    SELECT kc.name, OBJECT_NAME(kc.parent_object_id), c.name, CONVERT(tinyint, ic.key_ordinal)
    FROM sys.key_constraints AS kc
    INNER JOIN sys.index_columns AS ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
    INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE kc.type = N'PK' AND kc.parent_object_id IN
        (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
         OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
)
OR EXISTS
(
    SELECT kc.name, OBJECT_NAME(kc.parent_object_id), c.name, CONVERT(tinyint, ic.key_ordinal)
    FROM sys.key_constraints AS kc
    INNER JOIN sys.index_columns AS ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
    INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE kc.type = N'PK' AND kc.parent_object_id IN
        (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
         OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
    EXCEPT
    SELECT constraint_name, table_name, column_name, key_ordinal FROM @ExpectedPrimaryKeyColumns
)
    THROW 51604, 'Existing evidence table primary-key contract is incompatible.', 1;

DECLARE @ExpectedForeignKeyColumns table
(
    constraint_name sysname NOT NULL, parent_table sysname NOT NULL, parent_column sysname NOT NULL,
    referenced_table sysname NOT NULL, referenced_column sysname NOT NULL, constraint_column_id int NOT NULL,
    delete_referential_action_desc nvarchar(60) NOT NULL, update_referential_action_desc nvarchar(60) NOT NULL,
    is_disabled bit NOT NULL, is_not_trusted bit NOT NULL, is_not_for_replication bit NOT NULL
);
INSERT @ExpectedForeignKeyColumns VALUES
    (N'FK_WorkshopSample_WorkshopRun', N'WorkshopSample', N'RunID', N'WorkshopRun', N'RunID', 1, N'NO_ACTION', N'NO_ACTION', 0, 0, 0),
    (N'FK_WorkshopRequestSample_WorkshopSample', N'WorkshopRequestSample', N'RunID', N'WorkshopSample', N'RunID', 1, N'NO_ACTION', N'NO_ACTION', 0, 0, 0),
    (N'FK_WorkshopRequestSample_WorkshopSample', N'WorkshopRequestSample', N'SampleSequence', N'WorkshopSample', N'SampleSequence', 2, N'NO_ACTION', N'NO_ACTION', 0, 0, 0),
    (N'FK_ValidationRun_BaselineWorkshopRun', N'ValidationRun', N'BaselineRunID', N'WorkshopRun', N'RunID', 1, N'NO_ACTION', N'NO_ACTION', 0, 0, 0),
    (N'FK_ValidationRun_OptimizedWorkshopRun', N'ValidationRun', N'OptimizedRunID', N'WorkshopRun', N'RunID', 1, N'NO_ACTION', N'NO_ACTION', 0, 0, 0);

IF EXISTS
(
    SELECT * FROM @ExpectedForeignKeyColumns
    EXCEPT
    SELECT fk.name, OBJECT_NAME(fk.parent_object_id), pc.name, OBJECT_NAME(fk.referenced_object_id), rc.name,
            fkc.constraint_column_id, fk.delete_referential_action_desc, fk.update_referential_action_desc,
            fk.is_disabled, fk.is_not_trusted, fk.is_not_for_replication
    FROM sys.foreign_keys AS fk
    INNER JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
    INNER JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
    WHERE fk.parent_object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                  OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
)
OR EXISTS
(
    SELECT fk.name, OBJECT_NAME(fk.parent_object_id), pc.name, OBJECT_NAME(fk.referenced_object_id), rc.name,
            fkc.constraint_column_id, fk.delete_referential_action_desc, fk.update_referential_action_desc,
            fk.is_disabled, fk.is_not_trusted, fk.is_not_for_replication
    FROM sys.foreign_keys AS fk
    INNER JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
    INNER JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
    WHERE fk.parent_object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                  OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
    EXCEPT SELECT * FROM @ExpectedForeignKeyColumns
)
    THROW 51604, 'Existing evidence table foreign-key contract is incompatible.', 1;

DECLARE @ExpectedUniqueIndexColumns table
(
    index_name sysname NOT NULL, table_name sysname NOT NULL, type_desc nvarchar(60) NOT NULL,
    is_primary_key bit NOT NULL, is_unique_constraint bit NOT NULL, column_name sysname NOT NULL,
    key_ordinal tinyint NOT NULL, is_descending_key bit NOT NULL, filter_definition nvarchar(4000) NULL,
    is_disabled bit NOT NULL, is_hypothetical bit NOT NULL
);
INSERT @ExpectedUniqueIndexColumns VALUES
    (N'PK_WorkshopRun', N'WorkshopRun', N'CLUSTERED', 1, 0, N'RunID', 1, 0, NULL, 0, 0),
    (N'PK_WorkshopSample', N'WorkshopSample', N'CLUSTERED', 1, 0, N'RunID', 1, 0, NULL, 0, 0),
    (N'PK_WorkshopSample', N'WorkshopSample', N'CLUSTERED', 1, 0, N'SampleSequence', 2, 0, NULL, 0, 0),
    (N'PK_WorkshopRequestSample', N'WorkshopRequestSample', N'CLUSTERED', 1, 0, N'RunID', 1, 0, NULL, 0, 0),
    (N'PK_WorkshopRequestSample', N'WorkshopRequestSample', N'CLUSTERED', 1, 0, N'SampleSequence', 2, 0, NULL, 0, 0),
    (N'PK_WorkshopRequestSample', N'WorkshopRequestSample', N'CLUSTERED', 1, 0, N'SessionID', 3, 0, NULL, 0, 0),
    (N'PK_WorkshopRequestSample', N'WorkshopRequestSample', N'CLUSTERED', 1, 0, N'RequestID', 4, 0, NULL, 0, 0),
    (N'PK_ValidationRun', N'ValidationRun', N'CLUSTERED', 1, 0, N'ValidationRunID', 1, 0, NULL, 0, 0),
    (N'UQ_ValidationRun_BatchCase', N'ValidationRun', N'NONCLUSTERED', 0, 1, N'ValidationBatchID', 1, 0, NULL, 0, 0),
    (N'UQ_ValidationRun_BatchCase', N'ValidationRun', N'NONCLUSTERED', 0, 1, N'ValidationCaseName', 2, 0, NULL, 0, 0);

IF EXISTS
(
    SELECT * FROM @ExpectedUniqueIndexColumns
    EXCEPT
    SELECT i.name, OBJECT_NAME(i.object_id), i.type_desc, i.is_primary_key, i.is_unique_constraint,
            c.name, CONVERT(tinyint, ic.key_ordinal), ic.is_descending_key, i.filter_definition,
            i.is_disabled, i.is_hypothetical
    FROM sys.indexes AS i
    INNER JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
    INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE i.is_unique = 1 AND i.object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                              OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
)
OR EXISTS
(
    SELECT i.name, OBJECT_NAME(i.object_id), i.type_desc, i.is_primary_key, i.is_unique_constraint,
            c.name, CONVERT(tinyint, ic.key_ordinal), ic.is_descending_key, i.filter_definition,
            i.is_disabled, i.is_hypothetical
    FROM sys.indexes AS i
    INNER JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
    INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE i.is_unique = 1 AND i.object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                              OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
    EXCEPT SELECT * FROM @ExpectedUniqueIndexColumns
)
    THROW 51604, 'Existing evidence table unique-index contract is incompatible.', 1;

DECLARE @ExpectedDefaults table
(
    table_name sysname NOT NULL, column_name sysname NOT NULL,
    constraint_name sysname NOT NULL, normalized_definition nvarchar(4000) NOT NULL
);
IF EXISTS (SELECT * FROM @ExpectedDefaults)
   OR EXISTS
   (
       SELECT OBJECT_NAME(dc.parent_object_id), c.name, dc.name,
              UPPER(REPLACE(REPLACE(REPLACE(REPLACE(dc.definition, N' ', N''), CHAR(9), N''), CHAR(10), N''), CHAR(13), N''))
       FROM sys.default_constraints AS dc
       INNER JOIN sys.columns AS c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
       WHERE dc.parent_object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                     OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
       EXCEPT SELECT * FROM @ExpectedDefaults
   )
    THROW 51604, 'Existing evidence table default contract is incompatible.', 1;

DECLARE @ExpectedChecks table
(
    table_name sysname NOT NULL, constraint_name sysname NOT NULL,
    normalized_definition nvarchar(4000) NOT NULL, is_disabled bit NOT NULL,
    is_not_trusted bit NOT NULL, is_not_for_replication bit NOT NULL
);
INSERT @ExpectedChecks VALUES
    (N'WorkshopRun', N'CK_WorkshopRun_EvidenceClassification', N'EVIDENCECLASSIFICATIONIN''DOC-VERIFIED'',''SUBSCRIPTION-VALIDATED'',''LAB-MEASURED'',''ASSUMPTION'',''TARGET'',''ILLUSTRATIVE''', 0, 0, 0),
    (N'WorkshopRun', N'CK_WorkshopRun_Phase', N'PHASEIN''BASELINE'',''OPTIMIZED'',''COMPARISON''', 0, 0, 0),
    (N'WorkshopRun', N'CK_WorkshopRun_Status', N'RUNSTATUSIN''PENDING'',''RUNNING'',''COMPLETED'',''FAILED'',''STOPPED''', 0, 0, 0),
    (N'WorkshopRun', N'CK_WorkshopRun_Outcome', N'OUTCOMEISNULLOROUTCOMEIN''TARGETMET'',''IMPROVEDOUTSIDETARGET'',''NOMATERIALIMPROVEMENT'',''BASELINETARGETNOTREACHED'',''SAFETYSTOP'',''MANUALSTOP'',''FAILED''', 0, 0, 0),
    (N'WorkshopRun', N'CK_WorkshopRun_Timestamps', N'COMPLETEDATUTCISNULLORCOMPLETEDATUTC>=STARTEDATUTC', 0, 0, 0),
    (N'WorkshopRun', N'CK_WorkshopRun_FrozenSettingsJson', N'LENFROZENSETTINGSJSONBETWEEN2AND4000ANDISJSONFROZENSETTINGSJSON=1', 0, 0, 0),
    (N'WorkshopRun', N'CK_WorkshopRun_BaselineIdentifiers', N'BASELINEQUERYIDISNULLANDBASELINEPLANIDISNULLORBASELINEQUERYID>0ANDBASELINEPLANID>0', 0, 0, 0),
    (N'WorkshopRun', N'CK_WorkshopRun_OptimizedIdentifiers', N'OPTIMIZEDQUERYIDISNULLANDOPTIMIZEDPLANIDISNULLOROPTIMIZEDQUERYID>0ANDOPTIMIZEDPLANID>0', 0, 0, 0),
    (N'WorkshopRun', N'CK_WorkshopRun_Metrics', N'DURATIONMSISNULLORDURATIONMS>=0ANDCPUMSISNULLORCPUMS>=0ANDLOGICALREADSISNULLORLOGICALREADS>=0ANDSPILLSISNULLORSPILLS>=0ANDWAITTIMEMSISNULLORWAITTIMEMS>=0', 0, 0, 0),
    (N'WorkshopSample', N'CK_WorkshopSample_Sequence', N'SAMPLESEQUENCE>0', 0, 0, 0),
    (N'WorkshopSample', N'CK_WorkshopSample_Phase', N'PHASEIN''BASELINE'',''OPTIMIZED''', 0, 0, 0),
    (N'WorkshopSample', N'CK_WorkshopSample_PoolMemory', N'POOLTOTALMEMORYKB>=0ANDPOOLGRANTEDMEMORYKB>=0ANDPOOLUSEDMEMORYKB>=0ANDPOOLAVAILABLEMEMORYKB>=0', 0, 0, 0),
    (N'WorkshopSample', N'CK_WorkshopSample_Utilization', N'GRANTUTILIZATIONPERCENTBETWEEN0AND100', 0, 0, 0),
    (N'WorkshopSample', N'CK_WorkshopSample_Counts', N'GRANTEECOUNT>=0ANDWAITERCOUNT>=0', 0, 0, 0),
    (N'WorkshopSample', N'CK_WorkshopSample_HostMemory', N'HOSTAVAILABLEMEMORYKB>=0ANDHOSTUSEDMEMORYKB>=0', 0, 0, 0),
    (N'WorkshopSample', N'CK_WorkshopSample_ProcessMemory', N'PROCESSPHYSICALMEMORYKB>=0', 0, 0, 0),
    (N'WorkshopSample', N'CK_WorkshopSample_ServerMemory', N'TOTALSERVERMEMORYKB>=0ANDTARGETSERVERMEMORYKB>=0', 0, 0, 0),
    (N'WorkshopRequestSample', N'CK_WorkshopRequestSample_Identifiers', N'SAMPLESEQUENCE>0ANDSESSIONID>0ANDREQUESTID>=0', 0, 0, 0),
    (N'WorkshopRequestSample', N'CK_WorkshopRequestSample_Memory', N'REQUESTEDMEMORYKB>=0ANDGRANTEDMEMORYKB>=0ANDREQUIREDMEMORYKB>=0ANDIDEALMEMORYKB>=0ANDUSEDMEMORYKB>=0ANDMAXUSEDMEMORYKB>=0', 0, 0, 0),
    (N'WorkshopRequestSample', N'CK_WorkshopRequestSample_Wait', N'WAITORDERISNULLORWAITORDER>=0ANDWAITTIMEMS>=0', 0, 0, 0),
    (N'WorkshopRequestSample', N'CK_WorkshopRequestSample_QueryIdentifiers', N'QUERYIDISNULLANDPLANIDISNULLORQUERYID>0ANDPLANID>0', 0, 0, 0),
    (N'ValidationRun', N'CK_ValidationRun_Linkage', N'BASELINERUNIDISNULLANDOPTIMIZEDRUNIDISNULLORBASELINERUNIDISNOTNULLANDOPTIMIZEDRUNIDISNOTNULL', 0, 0, 0);

IF EXISTS
(
    SELECT * FROM @ExpectedChecks
    EXCEPT
    SELECT OBJECT_NAME(cc.parent_object_id), cc.name,
           UPPER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(cc.definition,
               N' ', N''), CHAR(9), N''), CHAR(10), N''), CHAR(13), N''), N'[', N''), N']', N''), N'(', N''), N')', N'')),
           cc.is_disabled, cc.is_not_trusted, cc.is_not_for_replication
    FROM sys.check_constraints AS cc
    WHERE cc.parent_object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                  OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
)
OR EXISTS
(
    SELECT OBJECT_NAME(cc.parent_object_id), cc.name,
           UPPER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(cc.definition,
               N' ', N''), CHAR(9), N''), CHAR(10), N''), CHAR(13), N''), N'[', N''), N']', N''), N'(', N''), N')', N'')),
           cc.is_disabled, cc.is_not_trusted, cc.is_not_for_replication
    FROM sys.check_constraints AS cc
    WHERE cc.parent_object_id IN (OBJECT_ID(N'lab.WorkshopRun'), OBJECT_ID(N'lab.WorkshopSample'),
                                  OBJECT_ID(N'lab.WorkshopRequestSample'), OBJECT_ID(N'lab.ValidationRun'))
    EXCEPT SELECT * FROM @ExpectedChecks
)
    THROW 51604, 'Existing evidence table CHECK contract is incompatible.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'mcp_workshop_diagnostics_certificate')
    CREATE CERTIFICATE [mcp_workshop_diagnostics_certificate]
        WITH SUBJECT = N'MCP workshop server DMV module signing', EXPIRY_DATE = '2099-12-31';
IF NOT EXISTS
(
    SELECT 1 FROM sys.certificates
    WHERE name = N'mcp_workshop_diagnostics_certificate'
      AND subject = N'MCP workshop server DMV module signing'
      AND pvt_key_encryption_type_desc = N'ENCRYPTED_BY_MASTER_KEY'
)
    THROW 51607, 'The diagnostics signing certificate contract is invalid.', 1;
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

CREATE OR ALTER PROCEDURE lab.usp_LinkValidationBatch
    @ValidationBatchID uniqueidentifier,
    @BaselineRunID uniqueidentifier,
    @OptimizedRunID uniqueidentifier
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT <> 0
        THROW 51684, 'Validation linkage cannot run inside an active transaction.', 1;
    IF @ValidationBatchID IS NULL OR @BaselineRunID IS NULL OR @OptimizedRunID IS NULL
       OR @BaselineRunID = @OptimizedRunID
        THROW 51685, 'Validation batch and distinct baseline and optimized run IDs are required.', 1;
    IF NOT EXISTS
       (
           SELECT 1 FROM lab.WorkshopRun
           WHERE RunID = @BaselineRunID AND Phase = 'Baseline' AND RunStatus = 'Completed'
       )
       OR NOT EXISTS
       (
           SELECT 1 FROM lab.WorkshopRun
           WHERE RunID = @OptimizedRunID AND Phase = 'Optimized' AND RunStatus = 'Completed'
       )
        THROW 51686, 'Validation linkage requires completed baseline and optimized workload runs.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Lock the whole batch so concurrent controllers cannot assign conflicting runs. */
        IF NOT EXISTS
           (
               SELECT 1
               FROM lab.ValidationRun WITH (UPDLOCK, HOLDLOCK)
               WHERE ValidationBatchID = @ValidationBatchID
           )
            THROW 51687, 'The validation batch does not exist.', 1;

        ;WITH RequiredValidationCases AS
        (
            SELECT required.ValidationCaseName
            FROM (VALUES
                (N'NARROW-NULL-TERRITORY'), (N'BROAD-NULL-TERRITORY'),
                (N'LOW-TERRITORY'), (N'MEDIUM-TERRITORY'), (N'HIGH-TERRITORY'),
                (N'TOP-MINIMUM'), (N'TOP-MAXIMUM'), (N'NO-MATCH'),
                (N'DATE-BOUNDARY'), (N'LEAP-BOUNDARY'), (N'REPEATED-EXECUTION')
            ) AS required(ValidationCaseName)
        )
        SELECT ValidationCaseName INTO #RequiredValidationCases
        FROM RequiredValidationCases;

        IF EXISTS
           (
               SELECT 1
               FROM #RequiredValidationCases AS required
               WHERE NOT EXISTS
               (
                   SELECT 1 FROM lab.ValidationRun AS validation
                   WHERE validation.ValidationBatchID = @ValidationBatchID
                     AND validation.ValidationCaseName = required.ValidationCaseName
                     AND validation.Passed = 1
               )
           )
           OR EXISTS
           (
               SELECT 1 FROM lab.ValidationRun
               WHERE ValidationBatchID = @ValidationBatchID AND Passed = 0
           )
           OR (SELECT COUNT_BIG(*) FROM lab.ValidationRun
               WHERE ValidationBatchID = @ValidationBatchID) <> 11
            THROW 51688, 'Every required validation case must exist and pass exactly once.', 1;

        IF EXISTS
        (
            SELECT 1 FROM lab.ValidationRun
            WHERE ValidationBatchID = @ValidationBatchID
              AND (BaselineRunID IS NOT NULL OR OptimizedRunID IS NOT NULL)
              AND (BaselineRunID <> @BaselineRunID OR OptimizedRunID <> @OptimizedRunID
                   OR BaselineRunID IS NULL OR OptimizedRunID IS NULL)
        )
            THROW 51689, 'The validation batch is already linked to different workload runs.', 1;

        UPDATE lab.ValidationRun
        SET BaselineRunID = @BaselineRunID,
            OptimizedRunID = @OptimizedRunID
        WHERE ValidationBatchID = @ValidationBatchID
          AND BaselineRunID IS NULL
          AND OptimizedRunID IS NULL;

        IF (SELECT COUNT_BIG(*) FROM lab.ValidationRun
            WHERE ValidationBatchID = @ValidationBatchID
              AND BaselineRunID = @BaselineRunID
              AND OptimizedRunID = @OptimizedRunID
              AND Passed = 1) <> 11
            THROW 51690, 'The validation batch linkage could not be verified.', 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
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
    @ValidationBatchID uniqueidentifier = NULL,
    @ParentComparisonID uniqueidentifier = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF @ParentComparisonID IS NULL AND (@BaselineRunID IS NULL OR @OptimizedRunID IS NULL)
        THROW 51660, 'Supply two run IDs or one parent comparison ID.', 1;
    IF @ParentComparisonID IS NOT NULL AND (@BaselineRunID IS NOT NULL OR @OptimizedRunID IS NOT NULL)
        THROW 51661, 'Parent comparison mode cannot be combined with explicit run IDs.', 1;
    IF @ValidationBatchID IS NULL
        THROW 51666, 'ValidationBatchID is required.', 1;

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

    ;WITH RequiredValidationCases AS
    (
        SELECT required.ValidationCaseName
        FROM (VALUES
            (N'NARROW-NULL-TERRITORY'),
            (N'BROAD-NULL-TERRITORY'),
            (N'LOW-TERRITORY'),
            (N'MEDIUM-TERRITORY'),
            (N'HIGH-TERRITORY'),
            (N'TOP-MINIMUM'),
            (N'TOP-MAXIMUM'),
            (N'NO-MATCH'),
            (N'DATE-BOUNDARY'),
            (N'LEAP-BOUNDARY'),
            (N'REPEATED-EXECUTION')
        ) AS required(ValidationCaseName)
    ), RankedSamples AS
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
            optimized.WaitTimeMs AS OptimizedWaitTimeMs,
            CONVERT(bit, CASE
                                WHEN NOT EXISTS
                (
                                        SELECT 1
                                        FROM RequiredValidationCases AS required
                                        WHERE NOT EXISTS
                                        (
                                                SELECT 1
                                                FROM lab.ValidationRun AS validation
                                                WHERE validation.ValidationBatchID = @ValidationBatchID
                                                    AND validation.ValidationCaseName = required.ValidationCaseName
                                                    AND validation.BaselineRunID = @BaselineRunID
                                                    AND validation.OptimizedRunID = @OptimizedRunID
                                                    AND validation.Passed = 1
                                        )
                )
                 AND NOT EXISTS
                (
                    SELECT 1 FROM lab.ValidationRun AS validation
                                        WHERE validation.ValidationBatchID = @ValidationBatchID
                                            AND (validation.BaselineRunID <> @BaselineRunID
                                                     OR validation.OptimizedRunID <> @OptimizedRunID
                                                     OR validation.BaselineRunID IS NULL
                                                     OR validation.OptimizedRunID IS NULL
                                                     OR validation.Passed = 0)
                ) THEN 1 ELSE 0 END) AS CorrectnessPassed
        FROM lab.WorkshopRun AS baseline
        INNER JOIN lab.WorkshopRun AS optimized ON optimized.RunID = @OptimizedRunID
        LEFT JOIN SampleMetrics AS baselineSample ON baselineSample.RunID = baseline.RunID
        LEFT JOIN SampleMetrics AS optimizedSample ON optimizedSample.RunID = optimized.RunID
        WHERE baseline.RunID = @BaselineRunID
    ), MetricEvaluation AS
    (
        SELECT *, CONVERT(bit, CASE
            WHEN (BaselineDurationMs = 0 AND OptimizedDurationMs > 0)
              OR (BaselineDurationMs > 0 AND CONVERT(decimal(38,4), OptimizedDurationMs) > CONVERT(decimal(38,4), BaselineDurationMs) * 1.10)
              OR (BaselineCpuMs = 0 AND OptimizedCpuMs > 0)
              OR (BaselineCpuMs > 0 AND CONVERT(decimal(38,4), OptimizedCpuMs) > CONVERT(decimal(38,4), BaselineCpuMs) * 1.10)
              OR (BaselineLogicalReads = 0 AND OptimizedLogicalReads > 0)
              OR (BaselineLogicalReads > 0 AND CONVERT(decimal(38,4), OptimizedLogicalReads) > CONVERT(decimal(38,4), BaselineLogicalReads) * 1.10)
              OR (BaselineSpills = 0 AND OptimizedSpills > 0)
              OR (BaselineSpills > 0 AND CONVERT(decimal(38,4), OptimizedSpills) > CONVERT(decimal(38,4), BaselineSpills) * 1.10)
              OR (BaselineWaitTimeMs = 0 AND OptimizedWaitTimeMs > 0)
              OR (BaselineWaitTimeMs > 0 AND CONVERT(decimal(38,4), OptimizedWaitTimeMs) > CONVERT(decimal(38,4), BaselineWaitTimeMs) * 1.10)
            THEN 1 ELSE 0 END) AS HasMaterialRegression
                        , CONVERT(bit, CASE WHEN BaselineDurationMs > 0 AND CONVERT(decimal(38,4), OptimizedDurationMs) <= CONVERT(decimal(38,4), BaselineDurationMs) * 0.90 THEN 1 ELSE 0 END) AS DurationImprovedMaterially
                        , CONVERT(bit, CASE WHEN BaselineCpuMs > 0 AND CONVERT(decimal(38,4), OptimizedCpuMs) <= CONVERT(decimal(38,4), BaselineCpuMs) * 0.90 THEN 1 ELSE 0 END) AS CpuImprovedMaterially
                        , CONVERT(bit, CASE WHEN BaselineLogicalReads > 0 AND CONVERT(decimal(38,4), OptimizedLogicalReads) <= CONVERT(decimal(38,4), BaselineLogicalReads) * 0.90 THEN 1 ELSE 0 END) AS LogicalReadsImprovedMaterially
                        , CONVERT(bit, CASE WHEN BaselineSpills > 0 AND CONVERT(decimal(38,4), OptimizedSpills) <= CONVERT(decimal(38,4), BaselineSpills) * 0.90 THEN 1 ELSE 0 END) AS SpillsImprovedMaterially
                        , CONVERT(bit, CASE WHEN BaselineWaitTimeMs > 0 AND CONVERT(decimal(38,4), OptimizedWaitTimeMs) <= CONVERT(decimal(38,4), BaselineWaitTimeMs) * 0.90 THEN 1 ELSE 0 END) AS WaitsImprovedMaterially
        FROM Comparison
        ), EvaluatedComparison AS
        (
                SELECT *, CONVERT(bit, CASE
                        WHEN DurationImprovedMaterially = 1 OR CpuImprovedMaterially = 1
                            OR LogicalReadsImprovedMaterially = 1 OR SpillsImprovedMaterially = 1
                            OR WaitsImprovedMaterially = 1
                        THEN 1 ELSE 0 END) AS HasAdditionalMetricImprovement
                FROM MetricEvaluation
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
        CorrectnessPassed,
        HasMaterialRegression,
        HasAdditionalMetricImprovement,
        DurationImprovedMaterially,
        CpuImprovedMaterially,
        LogicalReadsImprovedMaterially,
        SpillsImprovedMaterially,
        WaitsImprovedMaterially,
        CONVERT(decimal(6,2), BaselineMedianGrantUtilizationPercent - OptimizedMedianGrantUtilizationPercent)
            AS MedianUtilizationReductionPoints,
        CONVERT(varchar(24), CASE
            WHEN CorrectnessPassed = 0 THEN N'Failed'
            WHEN BaselinePeakGrantUtilizationPercent NOT BETWEEN 75.00 AND 85.00
                THEN N'BaselineTargetNotReached'
            WHEN HasMaterialRegression = 1 THEN N'NoMaterialImprovement'
            WHEN HasAdditionalMetricImprovement = 0 THEN N'NoMaterialImprovement'
            WHEN BaselinePeakGrantUtilizationPercent BETWEEN 75.00 AND 85.00
             AND OptimizedPeakGrantUtilizationPercent BETWEEN 35.00 AND 45.00
                THEN N'TargetMet'
            WHEN BaselinePeakGrantUtilizationPercent - OptimizedPeakGrantUtilizationPercent >= 25.00
                THEN N'ImprovedOutsideTarget'
            ELSE N'NoMaterialImprovement'
        END) AS OutcomeBand
    FROM EvaluatedComparison;
END;
GO

DECLARE @DatabaseCertificateThumbprint varbinary(32) =
(
    SELECT thumbprint FROM sys.certificates WHERE name = N'mcp_workshop_diagnostics_certificate'
);
IF @DatabaseCertificateThumbprint IS NULL
    THROW 51675, 'The database diagnostics signing certificate is missing.', 1;
IF EXISTS
(
    SELECT 1 FROM master.sys.certificates
    WHERE name = N'mcp_workshop_diagnostics_certificate'
      AND thumbprint <> @DatabaseCertificateThumbprint
)
    THROW 51676, 'The master diagnostics certificate does not match the database certificate.', 1;

IF NOT EXISTS (SELECT 1 FROM master.sys.certificates WHERE name = N'mcp_workshop_diagnostics_certificate')
BEGIN
    DECLARE @DefaultBackupPath nvarchar(4000) =
        CONVERT(nvarchar(4000), SERVERPROPERTY(N'InstanceDefaultBackupPath'));
    IF @DefaultBackupPath IS NULL OR LEN(@DefaultBackupPath) = 0 OR LEN(@DefaultBackupPath) > 3500
        THROW 51677, 'InstanceDefaultBackupPath is unavailable or too long for certificate export.', 1;
    IF RIGHT(@DefaultBackupPath, 1) NOT IN (N'\', N'/')
        SET @DefaultBackupPath += N'\';

    DECLARE @CertificateFile nvarchar(4000) = @DefaultBackupPath
        + N'mcp_workshop_diagnostics_'
        + CONVERT(nvarchar(64), @DatabaseCertificateThumbprint, 2)
        + N'_' + REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N'') + N'.cer';
    DECLARE @EscapedCertificateFile nvarchar(4000) = REPLACE(@CertificateFile, N'''', N'''''''');
    DECLARE @CertificateSql nvarchar(max) =
        N'BACKUP CERTIFICATE [mcp_workshop_diagnostics_certificate] TO FILE = N'''
        + @EscapedCertificateFile + N''';';
    EXEC sys.sp_executesql @CertificateSql;

    SET @CertificateSql = N'USE [master]; CREATE CERTIFICATE [mcp_workshop_diagnostics_certificate] FROM FILE = N'''
        + @EscapedCertificateFile + N''';';
    EXEC master.sys.sp_executesql @CertificateSql;

    /* Certificate export is public, contains no private key, and must be deleted by bootstrap cleanup. */
    PRINT N'Certificate export is public; bootstrap cleanup must delete: ' + @CertificateFile;
END;

IF SUSER_ID(N'mcp_workshop_diagnostics_certificate_login') IS NULL
    EXEC master.sys.sp_executesql
        N'CREATE LOGIN [mcp_workshop_diagnostics_certificate_login]
          FROM CERTIFICATE [mcp_workshop_diagnostics_certificate];';
IF NOT EXISTS
(
    SELECT 1
    FROM master.sys.server_principals AS principal
    INNER JOIN master.sys.certificates AS certificate ON certificate.sid = principal.sid
    WHERE principal.name = N'mcp_workshop_diagnostics_certificate_login'
      AND certificate.name = N'mcp_workshop_diagnostics_certificate'
)
    THROW 51678, 'The diagnostics certificate login mapping is invalid.', 1;

DECLARE @ReaderLoginName sysname = N'mcp_workshop_reader';
DECLARE @McpReaderPassword nvarchar(4000) =
    TRY_CONVERT(nvarchar(4000), SESSION_CONTEXT(N'McpReaderPassword'));

IF SUSER_ID(N'mcp_workshop_reader') IS NULL
BEGIN
    IF @McpReaderPassword IS NULL
        THROW 51670, 'McpReaderPassword session context is required when creating mcp_workshop_reader.', 1;

     IF LEN(@McpReaderPassword) NOT BETWEEN 20 AND 128
         OR DATALENGTH(@McpReaderPassword) / 2 NOT BETWEEN 20 AND 128
       OR @McpReaderPassword COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[A-Z]%'
       OR @McpReaderPassword COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[a-z]%'
       OR @McpReaderPassword COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[0-9]%'
       OR @McpReaderPassword COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[^A-Za-z0-9]%'
       OR CHARINDEX(NCHAR(0), @McpReaderPassword COLLATE Latin1_General_100_BIN2) > 0
       OR PATINDEX(N'%[' + NCHAR(1) + N'-' + NCHAR(31) + NCHAR(127) + N']%',
            @McpReaderPassword COLLATE Latin1_General_100_BIN2) > 0
       OR CHARINDEX(LOWER(@ReaderLoginName), LOWER(@McpReaderPassword)) > 0
    BEGIN
        BEGIN TRY
            EXEC sys.sp_set_session_context @key = N'McpReaderPassword', @value = NULL;
        END TRY
        BEGIN CATCH
        END CATCH;
        SET @McpReaderPassword = NULL;
        THROW 51667, 'McpReaderPassword does not satisfy the workshop secret policy.', 1;
    END;

    DECLARE @EscapedMcpReaderPassword nvarchar(8000) =
        REPLACE(@McpReaderPassword, N'''', N'''''' );
    DECLARE @CreateReaderLoginSql nvarchar(max) =
        N'CREATE LOGIN ' + QUOTENAME(@ReaderLoginName)
        + N' WITH PASS' + N'WORD = N''' + @EscapedMcpReaderPassword
        + N''', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = [AdventureWorks2022];';
    BEGIN TRY
        EXEC master.sys.sp_executesql @CreateReaderLoginSql;
    END TRY
    BEGIN CATCH
        BEGIN TRY
            EXEC sys.sp_set_session_context @key = N'McpReaderPassword', @value = NULL;
        END TRY
        BEGIN CATCH
        END CATCH;
        SET @McpReaderPassword = NULL;
        SET @CreateReaderLoginSql = NULL;
        THROW;
    END CATCH;

    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'McpReaderPassword', @value = NULL;
    END TRY
    BEGIN CATCH
    END CATCH;
    SET @McpReaderPassword = NULL;
    SET @EscapedMcpReaderPassword = NULL;
    SET @CreateReaderLoginSql = NULL;
END
ELSE
BEGIN
    /* Never consume or retain a supplied secret when the login already exists. */
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'McpReaderPassword', @value = NULL;
    END TRY
    BEGIN CATCH
    END CATCH;
    SET @McpReaderPassword = NULL;
END;

IF NOT EXISTS
(
    SELECT 1
        FROM master.sys.server_principals AS principal
        INNER JOIN master.sys.sql_logins AS sql_login
            ON sql_login.principal_id = principal.principal_id
        WHERE principal.name = @ReaderLoginName
            AND principal.type_desc = N'SQL_LOGIN'
            AND principal.is_disabled = 0
            AND principal.default_database_name = N'AdventureWorks2022'
            AND sql_login.is_policy_checked = 1
            AND sql_login.is_expiration_checked = 0
)
   OR IS_SRVROLEMEMBER(N'sysadmin', N'mcp_workshop_reader') <> 0
    THROW 51668, 'The mcp_workshop_reader server login contract is invalid.', 1;

GRANT VIEW SERVER PERFORMANCE STATE TO [mcp_workshop_diagnostics_certificate_login];
REVOKE VIEW SERVER STATE FROM [mcp_workshop_diagnostics_certificate_login];

IF EXISTS
(
    SELECT 1
    FROM master.sys.server_role_members AS membership
    WHERE membership.member_principal_id = SUSER_ID(N'mcp_workshop_diagnostics_certificate_login')
)
   OR EXISTS
   (
       SELECT permission_name, state
       FROM master.sys.server_permissions
       WHERE grantee_principal_id = SUSER_ID(N'mcp_workshop_diagnostics_certificate_login')
       EXCEPT SELECT N'VIEW SERVER PERFORMANCE STATE', N'G'
   )
   OR EXISTS
   (
       SELECT N'VIEW SERVER PERFORMANCE STATE', N'G'
       EXCEPT
       SELECT permission_name, state
       FROM master.sys.server_permissions
       WHERE grantee_principal_id = SUSER_ID(N'mcp_workshop_diagnostics_certificate_login')
   )
    THROW 51679, 'The diagnostics certificate login must have only VIEW SERVER PERFORMANCE STATE.', 1;

IF EXISTS
(
    SELECT 1
    FROM sys.crypt_properties AS crypt
    INNER JOIN sys.certificates AS certificate ON certificate.thumbprint = crypt.thumbprint
    WHERE crypt.class_desc = N'OBJECT_OR_COLUMN'
      AND crypt.major_id = OBJECT_ID(N'lab.usp_GetMemorySnapshot', N'P')
      AND certificate.name = N'mcp_workshop_diagnostics_certificate'
)
    DROP SIGNATURE FROM OBJECT::lab.usp_GetMemorySnapshot
        BY CERTIFICATE [mcp_workshop_diagnostics_certificate];
ADD SIGNATURE TO OBJECT::lab.usp_GetMemorySnapshot
    BY CERTIFICATE [mcp_workshop_diagnostics_certificate];

IF EXISTS
(
    SELECT 1
    FROM sys.crypt_properties AS crypt
    INNER JOIN sys.certificates AS certificate ON certificate.thumbprint = crypt.thumbprint
    WHERE crypt.class_desc = N'OBJECT_OR_COLUMN'
      AND crypt.major_id = OBJECT_ID(N'lab.usp_GetActiveWorkshopGrants', N'P')
      AND certificate.name = N'mcp_workshop_diagnostics_certificate'
)
    DROP SIGNATURE FROM OBJECT::lab.usp_GetActiveWorkshopGrants
        BY CERTIFICATE [mcp_workshop_diagnostics_certificate];
ADD SIGNATURE TO OBJECT::lab.usp_GetActiveWorkshopGrants
    BY CERTIFICATE [mcp_workshop_diagnostics_certificate];

DECLARE @ExpectedSignedObjects table
(
    object_id int NOT NULL, thumbprint varbinary(32) NOT NULL,
    crypt_type_desc nvarchar(60) NOT NULL
);
INSERT @ExpectedSignedObjects VALUES
    (OBJECT_ID(N'lab.usp_GetMemorySnapshot', N'P'), @DatabaseCertificateThumbprint, N'SIGNATURE BY CERTIFICATE'),
    (OBJECT_ID(N'lab.usp_GetActiveWorkshopGrants', N'P'), @DatabaseCertificateThumbprint, N'SIGNATURE BY CERTIFICATE');
IF EXISTS
(
    SELECT object_id, thumbprint, crypt_type_desc FROM @ExpectedSignedObjects
    EXCEPT
    SELECT crypt.major_id, crypt.thumbprint, crypt.crypt_type_desc
    FROM sys.crypt_properties AS crypt
    WHERE crypt.class_desc = N'OBJECT_OR_COLUMN'
      AND crypt.major_id IN (OBJECT_ID(N'lab.usp_GetMemorySnapshot', N'P'),
                             OBJECT_ID(N'lab.usp_GetActiveWorkshopGrants', N'P'))
)
OR EXISTS
(
    SELECT crypt.major_id, crypt.thumbprint, crypt.crypt_type_desc
    FROM sys.crypt_properties AS crypt
    WHERE crypt.class_desc = N'OBJECT_OR_COLUMN'
      AND crypt.major_id IN (OBJECT_ID(N'lab.usp_GetMemorySnapshot', N'P'),
                             OBJECT_ID(N'lab.usp_GetActiveWorkshopGrants', N'P'))
    EXCEPT SELECT object_id, thumbprint, crypt_type_desc FROM @ExpectedSignedObjects
)
    THROW 51680, 'The server DMV procedure signature contract is invalid.', 1;

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
IF EXISTS
(
    SELECT 1
    FROM sys.database_role_members AS membership
    INNER JOIN sys.database_principals AS member ON member.principal_id = membership.member_principal_id
    WHERE member.name = N'mcp_workshop_reader'
)
    THROW 51673, 'The reader must not belong to any custom or fixed database role; public is implicit.', 1;
IF EXISTS
(
    SELECT 1
    FROM master.sys.server_role_members AS membership
    WHERE membership.member_principal_id = SUSER_ID(N'mcp_workshop_reader')
)
    THROW 51674, 'The reader must not belong to any custom or fixed server role; public is implicit.', 1;
IF EXISTS
(
    SELECT 1 FROM master.sys.server_permissions
    WHERE grantee_principal_id = SUSER_ID(N'mcp_workshop_reader')
      AND state IN (N'G', N'W')
)
    THROW 51681, 'The reader login must not hold any direct server grant.', 1;

GRANT CONNECT TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetMemorySnapshot TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetActiveWorkshopGrants TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetQueryStoreTopQueries TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetQueryStoreWaits TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_GetProcedurePlanSummary TO [mcp_workshop_reader];
GRANT EXECUTE ON OBJECT::lab.usp_CompareWorkshopRuns TO [mcp_workshop_reader];
GRANT SELECT ON OBJECT::lab.vw_WorkshopRunSummary TO [mcp_workshop_reader];
GRANT SELECT ON OBJECT::lab.vw_WorkshopSampleSummary TO [mcp_workshop_reader];
DENY INSERT ON OBJECT::lab.WorkshopRun TO [mcp_workshop_reader];
DENY UPDATE ON OBJECT::lab.WorkshopRun TO [mcp_workshop_reader];
DENY DELETE ON OBJECT::lab.WorkshopRun TO [mcp_workshop_reader];
DENY ALTER ON OBJECT::lab.WorkshopRun TO [mcp_workshop_reader];
DENY CONTROL ON OBJECT::lab.WorkshopRun TO [mcp_workshop_reader];
DENY INSERT ON OBJECT::lab.WorkshopSample TO [mcp_workshop_reader];
DENY UPDATE ON OBJECT::lab.WorkshopSample TO [mcp_workshop_reader];
DENY DELETE ON OBJECT::lab.WorkshopSample TO [mcp_workshop_reader];
DENY ALTER ON OBJECT::lab.WorkshopSample TO [mcp_workshop_reader];
DENY CONTROL ON OBJECT::lab.WorkshopSample TO [mcp_workshop_reader];
DENY INSERT ON OBJECT::lab.WorkshopRequestSample TO [mcp_workshop_reader];
DENY UPDATE ON OBJECT::lab.WorkshopRequestSample TO [mcp_workshop_reader];
DENY DELETE ON OBJECT::lab.WorkshopRequestSample TO [mcp_workshop_reader];
DENY ALTER ON OBJECT::lab.WorkshopRequestSample TO [mcp_workshop_reader];
DENY CONTROL ON OBJECT::lab.WorkshopRequestSample TO [mcp_workshop_reader];
DENY INSERT ON OBJECT::lab.ValidationRun TO [mcp_workshop_reader];
DENY UPDATE ON OBJECT::lab.ValidationRun TO [mcp_workshop_reader];
DENY DELETE ON OBJECT::lab.ValidationRun TO [mcp_workshop_reader];
DENY ALTER ON OBJECT::lab.ValidationRun TO [mcp_workshop_reader];
DENY CONTROL ON OBJECT::lab.ValidationRun TO [mcp_workshop_reader];
DENY TAKE OWNERSHIP ON SCHEMA::lab TO [mcp_workshop_reader];
DENY VIEW DEFINITION ON SCHEMA::lab TO [mcp_workshop_reader];
DENY ALTER ON DATABASE::[AdventureWorks2022] TO [mcp_workshop_reader];
DENY TAKE OWNERSHIP ON DATABASE::[AdventureWorks2022] TO [mcp_workshop_reader];
DENY VIEW DEFINITION ON DATABASE::[AdventureWorks2022] TO [mcp_workshop_reader];
DENY IMPERSONATE ANY USER TO [mcp_workshop_reader];

DECLARE @ExpectedReaderPermissions table
(
    class tinyint NOT NULL, major_id int NOT NULL, minor_id int NOT NULL,
    permission_name nvarchar(128) NOT NULL, state char(1) NOT NULL
);
INSERT @ExpectedReaderPermissions VALUES
    (0, 0, 0, N'CONNECT', N'G'),
    (0, 0, 0, N'ALTER', N'D'),
    (0, 0, 0, N'TAKE OWNERSHIP', N'D'),
    (0, 0, 0, N'VIEW DEFINITION', N'D'),
    (0, 0, 0, N'IMPERSONATE ANY USER', N'D'),
    (3, SCHEMA_ID(N'lab'), 0, N'TAKE OWNERSHIP', N'D'),
    (3, SCHEMA_ID(N'lab'), 0, N'VIEW DEFINITION', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRun'), 0, N'INSERT', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRun'), 0, N'UPDATE', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRun'), 0, N'DELETE', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRun'), 0, N'ALTER', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRun'), 0, N'CONTROL', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopSample'), 0, N'INSERT', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopSample'), 0, N'UPDATE', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopSample'), 0, N'DELETE', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopSample'), 0, N'ALTER', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopSample'), 0, N'CONTROL', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRequestSample'), 0, N'INSERT', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRequestSample'), 0, N'UPDATE', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRequestSample'), 0, N'DELETE', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRequestSample'), 0, N'ALTER', N'D'),
    (1, OBJECT_ID(N'lab.WorkshopRequestSample'), 0, N'CONTROL', N'D'),
    (1, OBJECT_ID(N'lab.ValidationRun'), 0, N'INSERT', N'D'),
    (1, OBJECT_ID(N'lab.ValidationRun'), 0, N'UPDATE', N'D'),
    (1, OBJECT_ID(N'lab.ValidationRun'), 0, N'DELETE', N'D'),
    (1, OBJECT_ID(N'lab.ValidationRun'), 0, N'ALTER', N'D'),
    (1, OBJECT_ID(N'lab.ValidationRun'), 0, N'CONTROL', N'D'),
    (1, OBJECT_ID(N'lab.usp_GetMemorySnapshot'), 0, N'EXECUTE', N'G'),
    (1, OBJECT_ID(N'lab.usp_GetActiveWorkshopGrants'), 0, N'EXECUTE', N'G'),
    (1, OBJECT_ID(N'lab.usp_GetQueryStoreTopQueries'), 0, N'EXECUTE', N'G'),
    (1, OBJECT_ID(N'lab.usp_GetQueryStoreWaits'), 0, N'EXECUTE', N'G'),
    (1, OBJECT_ID(N'lab.usp_GetProcedurePlanSummary'), 0, N'EXECUTE', N'G'),
    (1, OBJECT_ID(N'lab.usp_CompareWorkshopRuns'), 0, N'EXECUTE', N'G'),
    (1, OBJECT_ID(N'lab.vw_WorkshopRunSummary'), 0, N'SELECT', N'G'),
    (1, OBJECT_ID(N'lab.vw_WorkshopSampleSummary'), 0, N'SELECT', N'G');

IF EXISTS
(
    SELECT class, major_id, minor_id, permission_name, state FROM @ExpectedReaderPermissions
    EXCEPT
    SELECT permission.class, permission.major_id, permission.minor_id, permission.permission_name, permission.state
    FROM sys.database_permissions AS permission
    WHERE permission.grantee_principal_id = USER_ID(N'mcp_workshop_reader')
)
OR EXISTS
(
    SELECT permission.class, permission.major_id, permission.minor_id, permission.permission_name, permission.state
    FROM sys.database_permissions AS permission
    WHERE permission.grantee_principal_id = USER_ID(N'mcp_workshop_reader')
      AND permission.state_desc IN (N'GRANT', N'GRANT_WITH_GRANT_OPTION', N'DENY')
    EXCEPT
    SELECT class, major_id, minor_id, permission_name, state FROM @ExpectedReaderPermissions
)
    THROW 51682, 'The reader direct database permission set is not exact.', 1;

DECLARE @LabObjectTargets table
(
    securable_name nvarchar(517) NOT NULL,
    object_name nvarchar(517) NOT NULL,
    object_type char(2) NOT NULL
);
INSERT @LabObjectTargets (securable_name, object_name, object_type)
SELECT QUOTENAME(schema_object.name) + N'.' + QUOTENAME(object_object.name),
       schema_object.name + N'.' + object_object.name,
       object_object.type
FROM sys.objects AS object_object
INNER JOIN sys.schemas AS schema_object ON schema_object.schema_id = object_object.schema_id
WHERE schema_object.name = N'lab'
  AND object_object.is_ms_shipped = 0;

DECLARE @EffectiveReaderPermissions table
(
    securable_name nvarchar(517) NOT NULL,
    object_name nvarchar(517) NULL,
    object_type char(2) NULL,
    securable_class nvarchar(60) NOT NULL,
    permission_name nvarchar(128) NOT NULL
);

IF EXISTS
(
    SELECT 1
    FROM sys.database_permissions AS public_permission
    LEFT JOIN sys.objects AS public_object
      ON public_permission.class = 1 AND public_object.object_id = public_permission.major_id
    WHERE public_permission.grantee_principal_id = USER_ID(N'public')
      AND public_permission.state IN (N'G', N'W')
      AND
      (
          (public_permission.class = 0
           AND public_permission.permission_name IN
               (N'ALTER', N'CONTROL', N'TAKE OWNERSHIP', N'IMPERSONATE ANY USER', N'VIEW DEFINITION'))
          OR (public_permission.class = 3
              AND public_permission.major_id = SCHEMA_ID(N'lab')
              AND public_permission.permission_name IN
                  (N'SELECT', N'EXECUTE', N'ALTER', N'CONTROL', N'TAKE OWNERSHIP', N'VIEW DEFINITION'))
          OR (public_permission.class = 1
              AND public_object.schema_id = SCHEMA_ID(N'lab')
              AND public_permission.permission_name IN
                  (N'SELECT', N'EXECUTE', N'ALTER', N'CONTROL', N'TAKE OWNERSHIP', N'VIEW DEFINITION',
                   N'INSERT', N'UPDATE', N'DELETE'))
      )
)
    THROW 51683, 'The public role grants permissions outside the lab reader allowlist.', 1;

DECLARE @PermissionFailure nvarchar(2048) = N'';
DECLARE @Impersonated bit = 0;
BEGIN TRY
    EXECUTE AS USER = N'mcp_workshop_reader';
    SET @Impersonated = 1;

    INSERT @EffectiveReaderPermissions
        (securable_name, object_name, object_type, securable_class, permission_name)
    SELECT DB_NAME(), NULL, NULL, N'DATABASE', permission.permission_name
    FROM sys.fn_my_permissions(DB_NAME(), N'DATABASE') AS permission;
    INSERT @EffectiveReaderPermissions
        (securable_name, object_name, object_type, securable_class, permission_name)
    SELECT N'lab', NULL, NULL, N'SCHEMA', permission.permission_name
    FROM sys.fn_my_permissions(N'lab', N'SCHEMA') AS permission;
    INSERT @EffectiveReaderPermissions
        (securable_name, object_name, object_type, securable_class, permission_name)
    SELECT target.securable_name, target.object_name, target.object_type, N'OBJECT', permission.permission_name
    FROM @LabObjectTargets AS target
    CROSS APPLY sys.fn_my_permissions(target.securable_name, N'OBJECT') AS permission;

    IF HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CONNECT') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopRun', N'OBJECT', N'INSERT') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopRun', N'OBJECT', N'UPDATE') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopRun', N'OBJECT', N'DELETE') <> 0
    OR HAS_PERMS_BY_NAME(N'lab.WorkshopRun', N'OBJECT', N'ALTER') <> 0
    OR HAS_PERMS_BY_NAME(N'lab.WorkshopRun', N'OBJECT', N'CONTROL') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopSample', N'OBJECT', N'INSERT') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopSample', N'OBJECT', N'UPDATE') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopSample', N'OBJECT', N'DELETE') <> 0
    OR HAS_PERMS_BY_NAME(N'lab.WorkshopSample', N'OBJECT', N'ALTER') <> 0
    OR HAS_PERMS_BY_NAME(N'lab.WorkshopSample', N'OBJECT', N'CONTROL') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopRequestSample', N'OBJECT', N'INSERT') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopRequestSample', N'OBJECT', N'UPDATE') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.WorkshopRequestSample', N'OBJECT', N'DELETE') <> 0
    OR HAS_PERMS_BY_NAME(N'lab.WorkshopRequestSample', N'OBJECT', N'ALTER') <> 0
    OR HAS_PERMS_BY_NAME(N'lab.WorkshopRequestSample', N'OBJECT', N'CONTROL') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.ValidationRun', N'OBJECT', N'INSERT') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.ValidationRun', N'OBJECT', N'UPDATE') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.ValidationRun', N'OBJECT', N'DELETE') <> 0
    OR HAS_PERMS_BY_NAME(N'lab.ValidationRun', N'OBJECT', N'ALTER') <> 0
    OR HAS_PERMS_BY_NAME(N'lab.ValidationRun', N'OBJECT', N'CONTROL') <> 0
       OR HAS_PERMS_BY_NAME(N'lab', N'SCHEMA', N'ALTER') <> 0
       OR HAS_PERMS_BY_NAME(N'lab', N'SCHEMA', N'CONTROL') <> 0
       OR HAS_PERMS_BY_NAME(N'lab', N'SCHEMA', N'TAKE OWNERSHIP') <> 0
       OR HAS_PERMS_BY_NAME(N'lab', N'SCHEMA', N'VIEW DEFINITION') <> 0
       OR HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CONTROL') <> 0
       OR HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'ALTER') <> 0
       OR HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'TAKE OWNERSHIP') <> 0
       OR HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'VIEW DEFINITION') <> 0
       OR HAS_PERMS_BY_NAME(N'dbo', N'USER', N'IMPERSONATE') <> 0
       OR HAS_PERMS_BY_NAME(N'lab.vw_WorkshopRunSummary', N'OBJECT', N'SELECT') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.vw_WorkshopSampleSummary', N'OBJECT', N'SELECT') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.usp_GetMemorySnapshot', N'OBJECT', N'EXECUTE') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.usp_GetActiveWorkshopGrants', N'OBJECT', N'EXECUTE') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.usp_GetQueryStoreTopQueries', N'OBJECT', N'EXECUTE') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.usp_GetQueryStoreWaits', N'OBJECT', N'EXECUTE') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.usp_GetProcedurePlanSummary', N'OBJECT', N'EXECUTE') <> 1
       OR HAS_PERMS_BY_NAME(N'lab.usp_CompareWorkshopRuns', N'OBJECT', N'EXECUTE') <> 1
        SET @PermissionFailure = N'Least-privilege verification failed for mcp_workshop_reader.';

    IF EXISTS
    (
        SELECT 1
        FROM @EffectiveReaderPermissions AS effective
        WHERE (effective.securable_class = N'DATABASE'
               AND effective.permission_name IN
                   (N'ALTER', N'CONTROL', N'TAKE OWNERSHIP', N'IMPERSONATE ANY USER', N'VIEW DEFINITION'))
           OR (effective.securable_class IN (N'SCHEMA', N'OBJECT')
               AND effective.permission_name IN
                   (N'ALTER', N'CONTROL', N'TAKE OWNERSHIP', N'VIEW DEFINITION', N'IMPERSONATE'))
           OR (effective.object_type = N'U' AND effective.permission_name IN
                   (N'SELECT', N'INSERT', N'UPDATE', N'DELETE'))
           OR (effective.permission_name = N'EXECUTE'
               AND COALESCE(effective.object_name, N'') NOT IN
                   (N'lab.usp_GetMemorySnapshot', N'lab.usp_GetActiveWorkshopGrants',
                    N'lab.usp_GetQueryStoreTopQueries', N'lab.usp_GetQueryStoreWaits',
                    N'lab.usp_GetProcedurePlanSummary', N'lab.usp_CompareWorkshopRuns'))
           OR (effective.permission_name = N'SELECT'
               AND effective.object_type IS NOT NULL
               AND COALESCE(effective.object_name, N'') NOT IN
                   (N'lab.vw_WorkshopRunSummary', N'lab.vw_WorkshopSampleSummary'))
    )
        SET @PermissionFailure = N'Effective permissions exceed the lab reader allowlist.';
    REVERT;
    SET @Impersonated = 0;
END TRY
BEGIN CATCH
    IF @Impersonated = 1
        REVERT;
    THROW;
END CATCH;
IF @PermissionFailure <> N''
    THROW 51671, @PermissionFailure, 1;
GO
