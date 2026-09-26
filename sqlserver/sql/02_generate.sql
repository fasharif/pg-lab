-- pg-lab, SQL Server chapter: data generator (T-SQL, SQL Server 2022 GENERATE_SERIES).
-- Written, not run: see docs/sqlserver.md.
--
-- Reads SCALE from dbo.lab_settings (./lab sqlserver seed inserts it after 01_schema.sql).
-- Follows the distributions of sql/generate/generate.sql (skewed customers, orders in time
-- order over two years, statuses by age, audit actions by weight) with SQL Server's hash
-- functions, so the rows are not identical to the PostgreSQL data set. Document numbers use
-- seven digits (TopFlow uses six) so that SCALE=50000000 cannot run out within a year.
SET NOCOUNT ON;
USE topflow;
GO

-- Deterministic number in [0, 1) from (n, salt).
CREATE OR ALTER FUNCTION dbo.lab_rnd (@n BIGINT, @salt INT)
RETURNS FLOAT
WITH SCHEMABINDING
AS
BEGIN
    RETURN (CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', CONCAT(@salt, ':', @n)), 1, 4) AS INT) AS BIGINT)
            & 2147483647) / 2147483648.0;
END;
GO

-- Deterministic UUID-shaped text id.
CREATE OR ALTER FUNCTION dbo.lab_uid (@kind VARCHAR(20), @n BIGINT)
RETURNS VARCHAR(36)
WITH SCHEMABINDING
AS
BEGIN
    RETURN LOWER(CONVERT(VARCHAR(36), CAST(HASHBYTES('MD5', CONCAT(@kind, ':', @n)) AS UNIQUEIDENTIFIER)));
END;
GO

DECLARE @scale BIGINT = (SELECT CAST([value] AS BIGINT) FROM dbo.lab_settings WHERE [key] = 'scale');
IF @scale IS NULL OR @scale < 1000 OR @scale > 100000000
    THROW 50001, 'lab_settings.scale must be between 1000 and 100000000', 1;

DECLARE @n_products BIGINT = CASE WHEN @scale / 200 < 1000 THEN 1000
                                  WHEN @scale / 200 > 50000 THEN 50000
                                  ELSE @scale / 200 END;
DECLARE @n_orgs BIGINT = CASE WHEN @scale / 2000 < 50 THEN 50 ELSE @scale / 2000 END;
DECLARE @n_retail BIGINT = CASE WHEN @scale / 100 < 200 THEN 200 ELSE @scale / 100 END;
DECLARE @n_orders BIGINT = CASE WHEN @scale / 5 < 1000 THEN 1000 ELSE @scale / 5 END;
DECLARE @n_rfqs BIGINT = CASE WHEN @scale / 8 < 500 THEN 500 ELSE @scale / 8 END;
DECLARE @n_audit BIGINT = @scale;
DECLARE @anchor DATETIME2(3) = CAST(DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSUTCDATETIME()), 0) AS DATETIME2(3));

DELETE FROM dbo.lab_settings WHERE [key] IN ('anchor', 'n_orgs');
INSERT INTO dbo.lab_settings ([key], [value])
VALUES ('anchor', CONVERT(NVARCHAR(30), @anchor, 126)),
       ('n_orgs', CAST(@n_orgs AS NVARCHAR(20)));

-- Categories: eight parents with four children each.
INSERT INTO dbo.categories (id, name, slug, displayOrder, parentId)
SELECT p.value,
       CHOOSE(p.value, N'Sprinklers & Rotors', N'Drip & Micro Irrigation', N'Pipes & Fittings',
              N'Valves', N'Filtration', N'Controllers & Sensors', N'Pumps & Water Supply',
              N'Landscape Supplies'),
       CONCAT('category-', p.value), p.value, NULL
FROM GENERATE_SERIES(1, 8) AS p;

INSERT INTO dbo.categories (id, name, slug, displayOrder, parentId)
SELECT 8 + (p.value - 1) * 4 + c.value,
       CONCAT(pc.name, N' - ', CHOOSE(c.value, N'Residential', N'Commercial', N'Agricultural', N'Accessories')),
       CONCAT('category-', 8 + (p.value - 1) * 4 + c.value), c.value, p.value
