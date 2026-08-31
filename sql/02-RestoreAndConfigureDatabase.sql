:on error exit
/*
Run from master. The bootstrap sets BackupPath, DataPath, LogPath, and DatabaseName
on this same connection using parameterized sys.sp_set_session_context calls. Never
substitute caller-controlled SQLCMD variables into this script.
*/
USE [master];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @BackupPath nvarchar(4000) = NULLIF(LTRIM(RTRIM(TRY_CONVERT(nvarchar(4000), SESSION_CONTEXT(N'BackupPath')))), N'');
DECLARE @DataPath nvarchar(4000) = NULLIF(LTRIM(RTRIM(TRY_CONVERT(nvarchar(4000), SESSION_CONTEXT(N'DataPath')))), N'');
DECLARE @LogPath nvarchar(4000) = NULLIF(LTRIM(RTRIM(TRY_CONVERT(nvarchar(4000), SESSION_CONTEXT(N'LogPath')))), N'');
DECLARE @DatabaseName sysname = NULLIF(LTRIM(RTRIM(TRY_CONVERT(sysname, SESSION_CONTEXT(N'DatabaseName')))), N'');
DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupContract nvarchar(200) = N'lab.WorkshopMarker|1|MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupHash varbinary(32) = HASHBYTES('SHA2_256', CONVERT(varbinary(max), @WorkshopSetupContract));
DECLARE @FreshRestore bit = 0;
DECLARE @ConfigureSql nvarchar(max) = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET QUERY_STORE = ON;
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET QUERY_STORE
(
    OPERATION_MODE = READ_WRITE,
    MAX_STORAGE_SIZE_MB = 2048,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 7),
    DATA_FLUSH_INTERVAL_SECONDS = 60,
    INTERVAL_LENGTH_MINUTES = 5,
    QUERY_CAPTURE_MODE = AUTO,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    WAIT_STATS_CAPTURE_MODE = ON
);';

IF @BackupPath IS NULL THROW 51200, 'BackupPath is required.', 1;
IF @DataPath IS NULL THROW 51201, 'DataPath is required.', 1;
IF @LogPath IS NULL THROW 51202, 'LogPath is required.', 1;
IF @DatabaseName IS NULL THROW 51203, 'DatabaseName is required.', 1;
IF @DatabaseName <> N'AdventureWorks2022'
    THROW 51204, 'DatabaseName must be exactly AdventureWorks2022.', 1;
IF @WorkshopSetupHash <> 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B
    THROW 51214, 'The workshop marker contract hash is invalid.', 1;

/* Permit only normalized local drive paths. UNC/device paths, traversal, wildcards,
   control characters, comments, and statement delimiters are rejected. Apostrophes
   are supported and escaped as SQL string-literal data after validation. */
IF LEN(@BackupPath) > 260 OR LEFT(@BackupPath, 1) COLLATE Latin1_General_100_BIN2 NOT LIKE N'[A-Za-z]'
   OR SUBSTRING(@BackupPath, 2, 2) <> N':\'
   OR RIGHT(LOWER(@BackupPath), 4) <> N'.bak'
   OR @BackupPath LIKE N'%..%' OR @BackupPath LIKE N'%[%]%' OR @BackupPath LIKE N'%[_]%'
   OR @BackupPath LIKE N'%[[]%' OR @BackupPath LIKE N'%]%' OR @BackupPath LIKE N'%*%' OR @BackupPath LIKE N'%?%'
   OR @BackupPath LIKE N'%;%' OR @BackupPath LIKE N'%--%'
   OR @BackupPath LIKE N'%/*%' OR @BackupPath LIKE N'%*/%' OR @BackupPath LIKE N'\\%'
   OR CHARINDEX(NCHAR(0), @BackupPath) > 0 OR PATINDEX(N'%[' + NCHAR(1) + N'-' + NCHAR(31) + N']%', @BackupPath) > 0
    THROW 51205, 'BackupPath must be a safe local Windows .bak path.', 1;

