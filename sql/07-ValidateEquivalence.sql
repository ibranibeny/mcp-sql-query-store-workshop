:on error exit
/*
Static and executable correctness harness for the Task 9 candidate. It performs no
configuration changes and derives territory cases from the deterministic source domain.
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
       SELECT 1 FROM lab.WorkshopMarker
       WHERE MarkerId = @WorkshopMarker
         AND SchemaVersion = @WorkshopSchemaVersion
         AND SetupName = @WorkshopSetupName
         AND SetupHash = @WorkshopSetupHash
   )
    THROW 51500, 'The workshop marker contract is invalid.', 1;
IF OBJECT_ID(N'lab.usp_MonthEndSalesBaseline', N'P') IS NULL
   OR OBJECT_ID(N'lab.usp_MonthEndSalesOptimized', N'P') IS NULL
    THROW 51501, 'Both month-end procedures must exist before validation.', 1;

/* Persist only fully passing cases. Task 10 can consume this exact table contract. */
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
BEGIN
    DECLARE @ExpectedValidationColumnCount bigint = (SELECT COUNT_BIG(*) FROM @ExpectedValidationColumns);
    DECLARE @ActualValidationColumnCount bigint =
        (SELECT COUNT_BIG(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'lab.ValidationRun'));
    DECLARE @ValidationContractDifferenceCount bigint =
    (
        SELECT COUNT_BIG(*) FROM
        (
            SELECT column_id, name, type_name, max_length, precision, scale, is_nullable, is_identity
            FROM @ExpectedValidationColumns
            EXCEPT
            SELECT column_id, name, TYPE_NAME(system_type_id), max_length, precision, scale, is_nullable, is_identity
            FROM sys.columns WHERE object_id = OBJECT_ID(N'lab.ValidationRun')
        ) AS ExpectedExceptActual
    ) +
    (
        SELECT COUNT_BIG(*) FROM
        (
            SELECT column_id, name, TYPE_NAME(system_type_id), max_length, precision, scale, is_nullable, is_identity
            FROM sys.columns WHERE object_id = OBJECT_ID(N'lab.ValidationRun')
            EXCEPT
            SELECT column_id, name, type_name, max_length, precision, scale, is_nullable, is_identity
            FROM @ExpectedValidationColumns
        ) AS ActualExceptExpected
    );
    DECLARE @ValidationContractMessage nvarchar(2048);
    SET @ValidationContractMessage = LEFT(N'Case VALIDATIONRUN-METADATA mismatch: ExpectedCount='
        + CONVERT(nvarchar(30), @ExpectedValidationColumnCount) + N', ActualCount='
        + CONVERT(nvarchar(30), @ActualValidationColumnCount) + N', DifferenceCount='
        + CONVERT(nvarchar(30), @ValidationContractDifferenceCount) + N'.', 2048);
    THROW 51502, @ValidationContractMessage, 1;
END;

DECLARE @ExpectedMetadata table
(
    column_ordinal int NOT NULL PRIMARY KEY,
    name sysname NOT NULL,
    system_type_name nvarchar(256) NOT NULL,
    is_nullable bit NOT NULL
);
INSERT @ExpectedMetadata (column_ordinal, name, system_type_name, is_nullable)
VALUES
    (1, N'TerritoryID', N'int', 1),
    (2, N'CustomerID', N'int', 0),
    (3, N'ProductID', N'int', 0),
    (4, N'OrderCount', N'bigint', 0),
    (5, N'TotalQuantity', N'bigint', 0),
    (6, N'TotalSales', N'decimal(38,4)', 0),
    (7, N'AverageUnitPrice', N'decimal(19,4)', 0),
    (8, N'SalesRank', N'bigint', 0);

DECLARE @BaselineMetadata table
(
    column_ordinal int NULL,
    name sysname NULL,
    system_type_name nvarchar(256) NULL,
    is_nullable bit NULL,
    error_number int NULL,
    error_message nvarchar(4096) NULL
);
DECLARE @OptimizedMetadata table
(
    column_ordinal int NULL,
    name sysname NULL,
    system_type_name nvarchar(256) NULL,
    is_nullable bit NULL,
    error_number int NULL,
    error_message nvarchar(4096) NULL
);

INSERT @BaselineMetadata (column_ordinal, name, system_type_name, is_nullable, error_number, error_message)
SELECT column_ordinal, name, system_type_name, is_nullable, error_number, error_message
FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'lab.usp_MonthEndSalesBaseline'), 0)
WHERE is_hidden = 0;
INSERT @OptimizedMetadata (column_ordinal, name, system_type_name, is_nullable, error_number, error_message)
SELECT column_ordinal, name, system_type_name, is_nullable, error_number, error_message
FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'lab.usp_MonthEndSalesOptimized'), 0)
WHERE is_hidden = 0;

