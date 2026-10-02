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
-- On top of the tenant policies, restrictive policies limit the states a customer can move a
-- row into (cancel an order, answer a quotation) and what they may append to an order (lines
-- only while placing it, status events that continue its timeline), and membership changes
-- need the organisation's owner. Column privileges (20_privileges.sql) limit which columns
-- change.
--
-- Trust boundary: the policies trust app.user_id and app.org_id, which any topflow_app
-- session can set. They stop API code that forgets a tenant filter; they do not stop code
-- that can run arbitrary SQL as topflow_app (SQL injection, a compromised API), which can
-- claim to be any user. docs/security.md, "Trust boundary", has the stronger options.
--
-- TopFlow already enables RLS on every table (migration 20260916090000) without policies;
-- the owner bypasses it. Flows that cross tenant boundaries (registering a trade account,
-- accepting an invitation, KYC review) belong to topflow_backoffice in this model.

CREATE SCHEMA IF NOT EXISTS app;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO topflow_app, topflow_backoffice;

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

-- The caller's role (OWNER, APPROVER or BUYER) in the organisation they act for; NULL when they
-- do not act for one or are not a member of it.
CREATE OR REPLACE FUNCTION app.org_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT m.role::text FROM public.organization_members AS m
    WHERE m."organizationId" = app.org_id() AND m."userId" = app.user_id()
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

-- True when a status event (from_status -> to_status) continues the timeline of one of the
-- caller's orders: from_status is the status the order's last event reached (NULL for its first
-- event) and to_status is the status the order has now. SECURITY DEFINER because a policy on
-- order_status_events cannot query order_status_events itself (PostgreSQL reports infinite
-- recursion); it answers only for the caller's own orders and returns a boolean, never rows.
CREATE OR REPLACE FUNCTION app.continues_order_timeline(order_id text, from_status text,
                                                        to_status text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.orders AS o
        WHERE o.id = order_id
          AND app.is_tenant_row(o."organizationId", o."userId")
          AND o.status::text = to_status
          AND from_status IS NOT DISTINCT FROM (
              SELECT e."toStatus"::text
              FROM public.order_status_events AS e
              WHERE e."orderId" = o.id
              ORDER BY e."createdAt" DESC, e.id DESC
              LIMIT 1
          )
    )
$$;

-- Document numbers (TF-SO-2026-000123). TopFlow's NumberingService increments the counter with
-- INSERT ... ON CONFLICT DO UPDATE on document_sequences, a table every tenant shares; with
-- that UPDATE privilege one tenant could reset or skip everyone's numbering. The same statement
-- runs here as the owner: the API roles may take the next number, nothing else.
CREATE OR REPLACE FUNCTION app.next_document_number(sequence_key text) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    next_value integer;
BEGIN
    IF sequence_key IS NULL OR sequence_key !~ '^TF-(SO|QT|RFQ)-[0-9]{4}$' THEN
        RAISE EXCEPTION 'not a document sequence key: %', sequence_key
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    INSERT INTO public.document_sequences AS s (key, value, "updatedAt")
    VALUES (sequence_key, 1, now())
    ON CONFLICT (key) DO UPDATE SET value = s.value + 1, "updatedAt" = now()
    RETURNING s.value INTO next_value;
    RETURN next_value;
END
$$;