FROM GENERATE_SERIES(1, 8) AS p
CROSS JOIN GENERATE_SERIES(1, 4) AS c
JOIN dbo.categories AS pc ON pc.id = p.value;

-- Products.
INSERT INTO dbo.products WITH (TABLOCK)
    (id, sku, name, categoryId, description, brand, unitPrice, stockQuantity, lowStockThreshold,
     isActive, isTradeOnly, createdAt, updatedAt)
SELECT dbo.lab_uid('product', g.value),
       CONCAT('TFL-', RIGHT(CONCAT('000000', g.value), 6)),
       CONCAT(t.product_type, N' ', CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(g.value, 22) * 6) AS INT),
                                          N'16 mm', N'25 mm', N'32 mm', N'63 mm', N'1 in', N'2 in')),
       9 + (g.value - 1) % 32,
       CONCAT(t.product_type, N' for ', CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(g.value, 40) * 4) AS INT),
                                             N'villa gardens', N'public parks', N'date palm farms',
                                             N'hotel landscapes'), N'.'),
       CASE WHEN dbo.lab_rnd(g.value, 24) < 0.1 THEN NULL
            ELSE CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(g.value, 25) * 8) AS INT), N'Aqualine', N'Dunewell',
                        N'Rainmark', N'Hydroseal', N'Palmtech', N'Sahara Pro', N'IrriCore',
                        N'Wadi Systems') END,
       CAST(5 + 1995 * POWER(dbo.lab_rnd(g.value, 31), 3) AS DECIMAL(10, 2)),
       CAST(FLOOR(500 * dbo.lab_rnd(g.value, 33)) AS INT),
       10 + CAST(FLOOR(40 * dbo.lab_rnd(g.value, 36)) AS INT),
       CASE WHEN dbo.lab_rnd(g.value, 34) < 0.97 THEN 1 ELSE 0 END,
       CASE WHEN dbo.lab_rnd(g.value, 35) < 0.15 THEN 1 ELSE 0 END,
       DATEADD(DAY, -1100, @anchor), DATEADD(DAY, -1100, @anchor)
FROM GENERATE_SERIES(CAST(1 AS BIGINT), @n_products) AS g
CROSS APPLY (SELECT CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(g.value, 21) * 10) AS INT),
                           N'Pop-up Sprinkler', N'Gear-driven Rotor', N'Drip Line', N'Solenoid Valve',
                           N'Ball Valve', N'Disc Filter', N'HDPE Pipe', N'Electrofusion Coupler',
                           N'Irrigation Controller', N'Booster Pump') AS product_type) AS t;

-- Organisations: organisation 1 is the largest customer, as in the PostgreSQL data set.
INSERT INTO dbo.organizations (id, name, status, discountRate, createdAt, updatedAt)
SELECT dbo.lab_uid('org', g.value),
       CONCAT(CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(g.value, 61) * 8) AS INT), N'Green', N'Oasis', N'Desert',
                     N'Palm', N'Crescent', N'Falcon', N'Pearl', N'Cedar'),
              N' ',
              CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(g.value, 62) * 5) AS INT), N'Landscaping', N'Irrigation',
                     N'Contracting', N'Facilities', N'Projects'),
              N' LLC'),
       CASE WHEN g.value <= 3 OR dbo.lab_rnd(g.value, 67) < 0.85 THEN 'ACTIVE'
            WHEN dbo.lab_rnd(g.value, 67) < 0.95 THEN 'PENDING_VERIFICATION'
            ELSE 'SUSPENDED' END,
       FLOOR(dbo.lab_rnd(g.value, 42) * 5) * 2.5,
       c.created, c.created
FROM GENERATE_SERIES(CAST(1 AS BIGINT), @n_orgs) AS g
CROSS APPLY (SELECT DATEADD(SECOND, CAST((g.value - 1 + dbo.lab_rnd(g.value, 68)) * (900 * 86400.0 / @n_orgs) AS INT),
                            DATEADD(DAY, -900, @anchor)) AS created) AS c;

