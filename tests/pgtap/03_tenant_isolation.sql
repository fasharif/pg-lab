-- Tenant isolation: one organisation cannot read or change another's rows.
--
-- Runs on the generated data set. Organisation 1 (A) and organisation 2 (B) are real
-- tenants with orders, quotations and members; their owners are users member_user(1, 1)
-- and member_user(2, 1). The expected counts are computed first as the superuser, which
-- bypasses row-level security, then compared with what each role sees.
BEGIN;
SET LOCAL search_path = public, tap;
SELECT plan(27);

CREATE TEMP TABLE ctx AS
SELECT lab.uid('org', 1) AS org_a,
       lab.uid('org', 2) AS org_b,
       lab.uid('user', lab.member_user(1, 1)) AS user_a,
       lab.uid('user', lab.retail_user(1, (lab.dataset_size(lab.scale())).n_orgs)) AS retail;

CREATE TEMP TABLE truth AS
SELECT (SELECT count(*) FROM orders WHERE "organizationId" = c.org_a) AS orders_a,
       (SELECT count(*) FROM orders WHERE "organizationId" IS NULL AND "userId" = c.retail) AS orders_retail,
       (SELECT count(*) FROM orders) AS orders_all,
       (SELECT min(id) FROM orders WHERE "organizationId" = c.org_a) AS order_a,
       (SELECT min(id) FROM orders WHERE "organizationId" = c.org_b) AS order_b,
       (SELECT count(*) FROM quotations WHERE "organizationId" = c.org_a AND status <> 'DRAFT') AS quotations_a,
       (SELECT count(*) FROM products WHERE "isActive" AND NOT "isTradeOnly") AS products_public,
       (SELECT count(*) FROM products WHERE "isActive") AS products_trade
FROM ctx AS c;

GRANT SELECT ON ctx, truth TO topflow_app, topflow_backoffice, topflow_analyst;

-- Sets the request context the way the API would (transaction-local settings).
CREATE FUNCTION pg_temp.act_as(user_id text, org_id text) RETURNS void
LANGUAGE sql AS $$
    SELECT set_config('app.user_id', coalesce(user_id, ''), true),
           set_config('app.org_id', coalesce(org_id, ''), true)
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act_as(text, text) TO topflow_app;

SELECT ok((SELECT orders_a > 0 AND order_b IS NOT NULL AND orders_retail > 0 FROM truth),
          'the data set has orders for both tenants and the retail customer');

-- ─── A member of organisation A, acting for A ──────────────────────────────
SET LOCAL ROLE topflow_app;
DO $$ BEGIN PERFORM pg_temp.act_as(user_a, org_a) FROM ctx; END $$;

SELECT is((SELECT count(*) FROM orders WHERE "organizationId" = (SELECT org_a FROM ctx)),
          (SELECT orders_a FROM truth), 'A sees every one of its orders');
SELECT is((SELECT count(*) FROM orders
           WHERE "organizationId" IS NOT NULL AND "organizationId" <> (SELECT org_a FROM ctx)),
          0::bigint, 'A sees no order of any other organisation');
SELECT is((SELECT count(*) FROM orders WHERE id = (SELECT order_b FROM truth)),
          0::bigint, 'B''s order cannot be read by id');
SELECT is((SELECT count(*) FROM order_items WHERE "orderId" = (SELECT order_b FROM truth)),
          0::bigint, 'B''s order lines cannot be read');
SELECT is((SELECT count(*) FROM order_status_events WHERE "orderId" = (SELECT order_b FROM truth)),
          0::bigint, 'B''s order history cannot be read');
SELECT is((SELECT count(*) FROM quotations), (SELECT quotations_a FROM truth),
          'A sees exactly its own quotations');
SELECT is((SELECT count(*) FROM quotations WHERE status = 'DRAFT'), 0::bigint,
          'draft quotations are never visible to customers');
SELECT is((SELECT count(*) FROM organizations), 1::bigint, 'A sees only its own organisation');
SELECT is((SELECT count(*) FROM products), (SELECT products_trade FROM truth),
          'members of a verified organisation see trade-only products');

SELECT throws_ok(
    format($$INSERT INTO orders (id, "orderNumber", "totalAmount", "shippingAddress", "updatedAt",
                                 "organizationId", "userId")
             VALUES ('rls-test', 'TF-SO-RLS-TEST', 1, 'test', now(), %L, %L)$$, org_b, user_a),
    '42501', NULL, 'A cannot create an order in B''s name')
FROM ctx;
SELECT throws_ok(
    format($$UPDATE orders SET "organizationId" = %L WHERE id = %L$$, c.org_b, t.order_a),
    '42501', NULL, 'A cannot move one of its orders to B')
FROM ctx AS c, truth AS t;
WITH changed AS (
    UPDATE orders SET notes = 'changed by another tenant'
    WHERE id = (SELECT order_b FROM truth)
    RETURNING 1
)
SELECT is(count(*), 0::bigint, 'an update aimed at B''s order changes nothing') FROM changed;
SELECT throws_ok(format($$DELETE FROM orders WHERE id = %L$$, order_a), '42501', NULL,
                 'the API role cannot delete orders at all')
FROM truth;
SELECT throws_ok($$UPDATE audit_logs SET action = 'tampered'$$, '42501', NULL,
                 'audit entries cannot be changed');
SELECT throws_ok($$DELETE FROM audit_logs$$, '42501', NULL, 'audit entries cannot be deleted');
SELECT throws_ok(format($$UPDATE users SET role = 'ADMIN' WHERE id = %L$$, user_a), '42501', NULL,
                 'a customer cannot make themselves an administrator')
FROM ctx;
SELECT throws_ok($$UPDATE organizations SET "creditLimit" = 1000000$$, '42501', NULL,
                 'a customer cannot raise their own credit limit');

-- ─── The same user claims to act for B (forged header) ─────────────────────
DO $$ BEGIN PERFORM pg_temp.act_as(user_a, org_b) FROM ctx; END $$;
SELECT is((SELECT count(*) FROM orders WHERE "organizationId" IS NOT NULL), 0::bigint,
          'a forged organisation id shows no trade orders');
SELECT is((SELECT count(*) FROM products WHERE "isTradeOnly"), 0::bigint,
          'a forged organisation id shows no trade-only products');

-- ─── No request context ────────────────────────────────────────────────────
DO $$ BEGIN PERFORM pg_temp.act_as(NULL, NULL); END $$;
SELECT is((SELECT count(*) FROM orders), 0::bigint, 'without a request context no order is visible');
SELECT is((SELECT count(*) FROM products), (SELECT products_public FROM truth),
          'anonymous shoppers see the public catalogue only');

-- ─── A retail customer ─────────────────────────────────────────────────────
DO $$ BEGIN PERFORM pg_temp.act_as(retail, NULL) FROM ctx; END $$;
SELECT is((SELECT count(*) FROM orders), (SELECT orders_retail FROM truth),
          'a retail customer sees exactly their own orders');

-- ─── Staff and analyst ─────────────────────────────────────────────────────
RESET ROLE;
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

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
