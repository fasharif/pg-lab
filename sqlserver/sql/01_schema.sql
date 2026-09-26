-- pg-lab, SQL Server chapter: the TopFlow tables that the ten casebook statements read,
-- translated from the PostgreSQL migrations in sql/topflow/ to T-SQL for SQL Server 2022.
-- Written, not run: see docs/sqlserver.md. Indexes are TopFlow's own (the baseline).
--
-- Translation choices:
--   * ids stay text (VARCHAR(36)), as Prisma stores them; enums become CHECK constraints;
--     JSONB becomes NVARCHAR(MAX); timestamps are DATETIME2(3) in UTC.
--   * A PRIMARY KEY is clustered by default in SQL Server, which Prisma keeps. Clustering on
--     random UUID text spreads inserts over the whole table (page splits); docs/sqlserver.md
--     discusses the alternative, but the baseline keeps the default for a fair comparison.
SET NOCOUNT ON;

IF DB_ID(N'topflow') IS NULL
    CREATE DATABASE topflow;
GO

ALTER DATABASE topflow SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE topflow SET QUERY_STORE = ON;
ALTER DATABASE topflow SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO

USE topflow;
GO

DROP TABLE IF EXISTS dbo.audit_logs;
DROP TABLE IF EXISTS dbo.quotations;
DROP TABLE IF EXISTS dbo.orders;
DROP TABLE IF EXISTS dbo.products;
DROP TABLE IF EXISTS dbo.categories;
DROP TABLE IF EXISTS dbo.users;
DROP TABLE IF EXISTS dbo.organizations;
DROP TABLE IF EXISTS dbo.lab_settings;
GO

CREATE TABLE dbo.lab_settings (
    [key]   VARCHAR(40)   NOT NULL CONSTRAINT lab_settings_pkey PRIMARY KEY,
    [value] NVARCHAR(100) NOT NULL
);

CREATE TABLE dbo.organizations (
    id          VARCHAR(36)   NOT NULL CONSTRAINT organizations_pkey PRIMARY KEY,
    name        NVARCHAR(200) NOT NULL,
    status      VARCHAR(30)   NOT NULL
        CONSTRAINT organizations_status_ck
        CHECK (status IN ('PENDING_VERIFICATION', 'ACTIVE', 'SUSPENDED')),
    discountRate DECIMAL(5, 2) NOT NULL CONSTRAINT organizations_discountRate_df DEFAULT 0,
    createdAt   DATETIME2(3)  NOT NULL,
    updatedAt   DATETIME2(3)  NOT NULL
);
CREATE INDEX organizations_status_idx ON dbo.organizations (status);

CREATE TABLE dbo.users (
    id             VARCHAR(36)   NOT NULL CONSTRAINT users_pkey PRIMARY KEY,
    email          NVARCHAR(320) NOT NULL,
    fullName       NVARCHAR(200) NOT NULL,
    phoneNumber    VARCHAR(30)   NULL,
    role           VARCHAR(20)   NOT NULL
        CONSTRAINT users_role_ck CHECK (role IN ('CUSTOMER', 'SALES', 'WAREHOUSE', 'ADMIN')),
    isActive       BIT           NOT NULL CONSTRAINT users_isActive_df DEFAULT 1,
    createdAt      DATETIME2(3)  NOT NULL,
    updatedAt      DATETIME2(3)  NOT NULL
);
CREATE UNIQUE INDEX users_email_key ON dbo.users (email);

CREATE TABLE dbo.categories (
    id           INT           NOT NULL CONSTRAINT categories_pkey PRIMARY KEY,
    name         NVARCHAR(200) NOT NULL,
    slug         VARCHAR(200)  NOT NULL,
    displayOrder INT           NOT NULL CONSTRAINT categories_displayOrder_df DEFAULT 0,
    parentId     INT           NULL CONSTRAINT categories_parentId_fkey REFERENCES dbo.categories (id)
);
CREATE UNIQUE INDEX categories_slug_key ON dbo.categories (slug);

CREATE TABLE dbo.products (
    id                VARCHAR(36)    NOT NULL CONSTRAINT products_pkey PRIMARY KEY,
    sku               VARCHAR(40)    NOT NULL,
    name              NVARCHAR(200)  NOT NULL,
    categoryId        INT            NULL CONSTRAINT products_categoryId_fkey REFERENCES dbo.categories (id),
    description       NVARCHAR(MAX)  NULL,
    brand             NVARCHAR(100)  NULL,
    unitPrice         DECIMAL(10, 2) NOT NULL,
    stockQuantity     INT            NOT NULL CONSTRAINT products_stockQuantity_df DEFAULT 0,
    lowStockThreshold INT            NOT NULL CONSTRAINT products_lowStockThreshold_df DEFAULT 10,
    isActive          BIT            NOT NULL CONSTRAINT products_isActive_df DEFAULT 1,
    isTradeOnly       BIT            NOT NULL CONSTRAINT products_isTradeOnly_df DEFAULT 0,
    createdAt         DATETIME2(3)   NOT NULL,
    updatedAt         DATETIME2(3)   NOT NULL
);
CREATE UNIQUE INDEX products_sku_key ON dbo.products (sku);
CREATE INDEX products_categoryId_idx ON dbo.products (categoryId);
CREATE INDEX products_brand_idx ON dbo.products (brand);
CREATE INDEX products_isActive_idx ON dbo.products (isActive);