IF LEN(@DataPath) > 260 OR LEFT(@DataPath, 1) COLLATE Latin1_General_100_BIN2 NOT LIKE N'[A-Za-z]'
    OR SUBSTRING(@DataPath, 2, 2) <> N':\'
   OR RIGHT(LOWER(@DataPath), 4) <> N'.mdf'
    OR @DataPath LIKE N'%..%' OR @DataPath LIKE N'%[%]%' OR @DataPath LIKE N'%[_]%'
    OR @DataPath LIKE N'%[[]%' OR @DataPath LIKE N'%]%' OR @DataPath LIKE N'%*%' OR @DataPath LIKE N'%?%'
    OR @DataPath LIKE N'%;%' OR @DataPath LIKE N'%--%'
   OR @DataPath LIKE N'%/*%' OR @DataPath LIKE N'%*/%' OR @DataPath LIKE N'\\%'
   OR CHARINDEX(NCHAR(0), @DataPath) > 0 OR PATINDEX(N'%[' + NCHAR(1) + N'-' + NCHAR(31) + N']%', @DataPath) > 0
    THROW 51206, 'DataPath must be a safe local Windows .mdf path.', 1;

IF LEN(@LogPath) > 260 OR LEFT(@LogPath, 1) COLLATE Latin1_General_100_BIN2 NOT LIKE N'[A-Za-z]'
    OR SUBSTRING(@LogPath, 2, 2) <> N':\'
   OR RIGHT(LOWER(@LogPath), 4) <> N'.ldf'
    OR @LogPath LIKE N'%..%' OR @LogPath LIKE N'%[%]%' OR @LogPath LIKE N'%[_]%'
    OR @LogPath LIKE N'%[[]%' OR @LogPath LIKE N'%]%' OR @LogPath LIKE N'%*%' OR @LogPath LIKE N'%?%'
    OR @LogPath LIKE N'%;%' OR @LogPath LIKE N'%--%'
   OR @LogPath LIKE N'%/*%' OR @LogPath LIKE N'%*/%' OR @LogPath LIKE N'\\%'
   OR CHARINDEX(NCHAR(0), @LogPath) > 0 OR PATINDEX(N'%[' + NCHAR(1) + N'-' + NCHAR(31) + N']%', @LogPath) > 0
    THROW 51207, 'LogPath must be a safe local Windows .ldf path.', 1;

/* Existing databases are never adopted: exact workshop ownership must pre-exist. */
IF DB_ID(@DatabaseName) IS NOT NULL
BEGIN
    DECLARE @ExistingMarkerValid bit = 0;
    DECLARE @ExistingMarkerSql nvarchar(max) = N'USE ' + QUOTENAME(@DatabaseName) + N';
        IF SCHEMA_ID(N''lab'') IS NOT NULL
           AND OBJECT_ID(N''lab.WorkshopMarker'', N''U'') IS NOT NULL
           AND EXISTS
           (
               SELECT 1 FROM lab.WorkshopMarker
               WHERE MarkerId = @MarkerId AND SchemaVersion = @SchemaVersion
               AND SetupName = @SetupName AND SetupHash = @SetupHash
           ) SET @Valid = 1;';
    EXEC sys.sp_executesql @ExistingMarkerSql,
         N'@MarkerId uniqueidentifier, @SchemaVersion int, @SetupName sysname, @SetupHash varbinary(32), @Valid bit OUTPUT',
        @MarkerId = @WorkshopMarker, @SchemaVersion = @WorkshopSchemaVersion,
         @SetupName = @WorkshopSetupName, @SetupHash = @WorkshopSetupHash,
        @Valid = @ExistingMarkerValid OUTPUT;
    IF @ExistingMarkerValid <> 1
        THROW 51208, 'Existing AdventureWorks2022 lacks the exact workshop marker; refusing to overwrite or adopt it.', 1;
