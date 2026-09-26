-- Tenant isolation: one organisation cannot read or change another's rows, and a customer
-- changes only what the customer flows change.
--
-- Runs on the generated data set. Organisation 1 (A) and organisation 2 (B) are generated
-- tenants with orders, quotations and members: member_user(o, 1) is the owner of organisation
-- o, member_user(o, 2) its approver, the others buyers. A few rows are adjusted inside this
-- transaction (an open order, an open quotation, invitations) so that every check has a row to
-- act on; everything is rolled back at the end.
--
-- The read checks are table-driven: for every tenant table, the rows A's owner should see when
-- acting for A are computed first as the superuser (which bypasses row-level security, and
-- without the policy functions), then compared with what topflow_app sees. Write checks go
-- through pg_temp.outcome(), which reports an error as a result instead of aborting the file,
-- so a broken policy shows up as failed tests. The last section breaks two policies inside the
-- transaction and checks that the same probes then see other tenants' rows.
BEGIN;
SET LOCAL search_path = public, tap;
SELECT plan(96);

CREATE TEMP TABLE ctx AS
SELECT lab.uid('org', 1) AS org_a,
       lab.uid('org', 2) AS org_b,
       lab.uid('user', lab.member_user(1, 1)) AS user_a,
       lab.uid('user', lab.member_user(1, 4)) AS buyer_a,
       lab.uid('user', lab.member_user(1, 5)) AS member_a,
       lab.uid('user', lab.member_user(2, 1)) AS user_b,
       lab.uid('user', lab.retail_user(1, (lab.dataset_size(lab.scale())).n_orgs)) AS retail;

-- ─── Fixtures: rows for the write checks ───────────────────────────────────
CREATE TEMP TABLE fx AS
SELECT (SELECT min(id) FROM orders WHERE "organizationId" = c.org_a) AS order_open,
       (SELECT min(id) FROM orders WHERE "organizationId" = c.org_a
        AND id > (SELECT min(id) FROM orders WHERE "organizationId" = c.org_a)) AS order_open2,
       (SELECT max(id) FROM orders WHERE "organizationId" = c.org_a) AS order_done,
       (SELECT min(id) FROM orders WHERE "organizationId" = c.org_b) AS order_b,
       (SELECT min(id) FROM quotations WHERE "organizationId" = c.org_a) AS quote_open,
       (SELECT max(id) FROM quotations WHERE "organizationId" = c.org_a) AS quote_expired,
       (SELECT min(id) FROM quotations WHERE "organizationId" = c.org_a
        AND id > (SELECT min(id) FROM quotations WHERE "organizationId" = c.org_a)) AS quote_other,
       (SELECT min(id) FROM quote_requests WHERE "organizationId" = c.org_a) AS rfq_a,
       (SELECT min(id) FROM quote_requests WHERE "organizationId" = c.org_b) AS rfq_b,
       (SELECT min(id) FROM addresses WHERE "organizationId" = c.org_b) AS address_b,
       (SELECT id FROM organization_members
        WHERE "organizationId" = c.org_a AND "userId" = c.member_a) AS membership_member_a
FROM ctx AS c;

UPDATE orders SET status = 'CONFIRMED', "paymentStatus" = 'UNPAID', "paidAt" = NULL,
                  "dispatchedAt" = NULL, "deliveredAt" = NULL, "cancelledAt" = NULL
WHERE id IN (SELECT order_open FROM fx UNION ALL SELECT order_open2 FROM fx);
UPDATE orders SET status = 'DELIVERED', "paymentStatus" = 'PAID'
WHERE id = (SELECT order_done FROM fx);
UPDATE quotations SET status = 'SENT', "approvedById" = NULL,
                      "validUntil" = (now() AT TIME ZONE 'UTC') + interval '10 days'
WHERE id IN (SELECT quote_open FROM fx UNION ALL SELECT quote_other FROM fx);
UPDATE quotations SET status = 'SENT', "approvedById" = NULL,
                      "validUntil" = (now() AT TIME ZONE 'UTC') - interval '1 day'