IF EXISTS (SELECT 1 FROM @BaselineMetadata WHERE error_number IS NOT NULL)
   OR EXISTS (SELECT 1 FROM @OptimizedMetadata WHERE error_number IS NOT NULL)
BEGIN
    DECLARE @MetadataDescribeErrorCount bigint =
        (SELECT COUNT_BIG(*) FROM @BaselineMetadata WHERE error_number IS NOT NULL)
        + (SELECT COUNT_BIG(*) FROM @OptimizedMetadata WHERE error_number IS NOT NULL);
    DECLARE @MetadataDescribeMessage nvarchar(2048);
    SET @MetadataDescribeMessage = LEFT(N'Case PROCEDURE-METADATA-DESCRIBE failed: ExpectedCount=0, ActualCount='
        + CONVERT(nvarchar(30), @MetadataDescribeErrorCount) + N', DifferenceCount='
        + CONVERT(nvarchar(30), @MetadataDescribeErrorCount) + N'.', 2048);
    THROW 51503, @MetadataDescribeMessage, 1;
END;

IF EXISTS
(
    SELECT column_ordinal, name, system_type_name, is_nullable FROM @ExpectedMetadata
    EXCEPT
    SELECT column_ordinal, name, system_type_name, is_nullable FROM @BaselineMetadata
)
OR EXISTS
(
    SELECT column_ordinal, name, system_type_name, is_nullable FROM @BaselineMetadata
    EXCEPT
    SELECT column_ordinal, name, system_type_name, is_nullable FROM @ExpectedMetadata
)
OR EXISTS
(
    SELECT column_ordinal, name, system_type_name, is_nullable FROM @BaselineMetadata
    EXCEPT
    SELECT column_ordinal, name, system_type_name, is_nullable FROM @OptimizedMetadata
)
OR EXISTS
(
    SELECT column_ordinal, name, system_type_name, is_nullable FROM @OptimizedMetadata
    EXCEPT
    SELECT column_ordinal, name, system_type_name, is_nullable FROM @BaselineMetadata
)
BEGIN
    DECLARE @ExpectedProcedureMetadataCount bigint = (SELECT COUNT_BIG(*) FROM @ExpectedMetadata) * 2;
    DECLARE @ActualProcedureMetadataCount bigint =
        (SELECT COUNT_BIG(*) FROM @BaselineMetadata) + (SELECT COUNT_BIG(*) FROM @OptimizedMetadata);
    DECLARE @ProcedureMetadataDifferenceCount bigint =
    (
        SELECT COUNT_BIG(*) FROM
        (
            SELECT column_ordinal, name, system_type_name, is_nullable FROM @ExpectedMetadata
            EXCEPT SELECT column_ordinal, name, system_type_name, is_nullable FROM @BaselineMetadata
        ) AS ExpectedExceptBaseline
    ) +
    (
        SELECT COUNT_BIG(*) FROM
        (
            SELECT column_ordinal, name, system_type_name, is_nullable FROM @BaselineMetadata
            EXCEPT SELECT column_ordinal, name, system_type_name, is_nullable FROM @ExpectedMetadata
        ) AS BaselineExceptExpected
    ) +
    (
        SELECT COUNT_BIG(*) FROM
        (
            SELECT column_ordinal, name, system_type_name, is_nullable FROM @ExpectedMetadata
            EXCEPT SELECT column_ordinal, name, system_type_name, is_nullable FROM @OptimizedMetadata
        ) AS ExpectedExceptOptimized
    ) +
    (
        SELECT COUNT_BIG(*) FROM
        (
            SELECT column_ordinal, name, system_type_name, is_nullable FROM @OptimizedMetadata
            EXCEPT SELECT column_ordinal, name, system_type_name, is_nullable FROM @ExpectedMetadata
        ) AS OptimizedExceptExpected
    );
    DECLARE @ProcedureMetadataMessage nvarchar(2048);
    SET @ProcedureMetadataMessage = LEFT(N'Case PROCEDURE-METADATA mismatch: ExpectedCount='
        + CONVERT(nvarchar(30), @ExpectedProcedureMetadataCount) + N', ActualCount='
        + CONVERT(nvarchar(30), @ActualProcedureMetadataCount) + N', DifferenceCount='
        + CONVERT(nvarchar(30), @ProcedureMetadataDifferenceCount) + N'.', 2048);
    THROW 51504, @ProcedureMetadataMessage, 1;
