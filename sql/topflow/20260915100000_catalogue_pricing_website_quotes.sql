-- ════════════════════════════════════════════════════════════════════════════
-- Top Flow catalogue pricing and website quote requests
--   • products: indicative price range per unit (priceMin / priceMax, net of VAT)
--     and lower-case search tags
--   • quote_requests: where the request came from (trade portal or website) and
--     the contact details of website visitors, who have no account
-- Additive only: existing rows keep their data and default to TRADE_PORTAL.
-- ════════════════════════════════════════════════════════════════════════════

-- CreateEnum
CREATE TYPE "RfqSource" AS ENUM ('TRADE_PORTAL', 'WEBSITE');

-- AlterTable
ALTER TABLE "products" ADD COLUMN     "priceMax" DECIMAL(10,2),
ADD COLUMN     "priceMin" DECIMAL(10,2),
ADD COLUMN     "tags" TEXT[] DEFAULT ARRAY[]::TEXT[];

-- AlterTable
ALTER TABLE "quote_requests" ADD COLUMN     "companyName" TEXT,
ADD COLUMN     "contactEmail" TEXT,
ADD COLUMN     "contactName" TEXT,
ADD COLUMN     "contactPhone" TEXT,
ADD COLUMN     "source" "RfqSource" NOT NULL DEFAULT 'TRADE_PORTAL';

-- CreateIndex
CREATE INDEX "quote_requests_source_status_idx" ON "quote_requests"("source", "status");
