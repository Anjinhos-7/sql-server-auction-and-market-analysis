-- ============================================================
-- Adventure Works | Auction System
-- Initiative 1: Stock Clearance
-- ============================================================
-- Description: Extends the AdventureWorks schema to support
--              an online auction system for stock clearance.
-- ============================================================

-- NOTE: Update the database name below to match your environment
USE [AdventureWorks]
GO

-- ============================================================
-- Phase 1: Schema Creation
-- ============================================================

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Auction')
BEGIN
    EXEC('CREATE SCHEMA Auction');
END
GO

-- ============================================================
-- Phase 2: Tables Creation
-- ============================================================

-- I. Drop tables in reverse dependency order for idempotency
DROP TABLE IF EXISTS Auction.Bids;
DROP TABLE IF EXISTS Auction.ProductsOnAuction;
DROP TABLE IF EXISTS Auction.BiddingStatus;
DROP TABLE IF EXISTS Auction.Configuration;
GO


-- II. Create Configuration Table
-- Stores global auction thresholds, configurable without schema changes
CREATE TABLE Auction.Configuration
(
    MinimumBidIncrement MONEY        NOT NULL,  -- Minimum amount a bid must increase by
    MaxBidMultiplier    FLOAT        NOT NULL,  -- Maximum bid as a multiplier of list price (1.0 = 100%)
    AuctionStartDate    DATETIME     NOT NULL,  -- Campaign start date
    AuctionEndDate      DATETIME     NOT NULL   -- Campaign end date
);
GO

-- Pre-populate with default values (idempotent)
IF NOT EXISTS (SELECT 1 FROM Auction.Configuration)
BEGIN
    INSERT INTO Auction.Configuration (MinimumBidIncrement, MaxBidMultiplier, AuctionStartDate, AuctionEndDate)
    VALUES (0.05, 1.0, '2025-11-16 00:00:00', '2025-11-30 23:59:59');
END
GO


-- III. Create BiddingStatus Lookup Table
-- Defines valid auction status values
CREATE TABLE Auction.BiddingStatus
(
    StatusID    INT          PRIMARY KEY,
    StatusName  VARCHAR(50)  NOT NULL
);
GO

-- Pre-populate with default values (idempotent)
IF NOT EXISTS (SELECT 1 FROM Auction.BiddingStatus)
BEGIN
    INSERT INTO Auction.BiddingStatus (StatusID, StatusName)
    VALUES
        (0, 'Cancelled'),
        (1, 'Closed'),
        (2, 'Active');
END
GO


-- IV. Create ProductsOnAuction Table
-- Tracks products listed for auction and their current state
CREATE TABLE Auction.ProductsOnAuction
(
    ProductID           INT      PRIMARY KEY,
    StartDate           DATETIME NOT NULL DEFAULT GETUTCDATE(),
    ExpireDate          DATETIME NOT NULL,
    InitialBidPrice     MONEY    NOT NULL,
    MaximumBidPrice     MONEY    NOT NULL,
    CurrentBidPrice     MONEY    NULL,        -- Tracks highest bid for fast reads under high load
    WinnerCustomerID    INT      NULL,        -- Populated when auction closes
    StatusID            INT      NOT NULL,
    FOREIGN KEY (ProductID)         REFERENCES Production.Product(ProductID),
    FOREIGN KEY (StatusID)          REFERENCES Auction.BiddingStatus(StatusID),
    FOREIGN KEY (WinnerCustomerID)  REFERENCES Sales.Customer(CustomerID)
);
GO


-- V. Create Bids Table
-- Records every bid placed by customers
CREATE TABLE Auction.Bids
(
    BidID       INT      IDENTITY PRIMARY KEY,
    ProductID   INT      NOT NULL,
    CustomerID  INT      NOT NULL,
    BidAmount   MONEY    NOT NULL,
    BidTime     DATETIME NOT NULL DEFAULT GETUTCDATE(),
    FOREIGN KEY (ProductID)   REFERENCES Auction.ProductsOnAuction(ProductID),
    FOREIGN KEY (CustomerID)  REFERENCES Sales.Customer(CustomerID)
);
GO