END;

DECLARE @OriginalRunId sql_variant = SESSION_CONTEXT(N'WorkshopRunId');
DECLARE @OriginalManualExecution sql_variant = SESSION_CONTEXT(N'WorkshopManualExecution');
DECLARE @ValidationRunId nvarchar(128) = N'Task9Validation-' + CONVERT(nvarchar(36), NEWID());

DECLARE @TerritoryCardinality table
(
    TerritoryID int NOT NULL PRIMARY KEY,
    ExpectedRowCount bigint NOT NULL,
    CardinalityRowNumber bigint NOT NULL,
    DistinctTerritoryCount bigint NOT NULL
);
;WITH TerritoryCounts AS
(
    SELECT TerritoryID, COUNT_BIG(*) AS ExpectedRowCount
    FROM lab.FactSales
    WHERE TerritoryID IS NOT NULL
    GROUP BY TerritoryID
), RankedTerritories AS
(
    SELECT
        TerritoryID,
        ExpectedRowCount,
        ROW_NUMBER() OVER (ORDER BY ExpectedRowCount, TerritoryID) AS CardinalityRowNumber,
        COUNT_BIG(*) OVER () AS DistinctTerritoryCount
    FROM TerritoryCounts
)
INSERT @TerritoryCardinality
    (TerritoryID, ExpectedRowCount, CardinalityRowNumber, DistinctTerritoryCount)
SELECT TerritoryID, ExpectedRowCount, CardinalityRowNumber, DistinctTerritoryCount
FROM RankedTerritories;

DECLARE @DistinctTerritoryCount bigint = COALESCE((SELECT MAX(DistinctTerritoryCount) FROM @TerritoryCardinality), 0);
IF @DistinctTerritoryCount < 3
BEGIN
    DECLARE @TerritoryCountMessage nvarchar(2048);
    SET @TerritoryCountMessage = LEFT(N'Case TERRITORY-CARDINALITY insufficient data: ExpectedCount=3, ActualCount='
        + CONVERT(nvarchar(30), @DistinctTerritoryCount) + N', DifferenceCount='
        + CONVERT(nvarchar(30), 3 - @DistinctTerritoryCount) + N'.', 2048);
    THROW 51505, @TerritoryCountMessage, 1;
END;

DECLARE @LowTerritoryID int;
DECLARE @MediumTerritoryID int;
DECLARE @HighTerritoryID int;
DECLARE @LowExpectedRowCount bigint;
DECLARE @MediumExpectedRowCount bigint;
DECLARE @HighExpectedRowCount bigint;
SELECT @LowTerritoryID = TerritoryID, @LowExpectedRowCount = ExpectedRowCount
FROM @TerritoryCardinality WHERE CardinalityRowNumber = 1;
SELECT @MediumTerritoryID = TerritoryID, @MediumExpectedRowCount = ExpectedRowCount
FROM @TerritoryCardinality WHERE CardinalityRowNumber = ((@DistinctTerritoryCount + 1) / 2);
SELECT @HighTerritoryID = TerritoryID, @HighExpectedRowCount = ExpectedRowCount
FROM @TerritoryCardinality WHERE CardinalityRowNumber = @DistinctTerritoryCount;

DECLARE @SelectedTerritoryCount bigint;
SELECT @SelectedTerritoryCount = COUNT_BIG(DISTINCT selected.TerritoryID)
FROM (VALUES (@LowTerritoryID), (@MediumTerritoryID), (@HighTerritoryID)) AS selected(TerritoryID);
IF @SelectedTerritoryCount <> 3
BEGIN
    DECLARE @SelectedTerritoryMessage nvarchar(2048);
    SET @SelectedTerritoryMessage = LEFT(N'Case TERRITORY-CARDINALITY selection mismatch: ExpectedCount=3, ActualCount='
        + CONVERT(nvarchar(30), @SelectedTerritoryCount) + N', DifferenceCount='
        + CONVERT(nvarchar(30), 3 - @SelectedTerritoryCount) + N'.', 2048);
    THROW 51505, @SelectedTerritoryMessage, 1;
END;

PRINT LEFT(N'Territory cardinality Low: TerritoryID=' + CONVERT(nvarchar(20), @LowTerritoryID)
    + N', ExpectedRowCount=' + CONVERT(nvarchar(30), @LowExpectedRowCount) + N'.', 2048);