WHERE id = (SELECT quote_expired FROM fx);
UPDATE quote_requests SET status = 'SUBMITTED' WHERE id = (SELECT rfq_a FROM fx);
-- Organisations 1 and 2 have no generated invitations; one each, and an audit entry that A's
-- owner wrote while acting for B (it must not show up when they act for A).
INSERT INTO organization_invitations (id, "organizationId", email, role, "tokenHash",
                                      "invitedById", "expiresAt")
SELECT 'rls-invitation-' || t.tenant, t.org, 'rls-' || t.tenant || '@example.com', 'BUYER',
       md5('rls-invitation:' || t.tenant), t.owner, (now() AT TIME ZONE 'UTC') + interval '7 days'
FROM ctx AS c
CROSS JOIN LATERAL (VALUES ('a', c.org_a, c.user_a), ('b', c.org_b, c.user_b)) AS t (tenant, org, owner);
INSERT INTO audit_logs (id, "userId", action, "entityType", "entityId", "organizationId")
SELECT 'rls-audit-' || t.tenant, c.user_a, 'RLS_TEST', 'Organization', t.org, t.org
FROM ctx AS c CROSS JOIN LATERAL (VALUES ('a', c.org_a), ('b', c.org_b)) AS t (tenant, org);
-- The open orders' history: one first event each, as TopFlow's checkout records it.
DELETE FROM order_status_events
WHERE "orderId" IN (SELECT order_open FROM fx UNION ALL SELECT order_open2 FROM fx);
INSERT INTO order_status_events (id, "orderId", "fromStatus", "toStatus", "actorId", "createdAt")
SELECT 'rls-event-open-' || v.n, v.order_id, NULL, 'CONFIRMED', c.user_a,
       (now() AT TIME ZONE 'UTC') - interval '1 day'
FROM ctx AS c, fx AS f
CROSS JOIN LATERAL (VALUES (1, f.order_open), (2, f.order_open2)) AS v (n, order_id);
-- Templates for the rows a customer writes when placing an order: copies of generated rows, so
-- that every NOT NULL column has a value, turned into a new open order of A and one line.
CREATE TEMP TABLE new_order AS
SELECT o.* FROM orders AS o WHERE o.id = (SELECT order_open FROM fx);
UPDATE new_order
SET id = 'rls-new-order', "orderNumber" = 'TF-SO-RLS-NEW', status = 'CONFIRMED',
    "paymentStatus" = 'UNPAID', "paidAt" = NULL, "dispatchedAt" = NULL, "deliveredAt" = NULL,
    "cancelledAt" = NULL, "quotationId" = NULL,
    "organizationId" = (SELECT org_a FROM ctx), "userId" = (SELECT user_a FROM ctx);
CREATE TEMP TABLE new_line AS
SELECT i.* FROM order_items AS i ORDER BY i.id LIMIT 1;
UPDATE new_line SET id = 'rls-new-line', "orderId" = 'rls-new-order';

-- ─── Truth: what A's owner, acting for A, should see ───────────────────────
CREATE TEMP TABLE expected (table_name text, id text, PRIMARY KEY (table_name, id));
INSERT INTO expected
SELECT 'users', u.id FROM users AS u, ctx AS c
WHERE u.id = c.user_a
   OR u.id IN (SELECT m."userId" FROM organization_members AS m WHERE m."organizationId" = c.org_a)