-- Users: 20 staff, five members per organisation, then retail customers.
INSERT INTO dbo.users WITH (TABLOCK) (id, email, fullName, phoneNumber, role, isActive, createdAt, updatedAt)
SELECT dbo.lab_uid('user', u.n), u.email,
       CONCAT(CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(u.n, 71) * 10) AS INT), N'Aisha', N'Omar', N'Fatima',
                     N'Yousef', N'Mariam', N'Priya', N'Arjun', N'Sara', N'James', N'Hiba'),
              N' ',
              CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(u.n, 72) * 10) AS INT), N'Al Mansoori', N'Khan', N'Rahman',
                     N'Haddad', N'Nair', N'Sharma', N'Smith', N'Qureshi', N'Menon', N'Saleh')),
       CONCAT('+9715', RIGHT(CONCAT('00000000', CAST(FLOOR(dbo.lab_rnd(u.n, 93) * 100000000) AS BIGINT)), 8)),
       u.role, 1, u.created, u.created
FROM (
    SELECT g.value AS n, CONCAT('staff', g.value, '@topflow-lab.example') AS email,
           CASE WHEN g.value <= 2 THEN 'ADMIN' WHEN g.value <= 12 THEN 'SALES' ELSE 'WAREHOUSE' END AS role,
           DATEADD(DAY, -1000, @anchor) AS created
    FROM GENERATE_SERIES(CAST(1 AS BIGINT), CAST(20 AS BIGINT)) AS g
    UNION ALL
    SELECT 20 + (o.value - 1) * 5 + m.value, CONCAT('member', 20 + (o.value - 1) * 5 + m.value, '@example.com'),
           'CUSTOMER', DATEADD(DAY, -900, @anchor)
    FROM GENERATE_SERIES(CAST(1 AS BIGINT), @n_orgs) AS o
    CROSS JOIN GENERATE_SERIES(CAST(1 AS BIGINT), CAST(5 AS BIGINT)) AS m
    UNION ALL
    SELECT 20 + 5 * @n_orgs + r.value, CONCAT('customer', 20 + 5 * @n_orgs + r.value, '@example.com'),
           'CUSTOMER', DATEADD(DAY, -900, @anchor)
    FROM GENERATE_SERIES(CAST(1 AS BIGINT), @n_retail) AS r
) AS u;

-- Orders, in time order over the last 730 days.
INSERT INTO dbo.orders WITH (TABLOCK)
    (id, orderNumber, userId, organizationId, status, channel, totalAmount, purchaseOrderNumber,
     projectReference, shippingAddress, createdAt, updatedAt)
SELECT dbo.lab_uid('order', g.value),
       CONCAT('TF-SO-', YEAR(c.created), '-',
              RIGHT(CONCAT('0000000', ROW_NUMBER() OVER (PARTITION BY YEAR(c.created) ORDER BY g.value)), 7)),
       CASE WHEN a.b2b = 1 THEN dbo.lab_uid('user', 20 + (a.org - 1) * 5 + 1 + CAST(FLOOR(dbo.lab_rnd(g.value, 9) * 5) AS INT))
            ELSE dbo.lab_uid('user', 20 + 5 * @n_orgs + a.retail) END,
       CASE WHEN a.b2b = 1 THEN dbo.lab_uid('org', a.org) END,
       s.status,
       CASE WHEN a.b2b = 1 THEN 'B2B' ELSE 'RETAIL' END,
       CAST(20 + 5000 * POWER(dbo.lab_rnd(g.value, 14), 2) AS DECIMAL(12, 2)),
       CASE WHEN a.b2b = 1 THEN CONCAT('PO-', RIGHT(CONCAT('00000', a.org), 5), '-',
                                       RIGHT(CONCAT('00000', g.value % 100000), 5)) END,
       CASE WHEN a.b2b = 1 AND dbo.lab_rnd(g.value, 10) < 0.7 THEN
            CONCAT(CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(g.value, 81) * 8) AS INT), N'Al Reem', N'Saadiyat',
                          N'Yas', N'Khalifa City', N'Jumeirah', N'Dubai Hills', N'Al Ain', N'Masdar'),
                   N' ',
                   CHOOSE(1 + CAST(FLOOR(dbo.lab_rnd(g.value, 82) * 5) AS INT), N'Villa', N'Tower', N'Park',
                          N'School', N'Hotel'),
                   N' ', 1 + CAST(FLOOR(dbo.lab_rnd(g.value, 83) * 40) AS INT)) END,
       CONCAT(N'Plot ', 1 + CAST(FLOOR(dbo.lab_rnd(g.value, 11) * 300) AS INT), N', Abu Dhabi'),
       c.created, c.created
