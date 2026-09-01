:on error exit
/*
The bootstrap must validate caller input, open one connection, and set these values with
parameterized SqlCommand calls to sys.sp_set_session_context before executing this file:
ExpectedServerName, DatabaseName, ExpectedPhysicalMemoryMB, PreflightPhase, and optionally
PlannedRestorePath, PlannedDataPath, MinimumFreeSpaceMB. SQLCMD variables must not be
substituted into this SQL text because substitution occurs before T-SQL validation.

Infrastructure validates the instance before a restore. Lab additionally requires the
restored database and both workshop ownership markers. This script is read-only.

Microsoft Learn — server memory configuration:
https://learn.microsoft.com/sql/database-engine/configure-windows/server-memory-server-configuration-options
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExpectedServerName nvarchar(256) = NULLIF(LOWER(LTRIM(RTRIM(TRY_CONVERT(nvarchar(256), SESSION_CONTEXT(N'ExpectedServerName'))))), N'');
DECLARE @DatabaseName sysname = NULLIF(LTRIM(RTRIM(TRY_CONVERT(sysname, SESSION_CONTEXT(N'DatabaseName')))), N'');
DECLARE @ExpectedPhysicalMemoryValue sql_variant = SESSION_CONTEXT(N'ExpectedPhysicalMemoryMB');
DECLARE @ExpectedPhysicalMemoryMB bigint = TRY_CONVERT(bigint, @ExpectedPhysicalMemoryValue);
DECLARE @PreflightPhase nvarchar(32) = UPPER(LTRIM(RTRIM(TRY_CONVERT(nvarchar(32), SESSION_CONTEXT(N'PreflightPhase')))));
DECLARE @PlannedRestorePath nvarchar(4000) = NULLIF(LTRIM(RTRIM(TRY_CONVERT(nvarchar(4000), SESSION_CONTEXT(N'PlannedRestorePath')))), N'');
DECLARE @PlannedDataPath nvarchar(4000) = NULLIF(LTRIM(RTRIM(TRY_CONVERT(nvarchar(4000), SESSION_CONTEXT(N'PlannedDataPath')))), N'');
DECLARE @MinimumFreeSpaceValue sql_variant = SESSION_CONTEXT(N'MinimumFreeSpaceMB');
DECLARE @MinimumFreeSpaceMB bigint = COALESCE(TRY_CONVERT(bigint, @MinimumFreeSpaceValue), 0);
DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupHash varbinary(32) = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B;
DECLARE @ServerMarkerId uniqueidentifier = NULL;
DECLARE @DatabaseMarkerId uniqueidentifier = NULL;
DECLARE @DatabaseSchemaVersion int = NULL;
DECLARE @DatabaseSetupName sysname = NULL;
DECLARE @DatabaseSetupHash varbinary(32) = NULL;

IF @PreflightPhase IS NULL OR @PreflightPhase NOT IN (N'INFRASTRUCTURE', N'LAB')
    THROW 51000, 'PreflightPhase must be Infrastructure or Lab.', 1;

IF @ExpectedServerName IS NULL
    THROW 51001, 'ExpectedServerName is required.', 1;

IF @DatabaseName IS NULL
    THROW 51002, 'DatabaseName is required.', 1;

IF @ExpectedPhysicalMemoryMB IS NULL OR @ExpectedPhysicalMemoryMB NOT BETWEEN 63000 AND 66000
    THROW 51003, 'ExpectedPhysicalMemoryMB must be between 63000 and 66000 MB.', 1;

IF (@MinimumFreeSpaceValue IS NOT NULL AND TRY_CONVERT(bigint, @MinimumFreeSpaceValue) IS NULL)
    OR @MinimumFreeSpaceMB < 0
    THROW 51004, 'MinimumFreeSpaceMB must be zero or greater.', 1;

DECLARE @ProductMajorVersion int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
IF @ProductMajorVersion <> 16
    THROW 51005, 'SQL Server major version 16 (SQL Server 2022) is required.', 1;

DECLARE @Edition nvarchar(256) = CONVERT(nvarchar(256), SERVERPROPERTY('Edition'));
IF @Edition NOT LIKE N'%Enterprise%'
    THROW 51006, 'SQL Server Enterprise edition is required.', 1;

DECLARE @PhysicalMemoryMB bigint;
SELECT @PhysicalMemoryMB = physical_memory_kb / 1024
FROM sys.dm_os_sys_info;

IF @PhysicalMemoryMB NOT BETWEEN 63000 AND 66000
    THROW 51007, 'Host physical memory must be between 63000 and 66000 MB.', 1;

IF ABS(@PhysicalMemoryMB - @ExpectedPhysicalMemoryMB) > 1024
    THROW 51008, 'Measured physical memory differs from ExpectedPhysicalMemoryMB by more than 1024 MB.', 1;

DECLARE @MachineName nvarchar(256) = LOWER(LTRIM(RTRIM(CONVERT(nvarchar(256), SERVERPROPERTY('MachineName')))));
DECLARE @ServerName nvarchar(256) = LOWER(LTRIM(RTRIM(CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')))));
DECLARE @ExpectedHost nvarchar(256) = @ExpectedServerName;
DECLARE @MachineHost nvarchar(256) = @MachineName;
DECLARE @ServerHost nvarchar(256) = @ServerName;

IF CHARINDEX(N'\', @ExpectedHost) > 0 SET @ExpectedHost = LEFT(@ExpectedHost, CHARINDEX(N'\', @ExpectedHost) - 1);
IF CHARINDEX(N'.', @ExpectedHost) > 0 SET @ExpectedHost = LEFT(@ExpectedHost, CHARINDEX(N'.', @ExpectedHost) - 1);
IF CHARINDEX(N'\', @MachineHost) > 0 SET @MachineHost = LEFT(@MachineHost, CHARINDEX(N'\', @MachineHost) - 1);
IF CHARINDEX(N'.', @MachineHost) > 0 SET @MachineHost = LEFT(@MachineHost, CHARINDEX(N'.', @MachineHost) - 1);
IF CHARINDEX(N'\', @ServerHost) > 0 SET @ServerHost = LEFT(@ServerHost, CHARINDEX(N'\', @ServerHost) - 1);
IF CHARINDEX(N'.', @ServerHost) > 0 SET @ServerHost = LEFT(@ServerHost, CHARINDEX(N'.', @ServerHost) - 1);

IF @ExpectedServerName NOT IN (@MachineName, @ServerName)
   AND @ExpectedHost NOT IN (@MachineHost, @ServerHost)
    THROW 51009, 'ExpectedServerName does not match the normalized SQL machine or server name.', 1;

DECLARE @FreeSpace table
(
    drive char(1) NOT NULL PRIMARY KEY,
    free_mb bigint NOT NULL
);

IF @PlannedRestorePath IS NOT NULL OR @PlannedDataPath IS NOT NULL
BEGIN
    IF (@PlannedRestorePath IS NOT NULL
        AND (LEN(@PlannedRestorePath) < 3
             OR SUBSTRING(@PlannedRestorePath, 2, 1) <> N':'
             OR SUBSTRING(@PlannedRestorePath, 3, 1) NOT IN (N'\', N'/')))
       OR (@PlannedDataPath IS NOT NULL
           AND (LEN(@PlannedDataPath) < 3
                OR SUBSTRING(@PlannedDataPath, 2, 1) <> N':'
                OR SUBSTRING(@PlannedDataPath, 3, 1) NOT IN (N'\', N'/')))
        THROW 51010, 'Planned restore and data paths must be absolute drive-letter paths.', 1;

    INSERT @FreeSpace (drive, free_mb)
    EXEC master.dbo.xp_fixeddrives;

    DECLARE @RestoreDrive char(1) = UPPER(LEFT(@PlannedRestorePath, 1));
    DECLARE @DataDrive char(1) = UPPER(LEFT(@PlannedDataPath, 1));

    IF @PlannedRestorePath IS NOT NULL
       AND NOT EXISTS
       (
           SELECT 1 FROM @FreeSpace
           WHERE drive = @RestoreDrive AND free_mb >= @MinimumFreeSpaceMB
       )
        THROW 51011, 'Planned restore path drive does not meet MinimumFreeSpaceMB.', 1;

    IF @PlannedDataPath IS NOT NULL
       AND NOT EXISTS
       (
           SELECT 1 FROM @FreeSpace
           WHERE drive = @DataDrive AND free_mb >= @MinimumFreeSpaceMB
       )
        THROW 51012, 'Planned data path drive does not meet MinimumFreeSpaceMB.', 1;
END;

IF @PreflightPhase = N'LAB'
BEGIN
    IF DB_ID(@DatabaseName) IS NULL
        THROW 51013, 'Lab preflight requires the target database to exist.', 1;

        SELECT @ServerMarkerId = TRY_CONVERT(uniqueidentifier, value)
        FROM master.sys.extended_properties
        WHERE class = 0 AND name = N'MCP_SQL_WORKSHOP';

        IF @ServerMarkerId <> @WorkshopMarker
        THROW 51014, 'The SQL instance workshop marker is absent or invalid.', 1;

    DECLARE @MarkerSql nvarchar(max) =
        N'USE ' + QUOTENAME(@DatabaseName) + N';
          IF OBJECT_ID(N''lab.WorkshopMarker'', N''U'') IS NOT NULL
                      SELECT
                            @DatabaseMarkerId = MarkerId,
                            @DatabaseSchemaVersion = SchemaVersion,
                            @DatabaseSetupName = SetupName,
                            @DatabaseSetupHash = SetupHash
                    FROM lab.WorkshopMarker
                    ORDER BY MarkerId, SchemaVersion, SetupName, SetupHash;';

    EXEC sys.sp_executesql
        @MarkerSql,
                N'@DatabaseMarkerId uniqueidentifier OUTPUT, @DatabaseSchemaVersion int OUTPUT,
                    @DatabaseSetupName sysname OUTPUT, @DatabaseSetupHash varbinary(32) OUTPUT',
                @DatabaseMarkerId = @DatabaseMarkerId OUTPUT,
                @DatabaseSchemaVersion = @DatabaseSchemaVersion OUTPUT,
                @DatabaseSetupName = @DatabaseSetupName OUTPUT,
                @DatabaseSetupHash = @DatabaseSetupHash OUTPUT;

        IF @DatabaseMarkerId <> @WorkshopMarker
             OR @DatabaseSchemaVersion <> @WorkshopSchemaVersion
             OR @DatabaseSetupName <> @WorkshopSetupName
             OR @DatabaseSetupHash <> @WorkshopSetupHash
        THROW 51015, 'The target database workshop marker is absent or invalid.', 1;
END;

IF @PreflightPhase = N'INFRASTRUCTURE'
BEGIN
    -- Database and marker checks are intentionally deferred until Lab phase.
    SET @DatabaseName = @DatabaseName;
END;

SELECT N'PreflightPassed' AS PreflightStatus,
       @PreflightPhase AS PreflightPhase,
       @MachineName AS MachineName,
       @ServerName AS ServerName,
       @ProductMajorVersion AS ProductMajorVersion,
       @Edition AS Edition,
       @PhysicalMemoryMB AS PhysicalMemoryMB,
    @DatabaseName AS DatabaseName,
    @DatabaseMarkerId AS MarkerId,
    @DatabaseSchemaVersion AS SchemaVersion,
    @DatabaseSetupName AS SetupName,
    LOWER(CONVERT(varchar(64), @DatabaseSetupHash, 2)) AS SetupHash,
    @ServerMarkerId AS ServerMarkerId;
GO