UNION ALL
SELECT 'organizations', c.org_a FROM ctx AS c
UNION ALL
SELECT 'organization_members', m.id FROM organization_members AS m, ctx AS c
WHERE m."organizationId" = c.org_a OR m."userId" = c.user_a
UNION ALL
SELECT 'organization_invitations', i.id FROM organization_invitations AS i, ctx AS c
WHERE i."organizationId" = c.org_a
UNION ALL
SELECT 'addresses', a.id FROM addresses AS a, ctx AS c
WHERE a."organizationId" = c.org_a OR (a."organizationId" IS NULL AND a."userId" = c.user_a)
UNION ALL
SELECT 'orders', o.id FROM orders AS o, ctx AS c
WHERE o."organizationId" = c.org_a OR (o."organizationId" IS NULL AND o."userId" = c.user_a)
UNION ALL
SELECT 'order_items', i.id FROM order_items AS i JOIN orders AS o ON o.id = i."orderId", ctx AS c
WHERE o."organizationId" = c.org_a OR (o."organizationId" IS NULL AND o."userId" = c.user_a)
UNION ALL
SELECT 'order_status_events', e.id
FROM order_status_events AS e JOIN orders AS o ON o.id = e."orderId", ctx AS c
WHERE o."organizationId" = c.org_a OR (o."organizationId" IS NULL AND o."userId" = c.user_a)
UNION ALL
SELECT 'quote_requests', r.id FROM quote_requests AS r, ctx AS c
WHERE r."organizationId" = c.org_a OR (r."organizationId" IS NULL AND r."requestedById" = c.user_a)
UNION ALL
SELECT 'quote_request_items', i.id
FROM quote_request_items AS i JOIN quote_requests AS r ON r.id = i."quoteRequestId", ctx AS c
WHERE r."organizationId" = c.org_a OR (r."organizationId" IS NULL AND r."requestedById" = c.user_a)
UNION ALL
SELECT 'quotations', q.id FROM quotations AS q, ctx AS c
WHERE q.status <> 'DRAFT'
  AND (q."organizationId" = c.org_a OR (q."organizationId" IS NULL AND q."customerId" = c.user_a))
UNION ALL
SELECT 'quotation_items', i.id
FROM quotation_items AS i JOIN quotations AS q ON q.id = i."quotationId", ctx AS c
WHERE q.status <> 'DRAFT'
  AND (q."organizationId" = c.org_a OR (q."organizationId" IS NULL AND q."customerId" = c.user_a))
UNION ALL
SELECT 'audit_logs', l.id FROM audit_logs AS l, ctx AS c
WHERE l."userId" = c.user_a AND (l."organizationId" IS NULL OR l."organizationId" = c.org_a);
ANALYZE expected;

CREATE TEMP TABLE truth AS
SELECT (SELECT count(*) FROM orders WHERE "organizationId" IS NULL AND "userId" = c.retail) AS orders_retail,
       (SELECT count(*) FROM orders) AS orders_all,
       (SELECT count(*) FROM orders WHERE "organizationId" = c.org_b) AS orders_b,
       (SELECT count(*) FROM products WHERE "isActive" AND NOT "isTradeOnly") AS products_public,
       (SELECT count(*) FROM products WHERE "isActive") AS products_trade
FROM ctx AS c;