END;

IF DB_ID(@DatabaseName) IS NULL
BEGIN
    DECLARE @FileList table
    (
        LogicalName nvarchar(128), PhysicalName nvarchar(260), [Type] char(1), FileGroupName nvarchar(128) NULL,
        Size numeric(20,0), MaxSize numeric(20,0), FileId bigint, CreateLSN numeric(25,0), DropLSN numeric(25,0) NULL,
        UniqueId uniqueidentifier, ReadOnlyLSN numeric(25,0) NULL, ReadWriteLSN numeric(25,0) NULL,
        BackupSizeInBytes bigint, SourceBlockSize int, FileGroupId int, LogGroupGUID uniqueidentifier NULL,
        DifferentialBaseLSN numeric(25,0) NULL, DifferentialBaseGUID uniqueidentifier NULL,
        IsReadOnly bit, IsPresent bit, TDEThumbprint varbinary(32) NULL, SnapshotUrl nvarchar(360) NULL
    );
    /* QUOTENAME is limited to sysname (128 characters), so validated paths are escaped
       directly and wrapped as Unicode SQL string literals. */
    DECLARE @QuotedBackupPath nvarchar(524) = N'N''' + REPLACE(@BackupPath, N'''', N'''''') + N'''';
    DECLARE @QuotedDataPath nvarchar(524) = N'N''' + REPLACE(@DataPath, N'''', N'''''') + N'''';
    DECLARE @QuotedLogPath nvarchar(524) = N'N''' + REPLACE(@LogPath, N'''', N'''''') + N'''';

    DECLARE @VerifySql nvarchar(max) = N'RESTORE VERIFYONLY FROM DISK = ' + @QuotedBackupPath + N' WITH CHECKSUM;';
    EXEC sys.sp_executesql @VerifySql;

    DECLARE @FileListSql nvarchar(max) = N'RESTORE FILELISTONLY FROM DISK = ' + @QuotedBackupPath + N';';
    INSERT @FileList EXEC sys.sp_executesql @FileListSql;

    IF (SELECT COUNT(*) FROM @FileList WHERE [Type] = 'D' AND FileGroupName = N'PRIMARY') <> 1
       OR EXISTS (SELECT 1 FROM @FileList WHERE [Type] = 'D' AND ISNULL(FileGroupName, N'') <> N'PRIMARY')
        THROW 51210, 'Backup must contain exactly one primary data file.', 1;
    IF (SELECT COUNT(*) FROM @FileList WHERE [Type] = 'L') <> 1
        THROW 51211, 'Backup must contain exactly one log file.', 1;
    IF EXISTS (SELECT 1 FROM @FileList WHERE [Type] NOT IN ('D', 'L'))
        THROW 51212, 'Backup contains an unsupported file type.', 1;

    DECLARE @LogicalDataName sysname = (SELECT LogicalName FROM @FileList WHERE [Type] = 'D' AND FileGroupName = N'PRIMARY');
    DECLARE @LogicalLogName sysname = (SELECT LogicalName FROM @FileList WHERE [Type] = 'L');
    DECLARE @RestoreSql nvarchar(max) = N'RESTORE DATABASE ' + QUOTENAME(@DatabaseName)
        + N' FROM DISK = ' + @QuotedBackupPath
        + N' WITH MOVE ' + QUOTENAME(@LogicalDataName, N'''') + N' TO ' + @QuotedDataPath
        + N', MOVE ' + QUOTENAME(@LogicalLogName, N'''') + N' TO ' + @QuotedLogPath
        + N', RECOVERY, CHECKSUM, STATS = 5;';
    EXEC sys.sp_executesql @RestoreSql;
    SET @FreshRestore = 1;
END;

EXEC sys.sp_executesql @ConfigureSql;

IF @FreshRestore = 1
BEGIN
    DECLARE @CreateSchemaSql nvarchar(max) = N'CREATE SCHEMA lab AUTHORIZATION dbo;';
    DECLARE @UseTargetDatabaseSql nvarchar(max) = N'USE ' + QUOTENAME(@DatabaseName) + N';
        IF SCHEMA_ID(N''lab'') IS NULL
            EXEC sys.sp_executesql @CreateSchemaSql;';
    EXEC sys.sp_executesql @UseTargetDatabaseSql,
        N'@CreateSchemaSql nvarchar(max)', @CreateSchemaSql = @CreateSchemaSql;

    DECLARE @CreateMarkerSql nvarchar(max) = N'USE ' + QUOTENAME(@DatabaseName) + N';
        CREATE TABLE lab.WorkshopMarker
        (
            MarkerId uniqueidentifier NOT NULL,
            SchemaVersion int NOT NULL,
            SetupName sysname NOT NULL,
            SetupHash varbinary(32) NOT NULL,
            CreatedAtUtc datetime2(0) NOT NULL,
            LastVerifiedAtUtc datetime2(0) NOT NULL,
            CONSTRAINT PK_WorkshopMarker PRIMARY KEY (MarkerId, SchemaVersion)
        );
        INSERT lab.WorkshopMarker
            (MarkerId, SchemaVersion, SetupName, SetupHash, CreatedAtUtc, LastVerifiedAtUtc)
        VALUES
            (@MarkerId, @SchemaVersion, @SetupName, @SetupHash, SYSUTCDATETIME(), SYSUTCDATETIME());';
    EXEC sys.sp_executesql @CreateMarkerSql,
        N'@MarkerId uniqueidentifier, @SchemaVersion int, @SetupName sysname, @SetupHash varbinary(32)',
        @MarkerId = @WorkshopMarker, @SchemaVersion = @WorkshopSchemaVersion,
        @SetupName = @WorkshopSetupName, @SetupHash = @WorkshopSetupHash;
END;

DECLARE @VerifyState bit = 0;
DECLARE @VerifyStateSql nvarchar(max) = N'USE ' + QUOTENAME(@DatabaseName) + N';
    IF EXISTS
    (
        SELECT 1 FROM sys.database_query_store_options
        WHERE actual_state_desc = N''READ_WRITE'' AND desired_state_desc = N''READ_WRITE''
          AND max_storage_size_mb = 2048 AND stale_query_threshold_days = 7
          AND flush_interval_seconds = 60 AND interval_length_minutes = 5
          AND query_capture_mode_desc = N''AUTO'' AND size_based_cleanup_mode_desc = N''AUTO''
          AND wait_stats_capture_mode_desc = N''ON''
    )
    AND EXISTS
    (
        SELECT 1 FROM lab.WorkshopMarker
        WHERE MarkerId = @MarkerId AND SchemaVersion = @SchemaVersion
            AND SetupName = @SetupName AND SetupHash = @SetupHash
    )
        AND EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND compatibility_level = 160)
    BEGIN
        UPDATE lab.WorkshopMarker SET LastVerifiedAtUtc = SYSUTCDATETIME()
        WHERE MarkerId = @MarkerId AND SchemaVersion = @SchemaVersion;
        SET @Valid = 1;
    END;';
EXEC sys.sp_executesql @VerifyStateSql,
    N'@MarkerId uniqueidentifier, @SchemaVersion int, @SetupName sysname, @SetupHash varbinary(32), @Valid bit OUTPUT',
    @MarkerId = @WorkshopMarker, @SchemaVersion = @WorkshopSchemaVersion,
    @SetupName = @WorkshopSetupName, @SetupHash = @WorkshopSetupHash,
    @Valid = @VerifyState OUTPUT;
IF @VerifyState <> 1
    THROW 51213, 'Database marker or effective Query Store state does not match the workshop contract.', 1;

SELECT N'DatabaseReady' AS RestoreStatus, @DatabaseName AS DatabaseName, @FreshRestore AS RestoredThisRun;
GO
