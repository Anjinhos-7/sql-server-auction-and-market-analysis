# SQL Server Auction and Market Analysis

A T-SQL database extension project built on the AdventureWorks 2014 sample 
database, tackling two independent business problems through schema design, 
stored procedures, and data-driven analysis.

## Project Overview

| Initiative | Description |
|------------|-------------|
| [01 Auction System](01_auction_system/README.md) | Transactional auction system to clear old bicycle stock before new model launches |
| [02 Market Expansion Analysis](02_market_expansion_analysis/README.md) | Data-driven analysis to identify the two optimal US cities for new brick and mortar stores |

## Tech Stack
- **Language:** T-SQL
- **Database:** Microsoft SQL Server
- **Dataset:** AdventureWorks 2014

## Repository Structure

```
sql-server-auction-and-market-analysis/
│
├── README.md
├── 01_auction_system/
│   ├── README.md
│   ├── auction.sql
│   └── auction_system_erd.png
└── 02_market_expansion_analysis/
    ├── README.md
    ├── store_expansion.sql
    ├── top_10_candidate_cities.png
    └── distance_comparison_with_top_30_sc_cities.png
```

## Getting Started

### Prerequisites
- Microsoft SQL Server
- SQL Server Management Studio (SSMS)
- AdventureWorks 2014 database - download it [here](https://github.com/Microsoft/sql-server-samples/releases/tag/adventureworks)

### How to Run
1. Download and restore the AdventureWorks 2014 database
2. Connect to your SQL Server instance in SSMS
3. Select your AdventureWorks database
4. Open and execute the relevant `.sql` file for each initiative

## Key Highlights
- Fully transactional auction system with concurrency handling designed 
  to withstand high load during Black Friday
- Schema extension follows best practices including idempotent scripts, 
  lookup tables, and proper foreign key constraints
- Market analysis uses Z-score normalisation and weighted scoring to 
  produce defensible, data-driven city recommendations
- Intermediate results materialised using temp tables rather than chained 
  views for performance and clarity
- Geographic analysis revealed that Adventure Works' reseller and individual 
  customer bases operate in largely distinct markets, with SC customers 
  concentrated in the South and Midwest while IN customers are predominantly 
  on the West Coast