-- Rows of a table that are not in A's expected set: run as the superuser, the truth; run as
-- topflow_app, the rows of others that A can see.
CREATE FUNCTION pg_temp.count_outside(table_name text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    result bigint;
BEGIN
    EXECUTE format('SELECT count(*) FROM public.%I AS t WHERE NOT EXISTS '
                   '(SELECT 1 FROM pg_temp.expected AS e WHERE e.table_name = %L AND e.id = t.id)',
                   table_name, table_name) INTO result;
    RETURN result;
END
$$;

CREATE FUNCTION pg_temp.count_all(table_name text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    result bigint;
BEGIN
    EXECUTE format('SELECT count(*) FROM public.%I', table_name) INTO result;
    RETURN result;
END
$$;

-- Runs a statement and reports what happened: 'N rows' or 'error SQLSTATE'.
CREATE FUNCTION pg_temp.outcome(statement text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    affected bigint;
BEGIN
    EXECUTE statement;
    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected || ' rows';
EXCEPTION WHEN OTHERS THEN
    RETURN 'error ' || SQLSTATE;
END
$$;

-- Sets the request context the way the API would (transaction-local settings).
CREATE FUNCTION pg_temp.act_as(user_id text, org_id text) RETURNS void
LANGUAGE sql AS $$
    SELECT set_config('app.user_id', coalesce(user_id, ''), true),
           set_config('app.org_id', coalesce(org_id, ''), true)
$$;

CREATE TEMP TABLE tenant_tables AS
SELECT unnest(ARRAY[
    'users', 'organizations', 'organization_members', 'organization_invitations', 'addresses',
    'orders', 'order_items', 'order_status_events', 'quote_requests', 'quote_request_items',
    'quotations', 'quotation_items', 'audit_logs'
]) AS table_name;

GRANT SELECT ON ctx, fx, expected, truth, tenant_tables, new_order, new_line
    TO topflow_app, topflow_backoffice, topflow_analyst;
GRANT EXECUTE ON FUNCTION pg_temp.count_outside(text), pg_temp.count_all(text),
    pg_temp.outcome(text), pg_temp.act_as(text, text) TO topflow_app;

SELECT is(
    (SELECT string_agg(t.table_name, ', ' ORDER BY t.table_name) FROM tenant_tables AS t
     WHERE NOT EXISTS (SELECT 1 FROM expected AS e WHERE e.table_name = t.table_name)
        OR pg_temp.count_outside(t.table_name) = 0),
    NULL,
    'every tenant table has rows of A and rows of others (so no check below is empty)'
);
SELECT ok((SELECT order_b IS NOT NULL AND quote_other IS NOT NULL AND rfq_b IS NOT NULL
                  AND address_b IS NOT NULL AND membership_member_a IS NOT NULL FROM fx)
          AND (SELECT orders_retail > 0 FROM truth),
          'the fixtures found their rows');

-- ─── Reads: A's owner, acting for A, on every tenant table ─────────────────
SET LOCAL ROLE topflow_app;
DO $$ BEGIN PERFORM pg_temp.act_as(user_a, org_a) FROM ctx; END $$;

SELECT is(pg_temp.count_outside(t.table_name), 0::bigint,
          format('%s: A sees no row of another tenant or customer', t.table_name))
FROM tenant_tables AS t;
SELECT is(pg_temp.count_all(t.table_name),
          (SELECT count(*) FROM expected AS e WHERE e.table_name = t.table_name),
          format('%s: A sees every one of its own rows', t.table_name))
FROM tenant_tables AS t;
SELECT is((SELECT count(*) FROM quotations WHERE status = 'DRAFT'), 0::bigint,
          'draft quotations are never visible to customers');
SELECT is((SELECT count(*) FROM products), (SELECT products_trade FROM truth),
          'members of a verified organisation see trade-only products');
SELECT is(pg_temp.outcome('SELECT * FROM document_sequences'), 'error 42501',
          'the API cannot read or write document_sequences directly');

-- ─── Writes aimed at B ─────────────────────────────────────────────────────
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO orders (id, "orderNumber", "totalAmount", "shippingAddress", "updatedAt",
                          "organizationId", "userId", status)
      VALUES ('rls-test', 'TF-SO-RLS-TEST', 1, 'test', now(), %L, %L, 'CONFIRMED')$$,
    org_b, user_a)), 'error 42501', 'A cannot create an order in B''s name')
FROM ctx;
SELECT is(pg_temp.outcome(format(
    $$UPDATE orders SET status = 'CANCELLED', "cancelledAt" = now() WHERE id = %L$$, order_b)),
    '0 rows', 'an update aimed at B''s order changes nothing')
FROM fx;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO order_items (id, "orderId", "productName", sku, "unitPrice", quantity,
                               "totalPrice")
      VALUES ('rls-line', %L, 'x', 'X', 1, 1, 1)$$, order_b)),
    'error 42501', 'A cannot add a line to B''s order')
FROM fx;
SELECT is(pg_temp.outcome(format($$UPDATE orders SET "organizationId" = %L WHERE id = %L$$,
                                 c.org_b, f.order_open)),
          'error 42501', 'A cannot move one of its orders to B')
