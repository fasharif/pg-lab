-- pg-lab, SQL Server chapter: the casebook fixes in SQL Server terms.
-- Written, not run: see docs/sqlserver.md. ONLINE = ON needs Enterprise or Developer edition.
SET NOCOUNT ON;
USE topflow;
GO

-- Case 1. LIKE 'prefix%' can seek an ordinary index: SQL Server needs no operator class.
CREATE INDEX audit_logs_action_idx ON dbo.audit_logs (action) WITH (ONLINE = ON);

-- Cases 2 and 3. The user's entries in time order.
CREATE INDEX audit_logs_userId_createdAt_idx ON dbo.audit_logs (userId, createdAt) WITH (ONLINE = ON);

-- Case 4. No trigram indexes in SQL Server: full-text search (word and prefix matching) on the
-- searched columns, with the query rewritten to CONTAINS (11_queries_after.sql). The container
-- needs the Full-Text Search package (sqlserver/Dockerfile).
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'topflow_search')
    CREATE FULLTEXT CATALOG topflow_search AS DEFAULT;
GO
CREATE FULLTEXT INDEX ON dbo.orders (orderNumber, purchaseOrderNumber, projectReference)
    KEY INDEX orders_pkey WITH CHANGE_TRACKING = AUTO;
CREATE FULLTEXT INDEX ON dbo.users (fullName) KEY INDEX users_pkey WITH CHANGE_TRACKING = AUTO;
CREATE FULLTEXT INDEX ON dbo.organizations (name) KEY INDEX organizations_pkey WITH CHANGE_TRACKING = AUTO;
GO

-- Cases 5, 6 and 7. Covering index for the dashboard: the INCLUDE columns sit in the leaf level.
CREATE INDEX orders_createdAt_idx ON dbo.orders (createdAt) INCLUDE (status, totalAmount) WITH (ONLINE = ON);

-- Case 8. The organisation's orders in date order.
CREATE INDEX orders_organizationId_createdAt_idx ON dbo.orders (organizationId, createdAt) WITH (ONLINE = ON);

-- Case 9. Filtered index (SQL Server's partial index). The optimiser matches it only when the
-- query's predicate is a literal, which is why the statement uses 1 and 0, not parameters.
CREATE INDEX products_categoryId_visible_idx ON dbo.products (categoryId)
    WHERE isActive = 1 AND isTradeOnly = 0 WITH (ONLINE = ON);

-- Case 10. Composite index; the single-column one becomes redundant.
CREATE INDEX quotations_status_updatedAt_idx ON dbo.quotations (status, updatedAt) WITH (ONLINE = ON);
DROP INDEX quotations_status_idx ON dbo.quotations;
GO

-- Full-text indexes are populated in the background: wait until the catalogue is idle.
DECLARE @waited INT = 0;
WHILE FULLTEXTCATALOGPROPERTY('topflow_search', 'PopulateStatus') <> 0 AND @waited < 600
BEGIN
    WAITFOR DELAY '00:00:01';
    SET @waited = @waited + 1;
END;
IF FULLTEXTCATALOGPROPERTY('topflow_search', 'PopulateStatus') <> 0
    THROW 50002, 'full-text population did not finish within 600 seconds', 1;
EXEC sys.sp_updatestats;
GO