PRINT LEFT(N'Territory cardinality Medium: TerritoryID=' + CONVERT(nvarchar(20), @MediumTerritoryID)
    + N', ExpectedRowCount=' + CONVERT(nvarchar(30), @MediumExpectedRowCount) + N'.', 2048);
PRINT LEFT(N'Territory cardinality High: TerritoryID=' + CONVERT(nvarchar(20), @HighTerritoryID)
    + N', ExpectedRowCount=' + CONVERT(nvarchar(30), @HighExpectedRowCount) + N'.', 2048);

DECLARE @Cases table
(
    CaseNumber int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CaseName sysname NOT NULL,
    StartDate date NOT NULL,
    EndDateExclusive date NOT NULL,
    TerritoryID int NULL,
    TopCount int NOT NULL,
    CardinalityLabel nvarchar(10) NULL,
    ExpectedTerritoryRowCount bigint NULL
);
INSERT @Cases
    (CaseName, StartDate, EndDateExclusive, TerritoryID, TopCount, CardinalityLabel, ExpectedTerritoryRowCount)
VALUES
    (N'NARROW-NULL-TERRITORY', '2022-06-01', '2022-06-02', NULL, 100, NULL, NULL),
    (N'BROAD-NULL-TERRITORY', '2022-01-01', '2023-01-01', NULL, 100, NULL, NULL),
    (N'LOW-TERRITORY', '2021-04-01', '2021-05-01', @LowTerritoryID, 100, N'Low', @LowExpectedRowCount),
    (N'MEDIUM-TERRITORY', '2018-01-01', '2018-04-01', @MediumTerritoryID, 250, N'Medium', @MediumExpectedRowCount),
    (N'HIGH-TERRITORY', '2021-04-01', '2022-04-01', @HighTerritoryID, 100, N'High', @HighExpectedRowCount),
    (N'TOP-MINIMUM', '2020-01-01', '2020-02-01', NULL, 1, NULL, NULL),
    (N'TOP-MAXIMUM', '2019-01-01', '2020-01-01', NULL, 1000, NULL, NULL),
    (N'NO-MATCH', '2017-01-01', '2017-01-02', NULL, 100, NULL, NULL),
    (N'DATE-BOUNDARY', '2023-12-31', '2024-01-01', NULL, 100, NULL, NULL),
    (N'LEAP-BOUNDARY', '2020-02-28', '2020-03-01', @LowTerritoryID, 100, NULL, NULL),
    (N'REPEATED-EXECUTION', '2022-06-01', '2022-06-02', NULL, 100, NULL, NULL);

CREATE TABLE #Baseline
(
    CaptureOrder bigint IDENTITY(1,1) NOT NULL,
    TerritoryID int NULL,
    CustomerID int NOT NULL,
    ProductID int NOT NULL,
    OrderCount bigint NOT NULL,
    TotalQuantity bigint NOT NULL,
    TotalSales decimal(38,4) NOT NULL,
    AverageUnitPrice decimal(19,4) NOT NULL,
    SalesRank bigint NOT NULL
);
CREATE TABLE #Optimized
(
    CaptureOrder bigint IDENTITY(1,1) NOT NULL,
    TerritoryID int NULL,
    CustomerID int NOT NULL,
    ProductID int NOT NULL,
    OrderCount bigint NOT NULL,
    TotalQuantity bigint NOT NULL,
    TotalSales decimal(38,4) NOT NULL,
    AverageUnitPrice decimal(19,4) NOT NULL,
    SalesRank bigint NOT NULL
);