FROM ctx AS c, fx AS f;
SELECT is(pg_temp.outcome(format($$UPDATE addresses SET city = 'Elsewhere' WHERE id = %L$$,
                                 address_b)),
          '0 rows', 'A cannot change B''s address')
FROM fx;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO addresses (id, "organizationId", label, "contactName", "phoneNumber", line1,
                             area, city, emirate, "updatedAt")
      VALUES ('rls-address', %L, 'x', 'x', 'x', 'x', 'x', 'x', 'DUBAI', now())$$, org_b)),
    'error 42501', 'A cannot add an address to B')
FROM ctx;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO quote_requests (id, number, "organizationId", "requestedById", "updatedAt")
      VALUES ('rls-rfq', 'TF-RFQ-RLS', %L, %L, now())$$, org_b, user_a)),
    'error 42501', 'A cannot submit a request for a quotation in B''s name')
FROM ctx;
SELECT is(pg_temp.outcome(format($$UPDATE quote_requests SET status = 'CANCELLED' WHERE id = %L$$,
                                 rfq_b)),
          '0 rows', 'A cannot cancel B''s request for a quotation')
FROM fx;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO organization_invitations (id, "organizationId", email, "tokenHash",
                                            "invitedById", "expiresAt")
      VALUES ('rls-invite', %L, 'x@example.com', 'x', %L, now())$$, org_b, user_a)),
    'error 42501', 'A cannot invite anyone into B')
FROM ctx;
SELECT is(pg_temp.outcome($$UPDATE organization_invitations SET "revokedAt" = now()
                            WHERE id = 'rls-invitation-b'$$),
          '0 rows', 'A cannot revoke B''s invitations');
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO organization_members (id, "organizationId", "userId", role)
      VALUES ('rls-member', %L, %L, 'BUYER')$$, org_a, user_b)),
    'error 42501', 'A''s owner cannot add a user to A directly (joining is a staff flow)')
FROM ctx;
SELECT is((SELECT count(*) FROM users WHERE id = (SELECT user_b FROM ctx)), 0::bigint,
          'so B''s owner''s profile (e-mail, name, phone) stays out of A''s reach');

-- ─── What a customer may change on their own rows ──────────────────────────
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO orders (id, "orderNumber", "totalAmount", "shippingAddress", "updatedAt",
                          "organizationId", "userId", status, "paymentStatus", "paidAt")
      VALUES ('rls-paid', 'TF-SO-RLS-PAID', 1, 'test', now(), %L, %L, 'DELIVERED', 'PAID', now())$$,
    org_a, user_a)), 'error 42501', 'a new order cannot start paid or delivered')
FROM ctx;
SELECT is(pg_temp.outcome(format($$UPDATE orders SET "paymentStatus" = 'PAID' WHERE id = %L$$,
                                 order_open)),
          'error 42501', 'a customer cannot mark their order paid')
FROM fx;
SELECT is(pg_temp.outcome(format($$UPDATE orders SET "totalAmount" = 0.01 WHERE id = %L$$,
                                 order_open)),
          'error 42501', 'a customer cannot change the amount of their order')
FROM fx;
SELECT is(pg_temp.outcome(format($$UPDATE orders SET status = 'DELIVERED' WHERE id = %L$$,
                                 order_open)),
          'error 42501', 'a customer cannot move their order to delivered')
FROM fx;
SELECT is(pg_temp.outcome(format(
    $$UPDATE orders SET status = 'CANCELLED', "cancelledAt" = now(),
                        "cancellationReason" = 'test', "updatedAt" = now()
      WHERE id = %L$$, order_open)),
    '1 rows', 'the owner can cancel an open, unpaid order of the organisation')
FROM fx;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO order_status_events (id, "orderId", "fromStatus", "toStatus", "actorId")
      VALUES ('rls-event-cancel', %L, 'CONFIRMED', 'CANCELLED', %L)$$, f.order_open, c.user_a)),
    '1 rows', 'the owner records the cancellation in the order''s history, in their own name')
