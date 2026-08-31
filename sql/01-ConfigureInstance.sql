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

IF @WorkshopClassifierId IS NOT NULL
BEGIN
    SELECT @ExistingDefinition = OBJECT_DEFINITION(@WorkshopClassifierId);
    IF OBJECTPROPERTYEX(@WorkshopClassifierId, N'IsSchemaBound') <> 1
       OR @ExistingDefinition NOT LIKE N'%APP_NAME()%LIKE N''MCP-SQL-Workshop%''%'
       OR @ExistingDefinition NOT LIKE N'%MCP_SQL_WORKSHOP_GROUP%'
        THROW 51106, 'The existing workshop classifier name is owned by an unexpected function definition.', 1;
END;

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
        ClaimedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ResourceGovernorObjectOwnership_ClaimedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ResourceGovernorObjectOwnership PRIMARY KEY (MarkerId, SchemaVersion, ObjectType, ObjectName)
    );
END;
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

EXEC @ApplicationLockResult = sys.sp_getapplock
    @Resource = N'MCP_SQL_WORKSHOP_RESOURCE_GOVERNOR_CONFIGURATION',
    @LockMode = N'Exclusive',
    @LockOwner = N'Session',
    @LockTimeout = 0;

IF @ApplicationLockResult < 0
    THROW 51114, 'Another session is configuring the workshop Resource Governor objects.', 1;

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
    EXEC sys.sp_releaseapplock
        @Resource = N'MCP_SQL_WORKSHOP_RESOURCE_GOVERNOR_CONFIGURATION',
        @LockOwner = N'Session';
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
    EXEC sys.sp_releaseapplock
        @Resource = N'MCP_SQL_WORKSHOP_RESOURCE_GOVERNOR_CONFIGURATION',
        @LockOwner = N'Session';
    THROW 51116, 'A Resource Governor workload group with the workshop name exists without workshop ownership metadata.', 1;
END;
GO

USE [master];
GO
SET NOCOUNT ON;

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
GO

USE [master];
GO
SET NOCOUNT ON;

IF DB_ID(N'$(DatabaseName)') IS NOT NULL
BEGIN
    DECLARE @DisableMemoryGrantFeedbackSql nvarchar(max) =
        N'USE ' + QUOTENAME(N'$(DatabaseName)') + N';
          ALTER DATABASE SCOPED CONFIGURATION SET ROW_MODE_MEMORY_GRANT_FEEDBACK = OFF;
          ALTER DATABASE SCOPED CONFIGURATION SET BATCH_MODE_MEMORY_GRANT_FEEDBACK = OFF;';
    EXEC sys.sp_executesql @DisableMemoryGrantFeedbackSql;
END;
GO

USE [master];
GO
SET NOCOUNT ON;

DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.resource_governor_resource_pools
    WHERE name = N'mcp_sql_workshop_pool'
)
BEGIN
    CREATE RESOURCE POOL [mcp_sql_workshop_pool]
    WITH
    (
        MIN_MEMORY_PERCENT = 0,
        MAX_MEMORY_PERCENT = 50
    );

    IF NOT EXISTS
    (
        SELECT 1
        FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
        WHERE MarkerId = @WorkshopMarker
          AND SchemaVersion = @WorkshopSchemaVersion
          AND ObjectType = 'POOL'
          AND ObjectName = N'mcp_sql_workshop_pool'
    )
    BEGIN
        INSERT INTO WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
            (MarkerId, SchemaVersion, ObjectType, ObjectName)
        VALUES
            (@WorkshopMarker, @WorkshopSchemaVersion, 'POOL', N'mcp_sql_workshop_pool');
    END;
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
GO

USE [master];
GO
SET NOCOUNT ON;

DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.resource_governor_workload_groups
    WHERE name = N'mcp_sql_workshop_group'
)
BEGIN
    CREATE WORKLOAD GROUP [mcp_sql_workshop_group]
    WITH
    (
        REQUEST_MAX_MEMORY_GRANT_PERCENT = 40,
        MAX_DOP = 4,
        GROUP_MAX_REQUESTS = 4
    )
    USING [mcp_sql_workshop_pool];

    IF NOT EXISTS
    (
        SELECT 1
        FROM WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
        WHERE MarkerId = @WorkshopMarker
          AND SchemaVersion = @WorkshopSchemaVersion
          AND ObjectType = 'GROUP'
          AND ObjectName = N'mcp_sql_workshop_group'
    )
    BEGIN
        INSERT INTO WorkshopAdmin.dbo.ResourceGovernorObjectOwnership
            (MarkerId, SchemaVersion, ObjectType, ObjectName)
        VALUES
            (@WorkshopMarker, @WorkshopSchemaVersion, 'GROUP', N'mcp_sql_workshop_group');
    END;
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

EXEC sys.sp_releaseapplock
    @Resource = N'MCP_SQL_WORKSHOP_RESOURCE_GOVERNOR_CONFIGURATION',
    @LockOwner = N'Session';
GO

USE [master];
GO
IF OBJECT_ID(N'dbo.mcp_sql_workshop_classifier', N'FN') IS NULL
BEGIN
    EXEC sys.sp_executesql N'
CREATE FUNCTION dbo.mcp_sql_workshop_classifier()
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
END;
GO

USE [master];
GO
SET NOCOUNT ON;

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
GO

USE [master];
GO
ALTER RESOURCE GOVERNOR RECONFIGURE;
GO

USE [master];
GO
SET NOCOUNT ON;

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
