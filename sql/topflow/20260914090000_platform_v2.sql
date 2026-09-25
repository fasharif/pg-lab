-- ════════════════════════════════════════════════════════════════════════════
-- Top Flow platform v2
--   • B2B tenancy (organizations, members, invitations, addresses)
--   • Auth sessions (rotating refresh tokens) and one-time tokens
--   • Procurement pipeline: quote_requests (RFQ) → quotations (revisions) → orders
--   • VAT-ready order totals, payment and fulfilment fields, order timeline
--   • Catalog enrichment (slug, brand, UoM, MOQ, soft delete, trade-only)
--
-- Hand-edited from `prisma migrate diff` to preserve v1 data:
--   1. users with role CONTRACTOR  → CUSTOMER + OWNER of a new organization
--   2. orders ENQUIRY_SUBMITTED / QUOTATION_ISSUED → quote_requests (same id/number)
--   3. products get a backfilled slug before it becomes NOT NULL
--   4. remaining legacy orders are flagged as B2B, VAT-free (v1 prices had no VAT)
-- The whole migration runs in one transaction (PostgreSQL has transactional DDL).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── 1. New enum types ─────────────────────────────────────────────────────
CREATE TYPE "TokenPurpose" AS ENUM ('EMAIL_VERIFICATION', 'PASSWORD_RESET');
CREATE TYPE "OrgRole" AS ENUM ('OWNER', 'APPROVER', 'BUYER');
CREATE TYPE "OrgStatus" AS ENUM ('PENDING_VERIFICATION', 'ACTIVE', 'SUSPENDED');
CREATE TYPE "OrgType" AS ENUM ('CONTRACTOR', 'LANDSCAPING', 'FACILITY_MANAGEMENT', 'DEVELOPER', 'GOVERNMENT', 'RESELLER', 'OTHER');
CREATE TYPE "PaymentTerms" AS ENUM ('PREPAID', 'NET_15', 'NET_30', 'NET_60');
CREATE TYPE "Emirate" AS ENUM ('ABU_DHABI', 'DUBAI', 'SHARJAH', 'AJMAN', 'UMM_AL_QUWAIN', 'RAS_AL_KHAIMAH', 'FUJAIRAH');
CREATE TYPE "UnitOfMeasure" AS ENUM ('PIECE', 'METER', 'ROLL', 'BOX', 'SET');
CREATE TYPE "RfqStatus" AS ENUM ('SUBMITTED', 'IN_REVIEW', 'QUOTED', 'CLOSED', 'CANCELLED');
CREATE TYPE "QuotationStatus" AS ENUM ('DRAFT', 'SENT', 'PENDING_APPROVAL', 'ACCEPTED', 'REJECTED', 'REVISION_REQUESTED', 'EXPIRED', 'SUPERSEDED');
CREATE TYPE "OrderChannel" AS ENUM ('RETAIL', 'B2B');
CREATE TYPE "PaymentMethod" AS ENUM ('CASH_ON_DELIVERY', 'CARD', 'BANK_TRANSFER', 'CREDIT_ACCOUNT');
CREATE TYPE "PaymentStatus" AS ENUM ('UNPAID', 'PAID', 'REFUNDED');