REVOKE ALL ON FUNCTION app.user_id(), app.org_id(), app.context_is_valid(), app.has_trade_access(),
    app.is_tenant_row(text, text), app.org_role(), app.next_document_number(text),
    app.continues_order_timeline(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.user_id(), app.org_id(), app.context_is_valid(), app.has_trade_access(),
    app.is_tenant_row(text, text), app.org_role(), app.next_document_number(text),
    app.continues_order_timeline(text, text, text) TO topflow_app;
GRANT EXECUTE ON FUNCTION app.next_document_number(text) TO topflow_backoffice;

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

-- Members: everyone sees their colleagues and their own memberships. Only the organisation's
-- owner changes or removes members (TopFlow's MEMBERS_MANAGE permission), so a buyer cannot
-- promote themselves. There is no INSERT privilege: joining is a staff flow.
CREATE POLICY members_app_read ON organization_members FOR SELECT TO topflow_app
    USING ("organizationId" = app.org_id() OR "userId" = app.user_id());
CREATE POLICY members_app_update ON organization_members FOR UPDATE TO topflow_app
    USING ("organizationId" = app.org_id() AND (SELECT app.org_role()) = 'OWNER')
    WITH CHECK ("organizationId" = app.org_id());
CREATE POLICY members_app_delete ON organization_members FOR DELETE TO topflow_app
    USING ("organizationId" = app.org_id() AND (SELECT app.org_role()) = 'OWNER');

-- Invitations hold the invitee's e-mail address and a token hash: owners only. An invitation
-- is created in the inviting owner's name and unused; revoking sets revokedAt.
CREATE POLICY invitations_app_read ON organization_invitations FOR SELECT TO topflow_app
    USING ("organizationId" = app.org_id() AND (SELECT app.org_role()) = 'OWNER');
CREATE POLICY invitations_app_insert ON organization_invitations FOR INSERT TO topflow_app
    WITH CHECK ("organizationId" = app.org_id() AND (SELECT app.org_role()) = 'OWNER'
                AND "invitedById" = app.user_id()
                AND "acceptedAt" IS NULL AND "revokedAt" IS NULL);
CREATE POLICY invitations_app_update ON organization_invitations FOR UPDATE TO topflow_app
    USING ("organizationId" = app.org_id() AND (SELECT app.org_role()) = 'OWNER')
    WITH CHECK ("organizationId" = app.org_id());

CREATE POLICY addresses_app ON addresses FOR ALL TO topflow_app
    USING (app.is_tenant_row("organizationId", "userId"))
    WITH CHECK (app.is_tenant_row("organizationId", "userId"));

-- Orders: the organisation's orders, or the customer's own retail orders (TopFlow's
-- listMine filters organizationId IS NULL in the same way).
CREATE POLICY orders_app ON orders FOR ALL TO topflow_app
    USING (app.is_tenant_row("organizationId", "userId"))
    WITH CHECK (app.is_tenant_row("organizationId", "userId"));
-- A new order starts unpaid, waiting for payment or confirmed, and not yet dispatched.
CREATE POLICY orders_app_new ON orders AS RESTRICTIVE FOR INSERT TO topflow_app
    WITH CHECK (status IN ('PENDING_PAYMENT', 'CONFIRMED') AND "paymentStatus" = 'UNPAID'
                AND "paidAt" IS NULL AND "dispatchedAt" IS NULL AND "deliveredAt" IS NULL
                AND "cancelledAt" IS NULL);
-- The only change a customer makes to an order is to cancel it: while it waits for payment or
-- is confirmed and unpaid (TopFlow's isCustomerCancellable), and for an organisation's order
-- only as an owner or approver (hasOrgApprovalRights). Payment, dispatch and delivery are staff
-- flows; the column privileges do not include those columns or any amount.
CREATE POLICY orders_app_cancel ON orders AS RESTRICTIVE FOR UPDATE TO topflow_app
    USING (status IN ('PENDING_PAYMENT', 'CONFIRMED') AND "paymentStatus" <> 'PAID'
           AND ("organizationId" IS NULL OR (SELECT app.org_role()) IN ('OWNER', 'APPROVER')))
    WITH CHECK (status = 'CANCELLED');
-- Child rows follow their order: the subquery is itself filtered by orders_app.
CREATE POLICY order_items_app ON order_items FOR ALL TO topflow_app
    USING (EXISTS (SELECT 1 FROM orders AS o WHERE o.id = order_items."orderId"))
    WITH CHECK (EXISTS (SELECT 1 FROM orders AS o WHERE o.id = order_items."orderId"));
CREATE POLICY order_events_app ON order_status_events FOR ALL TO topflow_app
    USING (EXISTS (SELECT 1 FROM orders AS o WHERE o.id = order_status_events."orderId"))
    WITH CHECK (EXISTS (SELECT 1 FROM orders AS o WHERE o.id = order_status_events."orderId"));
-- Lines belong to placing an order. TopFlow creates the order with its lines and then records
-- its first status event, in one transaction (OrdersService.checkout,
-- OrderWriter.createFromQuotation). A line can therefore be added only to an open, unpaid order
-- whose timeline has not started: never to a paid, dispatched, delivered or cancelled order,
-- and never to an order after its first event.
CREATE POLICY order_items_app_new ON order_items AS RESTRICTIVE FOR INSERT TO topflow_app
    WITH CHECK (EXISTS (
        SELECT 1
        FROM orders AS o
        WHERE o.id = order_items."orderId"
          AND o.status IN ('PENDING_PAYMENT', 'CONFIRMED') AND o."paymentStatus" = 'UNPAID'
          AND o."dispatchedAt" IS NULL AND o."deliveredAt" IS NULL AND o."cancelledAt" IS NULL
          AND NOT EXISTS (SELECT 1 FROM order_status_events AS e WHERE e."orderId" = o.id)
    ));
-- Order history is append-only, and a customer appends only what their own flows write: the
-- first event of an order they place (it starts waiting for payment or confirmed) and the
-- cancellation of an open order (orders_app_cancel), in their own name, continuing the order's
-- timeline and ending in the status the order has. A customer cannot record a status the order
-- does not have, repeat an event, or write one in someone else's name.
CREATE POLICY order_events_app_new ON order_status_events AS RESTRICTIVE FOR INSERT TO topflow_app
    WITH CHECK ("actorId" = app.user_id()
                AND (("fromStatus" IS NULL AND "toStatus" IN ('PENDING_PAYMENT', 'CONFIRMED'))
                     OR ("fromStatus" IN ('PENDING_PAYMENT', 'CONFIRMED')
                         AND "toStatus" = 'CANCELLED'))
                AND app.continues_order_timeline("orderId", "fromStatus"::text,
                                                 "toStatus"::text));

CREATE POLICY rfqs_app ON quote_requests FOR ALL TO topflow_app
    USING (app.is_tenant_row("organizationId", "requestedById"))
    WITH CHECK (app.is_tenant_row("organizationId", "requestedById"));
-- A request starts as submitted. Afterwards a customer can cancel it, close it (by answering its
-- quotation) or send it back for review (by asking for a revision), and only while it is open.
-- The policies check the states a row leaves and enters; the API's RFQ_TRANSITIONS remain the
-- reference for each pair.
CREATE POLICY rfqs_app_new ON quote_requests AS RESTRICTIVE FOR INSERT TO topflow_app
    WITH CHECK (status = 'SUBMITTED');
CREATE POLICY rfqs_app_status ON quote_requests AS RESTRICTIVE FOR UPDATE TO topflow_app
    USING (status IN ('SUBMITTED', 'IN_REVIEW', 'QUOTED'))
    WITH CHECK (status IN ('CANCELLED', 'CLOSED', 'IN_REVIEW'));
CREATE POLICY rfq_items_app ON quote_request_items FOR ALL TO topflow_app
    USING (EXISTS (SELECT 1 FROM quote_requests AS r WHERE r.id = quote_request_items."quoteRequestId"))
    WITH CHECK (EXISTS (SELECT 1 FROM quote_requests AS r
                        WHERE r.id = quote_request_items."quoteRequestId"));

-- Quotations: never drafts (TopFlow's orgList and personalList hide them too).
CREATE POLICY quotations_app ON quotations FOR ALL TO topflow_app
    USING (status <> 'DRAFT' AND app.is_tenant_row("organizationId", "customerId"))
    WITH CHECK (status <> 'DRAFT' AND app.is_tenant_row("organizationId", "customerId"));
-- Answering a quotation: only an open one (sent, or waiting for the organisation's approver)
-- changes, into one of the states a customer can give it. An approval is recorded in the
-- caller's own name, and an expired quotation cannot be accepted. Prices, validity and notes
-- are outside the column privileges.
CREATE POLICY quotations_app_response ON quotations AS RESTRICTIVE FOR UPDATE TO topflow_app
    USING (status IN ('SENT', 'PENDING_APPROVAL'))
    WITH CHECK (status IN ('SENT', 'PENDING_APPROVAL', 'ACCEPTED', 'REJECTED',
                           'REVISION_REQUESTED', 'EXPIRED')
                AND ("approvedById" IS NULL OR "approvedById" = app.user_id())
                AND (status <> 'ACCEPTED' OR "validUntil" >= (now() AT TIME ZONE 'UTC')));
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