FROM ctx AS c, fx AS f;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO order_status_events (id, "orderId", "fromStatus", "toStatus", "actorId")
      VALUES ('rls-event-cancel-2', %L, 'CONFIRMED', 'CANCELLED', %L)$$, f.order_open, c.user_a)),
    'error 42501', 'the same cancellation cannot be recorded twice')
FROM ctx AS c, fx AS f;
SELECT is(pg_temp.outcome(format($$UPDATE orders SET status = 'CANCELLED' WHERE id = %L$$,
                                 order_done)),
          '0 rows', 'a delivered and paid order cannot be cancelled by the customer')
FROM fx;
SELECT is(pg_temp.outcome(format($$DELETE FROM orders WHERE id = %L$$, order_done)),
          'error 42501', 'the API role cannot delete orders at all')
FROM fx;

-- Order lines and history: written while placing an order, then closed.
SELECT is(pg_temp.outcome($$INSERT INTO orders SELECT * FROM pg_temp.new_order$$), '1 rows',
          'a customer can place an open, unpaid order');
SELECT is(pg_temp.outcome($$INSERT INTO order_items SELECT * FROM pg_temp.new_line$$), '1 rows',
          'and add its lines while placing it');
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO order_status_events (id, "orderId", "fromStatus", "toStatus", "actorId")
      VALUES ('rls-new-event-other', 'rls-new-order', NULL, 'CONFIRMED', %L)$$, buyer_a)),
    'error 42501', 'the order''s first event cannot be written in another member''s name')
FROM ctx;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO order_status_events (id, "orderId", "fromStatus", "toStatus", "actorId")
      VALUES ('rls-new-event', 'rls-new-order', NULL, 'CONFIRMED', %L)$$, user_a)),
    '1 rows', 'the customer records the order''s first event in their own name')
FROM ctx;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO order_status_events (id, "orderId", "fromStatus", "toStatus", "actorId")
      VALUES ('rls-new-event-2', 'rls-new-order', NULL, 'CONFIRMED', %L)$$, user_a)),
    'error 42501', 'the first event cannot be recorded twice')
FROM ctx;
SELECT is(pg_temp.outcome(
    $$INSERT INTO order_items (id, "orderId", "productName", sku, "unitPrice", quantity,
                               "totalPrice")
      VALUES ('rls-new-line-2', 'rls-new-order', 'x', 'X', 0.01, 1000, 10)$$),
    'error 42501', 'once the order''s history has started, no line can be added to it');
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO order_items (id, "orderId", "productName", sku, "unitPrice", quantity,
                               "totalPrice")
      VALUES ('rls-line-done', %L, 'x', 'X', 0.01, 1000, 10)$$, order_done)),
    'error 42501', 'a customer cannot add a line to a delivered, paid order')
FROM fx;
SELECT is(pg_temp.outcome(format(
    $$INSERT INTO order_status_events (id, "orderId", "fromStatus", "toStatus", "actorId")
      VALUES ('rls-event-forged', %L, 'DELIVERED', 'CANCELLED', %L)$$, f.order_done, c.user_a)),
    'error 42501', 'a customer cannot record a status change the order did not make')
FROM ctx AS c, fx AS f;
SELECT is(pg_temp.outcome($$UPDATE order_status_events SET "toStatus" = 'CANCELLED'$$),
          'error 42501', 'order history cannot be changed');
SELECT is(pg_temp.outcome($$DELETE FROM order_status_events$$), 'error 42501',
          'order history cannot be deleted');
SELECT is(pg_temp.outcome(format($$UPDATE quotations SET total = 0.01 WHERE id = %L$$,
                                 quote_open)),
          'error 42501', 'a customer cannot change the prices of a quotation')
FROM fx;
SELECT is(pg_temp.outcome(format(
    $$UPDATE quotations SET "validUntil" = now() + interval '10 years' WHERE id = %L$$,
    quote_expired)), 'error 42501', 'a customer cannot extend the validity of a quotation')