-- ─── 2. Tables required by the data conversion ────────────────────────────
CREATE TABLE "organizations" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "legalName" TEXT,
    "type" "OrgType" NOT NULL DEFAULT 'CONTRACTOR',
    "status" "OrgStatus" NOT NULL DEFAULT 'PENDING_VERIFICATION',
    "tradeLicenseNumber" TEXT,
    "trn" TEXT,
    "email" TEXT,
    "phoneNumber" TEXT,
    "paymentTerms" "PaymentTerms" NOT NULL DEFAULT 'PREPAID',
    "creditLimit" DECIMAL(12,2) NOT NULL DEFAULT 0,
    "discountRate" DECIMAL(5,2) NOT NULL DEFAULT 0,
    "verifiedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "organizations_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "organization_members" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "role" "OrgRole" NOT NULL DEFAULT 'BUYER',
    "approvalLimit" DECIMAL(12,2),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "organization_members_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "quote_requests" (
    "id" TEXT NOT NULL,
    "number" TEXT NOT NULL,
    "organizationId" TEXT,
    "requestedById" TEXT,
    "assignedToId" TEXT,
    "status" "RfqStatus" NOT NULL DEFAULT 'SUBMITTED',
    "projectReference" TEXT,
    "shippingAddress" TEXT,
    "deliveryAddress" JSONB,
    "requiredBy" TIMESTAMP(3),
    "notes" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "quote_requests_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "quote_request_items" (
    "id" TEXT NOT NULL,
    "quoteRequestId" TEXT NOT NULL,
    "productId" TEXT,
    "sku" TEXT NOT NULL,
    "productName" TEXT NOT NULL,
    "quantity" INTEGER NOT NULL,
    "notes" TEXT,

    CONSTRAINT "quote_request_items_pkey" PRIMARY KEY ("id")
);

-- ─── 3. Data conversion (v1 → v2) ──────────────────────────────────────────
-- 3a. Every CONTRACTOR becomes the OWNER of a (pending verification) organization.
WITH new_orgs AS (
    INSERT INTO "organizations" ("id", "name", "type", "status", "email", "phoneNumber", "updatedAt")
    SELECT gen_random_uuid()::text,
           COALESCE(NULLIF(trim(u."companyName"), ''), u."fullName" || ' (Business)'),
           'CONTRACTOR', 'PENDING_VERIFICATION', u."email", u."phoneNumber", CURRENT_TIMESTAMP
    FROM "users" u
    WHERE u."role"::text = 'CONTRACTOR'
    RETURNING "id", "email"
)
INSERT INTO "organization_members" ("id", "organizationId", "userId", "role")
SELECT gen_random_uuid()::text, o."id", u."id", 'OWNER'
FROM new_orgs o
JOIN "users" u ON u."email" = o."email" AND u."role"::text = 'CONTRACTOR';

-- 3b. v1 enquiries were really RFQs: move them (same id and number) with their lines.
INSERT INTO "quote_requests" ("id", "number", "organizationId", "requestedById", "status",
                              "projectReference", "shippingAddress", "notes", "createdAt", "updatedAt")
SELECT o."id", o."orderNumber", m."organizationId", o."userId",
       CASE o."status"::text WHEN 'QUOTATION_ISSUED' THEN 'IN_REVIEW'::"RfqStatus" ELSE 'SUBMITTED'::"RfqStatus" END,
       o."projectReference", o."shippingAddress", o."notes", o."createdAt", o."updatedAt"
FROM "orders" o
LEFT JOIN LATERAL (
    SELECT om."organizationId"
    FROM "organization_members" om
    WHERE om."userId" = o."userId"
    ORDER BY om."createdAt"
    LIMIT 1
) m ON TRUE
WHERE o."status"::text IN ('ENQUIRY_SUBMITTED', 'QUOTATION_ISSUED');

INSERT INTO "quote_request_items" ("id", "quoteRequestId", "productId", "sku", "productName", "quantity")
SELECT gen_random_uuid()::text, oi."orderId", oi."productId", oi."sku", oi."productName", oi."quantity"
FROM "order_items" oi
JOIN "orders" o ON o."id" = oi."orderId"
WHERE o."status"::text IN ('ENQUIRY_SUBMITTED', 'QUOTATION_ISSUED');

DELETE FROM "orders" WHERE "status"::text IN ('ENQUIRY_SUBMITTED', 'QUOTATION_ISSUED');

UPDATE "users" SET "role" = 'CUSTOMER' WHERE "role"::text = 'CONTRACTOR';

-- ─── 4. Enum replacements (safe now that no row uses a removed value) ─────
CREATE TYPE "Role_new" AS ENUM ('CUSTOMER', 'SALES', 'WAREHOUSE', 'ADMIN');
ALTER TABLE "users" ALTER COLUMN "role" DROP DEFAULT;
ALTER TABLE "users" ALTER COLUMN "role" TYPE "Role_new" USING ("role"::text::"Role_new");
ALTER TYPE "Role" RENAME TO "Role_old";
ALTER TYPE "Role_new" RENAME TO "Role";
DROP TYPE "Role_old";
ALTER TABLE "users" ALTER COLUMN "role" SET DEFAULT 'CUSTOMER';