CREATE TABLE dbo.orders (
    id                  VARCHAR(36)    NOT NULL CONSTRAINT orders_pkey PRIMARY KEY,
    orderNumber         VARCHAR(30)    NOT NULL,
    userId              VARCHAR(36)    NULL CONSTRAINT orders_userId_fkey REFERENCES dbo.users (id),
    organizationId      VARCHAR(36)    NULL
        CONSTRAINT orders_organizationId_fkey REFERENCES dbo.organizations (id),
    status              VARCHAR(20)    NOT NULL
        CONSTRAINT orders_status_ck CHECK (status IN ('PENDING_PAYMENT', 'CONFIRMED', 'PROCESSING',
                                                     'DISPATCHED', 'DELIVERED', 'CANCELLED')),
    channel             VARCHAR(10)    NOT NULL CONSTRAINT orders_channel_ck CHECK (channel IN ('RETAIL', 'B2B')),
    totalAmount         DECIMAL(12, 2) NOT NULL,
    purchaseOrderNumber VARCHAR(40)    NULL,
    projectReference    NVARCHAR(200)  NULL,
    shippingAddress     NVARCHAR(400)  NOT NULL,
    notes               NVARCHAR(MAX)  NULL,
    createdAt           DATETIME2(3)   NOT NULL,
    updatedAt           DATETIME2(3)   NOT NULL
);
CREATE UNIQUE INDEX orders_orderNumber_key ON dbo.orders (orderNumber);
CREATE INDEX orders_userId_idx ON dbo.orders (userId);
CREATE INDEX orders_organizationId_status_idx ON dbo.orders (organizationId, status);
CREATE INDEX orders_status_idx ON dbo.orders (status);

CREATE TABLE dbo.quotations (
    id             VARCHAR(36)    NOT NULL CONSTRAINT quotations_pkey PRIMARY KEY,
    number         VARCHAR(30)    NOT NULL,
    revision       INT            NOT NULL CONSTRAINT quotations_revision_df DEFAULT 1,
    organizationId VARCHAR(36)    NULL
        CONSTRAINT quotations_organizationId_fkey REFERENCES dbo.organizations (id),
    customerId     VARCHAR(36)    NULL CONSTRAINT quotations_customerId_fkey REFERENCES dbo.users (id),
    status         VARCHAR(20)    NOT NULL
        CONSTRAINT quotations_status_ck CHECK (status IN ('DRAFT', 'SENT', 'PENDING_APPROVAL', 'ACCEPTED',
                                                         'REJECTED', 'REVISION_REQUESTED', 'EXPIRED',
                                                         'SUPERSEDED')),
    total          DECIMAL(12, 2) NOT NULL,
    validUntil     DATETIME2(3)   NOT NULL,
    createdAt      DATETIME2(3)   NOT NULL,
    updatedAt      DATETIME2(3)   NOT NULL
);
CREATE UNIQUE INDEX quotations_number_revision_key ON dbo.quotations (number, revision);
CREATE INDEX quotations_organizationId_status_idx ON dbo.quotations (organizationId, status);
CREATE INDEX quotations_status_idx ON dbo.quotations (status);

CREATE TABLE dbo.audit_logs (
    id             VARCHAR(36)   NOT NULL CONSTRAINT audit_logs_pkey PRIMARY KEY,
    userId         VARCHAR(36)   NULL CONSTRAINT audit_logs_userId_fkey REFERENCES dbo.users (id),
    action         VARCHAR(80)   NOT NULL,
    entityType     VARCHAR(40)   NOT NULL,
    entityId       VARCHAR(36)   NULL,
    details        NVARCHAR(MAX) NULL,
    ipAddress      VARCHAR(45)   NULL,
    organizationId VARCHAR(36)   NULL,
    createdAt      DATETIME2(3)  NOT NULL
);
CREATE INDEX audit_logs_entityType_entityId_idx ON dbo.audit_logs (entityType, entityId);
CREATE INDEX audit_logs_createdAt_idx ON dbo.audit_logs (createdAt);
GO