FROM fx;
SELECT is(pg_temp.outcome(format(
    $$UPDATE quotations SET status = 'ACCEPTED', "approvedById" = %L, "approvedAt" = now()
      WHERE id = %L$$, c.user_a, f.quote_expired)),
    'error 42501', 'an expired quotation cannot be accepted')
FROM ctx AS c, fx AS f;
SELECT is(pg_temp.outcome(format(
    $$UPDATE quotations SET status = 'ACCEPTED', "approvedById" = %L, "approvedAt" = now()
      WHERE id = %L$$, c.buyer_a, f.quote_other)),
    'error 42501', 'an approval cannot be recorded in another member''s name')
FROM ctx AS c, fx AS f;
SELECT is(pg_temp.outcome(format(
    $$UPDATE quotations SET status = 'ACCEPTED', "approvedById" = %L, "approvedAt" = now(),
                            "respondedAt" = now(), "respondedById" = %L
      WHERE id = %L$$, c.user_a, c.user_a, f.quote_open)),
    '1 rows', 'a customer can accept an open, valid quotation in their own name')
FROM ctx AS c, fx AS f;
SELECT is(pg_temp.outcome(format($$UPDATE quotations SET status = 'SENT' WHERE id = %L$$,
                                 quote_open)),
          '0 rows', 'an accepted quotation cannot be reopened')
FROM fx;
SELECT is(pg_temp.outcome(format($$UPDATE quote_requests SET status = 'QUOTED' WHERE id = %L$$,
                                 rfq_a)),
          'error 42501', 'a customer cannot mark their own request as quoted')
FROM fx;
SELECT is(pg_temp.outcome($$UPDATE audit_logs SET action = 'tampered'$$), 'error 42501',
          'audit entries cannot be changed');
SELECT is(pg_temp.outcome($$DELETE FROM audit_logs$$), 'error 42501',
          'audit entries cannot be deleted');
SELECT is(pg_temp.outcome(format($$UPDATE users SET role = 'ADMIN' WHERE id = %L$$, user_a)),
          'error 42501', 'a customer cannot make themselves an administrator')
FROM ctx;
SELECT is(pg_temp.outcome($$UPDATE organizations SET "creditLimit" = 1000000$$), 'error 42501',
          'a customer cannot raise their own credit limit');
SELECT is(pg_temp.outcome(
    $$INSERT INTO organizations (id, name, "updatedAt") VALUES ('rls-org', 'x', now())$$),
    'error 42501', 'registering an organisation is a staff flow, not a customer privilege');
SELECT is(pg_temp.outcome($$UPDATE document_sequences SET value = 0$$), 'error 42501',
          'the API cannot reset document numbering');
SELECT is((SELECT app.next_document_number('TF-SO-2099') + 0),
          1, 'app.next_document_number starts a new sequence at 1');
SELECT is((SELECT app.next_document_number('TF-SO-2099')),
          2, 'and hands out the next number on each call');
SELECT is(pg_temp.outcome($$SELECT app.next_document_number('ANYTHING')$$), 'error 22023',
          'app.next_document_number accepts only document sequence keys');

-- ─── Membership: only the owner manages members ────────────────────────────
SELECT is(pg_temp.outcome(format($$UPDATE organization_members SET role = 'APPROVER' WHERE id = %L$$,
                                 membership_member_a)),
          '1 rows', 'the owner can change a member''s role')
FROM fx;
DO $$ BEGIN PERFORM pg_temp.act_as(buyer_a, org_a) FROM ctx; END $$;
SELECT is(pg_temp.outcome(format(
    $$UPDATE organization_members SET role = 'OWNER', "approvalLimit" = 1000000
      WHERE "userId" = %L$$, buyer_a)),
    '0 rows', 'a buyer cannot promote themselves or raise their approval limit')
FROM ctx;
SELECT is(pg_temp.outcome(format($$DELETE FROM organization_members WHERE "organizationId" = %L$$,
                                 org_a)),
          '0 rows', 'a buyer cannot remove members')
FROM ctx;
SELECT is((SELECT count(*) FROM organization_invitations), 0::bigint,
          'a buyer cannot see invitations (they hold e-mail addresses)');