CREATE TYPE "OrderStatus_new" AS ENUM ('PENDING_PAYMENT', 'CONFIRMED', 'PROCESSING', 'DISPATCHED', 'DELIVERED', 'CANCELLED');
ALTER TABLE "orders" ALTER COLUMN "status" DROP DEFAULT;
ALTER TABLE "orders" ALTER COLUMN "status" TYPE "OrderStatus_new" USING ("status"::text::"OrderStatus_new");
ALTER TYPE "OrderStatus" RENAME TO "OrderStatus_old";
ALTER TYPE "OrderStatus_new" RENAME TO "OrderStatus";
DROP TYPE "OrderStatus_old";
ALTER TABLE "orders" ALTER COLUMN "status" SET DEFAULT 'PENDING_PAYMENT';

-- ─── 5. Alter existing tables ──────────────────────────────────────────────
ALTER TABLE "audit_logs" ADD COLUMN "ipAddress" TEXT,
ADD COLUMN "organizationId" TEXT;

ALTER TABLE "categories" ADD COLUMN "imageUrl" TEXT,
ADD COLUMN "parentId" INTEGER;

ALTER TABLE "order_items" ADD COLUMN "discountRate" DECIMAL(5,2) NOT NULL DEFAULT 0,
ADD COLUMN "uom" "UnitOfMeasure" NOT NULL DEFAULT 'PIECE',
ADD COLUMN "vatAmount" DECIMAL(12,2) NOT NULL DEFAULT 0;

-- quotationPdfUrl was never populated in v1 (PDFs are rendered on demand).
ALTER TABLE "orders" DROP COLUMN "quotationPdfUrl",
ADD COLUMN "cancellationReason" TEXT,
ADD COLUMN "cancelledAt" TIMESTAMP(3),
ADD COLUMN "channel" "OrderChannel" NOT NULL DEFAULT 'RETAIL',
ADD COLUMN "confirmedAt" TIMESTAMP(3),
ADD COLUMN "deliveredAt" TIMESTAMP(3),
ADD COLUMN "deliveryAddress" JSONB,
ADD COLUMN "deliveryFee" DECIMAL(12,2) NOT NULL DEFAULT 0,
ADD COLUMN "discountTotal" DECIMAL(12,2) NOT NULL DEFAULT 0,
ADD COLUMN "dispatchedAt" TIMESTAMP(3),
ADD COLUMN "organizationId" TEXT,
ADD COLUMN "paidAt" TIMESTAMP(3),
ADD COLUMN "paymentMethod" "PaymentMethod",
ADD COLUMN "paymentReference" TEXT,
ADD COLUMN "paymentStatus" "PaymentStatus" NOT NULL DEFAULT 'UNPAID',
ADD COLUMN "purchaseOrderNumber" TEXT,
ADD COLUMN "quotationId" TEXT,
ADD COLUMN "subtotal" DECIMAL(12,2) NOT NULL DEFAULT 0,
ADD COLUMN "trackingReference" TEXT,
ADD COLUMN "vatAmount" DECIMAL(12,2) NOT NULL DEFAULT 0,
ADD COLUMN "vatRateBps" INTEGER NOT NULL DEFAULT 500;

-- Legacy orders came through the contractor enquiry flow and carried no VAT.
UPDATE "orders" o
SET "channel" = 'B2B',
    "vatRateBps" = 0,
    "subtotal" = o."totalAmount",
    "organizationId" = (
        SELECT om."organizationId" FROM "organization_members" om
        WHERE om."userId" = o."userId" ORDER BY om."createdAt" LIMIT 1
    ),
    "confirmedAt" = CASE WHEN o."status" IN ('CONFIRMED', 'PROCESSING', 'DISPATCHED', 'DELIVERED') THEN o."updatedAt" END,
    "dispatchedAt" = CASE WHEN o."status" IN ('DISPATCHED', 'DELIVERED') THEN o."updatedAt" END,
    "deliveredAt" = CASE WHEN o."status" = 'DELIVERED' THEN o."updatedAt" END,
    "cancelledAt" = CASE WHEN o."status" = 'CANCELLED' THEN o."updatedAt" END;

