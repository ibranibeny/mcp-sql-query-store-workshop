:on error exit
/*
Run in AdventureWorks2022 on the same connection on which the bootstrap sets optional,
parameterized SESSION_CONTEXT controls. Defaults are deliberately conservative and every
override is bounded. No SQLCMD text substitution is accepted.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TargetRowsValue sql_variant = SESSION_CONTEXT(N'TargetRows');
DECLARE @BatchSizeValue sql_variant = SESSION_CONTEXT(N'BatchSize');
DECLARE @MinimumFreeSpaceMBValue sql_variant = SESSION_CONTEXT(N'MinimumFreeSpaceMB');
DECLARE @MaximumDataFileSizeMBValue sql_variant = SESSION_CONTEXT(N'MaximumDataFileSizeMB');
DECLARE @TargetRows int = COALESCE(TRY_CONVERT(int, @TargetRowsValue), 8000000);
DECLARE @BatchSize int = COALESCE(TRY_CONVERT(int, @BatchSizeValue), 100000);
DECLARE @MinimumFreeSpaceMB int = COALESCE(TRY_CONVERT(int, @MinimumFreeSpaceMBValue), 65536);
DECLARE @MaximumDataFileSizeMB int = COALESCE(TRY_CONVERT(int, @MaximumDataFileSizeMBValue), 65536);
DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupContract nvarchar(200) = N'lab.WorkshopMarker|1|MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupHash varbinary(32) = HASHBYTES('SHA2_256', CONVERT(varbinary(max), @WorkshopSetupContract));

IF @TargetRowsValue IS NOT NULL AND (TRY_CONVERT(int, @TargetRowsValue) IS NULL OR SQL_VARIANT_PROPERTY(@TargetRowsValue, 'BaseType') NOT IN ('tinyint', 'smallint', 'int', 'bigint'))
    THROW 51300, 'TargetRows override must be an integer.', 1;
IF @BatchSizeValue IS NOT NULL AND (TRY_CONVERT(int, @BatchSizeValue) IS NULL OR SQL_VARIANT_PROPERTY(@BatchSizeValue, 'BaseType') NOT IN ('tinyint', 'smallint', 'int', 'bigint'))
    THROW 51301, 'BatchSize override must be an integer.', 1;
IF @MinimumFreeSpaceMBValue IS NOT NULL AND (TRY_CONVERT(int, @MinimumFreeSpaceMBValue) IS NULL OR SQL_VARIANT_PROPERTY(@MinimumFreeSpaceMBValue, 'BaseType') NOT IN ('tinyint', 'smallint', 'int', 'bigint'))
    THROW 51302, 'MinimumFreeSpaceMB override must be an integer.', 1;
IF @MaximumDataFileSizeMBValue IS NOT NULL AND (TRY_CONVERT(int, @MaximumDataFileSizeMBValue) IS NULL OR SQL_VARIANT_PROPERTY(@MaximumDataFileSizeMBValue, 'BaseType') NOT IN ('tinyint', 'smallint', 'int', 'bigint'))
    THROW 51303, 'MaximumDataFileSizeMB override must be an integer.', 1;
IF @TargetRows NOT BETWEEN 100000 AND 8000000 THROW 51304, 'TargetRows must be between 100000 and 8000000.', 1;
IF @BatchSize NOT BETWEEN 10000 AND 100000 THROW 51305, 'BatchSize must be between 10000 and 100000.', 1;
IF @MinimumFreeSpaceMB < 16384 THROW 51306, 'MinimumFreeSpaceMB must be at least 16384.', 1;
IF @MaximumDataFileSizeMB <= 0 OR @MaximumDataFileSizeMB > 65536 THROW 51307, 'MaximumDataFileSizeMB must be between 1 and 65536.', 1;
IF DB_NAME() <> N'AdventureWorks2022' THROW 51308, 'This script must run in AdventureWorks2022.', 1;
IF @WorkshopSetupHash <> 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B
    THROW 51327, 'The workshop marker contract hash is invalid.', 1;
IF SCHEMA_ID(N'lab') IS NULL OR OBJECT_ID(N'lab.WorkshopMarker', N'U') IS NULL
    THROW 51309, 'The workshop marker is required before data generation.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM lab.WorkshopMarker
    WHERE MarkerId = @WorkshopMarker
      AND SchemaVersion = @WorkshopSchemaVersion
      AND SetupName = @WorkshopSetupName
      AND SetupHash = @WorkshopSetupHash
)
    THROW 51310, 'The workshop marker contract is invalid.', 1;
IF EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc <> N'READ_WRITE')
   OR NOT EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = N'READ_WRITE')
    THROW 51311, 'Query Store actual_state_desc must be READ_WRITE.', 1;

/* This no-op branch makes the ownership prerequisite explicit to static review. */
IF SCHEMA_ID(N'lab') IS NULL EXEC(N'CREATE SCHEMA lab AUTHORIZATION dbo;');