-- VI. Confirm Table Creation
SELECT * FROM Auction.Configuration
SELECT * FROM Auction.BiddingStatus
SELECT * FROM Auction.ProductsOnAuction
SELECT * FROM Auction.Bids
GO

-- ============================================================
-- Phase 3: Stored Procedures Creation
-- ============================================================

-- I. uspAddProductToAuction
-- Adds a product to the auction with optional expiry date and initial bid price
CREATE OR ALTER PROCEDURE Auction.uspAddProductToAuction
    @ProductID      INT,
    @ExpireDate     DATETIME = NULL,
    @InitialBidPrice MONEY   = NULL
AS
BEGIN
-- Set up environment, error handling, and transaction management
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Declare variables
        DECLARE
            @ListPrice          MONEY,
            @MakeFlag           BIT,
            @MaximumBidPrice    MONEY,
            @AuctionStartDate   DATETIME,
            @AuctionEndDate     DATETIME;

        -- Retrieve configuration
        SELECT
            @AuctionStartDate   = AuctionStartDate,
            @AuctionEndDate     = AuctionEndDate
        FROM Auction.Configuration;

        -- Retrieve product details
        SELECT
            @ListPrice  = ListPrice,
            @MakeFlag   = MakeFlag
        FROM Production.Product
        WHERE ProductID = @ProductID;