SELECT is(pg_temp.outcome(format($$UPDATE orders SET status = 'CANCELLED' WHERE id = %L$$,
                                 order_open2)),
          '0 rows', 'a buyer cannot cancel the organisation''s orders (owners and approvers can)')
FROM fx;

-- ─── The same user claims to act for B (forged header) ─────────────────────
DO $$ BEGIN PERFORM pg_temp.act_as(user_a, org_b) FROM ctx; END $$;
SELECT is((SELECT count(*) FROM orders WHERE "organizationId" IS NOT NULL), 0::bigint,
          'a forged organisation id shows no trade orders');
SELECT is((SELECT count(*) FROM products WHERE "isTradeOnly"), 0::bigint,
          'a forged organisation id shows no trade-only products');

-- ─── The trust boundary (docs/security.md) ─────────────────────────────────
-- The context is asserted by the session. A session that claims to be B's owner is B's owner
-- as far as the policies can tell: row-level security here guards against queries that forget
-- their tenant filter, not against code that can run arbitrary SQL as topflow_app.
DO $$ BEGIN PERFORM pg_temp.act_as(user_b, org_b) FROM ctx; END $$;
SELECT is((SELECT count(*) FROM orders WHERE "organizationId" = (SELECT org_b FROM ctx)),
          (SELECT orders_b FROM truth),
          'trust boundary: a session that sets B''s owner as its user reads B''s orders');

-- ─── No request context ────────────────────────────────────────────────────
DO $$ BEGIN PERFORM pg_temp.act_as(NULL, NULL); END $$;
SELECT is((SELECT count(*) FROM orders), 0::bigint, 'without a request context no order is visible');
SELECT is((SELECT count(*) FROM users), 0::bigint, 'without a request context no user is visible');
SELECT is((SELECT count(*) FROM products), (SELECT products_public FROM truth),
          'anonymous shoppers see the public catalogue only');

-- ─── A retail customer ─────────────────────────────────────────────────────
DO $$ BEGIN PERFORM pg_temp.act_as(retail, NULL) FROM ctx; END $$;
SELECT is((SELECT count(*) FROM orders), (SELECT orders_retail FROM truth),
          'a retail customer sees exactly their own orders');

-- ─── Staff and analyst ─────────────────────────────────────────────────────
RESET ROLE;
-- The write checks placed one order since the truth was computed.
UPDATE truth SET orders_all = (SELECT count(*) FROM orders);
SET LOCAL ROLE topflow_backoffice;
SELECT is((SELECT count(*) FROM orders), (SELECT orders_all FROM truth),
          'back-office staff see every organisation''s orders');
SELECT throws_ok($$DELETE FROM audit_logs$$, '42501', NULL, 'staff cannot delete audit entries either');

RESET ROLE;
SET LOCAL ROLE topflow_analyst;
SELECT is((SELECT count(*) FROM orders), (SELECT orders_all FROM truth),
          'the analyst reads every organisation');
SELECT throws_ok($$SELECT email FROM users LIMIT 1$$, '42501', NULL,
                 'the analyst cannot read e-mail addresses');

-- ─── Self-check: the probes detect a broken policy ─────────────────────────
-- Inside this transaction only: disable the orders and users policies, then run the same
-- probes as A. If these fail, the checks above could not have failed either.
RESET ROLE;
ALTER POLICY orders_app ON orders USING (true) WITH CHECK (true);
ALTER POLICY users_app_read ON users USING (true);
SET LOCAL ROLE topflow_app;
DO $$ BEGIN PERFORM pg_temp.act_as(user_a, org_a) FROM ctx; END $$;
SELECT cmp_ok(pg_temp.count_outside('orders'), '>', 0::bigint,
              'self-check: with orders_app disabled, the probe sees other tenants'' orders');
SELECT cmp_ok(pg_temp.count_outside('users'), '>', 0::bigint,
              'self-check: with users_app_read disabled, the probe sees other tenants'' users');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
