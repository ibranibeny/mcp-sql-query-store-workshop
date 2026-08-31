:on error exit
/*
Run only after 00-Preflight.sql succeeds in Infrastructure phase. This script owns
only the MCP SQL workshop marker, utility database, Resource Governor objects, and
classifier function named below. It never replaces an unrelated classifier.

Microsoft Learn — server memory configuration:
https://learn.microsoft.com/sql/database-engine/configure-windows/server-memory-server-configuration-options
Microsoft Learn — Resource Governor:
https://learn.microsoft.com/sql/relational-databases/resource-governor/resource-governor
Microsoft Learn — classifier functions:
https://learn.microsoft.com/sql/relational-databases/resource-governor/resource-governor-classifier-function
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DatabaseName sysname = NULLIF(LTRIM(RTRIM(N'$(DatabaseName)')), N'');
DECLARE @ExpectedServerName nvarchar(256) = NULLIF(LOWER(LTRIM(RTRIM(N'$(ExpectedServerName)'))), N'');
DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @CurrentClassifierId int;
DECLARE @WorkshopClassifierId int = OBJECT_ID(N'master.dbo.mcp_sql_workshop_classifier', N'FN');
DECLARE @ExistingDefinition nvarchar(max);
DECLARE @UtilityDatabaseCreated bit = 0;

IF TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 16
    THROW 51100, 'SQL Server major version 16 (SQL Server 2022) is required.', 1;

IF CONVERT(nvarchar(256), SERVERPROPERTY('Edition')) NOT LIKE N'%Enterprise%'
    THROW 51101, 'SQL Server Enterprise edition is required for Resource Governor.', 1;

IF @DatabaseName IS NULL
    THROW 51102, 'DatabaseName is required.', 1;

IF @ExpectedServerName IS NULL
    THROW 51103, 'ExpectedServerName is required.', 1;

DECLARE @ActualMachine nvarchar(256) = LOWER(LTRIM(RTRIM(CONVERT(nvarchar(256), SERVERPROPERTY('MachineName')))));
DECLARE @ActualServer nvarchar(256) = LOWER(LTRIM(RTRIM(CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')))));
DECLARE @ExpectedHost nvarchar(256) = @ExpectedServerName;
IF CHARINDEX(N'\', @ExpectedHost) > 0 SET @ExpectedHost = LEFT(@ExpectedHost, CHARINDEX(N'\', @ExpectedHost) - 1);
IF CHARINDEX(N'.', @ExpectedHost) > 0 SET @ExpectedHost = LEFT(@ExpectedHost, CHARINDEX(N'.', @ExpectedHost) - 1);
IF CHARINDEX(N'\', @ActualServer) > 0 SET @ActualServer = LEFT(@ActualServer, CHARINDEX(N'\', @ActualServer) - 1);
IF CHARINDEX(N'.', @ActualServer) > 0 SET @ActualServer = LEFT(@ActualServer, CHARINDEX(N'.', @ActualServer) - 1);
IF CHARINDEX(N'.', @ActualMachine) > 0 SET @ActualMachine = LEFT(@ActualMachine, CHARINDEX(N'.', @ActualMachine) - 1);

IF @ExpectedHost NOT IN (@ActualMachine, @ActualServer)
    THROW 51104, 'ExpectedServerName does not match this SQL Server host.', 1;

SELECT @CurrentClassifierId = classifier_function_id
FROM sys.resource_governor_configuration;

IF @CurrentClassifierId <> 0
   AND (@WorkshopClassifierId IS NULL OR @CurrentClassifierId <> @WorkshopClassifierId)
    THROW 51105, 'A non-workshop Resource Governor classifier is configured; it will not be replaced automatically.', 1;

IF DB_ID(N'WorkshopAdmin') IS NULL
BEGIN
    EXEC(N'CREATE DATABASE [WorkshopAdmin];');
    SET @UtilityDatabaseCreated = 1;
END;

IF @UtilityDatabaseCreated = 0
   AND NOT EXISTS
   (
       SELECT 1
       FROM WorkshopAdmin.sys.extended_properties
       WHERE class = 0
         AND name = N'MCP_SQL_WORKSHOP'
         AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
   )
    THROW 51107, 'Database WorkshopAdmin exists without the workshop ownership marker.', 1;

IF @UtilityDatabaseCreated = 1
BEGIN
    EXEC WorkshopAdmin.sys.sp_addextendedproperty
        @name = N'MCP_SQL_WORKSHOP',
        @value = @WorkshopMarker;
END;

IF EXISTS
(
    SELECT 1
    FROM master.sys.extended_properties
    WHERE class = 0
      AND name = N'MCP_SQL_WORKSHOP'
      AND TRY_CONVERT(uniqueidentifier, value) <> @WorkshopMarker
)
    THROW 51108, 'The master database contains a conflicting MCP_SQL_WORKSHOP marker.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM master.sys.extended_properties
    WHERE class = 0
      AND name = N'MCP_SQL_WORKSHOP'
      AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
)
BEGIN
    EXEC master.sys.sp_addextendedproperty
        @name = N'MCP_SQL_WORKSHOP',
        @value = @WorkshopMarker;
END;
GO

USE [WorkshopAdmin];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.ConfigurationBackup', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ConfigurationBackup
    (
        MarkerId uniqueidentifier NOT NULL,
        SchemaVersion int NOT NULL,
        CapturedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ConfigurationBackup_CapturedAtUtc DEFAULT SYSUTCDATETIME(),
        ShowAdvancedOptions int NOT NULL,
        MaxServerMemoryMB int NOT NULL,
        MinServerMemoryMB int NOT NULL,
        ResourceGovernorEnabled bit NOT NULL,
        ClassifierFunctionId int NOT NULL,
        ClassifierFunctionSchema sysname NULL,
        ClassifierFunctionName sysname NULL,
        CONSTRAINT PK_ConfigurationBackup PRIMARY KEY (MarkerId, SchemaVersion)
    );
END;

IF OBJECT_ID(N'dbo.DatabaseConfigurationBackup', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DatabaseConfigurationBackup
    (
        MarkerId uniqueidentifier NOT NULL,
        SchemaVersion int NOT NULL,
        DatabaseName sysname NOT NULL,
        CapturedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_DatabaseConfigurationBackup_CapturedAtUtc DEFAULT SYSUTCDATETIME(),
        QueryStoreActualStateDesc nvarchar(60) NULL,
        QueryStoreDesiredStateDesc nvarchar(60) NULL,
        QueryStoreMaxStorageSizeMB bigint NULL,
        QueryStoreCaptureModeDesc nvarchar(60) NULL,
        RowModeMemoryGrantFeedback nvarchar(60) NULL,
        BatchModeMemoryGrantFeedback nvarchar(60) NULL,
        MemoryGrantFeedbackPercentileGrant nvarchar(60) NULL,
        MemoryGrantFeedbackPersistence nvarchar(60) NULL,
        CONSTRAINT PK_DatabaseConfigurationBackup PRIMARY KEY (MarkerId, SchemaVersion, DatabaseName)
    );
END;

IF OBJECT_ID(N'dbo.ResourceGovernorObjectOwnership', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ResourceGovernorObjectOwnership
    (
        MarkerId uniqueidentifier NOT NULL,
        SchemaVersion int NOT NULL,
        ObjectType varchar(20) NOT NULL,
        ObjectName sysname NOT NULL,
        OwnershipState varchar(10) NOT NULL CONSTRAINT DF_ResourceGovernorObjectOwnership_State DEFAULT ('Active'),
        DefinitionHash varbinary(32) NULL,
        ClaimedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ResourceGovernorObjectOwnership_ClaimedAtUtc DEFAULT SYSUTCDATETIME(),
        UpdatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ResourceGovernorObjectOwnership_UpdatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ResourceGovernorObjectOwnership PRIMARY KEY (MarkerId, SchemaVersion, ObjectType, ObjectName)
    );
END;

IF COL_LENGTH(N'dbo.ResourceGovernorObjectOwnership', N'OwnershipState') IS NULL
    ALTER TABLE dbo.ResourceGovernorObjectOwnership ADD OwnershipState varchar(10) NOT NULL CONSTRAINT DF_ResourceGovernorObjectOwnership_State DEFAULT ('Active') WITH VALUES;
IF COL_LENGTH(N'dbo.ResourceGovernorObjectOwnership', N'DefinitionHash') IS NULL
    ALTER TABLE dbo.ResourceGovernorObjectOwnership ADD DefinitionHash varbinary(32) NULL;
IF COL_LENGTH(N'dbo.ResourceGovernorObjectOwnership', N'UpdatedAtUtc') IS NULL
    ALTER TABLE dbo.ResourceGovernorObjectOwnership ADD UpdatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ResourceGovernorObjectOwnership_UpdatedAtUtc DEFAULT SYSUTCDATETIME() WITH VALUES;
GO

USE [master];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @DatabaseName sysname = NULLIF(LTRIM(RTRIM(N'$(DatabaseName)')), N'');

BEGIN TRY
    BEGIN TRANSACTION;

    IF NOT EXISTS
    (
        SELECT 1
        FROM WorkshopAdmin.dbo.ConfigurationBackup WITH (UPDLOCK, HOLDLOCK)
        WHERE MarkerId = @WorkshopMarker
          AND SchemaVersion = @WorkshopSchemaVersion
    )
    BEGIN
        INSERT INTO WorkshopAdmin.dbo.ConfigurationBackup
        (
            MarkerId,
            SchemaVersion,
            ShowAdvancedOptions,
            MaxServerMemoryMB,
            MinServerMemoryMB,
            ResourceGovernorEnabled,
            ClassifierFunctionId,
            ClassifierFunctionSchema,
            ClassifierFunctionName
        )
        SELECT @WorkshopMarker,
               @WorkshopSchemaVersion,
               MAX(CASE WHEN c.name = N'show advanced options' THEN CONVERT(int, c.value_in_use) END),
               MAX(CASE WHEN c.name = N'max server memory (MB)' THEN CONVERT(int, c.value_in_use) END),
               MAX(CASE WHEN c.name = N'min server memory (MB)' THEN CONVERT(int, c.value_in_use) END),
               rg.is_enabled,
               rg.classifier_function_id,
               OBJECT_SCHEMA_NAME(NULLIF(rg.classifier_function_id, 0), DB_ID(N'master')),
               OBJECT_NAME(NULLIF(rg.classifier_function_id, 0), DB_ID(N'master'))
        FROM sys.configurations AS c
        CROSS JOIN sys.resource_governor_configuration AS rg
        WHERE c.name IN (N'show advanced options', N'max server memory (MB)', N'min server memory (MB)')
        GROUP BY rg.is_enabled, rg.classifier_function_id;
    END;

    IF DB_ID(@DatabaseName) IS NOT NULL
       AND NOT EXISTS
       (
           SELECT 1
           FROM WorkshopAdmin.dbo.DatabaseConfigurationBackup WITH (UPDLOCK, HOLDLOCK)
           WHERE MarkerId = @WorkshopMarker
             AND SchemaVersion = @WorkshopSchemaVersion
             AND DatabaseName = @DatabaseName
       )
    BEGIN
        DECLARE @CaptureDatabaseSql nvarchar(max) =
            N'USE ' + QUOTENAME(@DatabaseName) + N';
              INSERT INTO WorkshopAdmin.dbo.DatabaseConfigurationBackup
              (
                  MarkerId, SchemaVersion, DatabaseName,
                  QueryStoreActualStateDesc, QueryStoreDesiredStateDesc,
                  QueryStoreMaxStorageSizeMB, QueryStoreCaptureModeDesc,
                  RowModeMemoryGrantFeedback, BatchModeMemoryGrantFeedback,
                  MemoryGrantFeedbackPercentileGrant, MemoryGrantFeedbackPersistence
              )
              SELECT @MarkerId, @Version, DB_NAME(),
                     q.actual_state_desc, q.desired_state_desc,
                     q.max_storage_size_mb, q.query_capture_mode_desc,
                     MAX(CASE WHEN d.name = N''ROW_MODE_MEMORY_GRANT_FEEDBACK'' THEN CONVERT(nvarchar(60), d.value) END),
                     MAX(CASE WHEN d.name = N''BATCH_MODE_MEMORY_GRANT_FEEDBACK'' THEN CONVERT(nvarchar(60), d.value) END),
                     MAX(CASE WHEN d.name = N''MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT'' THEN CONVERT(nvarchar(60), d.value) END),
                     MAX(CASE WHEN d.name = N''MEMORY_GRANT_FEEDBACK_PERSISTENCE'' THEN CONVERT(nvarchar(60), d.value) END)
              FROM sys.database_query_store_options AS q
              CROSS JOIN sys.database_scoped_configurations AS d
              GROUP BY q.actual_state_desc, q.desired_state_desc,
                       q.max_storage_size_mb, q.query_capture_mode_desc;';

        EXEC sys.sp_executesql
            @CaptureDatabaseSql,
            N'@MarkerId uniqueidentifier, @Version int',
            @MarkerId = @WorkshopMarker,
            @Version = @WorkshopSchemaVersion;
    END;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

USE [master];
GO
SET NOCOUNT ON;

DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @ApplicationLockResult int;
DECLARE @DatabaseName sysname = NULLIF(LTRIM(RTRIM(N'$(DatabaseName)')), N'');
DECLARE @OriginalShowAdvancedOptions int;
DECLARE @OriginalMaxServerMemoryMB int;
DECLARE @OriginalMinServerMemoryMB int;
DECLARE @OriginalResourceGovernorEnabled bit;
DECLARE @OriginalClassifierId int;
DECLARE @OriginalClassifierSchema sysname;
DECLARE @OriginalClassifierName sysname;
DECLARE @OriginalRowModeMemoryGrantFeedback nvarchar(60);
DECLARE @OriginalBatchModeMemoryGrantFeedback nvarchar(60);
DECLARE @CreatedPool bit = 0;
DECLARE @CreatedGroup bit = 0;
DECLARE @CreatedClassifier bit = 0;
DECLARE @RestorationErrors nvarchar(max) = N'';
DECLARE @ClassifierCreateSql nvarchar(max) = N'CREATE FUNCTION dbo.mcp_sql_workshop_classifier()
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
DECLARE @ExpectedClassifierNormalized nvarchar(max) = UPPER(REPLACE(REPLACE(REPLACE(REPLACE(@ClassifierCreateSql, NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''), N' ', N''));
DECLARE @ExpectedClassifierHash varbinary(32) = HASHBYTES('SHA2_256', CONVERT(varbinary(max), @ExpectedClassifierNormalized));

EXEC @ApplicationLockResult = sys.sp_getapplock
    @Resource = N'MCP_SQL_WORKSHOP_RESOURCE_GOVERNOR_CONFIGURATION',
    @LockMode = N'Exclusive',
    @LockOwner = N'Session',
    @LockTimeout = 0;

IF @ApplicationLockResult < 0
    THROW 51114, 'Another session is configuring the workshop Resource Governor objects.', 1;

BEGIN TRY
SELECT @OriginalShowAdvancedOptions = MAX(CASE WHEN name = N'show advanced options' THEN CONVERT(int, value_in_use) END),
       @OriginalMaxServerMemoryMB = MAX(CASE WHEN name = N'max server memory (MB)' THEN CONVERT(int, value_in_use) END),
       @OriginalMinServerMemoryMB = MAX(CASE WHEN name = N'min server memory (MB)' THEN CONVERT(int, value_in_use) END)
FROM sys.configurations
WHERE name IN (N'show advanced options', N'max server memory (MB)', N'min server memory (MB)');

SELECT @OriginalResourceGovernorEnabled = is_enabled,
       @OriginalClassifierId = classifier_function_id,
       @OriginalClassifierSchema = OBJECT_SCHEMA_NAME(NULLIF(classifier_function_id, 0), DB_ID(N'master')),
       @OriginalClassifierName = OBJECT_NAME(NULLIF(classifier_function_id, 0), DB_ID(N'master'))
FROM sys.resource_governor_configuration;

IF DB_ID(@DatabaseName) IS NOT NULL
BEGIN
    DECLARE @CaptureCurrentFeedbackSql nvarchar(max) = N'USE ' + QUOTENAME(@DatabaseName) + N';
        SELECT @RowMode = MAX(CASE WHEN name = N''ROW_MODE_MEMORY_GRANT_FEEDBACK'' THEN CONVERT(nvarchar(60), value) END),
               @BatchMode = MAX(CASE WHEN name = N''BATCH_MODE_MEMORY_GRANT_FEEDBACK'' THEN CONVERT(nvarchar(60), value) END)
        FROM sys.database_scoped_configurations;';
    EXEC sys.sp_executesql @CaptureCurrentFeedbackSql,
        N'@RowMode nvarchar(60) OUTPUT, @BatchMode nvarchar(60) OUTPUT',
        @RowMode = @OriginalRowModeMemoryGrantFeedback OUTPUT,
        @BatchMode = @OriginalBatchModeMemoryGrantFeedback OUTPUT;
END;

DECLARE @LockedWorkshopClassifierId int = OBJECT_ID(N'dbo.mcp_sql_workshop_classifier', N'FN');
IF @LockedWorkshopClassifierId IS NOT NULL
BEGIN
        DECLARE @LockedDefinition nvarchar(max) = OBJECT_DEFINITION(@LockedWorkshopClassifierId);
        DECLARE @LockedNormalized nvarchar(max) = UPPER(REPLACE(REPLACE(REPLACE(REPLACE(@LockedDefinition, NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''), N' ', N''));
        DECLARE @LockedHash varbinary(32) = HASHBYTES('SHA2_256', CONVERT(varbinary(max), @LockedNormalized));
        DECLARE @LockedOwnershipState varchar(10);
        DECLARE @LockedStoredHash varbinary(32);
        DECLARE @LockedMarkerValid bit = 0;

        SELECT @LockedOwnershipState = OwnershipState, @LockedStoredHash = DefinitionHash
        FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
            AND ObjectType = 'CLASSIFIER' AND ObjectName = N'mcp_sql_workshop_classifier';

        IF EXISTS
        (
                SELECT 1 FROM sys.extended_properties
                WHERE class = 1 AND major_id = @LockedWorkshopClassifierId AND minor_id = 0
                    AND name = N'MCP_SQL_WORKSHOP'
                    AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
        )
                SET @LockedMarkerValid = 1;

        IF OBJECTPROPERTYEX(@LockedWorkshopClassifierId, N'IsSchemaBound') <> 1
             OR @LockedHash <> @ExpectedClassifierHash
             OR @LockedStoredHash <> @ExpectedClassifierHash
             OR @LockedOwnershipState NOT IN ('Pending', 'Active')
             OR (@LockedOwnershipState = 'Active' AND @LockedMarkerValid <> 1)
                THROW 51106, 'The existing workshop classifier name has an unexpected function definition or ownership.', 1;

        IF @LockedOwnershipState = 'Pending' AND @LockedMarkerValid = 0
                EXEC sys.sp_addextendedproperty
                        @name = N'MCP_SQL_WORKSHOP', @value = @WorkshopMarker,
                        @level0type = N'SCHEMA', @level0name = N'dbo',
                        @level1type = N'FUNCTION', @level1name = N'mcp_sql_workshop_classifier';

        UPDATE WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
        SET OwnershipState = 'Active', DefinitionHash = @ExpectedClassifierHash, UpdatedAtUtc = SYSUTCDATETIME()
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
            AND ObjectType = 'CLASSIFIER' AND ObjectName = N'mcp_sql_workshop_classifier';
END;

IF EXISTS
(
    SELECT 1
    FROM sys.resource_governor_resource_pools
    WHERE name = N'mcp_sql_workshop_pool'
)
AND NOT EXISTS
(
    SELECT 1
    FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
    WHERE MarkerId = @WorkshopMarker
      AND SchemaVersion = @WorkshopSchemaVersion
      AND ObjectType = 'POOL'
      AND ObjectName = N'mcp_sql_workshop_pool'
)
BEGIN
    THROW 51115, 'A Resource Governor pool with the workshop name exists without workshop ownership metadata.', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM sys.resource_governor_workload_groups
    WHERE name = N'mcp_sql_workshop_group'
)
AND NOT EXISTS
(
    SELECT 1
    FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
    WHERE MarkerId = @WorkshopMarker
      AND SchemaVersion = @WorkshopSchemaVersion
      AND ObjectType = 'GROUP'
      AND ObjectName = N'mcp_sql_workshop_group'
)
BEGIN
    THROW 51116, 'A Resource Governor workload group with the workshop name exists without workshop ownership metadata.', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership AS ownership
    INNER JOIN sys.resource_governor_resource_pools AS resource_pool
        ON resource_pool.name = ownership.ObjectName
    WHERE ownership.MarkerId = @WorkshopMarker
      AND ownership.SchemaVersion = @WorkshopSchemaVersion
      AND ownership.ObjectType = 'POOL'
      AND ownership.ObjectName = N'mcp_sql_workshop_pool'
      AND ownership.OwnershipState = 'Pending'
      AND (resource_pool.min_memory_percent <> 0 OR resource_pool.max_memory_percent <> 50)
)
    THROW 51117, 'Pending pool does not match the workshop contract; refusing to alter it.', 1;

IF EXISTS
(
    SELECT 1
    FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership AS ownership
    INNER JOIN sys.resource_governor_workload_groups AS workload_group
        ON workload_group.name = ownership.ObjectName
    INNER JOIN sys.resource_governor_resource_pools AS resource_pool
        ON resource_pool.pool_id = workload_group.pool_id
    WHERE ownership.MarkerId = @WorkshopMarker
      AND ownership.SchemaVersion = @WorkshopSchemaVersion
      AND ownership.ObjectType = 'GROUP'
      AND ownership.ObjectName = N'mcp_sql_workshop_group'
      AND ownership.OwnershipState = 'Pending'
      AND (workload_group.request_max_memory_grant_percent <> 40
           OR workload_group.max_dop <> 4
           OR workload_group.group_max_requests <> 4
           OR resource_pool.name <> N'mcp_sql_workshop_pool')
)
    THROW 51118, 'Pending workload group does not match the workshop contract; refusing to alter it.', 1;

EXEC sys.sp_configure N'show advanced options', 1;
RECONFIGURE;
EXEC sys.sp_configure N'max server memory (MB)', 49152;
RECONFIGURE;
EXEC sys.sp_configure N'min server memory (MB)', 0;
RECONFIGURE;

IF EXISTS
(
    SELECT 1
    FROM sys.configurations
    WHERE (name = N'max server memory (MB)' AND value_in_use <> 49152)
       OR (name = N'min server memory (MB)' AND value_in_use <> 0)
)
    THROW 51109, 'Effective max/min server memory values do not match the workshop contract.', 1;

IF DB_ID(N'$(DatabaseName)') IS NOT NULL
BEGIN
    DECLARE @DisableMemoryGrantFeedbackSql nvarchar(max) =
        N'USE ' + QUOTENAME(N'$(DatabaseName)') + N';
          ALTER DATABASE SCOPED CONFIGURATION SET ROW_MODE_MEMORY_GRANT_FEEDBACK = OFF;
          ALTER DATABASE SCOPED CONFIGURATION SET BATCH_MODE_MEMORY_GRANT_FEEDBACK = OFF;';
    EXEC sys.sp_executesql @DisableMemoryGrantFeedbackSql;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.resource_governor_resource_pools
    WHERE name = N'mcp_sql_workshop_pool'
)
BEGIN
    BEGIN TRANSACTION;
    IF NOT EXISTS
    (
        SELECT 1 FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership WITH (UPDLOCK, HOLDLOCK)
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
          AND ObjectType = 'POOL' AND ObjectName = N'mcp_sql_workshop_pool'
    )
        INSERT INTO WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
            (MarkerId, SchemaVersion, ObjectType, ObjectName, OwnershipState, DefinitionHash)
        VALUES
            (@WorkshopMarker, @WorkshopSchemaVersion, 'POOL', N'mcp_sql_workshop_pool', 'Pending', NULL);
    COMMIT TRANSACTION;

    CREATE RESOURCE POOL [mcp_sql_workshop_pool]
    WITH
    (
        MIN_MEMORY_PERCENT = 0,
        MAX_MEMORY_PERCENT = 50
    );
    SET @CreatedPool = 1;
END
ELSE IF EXISTS
(
    SELECT 1
    FROM sys.resource_governor_resource_pools
    WHERE name = N'mcp_sql_workshop_pool'
      AND (min_memory_percent <> 0 OR max_memory_percent <> 50)
)
BEGIN
    ALTER RESOURCE POOL [mcp_sql_workshop_pool]
    WITH
    (
        MIN_MEMORY_PERCENT = 0,
        MAX_MEMORY_PERCENT = 50
    );
END;

UPDATE WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
SET OwnershipState = 'Active', UpdatedAtUtc = SYSUTCDATETIME()
WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
    AND ObjectType = 'POOL' AND ObjectName = N'mcp_sql_workshop_pool';

IF NOT EXISTS
(
    SELECT 1
    FROM sys.resource_governor_workload_groups
    WHERE name = N'mcp_sql_workshop_group'
)
BEGIN
    BEGIN TRANSACTION;
    IF NOT EXISTS
    (
        SELECT 1 FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership WITH (UPDLOCK, HOLDLOCK)
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
          AND ObjectType = 'GROUP' AND ObjectName = N'mcp_sql_workshop_group'
    )
        INSERT INTO WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
            (MarkerId, SchemaVersion, ObjectType, ObjectName, OwnershipState, DefinitionHash)
        VALUES
            (@WorkshopMarker, @WorkshopSchemaVersion, 'GROUP', N'mcp_sql_workshop_group', 'Pending', NULL);
    COMMIT TRANSACTION;

    CREATE WORKLOAD GROUP [mcp_sql_workshop_group]
    WITH
    (
        REQUEST_MAX_MEMORY_GRANT_PERCENT = 40,
        MAX_DOP = 4,
        GROUP_MAX_REQUESTS = 4
    )
    USING [mcp_sql_workshop_pool];
    SET @CreatedGroup = 1;
END
ELSE IF EXISTS
(
    SELECT 1
    FROM sys.resource_governor_workload_groups AS workload_group
    INNER JOIN sys.resource_governor_resource_pools AS resource_pool
        ON resource_pool.pool_id = workload_group.pool_id
    WHERE workload_group.name = N'mcp_sql_workshop_group'
      AND
      (
          workload_group.request_max_memory_grant_percent <> 40
          OR workload_group.max_dop <> 4
          OR workload_group.group_max_requests <> 4
          OR resource_pool.name <> N'mcp_sql_workshop_pool'
      )
)
BEGIN
    ALTER WORKLOAD GROUP [mcp_sql_workshop_group]
    WITH
    (
        REQUEST_MAX_MEMORY_GRANT_PERCENT = 40,
        MAX_DOP = 4,
        GROUP_MAX_REQUESTS = 4
    )
    USING [mcp_sql_workshop_pool];
END;

UPDATE WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
SET OwnershipState = 'Active', UpdatedAtUtc = SYSUTCDATETIME()
WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
  AND ObjectType = 'GROUP' AND ObjectName = N'mcp_sql_workshop_group';

IF OBJECT_ID(N'dbo.mcp_sql_workshop_classifier', N'FN') IS NULL
BEGIN
    BEGIN TRANSACTION;
    IF NOT EXISTS
    (
        SELECT 1 FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership WITH (UPDLOCK, HOLDLOCK)
        WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
          AND ObjectType = 'CLASSIFIER' AND ObjectName = N'mcp_sql_workshop_classifier'
    )
        INSERT INTO WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
            (MarkerId, SchemaVersion, ObjectType, ObjectName, OwnershipState, DefinitionHash)
        VALUES
            (@WorkshopMarker, @WorkshopSchemaVersion, 'CLASSIFIER', N'mcp_sql_workshop_classifier', 'Pending', @ExpectedClassifierHash);
    COMMIT TRANSACTION;

    EXEC sys.sp_executesql @ClassifierCreateSql;
    SET @CreatedClassifier = 1;
    EXEC sys.sp_addextendedproperty
        @name = N'MCP_SQL_WORKSHOP', @value = @WorkshopMarker,
        @level0type = N'SCHEMA', @level0name = N'dbo',
        @level1type = N'FUNCTION', @level1name = N'mcp_sql_workshop_classifier';
END;

UPDATE WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
SET OwnershipState = 'Active', DefinitionHash = @ExpectedClassifierHash, UpdatedAtUtc = SYSUTCDATETIME()
WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion
    AND ObjectType = 'CLASSIFIER' AND ObjectName = N'mcp_sql_workshop_classifier';

DECLARE @CurrentClassifierId int;
DECLARE @WorkshopClassifierId int = OBJECT_ID(N'dbo.mcp_sql_workshop_classifier', N'FN');
SELECT @CurrentClassifierId = classifier_function_id
FROM sys.resource_governor_configuration;

IF @CurrentClassifierId <> 0 AND @CurrentClassifierId <> @WorkshopClassifierId
    THROW 51110, 'A non-workshop classifier appeared during configuration; no replacement was made.', 1;

IF @CurrentClassifierId = 0
BEGIN
    ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.mcp_sql_workshop_classifier);
END;
ALTER RESOURCE GOVERNOR RECONFIGURE;

DECLARE @EffectiveClassifierId int;
SELECT @EffectiveClassifierId = classifier_function_id
FROM sys.resource_governor_configuration
WHERE is_enabled = 1;

IF @EffectiveClassifierId <> OBJECT_ID(N'dbo.mcp_sql_workshop_classifier', N'FN')
    THROW 51111, 'Resource Governor is not enabled with the workshop classifier.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_resource_governor_resource_pools
    WHERE name = N'mcp_sql_workshop_pool'
      AND min_memory_percent = 0
      AND max_memory_percent = 50
)
    THROW 51112, 'Effective Resource Governor pool values do not match the workshop contract.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_resource_governor_workload_groups AS workload_group
    INNER JOIN sys.dm_resource_governor_resource_pools AS resource_pool
        ON resource_pool.pool_id = workload_group.pool_id
    WHERE workload_group.name = N'mcp_sql_workshop_group'
      AND resource_pool.name = N'mcp_sql_workshop_pool'
      AND workload_group.request_max_memory_grant_percent = 40
      AND workload_group.max_dop = 4
      AND workload_group.group_max_requests = 4
)
    THROW 51113, 'Effective Resource Governor workload group values do not match the workshop contract.', 1;

EXEC sys.sp_releaseapplock
    @Resource = N'MCP_SQL_WORKSHOP_RESOURCE_GOVERNOR_CONFIGURATION',
    @LockOwner = N'Session';
END TRY
BEGIN CATCH
    DECLARE @OriginalErrorNumber int = ERROR_NUMBER();
    DECLARE @OriginalErrorMessage nvarchar(2048) = ERROR_MESSAGE();
    DECLARE @OriginalErrorState tinyint = ERROR_STATE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

    BEGIN TRY
        IF @OriginalClassifierId = 0
            ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
        ELSE
        BEGIN
            DECLARE @RestoreClassifierSql nvarchar(max) = N'ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = '
                + QUOTENAME(@OriginalClassifierSchema) + N'.' + QUOTENAME(@OriginalClassifierName) + N');';
            EXEC sys.sp_executesql @RestoreClassifierSql;
        END;
        ALTER RESOURCE GOVERNOR RECONFIGURE;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += N' classifier: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        IF @CreatedGroup = 1
                     AND EXISTS
                     (
                             SELECT 1
                             FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership AS ownership
                             INNER JOIN sys.resource_governor_workload_groups AS workload_group ON workload_group.name = ownership.ObjectName
                             INNER JOIN sys.resource_governor_resource_pools AS resource_pool ON resource_pool.pool_id = workload_group.pool_id
                             WHERE ownership.MarkerId = @WorkshopMarker AND ownership.SchemaVersion = @WorkshopSchemaVersion
                                 AND ownership.ObjectType = 'GROUP' AND ownership.ObjectName = N'mcp_sql_workshop_group'
                                 AND ownership.OwnershipState IN ('Pending', 'Active')
                                 AND workload_group.request_max_memory_grant_percent = 40
                                 AND workload_group.max_dop = 4 AND workload_group.group_max_requests = 4
                                 AND resource_pool.name = N'mcp_sql_workshop_pool'
                     )
        BEGIN
            DROP WORKLOAD GROUP [mcp_sql_workshop_group];
            ALTER RESOURCE GOVERNOR RECONFIGURE;
            DELETE FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion AND ObjectType = 'GROUP' AND ObjectName = N'mcp_sql_workshop_group';
        END;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += N' group: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        IF @CreatedPool = 1
                     AND EXISTS
                     (
                             SELECT 1
                             FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership AS ownership
                             INNER JOIN sys.resource_governor_resource_pools AS resource_pool ON resource_pool.name = ownership.ObjectName
                             WHERE ownership.MarkerId = @WorkshopMarker AND ownership.SchemaVersion = @WorkshopSchemaVersion
                                 AND ownership.ObjectType = 'POOL' AND ownership.ObjectName = N'mcp_sql_workshop_pool'
                                 AND ownership.OwnershipState IN ('Pending', 'Active')
                                 AND resource_pool.min_memory_percent = 0 AND resource_pool.max_memory_percent = 50
                     )
        BEGIN
            DROP RESOURCE POOL [mcp_sql_workshop_pool];
            ALTER RESOURCE GOVERNOR RECONFIGURE;
            DELETE FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion AND ObjectType = 'POOL' AND ObjectName = N'mcp_sql_workshop_pool';
        END;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += N' pool: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        IF @CreatedClassifier = 1
           AND OBJECT_ID(N'dbo.mcp_sql_workshop_classifier', N'FN') IS NOT NULL
           AND HASHBYTES('SHA2_256', CONVERT(varbinary(max), UPPER(REPLACE(REPLACE(REPLACE(REPLACE(OBJECT_DEFINITION(OBJECT_ID(N'dbo.mcp_sql_workshop_classifier', N'FN')), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''), N' ', N'')))) = @ExpectedClassifierHash
           AND NOT EXISTS (SELECT 1 FROM sys.resource_governor_configuration WHERE classifier_function_id = OBJECT_ID(N'dbo.mcp_sql_workshop_classifier', N'FN'))
           AND EXISTS (SELECT 1 FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion AND ObjectType = 'CLASSIFIER' AND ObjectName = N'mcp_sql_workshop_classifier' AND OwnershipState IN ('Pending', 'Active') AND DefinitionHash = @ExpectedClassifierHash)
        BEGIN
            DROP FUNCTION dbo.mcp_sql_workshop_classifier;
            DELETE FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership WHERE MarkerId = @WorkshopMarker AND SchemaVersion = @WorkshopSchemaVersion AND ObjectType = 'CLASSIFIER' AND ObjectName = N'mcp_sql_workshop_classifier';
        END;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += N' classifier object: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        IF DB_ID(@DatabaseName) IS NOT NULL
           AND @OriginalRowModeMemoryGrantFeedback IN (N'ON', N'OFF')
           AND @OriginalBatchModeMemoryGrantFeedback IN (N'ON', N'OFF')
        BEGIN
            DECLARE @RestoreFeedbackSql nvarchar(max) = N'USE ' + QUOTENAME(@DatabaseName)
                + N'; ALTER DATABASE SCOPED CONFIGURATION SET ROW_MODE_MEMORY_GRANT_FEEDBACK = ' + @OriginalRowModeMemoryGrantFeedback
                + N'; ALTER DATABASE SCOPED CONFIGURATION SET BATCH_MODE_MEMORY_GRANT_FEEDBACK = ' + @OriginalBatchModeMemoryGrantFeedback + N';';
            EXEC sys.sp_executesql @RestoreFeedbackSql;
        END;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += N' memory grant feedback: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        EXEC sys.sp_configure N'show advanced options', 1;
        RECONFIGURE;
        EXEC sys.sp_configure N'max server memory (MB)', @OriginalMaxServerMemoryMB;
        RECONFIGURE;
        EXEC sys.sp_configure N'min server memory (MB)', @OriginalMinServerMemoryMB;
        RECONFIGURE;
        EXEC sys.sp_configure N'show advanced options', @OriginalShowAdvancedOptions;
        RECONFIGURE;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += N' server memory: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        IF @OriginalResourceGovernorEnabled = 0
            ALTER RESOURCE GOVERNOR DISABLE;
        ELSE
            ALTER RESOURCE GOVERNOR RECONFIGURE;
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += N' Resource Governor state: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        EXEC sys.sp_releaseapplock
            @Resource = N'MCP_SQL_WORKSHOP_RESOURCE_GOVERNOR_CONFIGURATION',
            @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        SET @RestorationErrors += N' application lock: ' + ERROR_MESSAGE();
    END CATCH;

    IF @RestorationErrors <> N''
        PRINT N'Restoration warnings (original error preserved):' + @RestorationErrors;
    THROW @OriginalErrorNumber, @OriginalErrorMessage, @OriginalErrorState;
END CATCH;

SELECT N'ConfigurationApplied' AS ConfigurationStatus,
       memory_max.value_in_use AS MaxServerMemoryMB,
       memory_min.value_in_use AS MinServerMemoryMB,
       resource_pool.min_memory_percent AS MinMemoryPercent,
       resource_pool.max_memory_percent AS MaxMemoryPercent,
       workload_group.request_max_memory_grant_percent AS RequestMaxMemoryGrantPercent,
       workload_group.max_dop AS MaxDop,
       workload_group.group_max_requests AS GroupMaxRequests
FROM sys.configurations AS memory_max
CROSS JOIN sys.configurations AS memory_min
INNER JOIN sys.dm_resource_governor_resource_pools AS resource_pool
    ON resource_pool.name = N'mcp_sql_workshop_pool'
INNER JOIN sys.dm_resource_governor_workload_groups AS workload_group
    ON workload_group.pool_id = resource_pool.pool_id
   AND workload_group.name = N'mcp_sql_workshop_group'
WHERE memory_max.name = N'max server memory (MB)'
  AND memory_min.name = N'min server memory (MB)';
GO