DECLARE @DataFileLogicalName sysname;
DECLARE @CurrentDataFileSizeMB decimal(19,2);
DECLARE @AvailableSpaceMB bigint;
SELECT TOP (1)
    @DataFileLogicalName = f.name,
    @CurrentDataFileSizeMB = f.size * 8.0 / 1024,
    @AvailableSpaceMB = v.available_bytes / 1048576
FROM sys.database_files AS f
CROSS APPLY sys.dm_os_volume_stats(DB_ID(), f.file_id) AS v
WHERE f.type_desc = N'ROWS'
ORDER BY f.file_id;
IF @DataFileLogicalName IS NULL OR @AvailableSpaceMB IS NULL
    THROW 51312, 'Primary data-file volume information is unavailable.', 1;
IF @CurrentDataFileSizeMB > @MaximumDataFileSizeMB
    THROW 51313, 'Current data file already exceeds MaximumDataFileSizeMB.', 1;

DECLARE @EstimatedRequiredMB bigint = CEILING(CONVERT(decimal(19,2), @TargetRows) * 700 / 1048576.0);
IF @AvailableSpaceMB - @EstimatedRequiredMB < @MinimumFreeSpaceMB
    THROW 51314, 'Estimated generation footprint would violate MinimumFreeSpaceMB.', 1;
IF @CurrentDataFileSizeMB + @EstimatedRequiredMB > @MaximumDataFileSizeMB
    THROW 51315, 'Estimated generation footprint would violate MaximumDataFileSizeMB.', 1;

