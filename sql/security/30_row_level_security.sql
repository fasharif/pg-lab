-- Tenant isolation with row-level security (RLS). Applied by ./lab migrate as
-- topflow_migrator; idempotent: every run drops and recreates the policies.
--
-- Request context. For each transaction the API sets who is asking and, for trade
-- requests, which organisation they act for (TopFlow's x-organization-id header):
--
--     SELECT set_config('app.user_id', '<user id>', true),
--            set_config('app.org_id',  '<organization id or empty>', true);
--
-- Two kinds of policy work together on every tenant table:
--   * a permissive policy says which rows belong to the context: the organisation's rows,
--     or the customer's own rows outside any organisation. On the tables where rows can be
--     either (orders, quote requests, quotations, addresses), the test is one PL/pgSQL
--     function, app.is_tenant_row(organisation, owner);
--   * a restrictive policy checks once per statement that the user really is a member of
--     the organisation they claim (app.context_is_valid(), evaluated as an InitPlan).
-- Why a function the planner cannot see into: the API already filters by organisation. With
-- a transparent policy the planner reads the setting while planning, applies the
-- organisation's share of the rows twice (the API's predicate and the policy's) and expects a
-- small fraction of the real rows, which brings a bitmap scan and sort close to the cost of
-- the (organizationId, createdAt) index scan. For an opaque function it assumes a fixed third
-- of the rows, whichever the organisation. docs/security.md, "RLS and query plans", has the
-- measurements.
--
-- TopFlow already enables RLS on every table (migration 20260916090000) without policies;
-- the owner bypasses it. Flows that cross tenant boundaries (sign-up, accepting an
-- invitation, KYC review) belong to topflow_backoffice in this model.

CREATE SCHEMA IF NOT EXISTS app;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO topflow_app;

-- Start from a clean slate: drop every policy on TopFlow's tables and make sure RLS is on.
DO $$
DECLARE
    item record;
BEGIN
    FOR item IN SELECT tablename, policyname FROM pg_policies WHERE schemaname = 'public' LOOP
        EXECUTE format('DROP POLICY %I ON public.%I', item.policyname, item.tablename);
    END LOOP;
    FOR item IN
        SELECT c.relname FROM pg_class AS c
        WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', item.relname);
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION app.user_id() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE
AS $$ SELECT nullif(current_setting('app.user_id', true), '') $$;

CREATE OR REPLACE FUNCTION app.org_id() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE
AS $$ SELECT nullif(current_setting('app.org_id', true), '') $$;

-- True when no organisation is claimed, or when the user is a member of the one claimed.
-- SECURITY DEFINER: reads organization_members as the owner, whatever the caller may see;
-- search_path is pinned so the function cannot be pointed at other objects.
CREATE OR REPLACE FUNCTION app.context_is_valid() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT app.org_id() IS NULL
        OR EXISTS (SELECT 1 FROM public.organization_members AS m
                   WHERE m."organizationId" = app.org_id() AND m."userId" = app.user_id())
$$;

-- The organisation's row, or the customer's own row outside any organisation. PL/pgSQL so
-- that it is never inlined (see the header); NULL comparisons count as "not visible".
-- COST 10 rather than the default 100 for non-C functions: it is two comparisons, and at 100
-- the planner moved a 10,000-row count to a parallel plan to share out the calls.
CREATE OR REPLACE FUNCTION app.is_tenant_row(row_org text, row_owner text) RETURNS boolean
LANGUAGE plpgsql STABLE PARALLEL SAFE COST 10
AS $$
BEGIN
    RETURN coalesce(row_org = app.org_id() OR (row_org IS NULL AND row_owner = app.user_id()),
                    false);
END
$$;

-- Trade-only products are visible to members of verified (ACTIVE) organisations only.
CREATE OR REPLACE FUNCTION app.has_trade_access() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.organization_members AS m
        JOIN public.organizations AS o ON o.id = m."organizationId"
        WHERE m."organizationId" = app.org_id() AND m."userId" = app.user_id()
          AND o.status = 'ACTIVE'
    )
$$;