FROM GENERATE_SERIES(CAST(1 AS BIGINT), @n_orders) AS g
CROSS APPLY (SELECT DATEADD(SECOND, CAST((g.value - 1 + dbo.lab_rnd(g.value, 1)) * (730 * 86400.0 / @n_orders) AS INT),
                            DATEADD(DAY, -730, @anchor)) AS created,
                    dbo.lab_rnd(g.value, 4) AS r4) AS c
CROSS APPLY (SELECT CASE WHEN dbo.lab_rnd(g.value, 2) < 0.6 THEN 1 ELSE 0 END AS b2b,
                    1 + CAST(FLOOR(@n_orgs * POWER(dbo.lab_rnd(g.value, 3), 2.5)) AS BIGINT) AS org,
                    1 + CAST(FLOOR(@n_retail * POWER(dbo.lab_rnd(g.value, 5), 1.5)) AS BIGINT) AS retail) AS a
CROSS APPLY (SELECT CASE
        WHEN DATEDIFF(DAY, c.created, @anchor) > 21 THEN
            CASE WHEN c.r4 < 0.92 THEN 'DELIVERED' ELSE 'CANCELLED' END
        WHEN DATEDIFF(DAY, c.created, @anchor) > 7 THEN
            CASE WHEN c.r4 < 0.60 THEN 'DELIVERED' WHEN c.r4 < 0.80 THEN 'DISPATCHED'
                 WHEN c.r4 < 0.92 THEN 'PROCESSING' ELSE 'CANCELLED' END
        ELSE
            CASE WHEN c.r4 < 0.20 THEN 'PENDING_PAYMENT' WHEN c.r4 < 0.50 THEN 'CONFIRMED'
                 WHEN c.r4 < 0.75 THEN 'PROCESSING' WHEN c.r4 < 0.90 THEN 'DISPATCHED'
                 WHEN c.r4 < 0.95 THEN 'CANCELLED' ELSE 'DELIVERED' END
    END AS status) AS s;

-- Quotations: open ones keep the status SENT until someone opens them after their validity.
INSERT INTO dbo.quotations WITH (TABLOCK)
    (id, number, revision, organizationId, customerId, status, total, validUntil, createdAt, updatedAt)
SELECT dbo.lab_uid('quotation', g.value),
       CONCAT('TF-QT-', YEAR(c.created), '-',
              RIGHT(CONCAT('0000000', ROW_NUMBER() OVER (PARTITION BY YEAR(c.created) ORDER BY g.value)), 7)),
       1 + CASE WHEN dbo.lab_rnd(g.value, 123) < 0.2 THEN 1 ELSE 0 END,
       CASE WHEN a.web = 0 THEN dbo.lab_uid('org', a.org) END,
       CASE WHEN a.web = 0 THEN dbo.lab_uid('user', 20 + (a.org - 1) * 5 + 1) END,
       CASE WHEN DATEDIFF(DAY, c.created, @anchor) > 30 THEN
                CASE WHEN c.r < 0.35 THEN 'ACCEPTED' WHEN c.r < 0.60 THEN 'EXPIRED' WHEN c.r < 0.75 THEN 'SENT'
                     WHEN c.r < 0.87 THEN 'REJECTED' ELSE 'SUPERSEDED' END
            ELSE
                CASE WHEN c.r < 0.10 THEN 'DRAFT' WHEN c.r < 0.55 THEN 'SENT' WHEN c.r < 0.75 THEN 'PENDING_APPROVAL'
                     WHEN c.r < 0.90 THEN 'REVISION_REQUESTED' ELSE 'ACCEPTED' END
       END,
       CAST(100 + 50000 * POWER(dbo.lab_rnd(g.value, 113), 2) AS DECIMAL(12, 2)),
       DATEADD(DAY, 30, c.created),
       c.created,
       CASE WHEN DATEADD(DAY, CAST(FLOOR(dbo.lab_rnd(g.value, 124) * 10) AS INT), c.created) > @anchor THEN @anchor
            ELSE DATEADD(DAY, CAST(FLOOR(dbo.lab_rnd(g.value, 124) * 10) AS INT), c.created) END
