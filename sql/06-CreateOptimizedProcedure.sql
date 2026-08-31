:on error exit
/*
Creates the candidate's narrow covering index and contract-equivalent procedure.
The index is intentionally part of the candidate and is created only by this script.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupHash varbinary(32) = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B;

IF DB_NAME() <> N'AdventureWorks2022'
   OR OBJECT_ID(N'lab.WorkshopMarker', N'U') IS NULL
   OR OBJECT_ID(N'lab.FactSales', N'U') IS NULL
   OR NOT EXISTS
   (
       SELECT 1
       FROM lab.WorkshopMarker
       WHERE MarkerId = @WorkshopMarker
         AND SchemaVersion = @WorkshopSchemaVersion
         AND SetupName = @WorkshopSetupName
         AND SetupHash = @WorkshopSetupHash
   )
    THROW 51400, 'The workshop marker contract is invalid.', 1;

DECLARE @CandidateIndexId int = INDEXPROPERTY(OBJECT_ID(N'lab.FactSales'), N'IX_FactSales_OrderDate_Territory', 'IndexId');
IF @CandidateIndexId IS NOT NULL
BEGIN
    DECLARE @ActualKeyColumns nvarchar(4000);
    DECLARE @ActualIncludeColumns nvarchar(4000);

    SELECT @ActualKeyColumns = STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(c.name)), N',')
        WITHIN GROUP (ORDER BY ic.key_ordinal)
    FROM sys.index_columns AS ic
    INNER JOIN sys.columns AS c
        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = OBJECT_ID(N'lab.FactSales')
      AND ic.index_id = @CandidateIndexId
      AND ic.key_ordinal > 0;

    SELECT @ActualIncludeColumns = STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(c.name)), N',')
        WITHIN GROUP (ORDER BY ic.index_column_id)
    FROM sys.index_columns AS ic
    INNER JOIN sys.columns AS c
        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = OBJECT_ID(N'lab.FactSales')
      AND ic.index_id = @CandidateIndexId
      AND ic.is_included_column = 1;

    IF @ActualKeyColumns <> N'[OrderDate],[TerritoryID]'
       OR @ActualIncludeColumns <> N'[CustomerID],[ProductID],[OrderQty],[UnitPrice],[SalesAmount]'
       OR EXISTS
       (
           SELECT 1
           FROM sys.indexes
           WHERE object_id = OBJECT_ID(N'lab.FactSales')
             AND index_id = @CandidateIndexId
         AND (type <> 2 OR is_unique <> 0 OR has_filter <> 0 OR is_disabled <> 0 OR is_hypothetical <> 0)
     )
     OR EXISTS
     (
         SELECT 1
         FROM sys.index_columns
         WHERE object_id = OBJECT_ID(N'lab.FactSales')
         AND index_id = @CandidateIndexId
         AND key_ordinal > 0
         AND is_descending_key <> 0
       )
        THROW 51409, 'Existing IX_FactSales_OrderDate_Territory definition does not match the candidate contract.', 1;
END;
ELSE
BEGIN
    CREATE INDEX IX_FactSales_OrderDate_Territory
        ON lab.FactSales (OrderDate, TerritoryID)
        INCLUDE (CustomerID, ProductID, OrderQty, UnitPrice, SalesAmount);
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_MonthEndSalesOptimized
    @StartDate date,
    @EndDateExclusive date,
    @TerritoryID int = NULL,
    @TopCount int = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
    DECLARE @WorkshopSchemaVersion int = 1;
    DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
    DECLARE @WorkshopSetupHash varbinary(32) = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B;
    DECLARE @WorkshopRunId nvarchar(128) = NULLIF(LTRIM(RTRIM(TRY_CONVERT(nvarchar(128), SESSION_CONTEXT(N'WorkshopRunId')))), N'');
    DECLARE @WorkshopManualExecution bit = COALESCE(TRY_CONVERT(bit, SESSION_CONTEXT(N'WorkshopManualExecution')), 0);
    DECLARE @IsWorkshopApplication bit = CASE WHEN APP_NAME() LIKE N'MCP-SQL-Workshop%' THEN 1 ELSE 0 END;

    IF OBJECT_ID(N'lab.WorkshopMarker', N'U') IS NULL
       OR NOT EXISTS
       (
           SELECT 1
           FROM lab.WorkshopMarker
           WHERE MarkerId = @WorkshopMarker
             AND SchemaVersion = @WorkshopSchemaVersion
             AND SetupName = @WorkshopSetupName
             AND SetupHash = @WorkshopSetupHash
       )
        THROW 51400, 'The workshop marker contract is invalid.', 1;
    IF @WorkshopRunId IS NULL
        THROW 51401, 'WorkshopRunId session context is required.', 1;
    IF @IsWorkshopApplication = 0 AND @WorkshopManualExecution <> 1
        THROW 51402, 'The session must use a workshop application name or explicit manual execution context.', 1;
    IF @StartDate IS NULL
        THROW 51403, 'StartDate is required.', 1;
    IF @EndDateExclusive IS NULL
        THROW 51404, 'EndDateExclusive is required.', 1;
    IF @EndDateExclusive <= @StartDate
        THROW 51405, 'EndDateExclusive must be greater than StartDate.', 1;
    IF DATEDIFF(day, @StartDate, @EndDateExclusive) > 366
        THROW 51406, 'The date range must not exceed 366 days.', 1;
    IF @TopCount IS NULL OR @TopCount NOT BETWEEN 1 AND 1000
        THROW 51407, 'TopCount must be between 1 and 1000.', 1;
     /* The deterministic generator draws every non-null synthetic territory from this
         source domain; checking it avoids a second candidate fact-table access path. */
     IF @TerritoryID IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM Sales.SalesTerritory WHERE TerritoryID = @TerritoryID)
        THROW 51408, 'TerritoryID does not exist in the source or synthetic domain.', 1;

    DECLARE @Results table
    (
        TerritoryID int NULL,
        CustomerID int NOT NULL,
        ProductID int NOT NULL,
        OrderCount bigint NOT NULL,
        TotalQuantity bigint NOT NULL,
        TotalSales decimal(38,4) NOT NULL,
        AverageUnitPrice decimal(19,4) NOT NULL,
        SalesRank bigint NOT NULL
    );

    /* One narrow access path, one aggregate at output grain, then ranking. */
    ;WITH Aggregated AS
    (
        SELECT
            fs.TerritoryID,
            fs.CustomerID,
            fs.ProductID,
            COUNT_BIG(*) AS OrderCount,
            CONVERT(bigint, SUM(CONVERT(bigint, fs.OrderQty))) AS TotalQuantity,
            CONVERT(decimal(38,4), SUM(CONVERT(decimal(38,4), fs.SalesAmount))) AS TotalSales,
            CONVERT(decimal(19,4),
                SUM(CONVERT(decimal(38,4), fs.SalesAmount)) /
                NULLIF(SUM(CONVERT(decimal(38,4), fs.OrderQty)), 0)) AS AverageUnitPrice
        FROM lab.FactSales AS fs
        WHERE fs.OrderDate >= @StartDate
          AND fs.OrderDate < @EndDateExclusive
          AND (@TerritoryID IS NULL OR fs.TerritoryID = @TerritoryID)
        GROUP BY fs.TerritoryID, fs.CustomerID, fs.ProductID
    ), Ranked AS
    (
        SELECT
            TerritoryID,
            CustomerID,
            ProductID,
            OrderCount,
            TotalQuantity,
            TotalSales,
            AverageUnitPrice,
            ROW_NUMBER() OVER
            (
                ORDER BY TotalSales DESC,
                    CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END,
                    TerritoryID,
                    CustomerID,
                    ProductID
            ) AS SalesRank
        FROM Aggregated
    )
    INSERT @Results
        (TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank)
    SELECT TOP (@TopCount)
        TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank
    FROM Ranked
    ORDER BY SalesRank,
        CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END,
        TerritoryID, CustomerID, ProductID;

    SELECT
        TerritoryID,
        CustomerID,
        ProductID,
        OrderCount,
        TotalQuantity,
        TotalSales,
        AverageUnitPrice,
        SalesRank
    FROM @Results
    ORDER BY SalesRank, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID;
END;
GO