DECLARE @PassingCases table
(
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

DECLARE @CaseNumber int = 1;
DECLARE @CaseCount int = (SELECT COUNT(*) FROM @Cases);
EXEC sys.sp_set_session_context @key = N'WorkshopRunId', @value = @ValidationRunId;
EXEC sys.sp_set_session_context @key = N'WorkshopManualExecution', @value = 1;
BEGIN TRY
    WHILE @CaseNumber <= @CaseCount
    BEGIN
        DECLARE @CaseName sysname;
        DECLARE @StartDate date;
        DECLARE @EndDateExclusive date;
        DECLARE @TerritoryID int;
        DECLARE @TopCount int;
        DECLARE @CardinalityLabel nvarchar(10);
        DECLARE @ExpectedTerritoryRowCount bigint;
        SELECT
            @CaseName = CaseName,
            @StartDate = StartDate,
            @EndDateExclusive = EndDateExclusive,
            @TerritoryID = TerritoryID,
            @TopCount = TopCount,
            @CardinalityLabel = CardinalityLabel,
            @ExpectedTerritoryRowCount = ExpectedTerritoryRowCount
        FROM @Cases WHERE CaseNumber = @CaseNumber;

        IF @CardinalityLabel IS NOT NULL
        BEGIN
            DECLARE @ActualTerritoryRowCount bigint =
                (SELECT COUNT_BIG(*) FROM lab.FactSales WHERE TerritoryID = @TerritoryID);
            IF @ActualTerritoryRowCount <> @ExpectedTerritoryRowCount
            BEGIN
                DECLARE @CardinalityMessage nvarchar(2048);
                SET @CardinalityMessage = LEFT(N'Case ' + @CaseName + N' territory cardinality mismatch ('
                    + @CardinalityLabel + N'): ExpectedCount=' + CONVERT(nvarchar(30), @ExpectedTerritoryRowCount)
                    + N', ActualCount=' + CONVERT(nvarchar(30), @ActualTerritoryRowCount)
                    + N', DifferenceCount=' + CONVERT(nvarchar(30), ABS(@ExpectedTerritoryRowCount - @ActualTerritoryRowCount))
                    + N'.', 2048);
                THROW 51506, @CardinalityMessage, 1;
            END;
            PRINT LEFT(N'Territory cardinality verified for case ' + @CaseName + N' (' + @CardinalityLabel
                + N'): TerritoryID=' + CONVERT(nvarchar(20), @TerritoryID) + N', ExpectedCount='
                + CONVERT(nvarchar(30), @ExpectedTerritoryRowCount) + N', ActualCount='
                + CONVERT(nvarchar(30), @ActualTerritoryRowCount) + N', DifferenceCount=0.', 2048);
        END;

        TRUNCATE TABLE #Baseline;
        TRUNCATE TABLE #Optimized;

        INSERT #Baseline
            (TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank)
        EXEC lab.usp_MonthEndSalesBaseline
            @StartDate = @StartDate, @EndDateExclusive = @EndDateExclusive,
            @TerritoryID = @TerritoryID, @TopCount = @TopCount;
        INSERT #Optimized
            (TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank)
        EXEC lab.usp_MonthEndSalesOptimized
            @StartDate = @StartDate, @EndDateExclusive = @EndDateExclusive,
            @TerritoryID = @TerritoryID, @TopCount = @TopCount;

        DECLARE @BaselineRowCount bigint = (SELECT COUNT_BIG(*) FROM #Baseline);
        DECLARE @OptimizedRowCount bigint = (SELECT COUNT_BIG(*) FROM #Optimized);
        IF @BaselineRowCount <> @OptimizedRowCount
        BEGIN
            DECLARE @RowCountMessage nvarchar(2048);
            SET @RowCountMessage = LEFT(N'Case ' + @CaseName + N' row-count mismatch: ExpectedCount='
                + CONVERT(nvarchar(30), @BaselineRowCount) + N', ActualCount=' + CONVERT(nvarchar(30), @OptimizedRowCount)
                + N', DifferenceCount=' + CONVERT(nvarchar(30), ABS(@BaselineRowCount - @OptimizedRowCount)) + N'.', 2048);
            THROW 51510, @RowCountMessage, 1;
        END;

        DECLARE @BaselineExceptOptimized bigint;
        DECLARE @OptimizedExceptBaseline bigint;
        SELECT @BaselineExceptOptimized = COUNT_BIG(*)
        FROM
        (
            SELECT TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank FROM #Baseline
            EXCEPT
            SELECT TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank FROM #Optimized
        ) AS BaselineExceptOptimized;
        SELECT @OptimizedExceptBaseline = COUNT_BIG(*)
        FROM
        (
            SELECT TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank FROM #Optimized
            EXCEPT
            SELECT TerritoryID, CustomerID, ProductID, OrderCount, TotalQuantity, TotalSales, AverageUnitPrice, SalesRank FROM #Baseline
        ) AS OptimizedExceptBaseline;
        IF @BaselineExceptOptimized <> 0 OR @OptimizedExceptBaseline <> 0
        BEGIN
            DECLARE @DifferenceMessage nvarchar(2048);
            SET @DifferenceMessage = LEFT(N'Case ' + @CaseName + N' set mismatch: ExpectedCount=0, ActualCount='
                + CONVERT(nvarchar(30), @BaselineExceptOptimized + @OptimizedExceptBaseline)
                + N', DifferenceCount=' + CONVERT(nvarchar(30), @BaselineExceptOptimized + @OptimizedExceptBaseline)
                + N', BaselineExceptOptimized='
                + CONVERT(nvarchar(30), @BaselineExceptOptimized) + N', OptimizedExceptBaseline='
                + CONVERT(nvarchar(30), @OptimizedExceptBaseline) + N'.', 2048);
            THROW 51511, @DifferenceMessage, 1;
        END;

        DECLARE @BaselineHash varbinary(32);
        DECLARE @OptimizedHash varbinary(32);
        SELECT @BaselineHash = HASHBYTES('SHA2_256', CONVERT(varbinary(max), COALESCE(
            STRING_AGG(CONVERT(nvarchar(max), CONCAT_WS(NCHAR(31),
                COALESCE(CONVERT(nvarchar(20), TerritoryID), N'<NULL>'),
                CONVERT(nvarchar(20), CustomerID), CONVERT(nvarchar(20), ProductID),
                CONVERT(nvarchar(30), OrderCount), CONVERT(nvarchar(30), TotalQuantity),
                CONVERT(nvarchar(50), TotalSales), CONVERT(nvarchar(50), AverageUnitPrice),
                CONVERT(nvarchar(30), SalesRank))), NCHAR(30))
            WITHIN GROUP (ORDER BY SalesRank, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID), N'')))
        FROM #Baseline;
        SELECT @OptimizedHash = HASHBYTES('SHA2_256', CONVERT(varbinary(max), COALESCE(
            STRING_AGG(CONVERT(nvarchar(max), CONCAT_WS(NCHAR(31),
                COALESCE(CONVERT(nvarchar(20), TerritoryID), N'<NULL>'),
                CONVERT(nvarchar(20), CustomerID), CONVERT(nvarchar(20), ProductID),
                CONVERT(nvarchar(30), OrderCount), CONVERT(nvarchar(30), TotalQuantity),
                CONVERT(nvarchar(50), TotalSales), CONVERT(nvarchar(50), AverageUnitPrice),
                CONVERT(nvarchar(30), SalesRank))), NCHAR(30))
            WITHIN GROUP (ORDER BY SalesRank, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID), N'')))
        FROM #Optimized;
        IF @BaselineHash <> @OptimizedHash
        BEGIN
            DECLARE @HashMessage nvarchar(2048);
            SET @HashMessage = LEFT(N'Case ' + @CaseName + N' deterministic result hash mismatch: ExpectedCount='
                + CONVERT(nvarchar(30), @BaselineRowCount) + N', ActualCount=' + CONVERT(nvarchar(30), @OptimizedRowCount)
                + N', DifferenceCount='
                + CONVERT(nvarchar(30), @BaselineExceptOptimized + @OptimizedExceptBaseline)
                + N', ExpectedHash=' + COALESCE(CONVERT(nvarchar(64), @BaselineHash, 2), N'<NULL>')
                + N', ActualHash=' + COALESCE(CONVERT(nvarchar(64), @OptimizedHash, 2), N'<NULL>') + N'.', 2048);
            THROW 51512, @HashMessage, 1;
        END;

        ;WITH BaselineOrder AS
        (
            SELECT CaptureOrder,
                ROW_NUMBER() OVER (ORDER BY SalesRank, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID) AS ExpectedOrder,
                SalesRank,
                ROW_NUMBER() OVER (ORDER BY TotalSales DESC, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID) AS ExpectedRank
            FROM #Baseline
        ), OptimizedOrder AS
        (
            SELECT CaptureOrder,
                ROW_NUMBER() OVER (ORDER BY SalesRank, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID) AS ExpectedOrder,
                SalesRank,
                ROW_NUMBER() OVER (ORDER BY TotalSales DESC, CASE WHEN TerritoryID IS NULL THEN 0 ELSE 1 END, TerritoryID, CustomerID, ProductID) AS ExpectedRank
            FROM #Optimized
        )
        SELECT @BaselineExceptOptimized =
            (SELECT COUNT_BIG(*) FROM BaselineOrder WHERE CaptureOrder <> ExpectedOrder OR SalesRank <> ExpectedRank),
            @OptimizedExceptBaseline =
            (SELECT COUNT_BIG(*) FROM OptimizedOrder WHERE CaptureOrder <> ExpectedOrder OR SalesRank <> ExpectedRank);
        IF @BaselineExceptOptimized <> 0 OR @OptimizedExceptBaseline <> 0
        BEGIN
            DECLARE @OrderMessage nvarchar(2048);
            SET @OrderMessage = LEFT(N'Case ' + @CaseName
                + N' violates the deterministic ranking or output ordering contract: ExpectedCount=0, ActualCount='
                + CONVERT(nvarchar(30), @BaselineExceptOptimized + @OptimizedExceptBaseline)
                + N', DifferenceCount=' + CONVERT(nvarchar(30), @BaselineExceptOptimized + @OptimizedExceptBaseline)
                + N', BaselineViolations=' + CONVERT(nvarchar(30), @BaselineExceptOptimized)
                + N', OptimizedViolations=' + CONVERT(nvarchar(30), @OptimizedExceptBaseline) + N'.', 2048);
            THROW 51513, @OrderMessage, 1;
        END;

        INSERT @PassingCases
            (RunID, ValidationCaseName, StartDate, EndDateExclusive, TerritoryID, TopCount,
             BaselineRowCount, OptimizedRowCount, BaselineHash, OptimizedHash, Passed, ValidatedAtUtc)
        VALUES
            (@ValidationRunId, @CaseName, @StartDate, @EndDateExclusive, @TerritoryID, @TopCount,
             @BaselineRowCount, @OptimizedRowCount, @BaselineHash, @OptimizedHash, 1, SYSUTCDATETIME());

        SET @CaseNumber += 1;
    END;

    DECLARE @InvalidInputCases table
    (
        CaseNumber int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        CaseName sysname NOT NULL,
        StartDate date NULL,
        EndDateExclusive date NULL,
        TerritoryID int NULL,
        TopCount int NULL,
        ExpectedErrorNumber int NOT NULL,
        ExpectedErrorMessage nvarchar(2048) NOT NULL
    );
    INSERT @InvalidInputCases
        (CaseName, StartDate, EndDateExclusive, TerritoryID, TopCount, ExpectedErrorNumber, ExpectedErrorMessage)
    VALUES
        (N'NULL-START', NULL, '2022-01-02', NULL, 100, 51403, N'StartDate is required.'),
        (N'NULL-END', '2022-01-01', NULL, NULL, 100, 51404, N'EndDateExclusive is required.'),
        (N'REVERSED-RANGE', '2022-01-02', '2022-01-01', NULL, 100, 51405, N'EndDateExclusive must be greater than StartDate.'),
        (N'RANGE-TOO-LARGE', '2021-01-01', '2022-01-03', NULL, 100, 51406, N'The date range must not exceed 366 days.'),
        (N'TOP-BELOW-MINIMUM', '2022-01-01', '2022-01-02', NULL, 0, 51407, N'TopCount must be between 1 and 1000.'),
        (N'TOP-ABOVE-MAXIMUM', '2022-01-01', '2022-01-02', NULL, 1001, 51407, N'TopCount must be between 1 and 1000.'),
        (N'TOP-NULL', '2022-01-01', '2022-01-02', NULL, NULL, 51407, N'TopCount must be between 1 and 1000.'),
        (N'UNKNOWN-TERRITORY', '2022-01-01', '2022-01-02', 2147483647, 100, 51408, N'TerritoryID does not exist in the source or synthetic domain.');

    DECLARE @InvalidCaseNumber int = 1;
    DECLARE @InvalidCaseCount int = (SELECT COUNT(*) FROM @InvalidInputCases);
    WHILE @InvalidCaseNumber <= @InvalidCaseCount
    BEGIN
        DECLARE @InvalidCaseName sysname;
        DECLARE @InvalidStartDate date;
        DECLARE @InvalidEndDateExclusive date;
        DECLARE @InvalidTerritoryID int;
        DECLARE @InvalidTopCount int;
        DECLARE @ExpectedErrorNumber int;
        DECLARE @ExpectedErrorMessage nvarchar(2048);
        SELECT
            @InvalidCaseName = CaseName, @InvalidStartDate = StartDate,
            @InvalidEndDateExclusive = EndDateExclusive, @InvalidTerritoryID = TerritoryID,
            @InvalidTopCount = TopCount, @ExpectedErrorNumber = ExpectedErrorNumber,
            @ExpectedErrorMessage = ExpectedErrorMessage
        FROM @InvalidInputCases WHERE CaseNumber = @InvalidCaseNumber;

        DECLARE @BaselineErrorNumber int = 0;
        DECLARE @BaselineErrorMessage nvarchar(2048) = N'';
        DECLARE @OptimizedErrorNumber int = 0;
        DECLARE @OptimizedErrorMessage nvarchar(2048) = N'';
        BEGIN TRY
            EXEC lab.usp_MonthEndSalesBaseline @InvalidStartDate, @InvalidEndDateExclusive, @InvalidTerritoryID, @InvalidTopCount;
        END TRY
        BEGIN CATCH
            SELECT @BaselineErrorNumber = ERROR_NUMBER(), @BaselineErrorMessage = ERROR_MESSAGE();
        END CATCH;
        BEGIN TRY
            EXEC lab.usp_MonthEndSalesOptimized @InvalidStartDate, @InvalidEndDateExclusive, @InvalidTerritoryID, @InvalidTopCount;
        END TRY
        BEGIN CATCH
            SELECT @OptimizedErrorNumber = ERROR_NUMBER(), @OptimizedErrorMessage = ERROR_MESSAGE();
        END CATCH;

        IF @BaselineErrorNumber <> @ExpectedErrorNumber OR @OptimizedErrorNumber <> @ExpectedErrorNumber
           OR @BaselineErrorMessage <> @ExpectedErrorMessage OR @OptimizedErrorMessage <> @ExpectedErrorMessage
           OR @BaselineErrorNumber <> @OptimizedErrorNumber OR @BaselineErrorMessage <> @OptimizedErrorMessage
        BEGIN
            DECLARE @BaselineErrorMatched bit = CASE WHEN @BaselineErrorNumber = @ExpectedErrorNumber
                AND @BaselineErrorMessage = @ExpectedErrorMessage THEN 1 ELSE 0 END;
            DECLARE @OptimizedErrorMatched bit = CASE WHEN @OptimizedErrorNumber = @ExpectedErrorNumber
                AND @OptimizedErrorMessage = @ExpectedErrorMessage THEN 1 ELSE 0 END;
            DECLARE @InvalidCaseMatched bit = CASE WHEN @BaselineErrorMatched = 1 AND @OptimizedErrorMatched = 1
                AND @BaselineErrorNumber = @OptimizedErrorNumber AND @BaselineErrorMessage = @OptimizedErrorMessage
                THEN 1 ELSE 0 END;
            DECLARE @ErrorMessage nvarchar(2048);
            SET @ErrorMessage = LEFT(N'Invalid-input case ' + @InvalidCaseName
                + N' error mismatch: ExpectedCount=1, ActualCount=' + CONVERT(nvarchar(1), @InvalidCaseMatched)
                + N', DifferenceCount=1, ExpectedErrorNumber=' + CONVERT(nvarchar(20), @ExpectedErrorNumber)
                + N', BaselineErrorNumber=' + CONVERT(nvarchar(20), @BaselineErrorNumber)
                + N', OptimizedErrorNumber=' + CONVERT(nvarchar(20), @OptimizedErrorNumber)
                + N', ExpectedErrorMessage=' + COALESCE(@ExpectedErrorMessage, N'<NULL>')
                + N', BaselineErrorMessage=' + COALESCE(@BaselineErrorMessage, N'<NULL>')
                + N', OptimizedErrorMessage=' + COALESCE(@OptimizedErrorMessage, N'<NULL>')
                + N', BaselineMatched=' + CONVERT(nvarchar(1), @BaselineErrorMatched)
                + N', OptimizedMatched=' + CONVERT(nvarchar(1), @OptimizedErrorMatched) + N'.', 2048);
            THROW 51514, @ErrorMessage, 1;
        END;
        SET @InvalidCaseNumber += 1;
    END;

    /* Publish evidence only after every result and invalid-input case has passed. */
    INSERT lab.ValidationRun
        (RunID, ValidationCaseName, StartDate, EndDateExclusive, TerritoryID, TopCount,
         BaselineRowCount, OptimizedRowCount, BaselineHash, OptimizedHash, Passed, ValidatedAtUtc)
    SELECT RunID, ValidationCaseName, StartDate, EndDateExclusive, TerritoryID, TopCount,
        BaselineRowCount, OptimizedRowCount, BaselineHash, OptimizedHash, Passed, ValidatedAtUtc
    FROM @PassingCases;

    EXEC sys.sp_set_session_context @key = N'WorkshopRunId', @value = @OriginalRunId;
    EXEC sys.sp_set_session_context @key = N'WorkshopManualExecution', @value = @OriginalManualExecution;
END TRY
BEGIN CATCH
    EXEC sys.sp_set_session_context @key = N'WorkshopRunId', @value = @OriginalRunId;
    EXEC sys.sp_set_session_context @key = N'WorkshopManualExecution', @value = @OriginalManualExecution;
    THROW;
END CATCH;

SELECT @ValidationRunId AS RunID, @CaseCount AS PassingCaseCount, N'ValidationPassed' AS ValidationStatus;
GO