-- Primary Validations and Checks
        -- Product must exist
        IF @ListPrice IS NULL
        BEGIN
            RAISERROR('Product does not exist.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Product must be currently commercialised
        IF NOT EXISTS (
            SELECT 1 FROM Production.Product
            WHERE ProductID = @ProductID
            AND SellEndDate IS NULL
            AND DiscontinuedDate IS NULL
        )
        BEGIN
            RAISERROR('Product is not eligible for auction.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Product must not already be active in auction
        IF EXISTS (
            SELECT 1 FROM Auction.ProductsOnAuction
            WHERE ProductID = @ProductID
            AND StatusID = 2 -- Active
        )
        BEGIN
            RAISERROR('Product is already active in an auction.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

         -- Product must not have been previously closed
        IF EXISTS (
            SELECT 1 FROM Auction.ProductsOnAuction
            WHERE ProductID = @ProductID
            AND StatusID = 1 -- Closed
        )
        BEGIN
            RAISERROR('Product has already been sold at auction and cannot be relisted.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

-- Apply business logic: 
        -- Set initial bid price if not provided
        IF @InitialBidPrice IS NULL
        BEGIN
            SET @InitialBidPrice =
                CASE
                    WHEN @MakeFlag = 0 THEN @ListPrice * 0.75  -- Not manufactured in-house
                    ELSE @ListPrice * 0.50                      -- Manufactured in-house
                END;
        END

        -- Set expiry date if not provided
        IF @ExpireDate IS NULL
        BEGIN
            SET @ExpireDate = 
                CASE
                    WHEN DATEADD(DAY, 7, GETUTCDATE()) > @AuctionEndDate THEN @AuctionEndDate
                    ELSE DATEADD(DAY, 7, GETUTCDATE())
                END;
        END

        -- Expiry date must be within auction window
        IF @ExpireDate NOT BETWEEN @AuctionStartDate AND @AuctionEndDate
        BEGIN
            RAISERROR('Expiry date is outside the allowed auction window.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

-- Calculate maximum bid price
        SELECT @MaximumBidPrice = @ListPrice * MaxBidMultiplier
        FROM Auction.Configuration;

-- Insert product into auction
        INSERT INTO Auction.ProductsOnAuction (
            ProductID,
            ExpireDate,
            InitialBidPrice,
            MaximumBidPrice,
            StatusID
        )
        VALUES (
            @ProductID,
            @ExpireDate,
            @InitialBidPrice,
            @MaximumBidPrice,
            2 -- Active
        );

        PRINT 'Product successfully added to auction.';
        COMMIT TRANSACTION;
    END TRY

-- Error Handling
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO


-- II. uspTryBidProduct
-- Places a bid on behalf of a customer
CREATE OR ALTER PROCEDURE Auction.uspTryBidProduct
    @ProductID  INT,
    @CustomerID INT,
    @BidAmount  MONEY = NULL
AS
BEGIN
-- Set up environment, error handling, and transaction management
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Declare variables
        DECLARE
            @InitialBidPrice    MONEY,
            @MaximumBidPrice    MONEY,
            @CurrentBidPrice    MONEY,
            @MinimumBidIncrement MONEY,
            @ProductStatusID    INT,
            @ExpireDate         DATETIME,
            @AuctionStartDate   DATETIME,
            @AuctionEndDate     DATETIME;

        -- Retrieve configuration
        SELECT
            @MinimumBidIncrement    = MinimumBidIncrement,
            @AuctionStartDate       = AuctionStartDate,
            @AuctionEndDate         = AuctionEndDate
        FROM Auction.Configuration;

        -- Retrieve product auction details
        SELECT
            @InitialBidPrice    = InitialBidPrice,
            @MaximumBidPrice    = MaximumBidPrice,
            @CurrentBidPrice    = CurrentBidPrice,
            @ProductStatusID    = StatusID,
            @ExpireDate         = ExpireDate
        FROM Auction.ProductsOnAuction
        WHERE ProductID = @ProductID;

-- Primary Validations and Checks
        -- Product must exist in auction
        IF @ProductStatusID IS NULL
        BEGIN
            RAISERROR('Product not found in auction.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Product must be active
        IF @ProductStatusID <> 2
        BEGIN
            RAISERROR('Product is not active in auction.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Current date must be within auction window
        IF GETUTCDATE() NOT BETWEEN @AuctionStartDate AND @ExpireDate
        BEGIN
            RAISERROR('Current time is outside the auction window.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Customer must exist
        IF NOT EXISTS (SELECT 1 FROM Sales.Customer WHERE CustomerID = @CustomerID)
        BEGIN
            RAISERROR('Customer does not exist.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

-- Apply business logic
        -- Set bid amount if not provided
        IF @BidAmount IS NULL
        BEGIN
            SET @BidAmount =
                CASE
                    WHEN @CurrentBidPrice IS NULL THEN @InitialBidPrice
                    ELSE @CurrentBidPrice + @MinimumBidIncrement
                END;
        END

        -- Validate bid amount meets minimum requirement
        IF @CurrentBidPrice IS NULL AND @BidAmount < @InitialBidPrice
        BEGIN
            RAISERROR('Bid must be at least the initial bid price.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @CurrentBidPrice IS NOT NULL AND @BidAmount < (@CurrentBidPrice + @MinimumBidIncrement)
        BEGIN
            RAISERROR('Bid does not meet the minimum increment over the current bid.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Validate bid does not exceed maximum
        IF @BidAmount > @MaximumBidPrice
        BEGIN
            RAISERROR('Bid exceeds the maximum allowed price.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

-- Insert bid
        INSERT INTO Auction.Bids (ProductID, CustomerID, BidAmount, BidTime)
        VALUES (@ProductID, @CustomerID, @BidAmount, GETUTCDATE());

-- Update CurrentBidPrice on ProductsOnAuction
        UPDATE Auction.ProductsOnAuction
        SET CurrentBidPrice = @BidAmount
        WHERE ProductID = @ProductID;

-- Close auction if maximum bid price has been reached
        IF @BidAmount = @MaximumBidPrice
        BEGIN
            UPDATE Auction.ProductsOnAuction
            SET StatusID = 1, -- Closed
                WinnerCustomerID = @CustomerID
            WHERE ProductID = @ProductID;

            PRINT 'Maximum bid reached. Auction closed.';
        END

        PRINT 'Bid successfully placed.';
        COMMIT TRANSACTION;
    END TRY
-- Error Handling
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO


-- III. uspRemoveProductFromAuction
-- Removes a product from auction, preserving bid history
CREATE OR ALTER PROCEDURE Auction.uspRemoveProductFromAuction
    @ProductID INT
AS
BEGIN
-- Set up environment, error handling, and transaction management
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Declare variables
        DECLARE @ProductStatusID INT;

        -- Retrieve current auction status
        SELECT @ProductStatusID = StatusID
        FROM Auction.ProductsOnAuction
        WHERE ProductID = @ProductID;

-- Primary Validations and Checks
        -- Product must exist in auction
        IF @ProductStatusID IS NULL
        BEGIN
            RAISERROR('Product not found in auction.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Product must not already be cancelled
        IF @ProductStatusID = 0
        BEGIN
            RAISERROR('Product has already been cancelled.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Product must not already be closed
        IF @ProductStatusID = 1
        BEGIN
            RAISERROR('Product auction has already been closed and cannot be removed.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

-- Apply business logic
        -- Set product status to Cancelled
        -- Bid history is preserved as records remain in Auction.Bids
        UPDATE Auction.ProductsOnAuction
        SET StatusID = 0 -- Cancelled
        WHERE ProductID = @ProductID;

        PRINT 'Product successfully removed from auction.';
        COMMIT TRANSACTION;
    END TRY
-- Error Handling
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO


-- IV. uspListBidsOffersHistory
-- Returns a customer's bid history for a given time period
CREATE OR ALTER PROCEDURE Auction.uspListBidsOffersHistory
    @CustomerID INT,
    @StartTime  DATETIME,
    @EndTime    DATETIME,
    @Active     BIT = 1  -- Default: only active auctions
AS
BEGIN
-- Set up environment, error handling, and transaction management
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Declare variables
        DECLARE
            @AuctionStartDate   DATETIME,
            @AuctionEndDate     DATETIME;

        -- Retrieve configuration
        SELECT
            @AuctionStartDate   = AuctionStartDate,
            @AuctionEndDate     = AuctionEndDate
        FROM Auction.Configuration;

-- Primary Validations and Checks
        -- Parameters cannot be null
        IF @CustomerID IS NULL OR @StartTime IS NULL OR @EndTime IS NULL
        BEGIN
            RAISERROR('Parameters cannot be null.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Customer must exist
        IF NOT EXISTS (SELECT 1 FROM Sales.Customer WHERE CustomerID = @CustomerID)
        BEGIN
            RAISERROR('Customer does not exist.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Time frame must be within auction window
        IF @StartTime NOT BETWEEN @AuctionStartDate AND @AuctionEndDate
        OR @EndTime NOT BETWEEN @AuctionStartDate AND @AuctionEndDate
        BEGIN
            RAISERROR('Time frame is outside the auction window.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Start time must be before end time
        IF @StartTime > @EndTime
        BEGIN
            RAISERROR('Start time must be before end time.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

-- Apply business logic
        -- Return bid history based on @Active flag
        SELECT
            b.BidID,
            b.ProductID,
            p.Name                  AS ProductName,
            b.CustomerID,
            b.BidAmount,
            b.BidTime,
            bs.StatusName           AS AuctionStatus,
            poa.InitialBidPrice,
            poa.MaximumBidPrice,
            poa.CurrentBidPrice,
            poa.ExpireDate
        FROM Auction.Bids b
        JOIN Auction.ProductsOnAuction poa ON b.ProductID = poa.ProductID
        JOIN Auction.BiddingStatus bs      ON poa.StatusID = bs.StatusID
        JOIN Production.Product p          ON poa.ProductID = p.ProductID
        WHERE b.CustomerID = @CustomerID
        AND b.BidTime BETWEEN @StartTime AND @EndTime
        AND (@Active = 0 OR poa.StatusID = 2); -- If Active=1, only return active auctions

        COMMIT TRANSACTION;
    END TRY
-- Error Handling
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO


-- V. uspUpdateProductAuctionStatus
-- Updates auction status for all expired active products
-- To be manually invoked before processing orders for dispatch
CREATE OR ALTER PROCEDURE Auction.uspUpdateProductAuctionStatus
AS
BEGIN
-- Set up environment, error handling, and transaction management
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Declare variables
        DECLARE @UpdatedRows INT;

-- Apply business logic
        -- Close all active auctions that have passed their expiry date
        UPDATE Auction.ProductsOnAuction
        SET StatusID = 1 -- Closed
        WHERE StatusID = 2 -- Active
        AND ExpireDate < GETUTCDATE();

        SET @UpdatedRows = @@ROWCOUNT;

-- Report results
        IF @UpdatedRows > 0
            PRINT CAST(@UpdatedRows AS VARCHAR) + ' auction(s) successfully closed.';
        ELSE
            PRINT 'No expired auctions found.';

        COMMIT TRANSACTION;
    END TRY
-- Error Handling
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
