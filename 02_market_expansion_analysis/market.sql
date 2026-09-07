-- ============================================================
-- Adventure Works | Market Expansion Analysis
-- Initiative 2: Brick and Mortar Store Expansion
-- ============================================================
-- Description: Identifies the two optimal US cities for
--              Adventure Works' first brick and mortar stores
--              using a data-driven scoring approach.
-- ============================================================

-- NOTE: Update the database name below to match your environment
USE [AdventureWorks]
GO

-- ============================================================
-- Phase 1: Identify and Rank Top 30 SC Customers
-- ============================================================

-- I. Row level order details including LAG
DROP TABLE IF EXISTS #SCOrderDetails;

SELECT
    p.BusinessEntityID                                                               AS CustomerID,
    a.City,
    sp.Name                                                                          AS StateProvince,
    cr.CountryRegionCode                                                             AS Country,
    soh.OrderDate,
    soh.TotalDue,
    LAG(soh.OrderDate) OVER (PARTITION BY p.BusinessEntityID ORDER BY soh.OrderDate) AS PreviousOrderDate
INTO #SCOrderDetails
FROM Sales.SalesOrderHeader soh
JOIN Sales.Customer c        ON soh.CustomerID = c.CustomerID
JOIN Person.Person p         ON c.PersonID = p.BusinessEntityID
JOIN Person.Address a        ON soh.BillToAddressID = a.AddressID
JOIN Person.StateProvince sp ON a.StateProvinceID = sp.StateProvinceID
JOIN Person.CountryRegion cr ON sp.CountryRegionCode = cr.CountryRegionCode
WHERE p.PersonType = 'SC'
AND cr.CountryRegionCode = 'US';
GO

-- II. Aggregate metrics per customer
DROP TABLE IF EXISTS #SCAggregated;

SELECT
    CustomerID,
    City,
    StateProvince,
    Country,
    SUM(TotalDue)                                              AS TotalSalesValue,
    COUNT(OrderDate)                                           AS OrderFrequency,
    AVG(CASE
            WHEN PreviousOrderDate IS NULL THEN 0
            ELSE DATEDIFF(DAY, PreviousOrderDate, OrderDate)
        END)                                                   AS AverageTimeBetweenOrders,
    DATEDIFF(DAY, MIN(OrderDate), MAX(OrderDate))              AS TimeBetweenFirstAndLastOrder
INTO #SCAggregated
FROM #SCOrderDetails
GROUP BY CustomerID, City, StateProvince, Country;
GO

-- III. Normalise, weight and rank
DROP TABLE IF EXISTS #SCRanked;

SELECT
    CustomerID,
    City,
    StateProvince,
    Country,
    (((TotalSalesValue - AVG(TotalSalesValue) OVER()) / NULLIF(STDEV(TotalSalesValue) OVER(), 0)) * 0.50) +
    (((OrderFrequency - AVG(OrderFrequency) OVER()) / NULLIF(STDEV(OrderFrequency) OVER(), 0)) * 0.25) +
    (((AverageTimeBetweenOrders - AVG(AverageTimeBetweenOrders) OVER()) / NULLIF(STDEV(AverageTimeBetweenOrders) OVER(), 0)) * 0.10) +
    (((TimeBetweenFirstAndLastOrder - AVG(TimeBetweenFirstAndLastOrder) OVER()) / NULLIF(STDEV(TimeBetweenFirstAndLastOrder) OVER(), 0)) * 0.15)
                                                               AS RankingScore
INTO #SCRanked
FROM #SCAggregated;
GO

-- IV. Verify top 30
SELECT TOP 30 *,
    RANK() OVER (ORDER BY RankingScore DESC) AS Rank
FROM #SCRanked
ORDER BY Rank;
GO


-- ============================================================
-- Phase 2: Identify Candidate Cities
-- ============================================================

-- I. Calculate customer density per city
DROP TABLE IF EXISTS #CityDensity;

SELECT
    a.City,
    sp.Name                                                    AS StateProvince,
    sp.CountryRegionCode                                       AS Country,
    SUM(CASE WHEN p.PersonType = 'SC' THEN 1 ELSE 0 END)      AS SC_Density,
    SUM(CASE WHEN p.PersonType = 'IN' THEN 1 ELSE 0 END)      AS IN_Density
