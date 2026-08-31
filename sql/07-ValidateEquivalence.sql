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
    THROW 51502, 'Existing lab.ValidationRun does not match the validation contract.', 1;

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
    THROW 51503, 'Procedure result metadata could not be described.', 1;

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
    THROW 51504, 'Procedure result metadata differs from the exact shared contract.', 1;

DECLARE @OriginalRunId sql_variant = SESSION_CONTEXT(N'WorkshopRunId');
DECLARE @OriginalManualExecution sql_variant = SESSION_CONTEXT(N'WorkshopManualExecution');
DECLARE @ValidationRunId nvarchar(128) = N'Task9Validation-' + CONVERT(nvarchar(36), NEWID());
EXEC sys.sp_set_session_context @key = N'WorkshopRunId', @value = @ValidationRunId;
EXEC sys.sp_set_session_context @key = N'WorkshopManualExecution', @value = 1;

DECLARE @LowTerritoryID int =
(
    SELECT MIN(TerritoryID) FROM
    (
        SELECT TerritoryID FROM Sales.SalesTerritory
        UNION
        SELECT TerritoryID FROM lab.FactSales WHERE TerritoryID IS NOT NULL
    ) AS domain
);
DECLARE @HighTerritoryID int =
(
    SELECT MAX(TerritoryID) FROM
    (
        SELECT TerritoryID FROM Sales.SalesTerritory
        UNION
        SELECT TerritoryID FROM lab.FactSales WHERE TerritoryID IS NOT NULL
    ) AS domain
);
IF @LowTerritoryID IS NULL OR @HighTerritoryID IS NULL
    THROW 51505, 'The deterministic territory domain is empty.', 1;

DECLARE @Cases table
(
    CaseNumber int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CaseName sysname NOT NULL,
    StartDate date NOT NULL,
    EndDateExclusive date NOT NULL,
    TerritoryID int NULL,
    TopCount int NOT NULL
);
INSERT @Cases (CaseName, StartDate, EndDateExclusive, TerritoryID, TopCount)
VALUES
    (N'NARROW-NULL-TERRITORY', '2022-06-01', '2022-06-02', NULL, 100),
    (N'BROAD-NULL-TERRITORY', '2022-01-01', '2023-01-01', NULL, 100),
    (N'LOW-TERRITORY', '2021-04-01', '2021-05-01', @LowTerritoryID, 100),
    (N'HIGH-TERRITORY', '2021-04-01', '2022-04-01', @HighTerritoryID, 100),
    (N'TOP-MINIMUM', '2020-01-01', '2020-02-01', NULL, 1),
    (N'TOP-MAXIMUM', '2019-01-01', '2020-01-01', NULL, 1000),
    (N'NO-MATCH', '2017-01-01', '2017-01-02', NULL, 100),
    (N'DATE-BOUNDARY', '2023-12-31', '2024-01-01', NULL, 100),
    (N'LEAP-BOUNDARY', '2020-02-28', '2020-03-01', @LowTerritoryID, 100),
    (N'MEDIUM-CARDINALITY', '2018-01-01', '2018-04-01', @HighTerritoryID, 250),
    (N'REPEATED-EXECUTION', '2022-06-01', '2022-06-02', NULL, 100);

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
BEGIN TRY
    WHILE @CaseNumber <= @CaseCount
    BEGIN
        DECLARE @CaseName sysname;
        DECLARE @StartDate date;
        DECLARE @EndDateExclusive date;
        DECLARE @TerritoryID int;
        DECLARE @TopCount int;
        SELECT
            @CaseName = CaseName,
            @StartDate = StartDate,
            @EndDateExclusive = EndDateExclusive,
            @TerritoryID = TerritoryID,
            @TopCount = TopCount
        FROM @Cases WHERE CaseNumber = @CaseNumber;

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
            DECLARE @RowCountMessage nvarchar(2048) = N'Case ' + @CaseName + N' row-count mismatch: baseline='
                + CONVERT(nvarchar(30), @BaselineRowCount) + N', optimized=' + CONVERT(nvarchar(30), @OptimizedRowCount) + N'.';
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
            DECLARE @DifferenceMessage nvarchar(2048) = N'Case ' + @CaseName + N' differs: BaselineExceptOptimized='
                + CONVERT(nvarchar(30), @BaselineExceptOptimized) + N', OptimizedExceptBaseline='
                + CONVERT(nvarchar(30), @OptimizedExceptBaseline) + N'.';
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
            DECLARE @HashMessage nvarchar(2048) = N'Case ' + @CaseName + N' deterministic result hash mismatch.';
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
            DECLARE @OrderMessage nvarchar(2048) = N'Case ' + @CaseName + N' violates the deterministic ranking or output ordering contract.';
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
            DECLARE @ErrorMessage nvarchar(2048) = N'Invalid-input case ' + @InvalidCaseName
                + N' did not return the same expected error from both procedures.';
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
