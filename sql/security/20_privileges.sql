-- Least-privilege grants for the lab roles. Applied by ./lab migrate as topflow_migrator
-- (whose sessions run as topflow_owner); idempotent: every run revokes and re-grants.
--
--   topflow_owner       owns everything; nobody logs in as it (NOLOGIN)
--   topflow_migrator    runs migrations as topflow_owner (DDL); no other access path
--   topflow_app         customer-facing API: tenant-scoped by row-level security, and
--                       limited to the columns and states its flows change
--   topflow_backoffice  staff API: every tenant, no DDL, cannot rewrite history
--   topflow_analyst     read-only reporting, every tenant, no personal data (contact
--                       details, addresses, IP addresses)
--
-- Table privileges follow what TopFlow's API does (apps/api/src at 61310d2): customers
-- respond to quotations but never create quotation lines, place orders but never delete
-- them, and nobody updates or deletes audit entries or order status events. Where a customer
-- flow updates a table, the grant names the columns that flow changes, and the row-level
-- security policies (30_row_level_security.sql) limit the rows and the states it may reach.
--
-- Deliberately absent: default privileges. A table added by a future migration is not
-- readable by any role until this file grants it, so it cannot leak before its row-level
-- security policies exist.

-- Start from nothing on every object topflow_owner owns (extension objects in schema
-- public belong to the superuser and keep their own grants).
DO $$
DECLARE
    item record;
BEGIN
    FOR item IN
        SELECT c.oid::regclass AS name, c.relkind
        FROM pg_class AS c
        WHERE c.relnamespace = 'public'::regnamespace
          AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
          AND c.relowner = 'topflow_owner'::regrole
    LOOP
        EXECUTE format('REVOKE ALL ON %s %s FROM topflow_app, topflow_backoffice, topflow_analyst',
                       CASE item.relkind WHEN 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, item.name);
    END LOOP;
END
$$;
GRANT USAGE ON SCHEMA public TO topflow_app, topflow_backoffice, topflow_analyst;
-- postgres_exporter reads the pg_stat_statements view, which lives in schema public.
GRANT USAGE ON SCHEMA public TO monitor;

-- ─── Customer-facing API ────────────────────────────────────────────────────
-- What each customer flow may change (TopFlow service in brackets):
--   orders          place one; cancel it: status and the cancellation fields (OrdersService)
--   quotations      answer one: status, response and approval fields; never prices, validity
--                   or notes (QuotationsService.respond, decideApproval, personalRespond)
--   quote_requests  submit one; cancel or close it: status (RfqService, closeRfq)
--   organization_members  owners change a member's role or approval limit, or remove them
--                   (OrganizationsService); joining an organisation is a staff flow: no INSERT
--   organization_invitations  owners invite and revoke (InvitationsService); accepting is a
--                   staff flow
--   users, organizations  profile columns only; creating an organisation (a trade account,
--                   with its owner membership) is a staff flow: no INSERT on organizations
--   document_sequences  no table privilege: numbers come from app.next_document_number()
GRANT SELECT, INSERT, UPDATE, DELETE ON addresses TO topflow_app;
GRANT SELECT, INSERT ON orders, quote_requests, organization_invitations TO topflow_app;
GRANT UPDATE (status, "cancelledAt", "cancellationReason", "updatedAt") ON orders TO topflow_app;
GRANT UPDATE (status, "updatedAt") ON quote_requests TO topflow_app;
GRANT UPDATE ("revokedAt") ON organization_invitations TO topflow_app;
GRANT SELECT, DELETE ON organization_members TO topflow_app;
GRANT UPDATE (role, "approvalLimit") ON organization_members TO topflow_app;
GRANT SELECT ON quotations TO topflow_app;
GRANT UPDATE (status, "respondedAt", "respondedById", "responseNote", "purchaseOrderNumber",
              "approvedById", "approvedAt", "updatedAt")
    ON quotations TO topflow_app;
-- Customers edit their profile and their organisation's details, but not the columns that
-- back-office staff control: role and active flag, verification, credit and discount.
GRANT SELECT, INSERT ON users TO topflow_app;
GRANT UPDATE ("fullName", "companyName", "phoneNumber", "birthDate", gender, "updatedAt",
              "lastLoginAt", "lastSessionId", "emailVerifiedAt")
    ON users TO topflow_app;
GRANT SELECT ON organizations TO topflow_app;
GRANT UPDATE (name, "legalName", type, "tradeLicenseNumber", trn, email, "phoneNumber",
              "updatedAt")
    ON organizations TO topflow_app;
GRANT SELECT, INSERT ON quote_request_items, order_items, audit_logs, order_status_events
TO topflow_app;
GRANT SELECT ON quotation_items, products, categories TO topflow_app;

-- ─── Staff API ──────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON
    users, organizations, organization_members, organization_invitations, addresses,
    quote_requests, quote_request_items, quotations, quotation_items, orders, order_items,
    products, categories
TO topflow_backoffice;
-- Staff read the counters; new numbers come from app.next_document_number(), as for the API.
GRANT SELECT ON document_sequences TO topflow_backoffice;
GRANT SELECT, INSERT ON audit_logs, order_status_events TO topflow_backoffice;
GRANT DELETE ON organization_members, addresses, quotations, quotation_items, categories
TO topflow_backoffice;
GRANT USAGE ON SEQUENCE categories_id_seq TO topflow_backoffice;

-- carts and cart_items are not used by the current API: no role gets them.

-- ─── Lab helpers ────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA lab TO topflow_app, topflow_backoffice, topflow_analyst;
GRANT SELECT, INSERT ON lab.heartbeat TO topflow_app;
GRANT SELECT ON lab.settings TO topflow_app, topflow_backoffice, topflow_analyst;

-- ─── Analyst ────────────────────────────────────────────────────────────────
-- SELECT on every column except personal data: contact details, addresses and the IP
-- addresses in the audit trail. Column privileges are granted
-- per table from the catalogue, so a new column is hidden until it is reviewed here.
DO $$
DECLARE
    target record;
    columns text;
BEGIN
    FOR target IN
        SELECT c.relname
        FROM pg_class AS c
        WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
          AND c.relname NOT IN ('carts', 'cart_items')
        ORDER BY c.relname
    LOOP
        SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO columns
        FROM pg_attribute AS a
        WHERE a.attrelid = format('public.%I', target.relname)::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
          AND (target.relname, a.attname::text) NOT IN (
              ('users', 'email'), ('users', 'fullName'), ('users', 'phoneNumber'),
              ('users', 'birthDate'), ('users', 'gender'), ('users', 'lastSessionId'),
              ('addresses', 'contactName'), ('addresses', 'phoneNumber'),
              ('addresses', 'line1'), ('addresses', 'line2'),
              ('quote_requests', 'contactName'), ('quote_requests', 'contactEmail'),
              ('quote_requests', 'contactPhone'),
              ('organization_invitations', 'email'), ('organization_invitations', 'tokenHash'),
              ('orders', 'shippingAddress'), ('orders', 'deliveryAddress'),
              -- An IP address next to a user id is personal data (UAE PDPL, GDPR).
              ('audit_logs', 'ipAddress')
          );
        EXECUTE format('GRANT SELECT (%s) ON public.%I TO topflow_analyst', columns, target.relname);
    END LOOP;
END
$$;