INTO #CityDensity
FROM Sales.SalesOrderHeader soh
JOIN Sales.Customer c        ON soh.CustomerID = c.CustomerID
JOIN Person.Person p         ON c.PersonID = p.BusinessEntityID
JOIN Person.Address a        ON soh.BillToAddressID = a.AddressID
JOIN Person.StateProvince sp ON a.StateProvinceID = sp.StateProvinceID
WHERE p.PersonType IN ('SC', 'IN')
AND a.City IS NOT NULL
AND sp.CountryRegionCode = 'US'
GROUP BY a.City, sp.Name, sp.CountryRegionCode;
GO

/*
-- II. Exploratory: IN customer density distribution
-- Used to validate the 100 IN customer threshold decision
-- See README for full justification
SELECT
    MIN(IN_Density)  AS MinDensity,
    MAX(IN_Density)  AS MaxDensity,
    AVG(IN_Density)  AS AvgDensity
FROM #CityDensity
WHERE Country = 'US';
Go

SELECT DISTINCT
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY IN_Density) OVER () AS Percentile25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY IN_Density) OVER () AS Percentile50,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY IN_Density) OVER () AS Percentile75
FROM #CityDensity
WHERE Country = 'US';
GO

-- III. Exploratory: Hard threshold testing
SELECT
    SUM(CASE WHEN IN_Density >= 50  THEN 1 ELSE 0 END) AS Above50,
    SUM(CASE WHEN IN_Density >= 75  THEN 1 ELSE 0 END) AS Above75,
    SUM(CASE WHEN IN_Density >= 100 THEN 1 ELSE 0 END) AS Above100,
    SUM(CASE WHEN IN_Density >= 150 THEN 1 ELSE 0 END) AS Above150,
    SUM(CASE WHEN IN_Density >= 200 THEN 1 ELSE 0 END) AS Above200
FROM #CityDensity
WHERE Country = 'US';
GO
*/

-- IV. Filter candidate cities
    -- Exclude cities with fewer than 100 IN customers
    -- Exclude cities where top 30 SC customers are located
DROP TABLE IF EXISTS #CandidateCities;

SELECT
    cd.City,
    cd.StateProvince,
    cd.Country,
    cd.SC_Density,
    cd.IN_Density
INTO #CandidateCities
FROM #CityDensity cd
WHERE cd.IN_Density >= 100
AND cd.Country = 'US'
AND NOT EXISTS (
    SELECT 1
    FROM (
        SELECT TOP 30 City, StateProvince
        FROM #SCRanked
        ORDER BY RankingScore DESC
    ) AS Top30SC
    WHERE Top30SC.City = cd.City
    AND Top30SC.StateProvince = cd.StateProvince
);
GO

-- Verify
SELECT * FROM #CandidateCities ORDER BY IN_Density DESC;
GO

-- ============================================================
-- Phase 3: Score and Rank Candidate Cities
-- ============================================================

/* */
-- Exploratory: Verify time ranges used for period comparison
SELECT
    MAX(soh.OrderDate)                                      AS ReferenceDate,
    DATEADD(MONTH, -6, MAX(soh.OrderDate))                  AS StartPeriod1,
    MAX(soh.OrderDate)                                      AS EndPeriod1,
    DATEADD(MONTH, -12, MAX(soh.OrderDate))                 AS StartPeriod2,
    DATEADD(DAY, -1, DATEADD(MONTH, -6, MAX(soh.OrderDate))) AS EndPeriod2