DECLARE @FilePolicySql nvarchar(max) = N'ALTER DATABASE ' + QUOTENAME(DB_NAME())
    + N' MODIFY FILE (NAME = ' + QUOTENAME(@DataFileLogicalName, N'''')
    + N', FILEGROWTH = 512MB, MAXSIZE = ' + CONVERT(nvarchar(20), @MaximumDataFileSizeMB) + N'MB);';
EXEC sys.sp_executesql @FilePolicySql;

IF OBJECT_ID(N'lab.Numbers', N'U') IS NULL
BEGIN
    CREATE TABLE lab.Numbers
    (
        Number int NOT NULL CONSTRAINT PK_Numbers PRIMARY KEY
    );
END;

DECLARE @Needed int = @TargetRows;
IF @Needed <= 8000000 AND (SELECT COUNT_BIG(*) FROM lab.Numbers) < @Needed
BEGIN
    ;WITH Digit AS
    (
        SELECT d FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS digits(d)
    ), BoundedNumbers AS
    (
        SELECT TOP (@Needed)
            CONVERT(int, ROW_NUMBER() OVER (ORDER BY a.d, b.d, c.d, d.d, e.d, f.d, g.d) ) AS Number
        FROM Digit AS a
        CROSS JOIN Digit AS b
        CROSS JOIN Digit AS c
        CROSS JOIN Digit AS d
        CROSS JOIN Digit AS e
        CROSS JOIN Digit AS f
        CROSS JOIN Digit AS g
        ORDER BY a.d, b.d, c.d, d.d, e.d, f.d, g.d
    )
    INSERT lab.Numbers (Number)
    SELECT Number FROM BoundedNumbers AS source
    WHERE NOT EXISTS (SELECT 1 FROM lab.Numbers AS target WHERE target.Number = source.Number);
END;
IF (SELECT COUNT_BIG(*) FROM lab.Numbers WHERE Number BETWEEN 1 AND @TargetRows) <> @TargetRows
    THROW 51316, 'lab.Numbers does not contain the required deterministic sequence.', 1;

IF OBJECT_ID(N'lab.FactSales', N'U') IS NULL
BEGIN
    CREATE TABLE lab.FactSales
    (
        SyntheticSalesID bigint NOT NULL,
        OrderDate datetime2(0) NOT NULL,
        TerritoryID int NULL,
        CustomerID int NOT NULL,
        ProductID int NOT NULL,
        OrderQty smallint NOT NULL,
        UnitPrice decimal(19,4) NOT NULL,
        SalesAmount decimal(19,4) NOT NULL,
        WidePayload char(400) NOT NULL,
        SourceCustomerID int NOT NULL,
        SourceProductID int NOT NULL,
        SourceChecksum int NOT NULL,
        CONSTRAINT PK_FactSales PRIMARY KEY CLUSTERED (SyntheticSalesID),
        CONSTRAINT CK_FactSales_Positive CHECK (OrderQty > 0 AND UnitPrice >= 0 AND SalesAmount >= 0)
    );
END;

IF OBJECT_ID(N'lab.DataGenerationLog', N'U') IS NULL
BEGIN
    CREATE TABLE lab.DataGenerationLog
    (
        BatchStartSyntheticSalesID bigint NOT NULL,
        BatchEndSyntheticSalesID bigint NOT NULL,
        RowsInserted int NOT NULL,
        CompletedAtUtc datetime2(0) NOT NULL,
        TargetRows int NOT NULL,
        BatchSize int NOT NULL,
        CONSTRAINT PK_DataGenerationLog PRIMARY KEY (BatchStartSyntheticSalesID, BatchEndSyntheticSalesID)
    );
END;

/* The optimized index is deferred to Task 9 after baseline evidence is captured. */

CREATE TABLE #Customers (RowNumber int NOT NULL PRIMARY KEY, CustomerID int NOT NULL UNIQUE);
INSERT #Customers (RowNumber, CustomerID)
SELECT ROW_NUMBER() OVER (ORDER BY CustomerID), CustomerID FROM Sales.Customer;
CREATE TABLE #Products (RowNumber int NOT NULL PRIMARY KEY, ProductID int NOT NULL UNIQUE, UnitPrice decimal(19,4) NOT NULL);
INSERT #Products (RowNumber, ProductID, UnitPrice)
SELECT ROW_NUMBER() OVER (ORDER BY ProductID), ProductID, CONVERT(decimal(19,4), CASE WHEN ListPrice > 0 THEN ListPrice ELSE 1.00 END)
FROM Production.Product;
CREATE TABLE #Territories (RowNumber int NOT NULL PRIMARY KEY, TerritoryID int NOT NULL UNIQUE);
INSERT #Territories (RowNumber, TerritoryID)
SELECT ROW_NUMBER() OVER (ORDER BY TerritoryID), TerritoryID FROM Sales.SalesTerritory;
DECLARE @CustomerCount int = (SELECT COUNT(*) FROM #Customers);
DECLARE @ProductCount int = (SELECT COUNT(*) FROM #Products);
DECLARE @TerritoryCount int = (SELECT COUNT(*) FROM #Territories);
IF @CustomerCount = 0 OR @ProductCount = 0 OR @TerritoryCount = 0
    THROW 51317, 'AdventureWorks source key lists must not be empty.', 1;

DECLARE @ExistingRows bigint = (SELECT COUNT_BIG(*) FROM lab.FactSales);
IF @ExistingRows > @TargetRows THROW 51318, 'Existing FactSales COUNT_BIG(*) is greater than @TargetRows.', 1;
DECLARE @NextId bigint = ISNULL((SELECT MAX(SyntheticSalesID) FROM lab.FactSales), 0) + 1;

WHILE @NextId <= @TargetRows
BEGIN
    IF NOT EXISTS
    (
        SELECT 1 FROM lab.WorkshopMarker
        WHERE MarkerId = @WorkshopMarker
          AND SchemaVersion = @WorkshopSchemaVersion
          AND SetupName = @WorkshopSetupName
          AND SetupHash = @WorkshopSetupHash
    )
        THROW 51328, 'The workshop marker contract changed or disappeared during generation.', 1;

    DECLARE @ThisBatchSize int = CONVERT(int, CASE WHEN @TargetRows - @NextId + 1 < @BatchSize THEN @TargetRows - @NextId + 1 ELSE @BatchSize END);
    DECLARE @BatchEnd bigint = @NextId + @ThisBatchSize - 1;
    DECLARE @BatchAvailableSpaceMB bigint;
    DECLARE @BatchDataFileSizeMB decimal(19,2);
    SELECT TOP (1)
        @BatchDataFileSizeMB = f.size * 8.0 / 1024,
        @BatchAvailableSpaceMB = v.available_bytes / 1048576
    FROM sys.database_files AS f
    CROSS APPLY sys.dm_os_volume_stats(DB_ID(), f.file_id) AS v
    WHERE f.type_desc = N'ROWS'
    ORDER BY f.file_id;
    IF @BatchAvailableSpaceMB < @MinimumFreeSpaceMB
        THROW 51319, 'Per-batch free-space floor would be violated.', 1;
    IF @BatchDataFileSizeMB >= @MaximumDataFileSizeMB
        THROW 51320, 'Per-batch data-file size cap would be violated.', 1;
    DECLARE @EstimatedBatchMB bigint = CEILING(CONVERT(decimal(19,2), @ThisBatchSize) * 700 / 1048576.0);
    IF @BatchAvailableSpaceMB - @EstimatedBatchMB < @MinimumFreeSpaceMB
        THROW 51325, 'Estimated batch footprint would violate the free-space floor.', 1;
    IF @BatchDataFileSizeMB + @EstimatedBatchMB > @MaximumDataFileSizeMB
        THROW 51326, 'Estimated batch footprint would violate the data-file size cap.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT lab.FactSales
        (
            SyntheticSalesID, OrderDate, TerritoryID, CustomerID, ProductID,
            OrderQty, UnitPrice, SalesAmount, WidePayload,
            SourceCustomerID, SourceProductID, SourceChecksum
        )
        SELECT TOP (@ThisBatchSize)
            n.Number,
            DATEADD(minute, (n.Number * 37) % 1440, DATEADD(day, (n.Number * 17) % 2191, CONVERT(datetime2(0), '2018-01-01'))),
            CASE WHEN n.Number % 20 = 0 THEN NULL ELSE territory.TerritoryID END,
            customer.CustomerID,
            product.ProductID,
            CONVERT(smallint, 1 + (n.Number * 13) % 12),
            product.UnitPrice,
            CONVERT(decimal(19,4), product.UnitPrice * (1 + (n.Number * 13) % 12)),
            CONVERT(char(400), REPLICATE(CHAR(65 + n.Number % 26), 400)),
            customer.CustomerID,
            product.ProductID,
            CHECKSUM(n.Number, customer.CustomerID, product.ProductID, 20260831)
        FROM lab.Numbers AS n
        INNER JOIN #Customers AS customer ON customer.RowNumber = ((CONVERT(bigint, n.Number) * 104729) % @CustomerCount) + 1
        INNER JOIN #Products AS product ON product.RowNumber = ((CONVERT(bigint, n.Number) * 130363) % @ProductCount) + 1
        INNER JOIN #Territories AS territory ON territory.RowNumber = ((CONVERT(bigint, n.Number) * 15485863) % @TerritoryCount) + 1
        WHERE n.Number BETWEEN @NextId AND @BatchEnd
          AND NOT EXISTS (SELECT 1 FROM lab.FactSales AS existing WHERE existing.SyntheticSalesID = n.Number)
        ORDER BY n.Number;
        DECLARE @RowsInserted int = @@ROWCOUNT;
        IF @RowsInserted <> @ThisBatchSize
            THROW 51321, 'A batch did not insert its exact expected range.', 1;
        INSERT lab.DataGenerationLog
            (BatchStartSyntheticSalesID, BatchEndSyntheticSalesID, RowsInserted, CompletedAtUtc, TargetRows, BatchSize)
        SELECT @NextId, @BatchEnd, @RowsInserted, SYSUTCDATETIME(), @TargetRows, @BatchSize
        WHERE NOT EXISTS
        (
            SELECT 1 FROM lab.DataGenerationLog
            WHERE BatchStartSyntheticSalesID = @NextId AND BatchEndSyntheticSalesID = @BatchEnd
        );
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
    SET @NextId = @BatchEnd + 1;
END;

DECLARE @ActualRowCount bigint = (SELECT COUNT_BIG(*) FROM lab.FactSales);
DECLARE @GeneratedThroughSyntheticSalesID bigint = (SELECT MAX(SyntheticSalesID) FROM lab.FactSales);
IF @ActualRowCount > @TargetRows THROW 51322, 'FactSales row count exceeds target.', 1;
IF @ActualRowCount <> @TargetRows OR @GeneratedThroughSyntheticSalesID <> @TargetRows
    THROW 51323, 'FactSales generation is incomplete or non-contiguous.', 1;
IF (SELECT ISNULL(SUM(CONVERT(bigint, RowsInserted)), 0) FROM lab.DataGenerationLog) <> @ActualRowCount
    THROW 51324, 'DataGenerationLog is inconsistent with FactSales.', 1;

SELECT N'DataGenerationComplete' AS GenerationStatus,
       @ActualRowCount AS ActualRowCount,
       @GeneratedThroughSyntheticSalesID AS GeneratedThroughSyntheticSalesID,
       @TargetRows AS TargetRows,
       @BatchSize AS BatchSize;
GO
