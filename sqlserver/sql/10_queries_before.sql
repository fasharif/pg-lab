-- pg-lab, SQL Server chapter: the ten casebook statements (casebook/*.toml) in T-SQL,
-- as the API would send them before the fixes. Written, not run: see docs/sqlserver.md.
--
-- Each statement is preceded by a "=== case NN" marker. With STATISTICS XML ON, sqlcmd prints
-- the actual execution plan after each statement, and STATISTICS IO prints logical reads per
-- table; python -m pglab mssql-report reads both. OPTION (RECOMPILE) plans each statement for
-- its actual values, like PostgreSQL's custom plans in the PostgreSQL casebook.
SET NOCOUNT ON;
USE topflow;

DECLARE @n_orgs BIGINT = (SELECT CAST([value] AS BIGINT) FROM dbo.lab_settings WHERE [key] = 'n_orgs');
DECLARE @anchor DATETIME2(3) = (SELECT CAST([value] AS DATETIME2(3)) FROM dbo.lab_settings WHERE [key] = 'anchor');
DECLARE @since DATETIME2(3) = DATEADD(DAY, -30, @anchor);
DECLARE @org_id VARCHAR(36) = dbo.lab_uid('org', 1);
DECLARE @audit_user VARCHAR(36) = dbo.lab_uid('user', 20 + 5 * @n_orgs + 50);
DECLARE @pattern NVARCHAR(40) = (SELECT CONCAT('%', SUBSTRING(MIN(orderNumber), 7, 9), '%') FROM dbo.orders);

SET STATISTICS IO ON;
SET STATISTICS XML ON;

PRINT '=== case 01';
SELECT COUNT(*) FROM dbo.audit_logs AS a
WHERE a.action LIKE 'procurement.quotation[_]approval%'
OPTION (RECOMPILE);

PRINT '=== case 02';
SELECT COUNT(*) FROM dbo.audit_logs AS a
WHERE a.userId = @audit_user
OPTION (RECOMPILE);

PRINT '=== case 03';
SELECT TOP (20) a.* FROM dbo.audit_logs AS a
WHERE a.userId = @audit_user
ORDER BY a.createdAt DESC
OPTION (RECOMPILE);

PRINT '=== case 04';
SELECT TOP (20) o.* FROM dbo.orders AS o
WHERE o.orderNumber LIKE @pattern
   OR o.purchaseOrderNumber LIKE @pattern
   OR o.projectReference LIKE @pattern
   OR o.userId IN (SELECT u.id FROM dbo.users AS u WHERE u.fullName LIKE @pattern)
   OR o.organizationId IN (SELECT g.id FROM dbo.organizations AS g WHERE g.name LIKE @pattern)
ORDER BY o.createdAt DESC
OPTION (RECOMPILE);

PRINT '=== case 05';
SELECT TOP (8) o.* FROM dbo.orders AS o
ORDER BY o.createdAt DESC
OPTION (RECOMPILE);

PRINT '=== case 06';
SELECT COUNT(*) FROM dbo.orders AS o
WHERE o.createdAt >= @since
OPTION (RECOMPILE);

PRINT '=== case 07';
SELECT SUM(o.totalAmount) FROM dbo.orders AS o
WHERE o.createdAt >= @since AND o.status <> 'CANCELLED'
OPTION (RECOMPILE);

PRINT '=== case 08';
SELECT TOP (20) o.* FROM dbo.orders AS o
WHERE o.organizationId = @org_id
ORDER BY o.createdAt DESC
OPTION (RECOMPILE);

PRINT '=== case 09';
SELECT c.*,
       (SELECT COUNT(*) FROM dbo.products AS p
        WHERE p.categoryId = c.id AND p.isActive = 1 AND p.isTradeOnly = 0) AS product_count
FROM dbo.categories AS c
ORDER BY c.displayOrder, c.name
OPTION (RECOMPILE);

PRINT '=== case 10';
SELECT TOP (20) q.* FROM dbo.quotations AS q
WHERE q.status = 'SENT'
ORDER BY q.updatedAt DESC
OPTION (RECOMPILE);

SET STATISTICS XML OFF;
SET STATISTICS IO OFF;
