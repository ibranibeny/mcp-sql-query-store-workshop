:on error exit
/*
Run with sqlcmd mode enabled. Example:
  sqlcmd -S <server> -E -b -i sql/00-Preflight.sql -v ExpectedServerName="sql01" DatabaseName="AdventureWorks2022" ExpectedPhysicalMemoryMB="65536" PreflightPhase="Infrastructure" PlannedRestorePath="" PlannedDataPath="" MinimumFreeSpaceMB="0"

Infrastructure validates the instance before a restore. Lab additionally requires the
restored database and both workshop ownership markers. This script is read-only.

Microsoft Learn — server memory configuration:
https://learn.microsoft.com/sql/database-engine/configure-windows/server-memory-server-configuration-options
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExpectedServerName nvarchar(256) = NULLIF(LOWER(LTRIM(RTRIM(N'$(ExpectedServerName)'))), N'');
DECLARE @DatabaseName sysname = NULLIF(LTRIM(RTRIM(N'$(DatabaseName)')), N'');
DECLARE @ExpectedPhysicalMemoryMB bigint = TRY_CONVERT(bigint, N'$(ExpectedPhysicalMemoryMB)');
DECLARE @PreflightPhase nvarchar(32) = UPPER(LTRIM(RTRIM(N'$(PreflightPhase)')));
DECLARE @PlannedRestorePath nvarchar(4000) = NULLIF(LTRIM(RTRIM(N'$(PlannedRestorePath)')), N'');
DECLARE @PlannedDataPath nvarchar(4000) = NULLIF(LTRIM(RTRIM(N'$(PlannedDataPath)')), N'');
DECLARE @MinimumFreeSpaceMB bigint = TRY_CONVERT(bigint, N'$(MinimumFreeSpaceMB)');
DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;

IF @PreflightPhase NOT IN (N'INFRASTRUCTURE', N'LAB')
    THROW 51000, 'PreflightPhase must be Infrastructure or Lab.', 1;

IF @ExpectedServerName IS NULL
    THROW 51001, 'ExpectedServerName is required.', 1;

IF @DatabaseName IS NULL
    THROW 51002, 'DatabaseName is required.', 1;

IF @ExpectedPhysicalMemoryMB IS NULL OR @ExpectedPhysicalMemoryMB NOT BETWEEN 63000 AND 66000
    THROW 51003, 'ExpectedPhysicalMemoryMB must be between 63000 and 66000 MB.', 1;

IF @MinimumFreeSpaceMB IS NULL OR @MinimumFreeSpaceMB < 0
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

    IF NOT EXISTS
    (
        SELECT 1
        FROM master.sys.extended_properties
        WHERE class = 0
          AND name = N'MCP_SQL_WORKSHOP'
          AND TRY_CONVERT(uniqueidentifier, value) = @WorkshopMarker
    )
        THROW 51014, 'The SQL instance workshop marker is absent or invalid.', 1;

    DECLARE @DatabaseMarkerValid bit = 0;
    DECLARE @MarkerSql nvarchar(max) =
        N'USE ' + QUOTENAME(@DatabaseName) + N';
          IF OBJECT_ID(N''lab.WorkshopMarker'', N''U'') IS NOT NULL
             AND EXISTS
             (
                 SELECT 1
                 FROM lab.WorkshopMarker
                 WHERE MarkerId = @MarkerId
                   AND SchemaVersion = @SchemaVersion
             )
              SET @Valid = 1;';

    EXEC sys.sp_executesql
        @MarkerSql,
        N'@MarkerId uniqueidentifier, @SchemaVersion int, @Valid bit OUTPUT',
        @MarkerId = @WorkshopMarker,
        @SchemaVersion = @WorkshopSchemaVersion,
        @Valid = @DatabaseMarkerValid OUTPUT;

    IF @DatabaseMarkerValid <> 1
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
       @DatabaseName AS DatabaseName;
GO