FROM Sales.SalesOrderHeader soh
JOIN Sales.Customer c    ON soh.CustomerID = c.CustomerID
JOIN Person.Person p     ON c.PersonID = p.BusinessEntityID
JOIN Person.Address a    ON soh.BillToAddressID = a.AddressID
WHERE p.PersonType = 'IN'
AND a.City IN (SELECT City FROM #CandidateCities);


-- I. Calculate change in IN customers and spending across two periods
DROP TABLE IF EXISTS #CityMetrics;

DECLARE
    @ReferenceDate  DATETIME,
    @StartPeriod1   DATETIME,
    @EndPeriod1     DATETIME,
    @StartPeriod2   DATETIME,
    @EndPeriod2     DATETIME;

-- Dynamically calculate time periods based on most recent order date
SELECT
    @ReferenceDate  = MAX(soh.OrderDate),
    @StartPeriod1   = DATEADD(MONTH, -6, MAX(soh.OrderDate)),
    @EndPeriod1     = MAX(soh.OrderDate),
    @StartPeriod2   = DATEADD(MONTH, -12, MAX(soh.OrderDate)),
    @EndPeriod2     = DATEADD(DAY, -1, DATEADD(MONTH, -6, MAX(soh.OrderDate)))
FROM Sales.SalesOrderHeader soh
JOIN Sales.Customer c    ON soh.CustomerID = c.CustomerID
JOIN Person.Person p     ON c.PersonID = p.BusinessEntityID
JOIN Person.Address a    ON soh.BillToAddressID = a.AddressID
WHERE p.PersonType = 'IN'
AND a.City IN (SELECT City FROM #CandidateCities);

SELECT
    cc.City,
    cc.StateProvince,
    cc.Country,
    cc.SC_Density,
    cc.IN_Density,
    -- Change in IN customers between periods
    COUNT(CASE WHEN soh.OrderDate BETWEEN @StartPeriod1 AND @EndPeriod1 THEN 1 END) -
    COUNT(CASE WHEN soh.OrderDate BETWEEN @StartPeriod2 AND @EndPeriod2 THEN 1 END) AS Change_IN_Customers,
    -- Change in IN spending between periods
    SUM(CASE WHEN soh.OrderDate BETWEEN @StartPeriod1 AND @EndPeriod1 THEN soh.TotalDue ELSE 0 END) -
    SUM(CASE WHEN soh.OrderDate BETWEEN @StartPeriod2 AND @EndPeriod2 THEN soh.TotalDue ELSE 0 END) AS Change_IN_Spending
INTO #CityMetrics
FROM #CandidateCities cc
JOIN Person.Address a        ON cc.City = a.City
JOIN Person.StateProvince sp ON a.StateProvinceID = sp.StateProvinceID
                             AND cc.StateProvince = sp.Name
JOIN Sales.SalesOrderHeader soh ON soh.BillToAddressID = a.AddressID
JOIN Sales.Customer c        ON soh.CustomerID = c.CustomerID
JOIN Person.Person p         ON c.PersonID = p.BusinessEntityID
WHERE p.PersonType = 'IN'
GROUP BY cc.City, cc.StateProvince, cc.Country, cc.SC_Density, cc.IN_Density;
GO

-- Verify
SELECT * FROM #CityMetrics ORDER BY IN_Density DESC;
GO

-- II. Normalise metrics and calculate weighted ranking score
DROP TABLE IF EXISTS #RankedCities;

SELECT
    City,
    StateProvince,
    SC_Density,
    IN_Density,
    Change_IN_Customers,
    Change_IN_Spending,
    -- Calculate weighted score using Z-score normalisation
    (((SC_Density - AVG(SC_Density) OVER()) / NULLIF(STDEV(SC_Density) OVER(), 0)) * -0.30) +
    (((IN_Density - AVG(IN_Density) OVER()) / NULLIF(STDEV(IN_Density) OVER(), 0)) * 0.45) +
    (((Change_IN_Spending - AVG(Change_IN_Spending) OVER()) / NULLIF(STDEV(Change_IN_Spending) OVER(), 0)) * 0.35) +
    (((Change_IN_Customers - AVG(Change_IN_Customers) OVER()) / NULLIF(STDEV(Change_IN_Customers) OVER(), 0)) * 0.20)
                                                AS FinalScore
INTO #RankedCities
FROM #CityMetrics;
GO

-- III. Final ranking
SELECT
    City,
    StateProvince,
    SC_Density,
    IN_Density,
    Change_IN_Customers,
    Change_IN_Spending,
    FinalScore,
    RANK() OVER (ORDER BY FinalScore DESC) AS Rank
FROM #RankedCities
ORDER BY Rank;
GO
