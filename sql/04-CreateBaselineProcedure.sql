:on error exit
/*
Creates the deliberately inefficient, bounded baseline used by the workshop.
Manual diagnostic execution is permitted only when callers explicitly set both
WorkshopRunId and WorkshopManualExecution in SESSION_CONTEXT.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @WorkshopMarker uniqueidentifier = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C';
DECLARE @WorkshopSchemaVersion int = 1;
DECLARE @WorkshopSetupName sysname = N'MCP SQL Query Store Workshop';
DECLARE @WorkshopSetupHash varbinary(32) = 0xADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B;

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
    THROW 51400, 'The workshop marker contract is invalid.', 1;
GO

CREATE OR ALTER PROCEDURE lab.usp_MonthEndSalesBaseline
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
     /* Synthetic territories are generated exclusively from Sales.SalesTerritory, so this
         source-domain check is also the complete non-null synthetic-domain check. */
     IF @TerritoryID IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM Sales.SalesTerritory WHERE TerritoryID = @TerritoryID)
        THROW 51408, 'TerritoryID does not exist in the source or synthetic domain.', 1;

    /* Intentionally wide materialization. The payload is carried into TempDB/table work
       but never influences the business result. The validated date span bounds this work. */
    DECLARE @WideWork table
    (
        SyntheticSalesID bigint NOT NULL,
        TerritoryID int NULL,
        CustomerID int NOT NULL,
        ProductID int NOT NULL,
        OrderQty smallint NOT NULL,
        SalesAmount decimal(19,4) NOT NULL,
        WidePayload char(400) NOT NULL
    );

    INSERT @WideWork
        (SyntheticSalesID, TerritoryID, CustomerID, ProductID, OrderQty, SalesAmount, WidePayload)
    SELECT
        fs.SyntheticSalesID,
        fs.TerritoryID,
        fs.CustomerID,
        fs.ProductID,
        fs.OrderQty,
        fs.SalesAmount,
        fs.WidePayload
    FROM lab.FactSales AS fs
    WHERE CONVERT(date, fs.OrderDate) >= @StartDate
      AND CONVERT(date, fs.OrderDate) < @EndDateExclusive
      AND (@TerritoryID IS NULL OR fs.TerritoryID = @TerritoryID);

    DECLARE @OrderStats table
    (
        TerritoryID int NULL,
        CustomerID int NOT NULL,
        ProductID int NOT NULL,
        OrderCount bigint NOT NULL,
        TotalQuantity bigint NOT NULL,
        TotalSales decimal(38,4) NOT NULL,
        CarriedPayload char(400) NOT NULL
    );

    /* Aggregation is deliberately late, after the wide materialization. */
    INSERT @OrderStats
        (TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, CarriedPayload)
    SELECT
        w.TerritoryID,
        w.CustomerID,
        w.ProductID,
        COUNT_BIG(*),
        CONVERT(bigint, SUM(CONVERT(bigint, w.OrderQty))),
        CONVERT(decimal(38,4), SUM(CONVERT(decimal(38,4), w.SalesAmount))),
        MAX(w.WidePayload)
    FROM @WideWork AS w
    GROUP BY w.TerritoryID, w.CustomerID, w.ProductID;

    DECLARE @PriceStats table
    (
        TerritoryID int NULL,
        CustomerID int NOT NULL,
        ProductID int NOT NULL,
        AverageUnitPrice decimal(19,4) NOT NULL
    );

    /* The second source access is intentional. It calculates the quantity-weighted
       average from the same bounded rows without an artificial plan hint. */
    INSERT @PriceStats (TerritoryID, CustomerID, ProductID, AverageUnitPrice)
    SELECT
        fs.TerritoryID,
        fs.CustomerID,
        fs.ProductID,
        CONVERT(decimal(19,4),
            SUM(CONVERT(decimal(38,4), fs.SalesAmount)) /
            NULLIF(SUM(CONVERT(decimal(38,4), fs.OrderQty)), 0))
    FROM lab.FactSales AS fs
    WHERE CONVERT(date, fs.OrderDate) >= @StartDate
      AND CONVERT(date, fs.OrderDate) < @EndDateExclusive
      AND (@TerritoryID IS NULL OR fs.TerritoryID = @TerritoryID)
    GROUP BY fs.TerritoryID, fs.CustomerID, fs.ProductID;

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

    ;WITH Ranked AS
    (
        SELECT
            orders.TerritoryID,
            orders.CustomerID,
            orders.ProductID,
            orders.OrderCount,
            orders.TotalQuantity,
            orders.TotalSales,
            prices.AverageUnitPrice,
            ROW_NUMBER() OVER
            (
                ORDER BY orders.TotalSales DESC,
                    CASE WHEN orders.TerritoryID IS NULL THEN 0 ELSE 1 END,
                    orders.TerritoryID,
                    orders.CustomerID,
                    orders.ProductID
            ) AS SalesRank
        FROM @OrderStats AS orders
        INNER JOIN @PriceStats AS prices
            ON (prices.TerritoryID = orders.TerritoryID OR (prices.TerritoryID IS NULL AND orders.TerritoryID IS NULL))
           AND prices.CustomerID = orders.CustomerID
           AND prices.ProductID = orders.ProductID
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