ALTER TABLE "products" ADD COLUMN "brand" TEXT,
ADD COLUMN "isActive" BOOLEAN NOT NULL DEFAULT true,
ADD COLUMN "isTradeOnly" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN "lowStockThreshold" INTEGER NOT NULL DEFAULT 10,
ADD COLUMN "minOrderQty" INTEGER NOT NULL DEFAULT 1,
ADD COLUMN "slug" TEXT,
ADD COLUMN "uom" "UnitOfMeasure" NOT NULL DEFAULT 'PIECE';

UPDATE "products"
SET "slug" = trim(BOTH '-' FROM lower(regexp_replace("name" || '-' || "sku", '[^a-zA-Z0-9]+', '-', 'g')));

ALTER TABLE "products" ALTER COLUMN "slug" SET NOT NULL;

ALTER TABLE "users" ADD COLUMN "emailVerifiedAt" TIMESTAMP(3),
ADD COLUMN "lastLoginAt" TIMESTAMP(3),
ADD COLUMN "passwordChangedAt" TIMESTAMP(3),
ALTER COLUMN "phoneNumber" DROP NOT NULL;

-- ─── 6. Remaining new tables ───────────────────────────────────────────────
CREATE TABLE "refresh_tokens" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "familyId" TEXT NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "rotatedAt" TIMESTAMP(3),
    "revokedAt" TIMESTAMP(3),
    "userAgent" TEXT,
    "ipAddress" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "refresh_tokens_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "one_time_tokens" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "purpose" "TokenPurpose" NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "consumedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "one_time_tokens_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "organization_invitations" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "role" "OrgRole" NOT NULL DEFAULT 'BUYER',
    "tokenHash" TEXT NOT NULL,
    "invitedById" TEXT,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "acceptedAt" TIMESTAMP(3),
    "revokedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "organization_invitations_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "addresses" (
    "id" TEXT NOT NULL,
    "userId" TEXT,
    "organizationId" TEXT,
    "label" TEXT NOT NULL,
    "contactName" TEXT NOT NULL,
    "phoneNumber" TEXT NOT NULL,
    "line1" TEXT NOT NULL,
    "line2" TEXT,
    "area" TEXT NOT NULL,
    "city" TEXT NOT NULL,
    "emirate" "Emirate" NOT NULL,
    "country" TEXT NOT NULL DEFAULT 'AE',
    "isDefault" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "addresses_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "quotations" (
    "id" TEXT NOT NULL,
    "number" TEXT NOT NULL,
    "revision" INTEGER NOT NULL DEFAULT 1,
    "quoteRequestId" TEXT,
    "organizationId" TEXT,
    "customerId" TEXT,
    "createdById" TEXT,
    "status" "QuotationStatus" NOT NULL DEFAULT 'DRAFT',
    "currency" TEXT NOT NULL DEFAULT 'AED',
    "vatRateBps" INTEGER NOT NULL DEFAULT 500,
    "subtotal" DECIMAL(12,2) NOT NULL DEFAULT 0,
    "discountTotal" DECIMAL(12,2) NOT NULL DEFAULT 0,
    "deliveryFee" DECIMAL(12,2) NOT NULL DEFAULT 0,
    "vatAmount" DECIMAL(12,2) NOT NULL DEFAULT 0,
    "total" DECIMAL(12,2) NOT NULL DEFAULT 0,
    "validUntil" TIMESTAMP(3) NOT NULL,
    "terms" TEXT,
    "notes" TEXT,
    "internalNotes" TEXT,
    "sentAt" TIMESTAMP(3),
    "respondedAt" TIMESTAMP(3),
    "respondedById" TEXT,
    "responseNote" TEXT,
    "purchaseOrderNumber" TEXT,
    "approvedById" TEXT,
    "approvedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "quotations_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "quotation_items" (
    "id" TEXT NOT NULL,
    "quotationId" TEXT NOT NULL,
    "productId" TEXT,
    "sku" TEXT NOT NULL,
    "productName" TEXT NOT NULL,
    "uom" "UnitOfMeasure" NOT NULL DEFAULT 'PIECE',
    "quantity" INTEGER NOT NULL,
    "listPrice" DECIMAL(10,2) NOT NULL,
    "discountRate" DECIMAL(5,2) NOT NULL DEFAULT 0,
    "unitPrice" DECIMAL(10,2) NOT NULL,
    "lineSubtotal" DECIMAL(12,2) NOT NULL,
    "vatAmount" DECIMAL(12,2) NOT NULL,
    "lineTotal" DECIMAL(12,2) NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,

    CONSTRAINT "quotation_items_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "order_status_events" (
    "id" TEXT NOT NULL,
    "orderId" TEXT NOT NULL,
    "fromStatus" "OrderStatus",
    "toStatus" "OrderStatus" NOT NULL,
    "actorId" TEXT,
    "note" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "order_status_events_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "document_sequences" (
    "key" TEXT NOT NULL,
    "value" INTEGER NOT NULL DEFAULT 0,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "document_sequences_pkey" PRIMARY KEY ("key")
);

-- Seed the timeline of pre-existing orders.
INSERT INTO "order_status_events" ("id", "orderId", "fromStatus", "toStatus", "note", "createdAt")
SELECT gen_random_uuid()::text, o."id", NULL, o."status", 'Migrated from platform v1', o."createdAt"
FROM "orders" o;

-- ─── 7. Indexes ─────────────────────────────────────────────────────────────
CREATE UNIQUE INDEX "refresh_tokens_tokenHash_key" ON "refresh_tokens"("tokenHash");
CREATE INDEX "refresh_tokens_userId_idx" ON "refresh_tokens"("userId");
CREATE INDEX "refresh_tokens_familyId_idx" ON "refresh_tokens"("familyId");
CREATE UNIQUE INDEX "one_time_tokens_tokenHash_key" ON "one_time_tokens"("tokenHash");
CREATE INDEX "one_time_tokens_userId_purpose_idx" ON "one_time_tokens"("userId", "purpose");
CREATE UNIQUE INDEX "organizations_trn_key" ON "organizations"("trn");
CREATE INDEX "organizations_status_idx" ON "organizations"("status");
CREATE INDEX "organization_members_userId_idx" ON "organization_members"("userId");
CREATE UNIQUE INDEX "organization_members_organizationId_userId_key" ON "organization_members"("organizationId", "userId");
CREATE UNIQUE INDEX "organization_invitations_tokenHash_key" ON "organization_invitations"("tokenHash");
CREATE INDEX "organization_invitations_organizationId_idx" ON "organization_invitations"("organizationId");
CREATE INDEX "organization_invitations_email_idx" ON "organization_invitations"("email");
CREATE INDEX "addresses_userId_idx" ON "addresses"("userId");
CREATE INDEX "addresses_organizationId_idx" ON "addresses"("organizationId");
CREATE UNIQUE INDEX "quote_requests_number_key" ON "quote_requests"("number");
CREATE INDEX "quote_requests_organizationId_status_idx" ON "quote_requests"("organizationId", "status");
CREATE INDEX "quote_requests_requestedById_idx" ON "quote_requests"("requestedById");
CREATE INDEX "quote_requests_status_idx" ON "quote_requests"("status");
CREATE INDEX "quote_request_items_quoteRequestId_idx" ON "quote_request_items"("quoteRequestId");
CREATE INDEX "quotations_organizationId_status_idx" ON "quotations"("organizationId", "status");
CREATE INDEX "quotations_quoteRequestId_idx" ON "quotations"("quoteRequestId");
CREATE INDEX "quotations_status_idx" ON "quotations"("status");
CREATE UNIQUE INDEX "quotations_number_revision_key" ON "quotations"("number", "revision");
CREATE INDEX "quotation_items_quotationId_idx" ON "quotation_items"("quotationId");
CREATE INDEX "order_status_events_orderId_idx" ON "order_status_events"("orderId");
CREATE INDEX "audit_logs_entityType_entityId_idx" ON "audit_logs"("entityType", "entityId");
CREATE INDEX "audit_logs_createdAt_idx" ON "audit_logs"("createdAt");
CREATE INDEX "order_items_orderId_idx" ON "order_items"("orderId");
CREATE UNIQUE INDEX "orders_quotationId_key" ON "orders"("quotationId");
CREATE INDEX "orders_userId_idx" ON "orders"("userId");
CREATE INDEX "orders_organizationId_status_idx" ON "orders"("organizationId", "status");
CREATE INDEX "orders_status_idx" ON "orders"("status");
CREATE UNIQUE INDEX "products_slug_key" ON "products"("slug");
CREATE INDEX "products_categoryId_idx" ON "products"("categoryId");
CREATE INDEX "products_brand_idx" ON "products"("brand");
CREATE INDEX "products_isActive_idx" ON "products"("isActive");

-- ─── 8. Foreign keys ───────────────────────────────────────────────────────
ALTER TABLE "refresh_tokens" ADD CONSTRAINT "refresh_tokens_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "one_time_tokens" ADD CONSTRAINT "one_time_tokens_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "organization_members" ADD CONSTRAINT "organization_members_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES "organizations"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "organization_members" ADD CONSTRAINT "organization_members_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "organization_invitations" ADD CONSTRAINT "organization_invitations_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES "organizations"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "organization_invitations" ADD CONSTRAINT "organization_invitations_invitedById_fkey" FOREIGN KEY ("invitedById") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "addresses" ADD CONSTRAINT "addresses_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "addresses" ADD CONSTRAINT "addresses_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES "organizations"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "categories" ADD CONSTRAINT "categories_parentId_fkey" FOREIGN KEY ("parentId") REFERENCES "categories"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quote_requests" ADD CONSTRAINT "quote_requests_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES "organizations"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quote_requests" ADD CONSTRAINT "quote_requests_requestedById_fkey" FOREIGN KEY ("requestedById") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quote_requests" ADD CONSTRAINT "quote_requests_assignedToId_fkey" FOREIGN KEY ("assignedToId") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quote_request_items" ADD CONSTRAINT "quote_request_items_quoteRequestId_fkey" FOREIGN KEY ("quoteRequestId") REFERENCES "quote_requests"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "quote_request_items" ADD CONSTRAINT "quote_request_items_productId_fkey" FOREIGN KEY ("productId") REFERENCES "products"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quotations" ADD CONSTRAINT "quotations_quoteRequestId_fkey" FOREIGN KEY ("quoteRequestId") REFERENCES "quote_requests"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quotations" ADD CONSTRAINT "quotations_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES "organizations"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quotations" ADD CONSTRAINT "quotations_customerId_fkey" FOREIGN KEY ("customerId") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quotations" ADD CONSTRAINT "quotations_createdById_fkey" FOREIGN KEY ("createdById") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quotations" ADD CONSTRAINT "quotations_respondedById_fkey" FOREIGN KEY ("respondedById") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quotations" ADD CONSTRAINT "quotations_approvedById_fkey" FOREIGN KEY ("approvedById") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "quotation_items" ADD CONSTRAINT "quotation_items_quotationId_fkey" FOREIGN KEY ("quotationId") REFERENCES "quotations"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "quotation_items" ADD CONSTRAINT "quotation_items_productId_fkey" FOREIGN KEY ("productId") REFERENCES "products"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "orders" ADD CONSTRAINT "orders_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES "organizations"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "orders" ADD CONSTRAINT "orders_quotationId_fkey" FOREIGN KEY ("quotationId") REFERENCES "quotations"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "order_status_events" ADD CONSTRAINT "order_status_events_orderId_fkey" FOREIGN KEY ("orderId") REFERENCES "orders"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "order_status_events" ADD CONSTRAINT "order_status_events_actorId_fkey" FOREIGN KEY ("actorId") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;

COMMIT;