FROM GENERATE_SERIES(CAST(1 AS BIGINT), @n_rfqs) AS g
CROSS APPLY (SELECT DATEADD(SECOND, CAST((g.value - 1 + dbo.lab_rnd(g.value, 101)) * (730 * 86400.0 / @n_rfqs) AS INT),
                            DATEADD(DAY, -730, @anchor)) AS created,
                    dbo.lab_rnd(g.value, 112) AS r) AS c
CROSS APPLY (SELECT CASE WHEN dbo.lab_rnd(g.value, 102) < 0.25 THEN 1 ELSE 0 END AS web,
                    1 + CAST(FLOOR(@n_orgs * POWER(dbo.lab_rnd(g.value, 103), 2.5)) AS BIGINT) AS org) AS a;

-- Audit trail: actions weighted as in TopFlow's audit-actions.ts.
INSERT INTO dbo.audit_logs WITH (TABLOCK)
    (id, userId, action, entityType, entityId, details, ipAddress, organizationId, createdAt)
SELECT dbo.lab_uid('audit', g.value),
       dbo.lab_uid('user', 1 + CAST(FLOOR((20 + 5 * @n_orgs + @n_retail) * POWER(dbo.lab_rnd(g.value, 53), 2.0)) AS BIGINT)),
       w.action, w.entity_type,
       dbo.lab_uid(LOWER(w.entity_type), 1 + CAST(FLOOR(@n_orders * dbo.lab_rnd(g.value, 54)) AS BIGINT)),
       N'{"client": "web"}',
       CONCAT('10.', CAST(FLOOR(256 * dbo.lab_rnd(g.value, 57)) AS INT), '.0.1'),
       CASE WHEN dbo.lab_rnd(g.value, 58) < 0.5
            THEN dbo.lab_uid('org', 1 + CAST(FLOOR(@n_orgs * POWER(dbo.lab_rnd(g.value, 59), 2.5)) AS BIGINT)) END,
       DATEADD(SECOND, CAST((g.value - 1 + dbo.lab_rnd(g.value, 56)) * (730 * 86400.0 / @n_audit) AS INT),
               DATEADD(DAY, -730, @anchor))
FROM GENERATE_SERIES(CAST(1 AS BIGINT), @n_audit) AS g
CROSS APPLY (SELECT CAST(FLOOR(dbo.lab_rnd(g.value, 51) * 100) AS INT) AS bucket) AS b
CROSS APPLY (SELECT CASE
        WHEN b.bucket < 15 THEN 'auth.login'
        WHEN b.bucket < 35 THEN 'orders.status_changed'
        WHEN b.bucket < 45 THEN 'orders.placed'
        WHEN b.bucket < 50 THEN 'orders.payment_recorded'
        WHEN b.bucket < 52 THEN 'orders.cancelled'
        WHEN b.bucket < 60 THEN 'procurement.rfq_submitted'
        WHEN b.bucket < 66 THEN 'procurement.rfq_updated'
        WHEN b.bucket < 72 THEN 'procurement.quotation_created'
        WHEN b.bucket < 78 THEN 'procurement.quotation_sent'
        WHEN b.bucket < 83 THEN 'procurement.quotation_responded'
        WHEN b.bucket < 85 THEN 'procurement.quotation_revised'
        WHEN b.bucket < 86 THEN 'procurement.quotation_approval_decided'
        WHEN b.bucket < 91 THEN 'catalog.stock_adjusted'
        WHEN b.bucket < 93 THEN 'catalog.product_updated'
        WHEN b.bucket < 97 THEN 'organizations.updated'
        WHEN b.bucket < 99 THEN 'users.updated'
        ELSE 'auth.user_registered' END AS action,
    CASE
        WHEN b.bucket < 15 OR b.bucket >= 97 THEN 'User'
        WHEN b.bucket < 52 THEN 'Order'
        WHEN b.bucket < 66 THEN 'QuoteRequest'
        WHEN b.bucket < 86 THEN 'Quotation'
        WHEN b.bucket < 93 THEN 'Product'
        ELSE 'Organization' END AS entity_type) AS w;

EXEC sys.sp_updatestats;
GO