REVOKE ALL ON FUNCTION app.user_id(), app.org_id(), app.context_is_valid(), app.has_trade_access(),
    app.is_tenant_row(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.user_id(), app.org_id(), app.context_is_valid(), app.has_trade_access(),
    app.is_tenant_row(text, text) TO topflow_app;

-- ─── Customer-facing API (topflow_app) ─────────────────────────────────────
-- Customers: themselves, and colleagues in the organisation they act for. Column
-- privileges (20_privileges.sql) stop them from changing their own role or active flag.
CREATE POLICY users_app_read ON users FOR SELECT TO topflow_app
    USING (id = app.user_id()
           OR id IN (SELECT m."userId" FROM organization_members AS m
                     WHERE m."organizationId" = app.org_id()));
CREATE POLICY users_app_insert ON users FOR INSERT TO topflow_app
    WITH CHECK (id = app.user_id() AND role = 'CUSTOMER');
CREATE POLICY users_app_update ON users FOR UPDATE TO topflow_app
    USING (id = app.user_id()) WITH CHECK (id = app.user_id());

CREATE POLICY organizations_app_read ON organizations FOR SELECT TO topflow_app
    USING (id = app.org_id());
CREATE POLICY organizations_app_update ON organizations FOR UPDATE TO topflow_app
    USING (id = app.org_id()) WITH CHECK (id = app.org_id());
-- Anyone signed in may open a trade account, but only as an unverified one with no credit.
CREATE POLICY organizations_app_insert ON organizations FOR INSERT TO topflow_app
    WITH CHECK (status = 'PENDING_VERIFICATION' AND "verifiedAt" IS NULL
                AND "creditLimit" = 0 AND "discountRate" = 0);

CREATE POLICY members_app_read ON organization_members FOR SELECT TO topflow_app
    USING ("organizationId" = app.org_id() OR "userId" = app.user_id());
CREATE POLICY members_app_write ON organization_members FOR ALL TO topflow_app
    USING ("organizationId" = app.org_id()) WITH CHECK ("organizationId" = app.org_id());

CREATE POLICY invitations_app ON organization_invitations FOR ALL TO topflow_app
    USING ("organizationId" = app.org_id()) WITH CHECK ("organizationId" = app.org_id());

CREATE POLICY addresses_app ON addresses FOR ALL TO topflow_app
    USING (app.is_tenant_row("organizationId", "userId"))
    WITH CHECK (app.is_tenant_row("organizationId", "userId"));

-- Orders: the organisation's orders, or the customer's own retail orders (TopFlow's
-- listMine filters organizationId IS NULL in the same way).
CREATE POLICY orders_app ON orders FOR ALL TO topflow_app
    USING (app.is_tenant_row("organizationId", "userId"))
    WITH CHECK (app.is_tenant_row("organizationId", "userId"));
-- Child rows follow their order: the subquery is itself filtered by orders_app.
CREATE POLICY order_items_app ON order_items FOR ALL TO topflow_app
    USING (EXISTS (SELECT 1 FROM orders AS o WHERE o.id = order_items."orderId"))
    WITH CHECK (EXISTS (SELECT 1 FROM orders AS o WHERE o.id = order_items."orderId"));
CREATE POLICY order_events_app ON order_status_events FOR ALL TO topflow_app
    USING (EXISTS (SELECT 1 FROM orders AS o WHERE o.id = order_status_events."orderId"))
    WITH CHECK (EXISTS (SELECT 1 FROM orders AS o WHERE o.id = order_status_events."orderId"));

CREATE POLICY rfqs_app ON quote_requests FOR ALL TO topflow_app
    USING (app.is_tenant_row("organizationId", "requestedById"))
    WITH CHECK (app.is_tenant_row("organizationId", "requestedById"));
CREATE POLICY rfq_items_app ON quote_request_items FOR ALL TO topflow_app
    USING (EXISTS (SELECT 1 FROM quote_requests AS r WHERE r.id = quote_request_items."quoteRequestId"))
    WITH CHECK (EXISTS (SELECT 1 FROM quote_requests AS r
                        WHERE r.id = quote_request_items."quoteRequestId"));

-- Quotations: never drafts (TopFlow's orgList and personalList hide them too).
CREATE POLICY quotations_app ON quotations FOR ALL TO topflow_app
    USING (status <> 'DRAFT' AND app.is_tenant_row("organizationId", "customerId"))
    WITH CHECK (status <> 'DRAFT' AND app.is_tenant_row("organizationId", "customerId"));
CREATE POLICY quotation_items_app ON quotation_items FOR SELECT TO topflow_app
    USING (EXISTS (SELECT 1 FROM quotations AS q WHERE q.id = quotation_items."quotationId"));

-- Audit entries are written by the user they describe, in their current context. The read
-- policy exists because Prisma's create() reads the new row back (INSERT ... RETURNING).
CREATE POLICY audit_app ON audit_logs FOR ALL TO topflow_app
    USING ("userId" = app.user_id()
           AND ("organizationId" IS NULL OR "organizationId" = app.org_id()))
    WITH CHECK ("userId" = app.user_id()
                AND ("organizationId" IS NULL OR "organizationId" = app.org_id()));

CREATE POLICY products_app ON products FOR SELECT TO topflow_app
    USING ("isActive" AND (NOT "isTradeOnly" OR (SELECT app.has_trade_access())));
CREATE POLICY categories_app ON categories FOR SELECT TO topflow_app USING (true);
CREATE POLICY sequences_app ON document_sequences FOR ALL TO topflow_app
    USING (true) WITH CHECK (true);

-- The membership gate: restrictive, so it is ANDed with the policies above. It references no
-- column, so it runs once per statement as an InitPlan and each row only tests its result.
DO $$
DECLARE
    tenant_table text;
BEGIN
    FOREACH tenant_table IN ARRAY ARRAY[
        'users', 'organizations', 'organization_members', 'organization_invitations',
        'addresses', 'orders', 'order_items', 'order_status_events', 'quote_requests',
        'quote_request_items', 'quotations', 'quotation_items', 'audit_logs'
    ] LOOP
        EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO topflow_app '
                       'USING ((SELECT app.context_is_valid())) '
                       'WITH CHECK ((SELECT app.context_is_valid()))',
                       tenant_table || '_app_context', tenant_table);
    END LOOP;
END
$$;

-- ─── Staff API and analyst: every tenant ───────────────────────────────────
-- Their table and column privileges (20_privileges.sql) still limit what they can do.
DO $$
DECLARE
    item record;
BEGIN
    FOR item IN
        SELECT c.relname FROM pg_class AS c
        WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
          AND c.relname NOT IN ('carts', 'cart_items')
    LOOP
        EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO topflow_backoffice '
                       'USING (true) WITH CHECK (true)', item.relname || '_backoffice', item.relname);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO topflow_analyst USING (true)',
                       item.relname || '_analyst', item.relname);
    END LOOP;
END
$$;
