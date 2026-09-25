-- pg-lab data generator.
--
--   psql -v scale=100000 -f sql/generate/generate.sql      (./lab seed --scale 100000)
--
-- SCALE is the approximate number of order lines. Every other table is sized from it (see
-- lab.dataset_size). The data is deterministic: the same SCALE and anchor give the same rows.
-- Pure SQL (generate_series + the model functions in sql/lab/20_generator_model.sql): the
-- rows never leave the server. Secondary indexes and foreign keys are dropped for the load and
-- rebuilt afterwards, then the tables are vacuumed and analysed.
\set ON_ERROR_STOP on
\if :{?scale}
\else
  \set scale 100000
\endif
\timing on

SET client_min_messages = warning;
SET ROLE topflow_owner;
SET synchronous_commit = off;
SET work_mem = '64MB';

SELECT CASE WHEN :scale::bigint BETWEEN 1000 AND 100000000 THEN true END AS scale_ok \gset
\if :scale_ok
\else
  \warn 'generate.sql: scale must be between 1000 and 100000000'
  SELECT 1 / 0 AS scale_out_of_range;
\endif

\echo '== resetting tables and dropping secondary indexes and foreign keys'
BEGIN;
SELECT lab.begin_bulk_load() AS dropped_objects;
TRUNCATE users, categories, products, carts, cart_items, orders, order_items, audit_logs,
         organizations, organization_members, quote_requests, quote_request_items,
         organization_invitations, addresses, quotations, quotation_items,
         order_status_events, document_sequences, lab.heartbeat
    RESTART IDENTITY;
DELETE FROM lab.settings WHERE key IN ('scale', 'anchor', 'generated_at');
INSERT INTO lab.settings (key, value) VALUES
    ('scale', :'scale'),
    ('anchor', to_char(date_trunc('hour', localtimestamp), 'YYYY-MM-DD HH24:MI:SS')),
    ('generated_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
COMMIT;

SELECT * FROM lab.dataset_size(:scale) \gset
SELECT lab.anchor() AS anchor \gset
\echo 'anchor' :anchor 'products' :n_products 'organisations' :n_orgs 'users' :n_users 'orders' :n_orders 'rfqs' :n_rfqs 'audit' :n_audit

CREATE TEMP TABLE vocab AS SELECT
    ARRAY['Sprinklers & Rotors','Drip & Micro Irrigation','Pipes & Fittings','Valves',
          'Filtration','Controllers & Sensors','Pumps & Water Supply','Landscape Supplies'] AS parents,
    ARRAY['Residential','Commercial','Agricultural','Accessories'] AS children,
    ARRAY['villa gardens','public parks','sports fields','date palm farms','hotel landscapes',
          'road medians','greenhouses','plant nurseries'] AS uses,
    ARRAY['UV-stabilised body','Pressure-compensating','Anti-drain check valve',
          'Stainless steel spring','Self-flushing','Adjustable arc','Low-flow design',
          'Heavy-duty construction','Corrosion-resistant','Tool-free maintenance'] AS features,
    ARRAY['drip','sprinkler','valve','filter','pipe','fitting','pump','controller','sensor','hdpe',
          'pvc','landscape','farm','greenhouse','water-saving','smart','heavy-duty',
          'uv-resistant'] AS tags,
    ARRAY['Customer request','Duplicate order','Out of stock','Payment not received',
          'Delivery date not suitable'] AS cancel_reasons;

\echo '== categories'
INSERT INTO categories (id, name, slug, description, "displayOrder", "parentId", "createdAt")
SELECT p.n, p.name,
       trim(BOTH '-' FROM lower(regexp_replace(p.name, '[^a-zA-Z0-9]+', '-', 'g'))),
       'Irrigation supplies: ' || lower(p.name) || '.', p.n, NULL,
       :'anchor'::timestamp - interval '1200 days'
FROM vocab, unnest(vocab.parents) WITH ORDINALITY AS p (name, n)
UNION ALL
SELECT 8 + (p.n - 1) * 4 + c.m, p.name || ' - ' || c.name,
       trim(BOTH '-' FROM lower(regexp_replace(p.name || '-' || c.name, '[^a-zA-Z0-9]+', '-', 'g'))),
       c.name || ' range of ' || lower(p.name) || '.', c.m, p.n,
       :'anchor'::timestamp - interval '1200 days'
FROM vocab, unnest(vocab.parents) WITH ORDINALITY AS p (name, n)
CROSS JOIN unnest(vocab.children) WITH ORDINALITY AS c (name, m);
SELECT setval(pg_get_serial_sequence('categories', 'id'), (SELECT max(id) FROM categories));

\echo '== products'
INSERT INTO products (id, sku, name, "categoryId", description, specifications, "unitPrice",
                      "stockStatus", "stockQuantity", "createdAt", "updatedAt", brand, "isActive",
                      "isTradeOnly", "lowStockThreshold", "minOrderQty", slug, uom, "priceMax",
                      "priceMin", tags)
SELECT lab.uid('product', k), lab.product_sku(k), lab.product_name(k), 9 + ((k - 1) % 32)::int,
       lab.product_type(k) || ' for ' || lab.pick(v.uses, lab.rnd(k, 40)) || '. '
           || lab.pick(v.features, lab.rnd(k, 41)) || '.',
       jsonb_build_object(
           'Material', lab.pick(ARRAY['HDPE','PVC','Brass','Stainless steel','ABS','Polypropylene'], lab.rnd(k, 43)),
           'Pressure rating', (4 + floor(12 * lab.rnd(k, 44)))::int || ' bar'),
       lab.product_price(k),
       CASE WHEN lab.rnd(k, 32) < 0.85 THEN 'IN_STOCK' ELSE 'ON_ORDER' END::"StockStatus",
       CASE WHEN lab.rnd(k, 32) < 0.85 THEN floor(500 * lab.rnd(k, 33))::int ELSE 0 END,
       t.created, t.created + make_interval(days => floor(200 * lab.rnd(k, 45))::int),
       lab.product_brand(k),
       lab.rnd(k, 34) < 0.97,
       lab.rnd(k, 35) < 0.15,
       10 + floor(40 * lab.rnd(k, 36))::int,
       CASE WHEN lab.rnd(k, 46) < 0.2 THEN 10 ELSE 1 END,
       trim(BOTH '-' FROM lower(regexp_replace(lab.product_name(k) || '-' || lab.product_sku(k), '[^a-zA-Z0-9]+', '-', 'g'))),
       lab.pick(ARRAY['PIECE','PIECE','PIECE','METER','ROLL','BOX','SET'], lab.rnd(k, 47))::"UnitOfMeasure",
       lab.product_price(k), round(lab.product_price(k) * 0.78, 2),
       ARRAY(SELECT DISTINCT lab.pick(v.tags, lab.rnd(k * 4 + g, 37))
             FROM generate_series(1, 2 + floor(2 * lab.rnd(k, 38))::int) AS g)
FROM generate_series(1, :n_products) AS k
CROSS JOIN vocab AS v
CROSS JOIN LATERAL (SELECT (:'anchor'::timestamp - interval '1100 days'
                            + make_interval(secs => k * (1000 * 86400.0 / :n_products)))::timestamp(3) AS created) AS t;

\echo '== organizations'
INSERT INTO organizations (id, name, "legalName", type, status, "tradeLicenseNumber", trn, email,
                           "phoneNumber", "paymentTerms", "creditLimit", "discountRate",
                           "verifiedAt", "createdAt", "updatedAt")
SELECT lab.uid('org', o), lab.org_name(o), lab.org_name(o) || ' (licence ' || o || ')',
       lab.pick(ARRAY['CONTRACTOR','LANDSCAPING','FACILITY_MANAGEMENT','DEVELOPER','GOVERNMENT',
                      'RESELLER','OTHER'], lab.rnd(o, 64))::"OrgType",
       x.status::"OrgStatus",
       'CN-' || lpad(o::text, 7, '0'), '100' || lpad(o::text, 12, '0'),
       'accounts' || o || '@example.com', lab.phone(5000000 + o),
       lab.pick(ARRAY['PREPAID','NET_15','NET_30','NET_30','NET_60'], lab.rnd(o, 65))::"PaymentTerms",
       (floor(20 * lab.rnd(o, 66)) * 25000)::numeric(12, 2),
       lab.org_discount(o),
       CASE WHEN x.status <> 'PENDING_VERIFICATION' THEN x.created + interval '2 days' END,
       x.created, x.created + interval '2 days'
FROM generate_series(1, :n_orgs) AS o
CROSS JOIN LATERAL (
    SELECT CASE WHEN o <= 3 OR lab.rnd(o, 67) < 0.85 THEN 'ACTIVE'
                WHEN lab.rnd(o, 67) < 0.95 THEN 'PENDING_VERIFICATION'
                ELSE 'SUSPENDED' END AS status,
           lab.slot_ts(o, :n_orgs, 900, :'anchor', 68) AS created) AS x;

\echo '== users'
INSERT INTO users (id, email, "fullName", "companyName", "phoneNumber", role, "isActive",
                   "createdAt", "updatedAt", "emailVerifiedAt", "lastLoginAt")
SELECT lab.uid('user', u.n), u.email, lab.person_name(u.n), u.company, lab.phone(u.n),
       u.role::"Role", lab.rnd(u.n, 73) < 0.98, u.created, u.created, u.created,
       (:'anchor'::timestamp - make_interval(days => floor(60 * lab.rnd(u.n, 74))::int))::timestamp(3)
FROM (
    SELECT n, 'staff' || n || '@topflow-lab.example' AS email, NULL::text AS company,
           CASE WHEN n <= 2 THEN 'ADMIN' WHEN n <= 12 THEN 'SALES' ELSE 'WAREHOUSE' END AS role,
           (:'anchor'::timestamp - interval '1000 days')::timestamp(3) AS created
    FROM generate_series(1, 20) AS n
    UNION ALL
    SELECT lab.member_user(o, m), 'member' || lab.member_user(o, m) || '@example.com',
           lab.org_name(o), 'CUSTOMER',
           lab.slot_ts(o, :n_orgs, 900, :'anchor', 68) + make_interval(days => m)
    FROM generate_series(1, :n_orgs) AS o CROSS JOIN generate_series(1, 5) AS m
    UNION ALL
    SELECT lab.retail_user(r, :n_orgs), 'customer' || lab.retail_user(r, :n_orgs) || '@example.com',
           NULL, 'CUSTOMER', lab.slot_ts(r, :n_retail, 900, :'anchor', 75)
    FROM generate_series(1, :n_retail) AS r
) AS u;

\echo '== organization members, addresses, invitations, carts'
INSERT INTO organization_members (id, "organizationId", "userId", role, "approvalLimit", "createdAt")
SELECT lab.uid('member', o * 8 + m), lab.uid('org', o), lab.uid('user', lab.member_user(o, m)),
       CASE m WHEN 1 THEN 'OWNER' WHEN 2 THEN 'APPROVER' ELSE 'BUYER' END::"OrgRole",
       CASE WHEN m = 2 THEN 50000.00 END,
       lab.slot_ts(o, :n_orgs, 900, :'anchor', 68) + make_interval(days => m)
FROM generate_series(1, :n_orgs) AS o CROSS JOIN generate_series(1, 5) AS m;

INSERT INTO addresses (id, "userId", "organizationId", label, "contactName", "phoneNumber", line1,
                       area, city, emirate, "isDefault", "createdAt", "updatedAt")
SELECT lab.uid('org-address', o * 4 + a), NULL, lab.uid('org', o),
       CASE a WHEN 1 THEN 'Head office' ELSE 'Site store' END,
       lab.person_name(lab.member_user(o, 1)), lab.phone(lab.member_user(o, 1)),
       'Plot ' || (1 + floor(300 * lab.rnd(o * 4 + a, 94)))::int,
       lab.project_ref(o * 4 + a), initcap(replace(lab.emirate(o * 4 + a), '_', ' ')),
       lab.emirate(o * 4 + a)::"Emirate", a = 1,
       lab.slot_ts(o, :n_orgs, 900, :'anchor', 68), lab.slot_ts(o, :n_orgs, 900, :'anchor', 68)
FROM generate_series(1, :n_orgs) AS o CROSS JOIN generate_series(1, 2) AS a
UNION ALL
SELECT lab.uid('user-address', r), lab.uid('user', lab.retail_user(r, :n_orgs)), NULL, 'Home',
       lab.person_name(lab.retail_user(r, :n_orgs)), lab.phone(lab.retail_user(r, :n_orgs)),
       'Villa ' || (1 + floor(200 * lab.rnd(r, 95)))::int, lab.project_ref(900000000 + r),
       initcap(replace(lab.emirate(900000000 + r), '_', ' ')), lab.emirate(900000000 + r)::"Emirate", true,
       lab.slot_ts(r, :n_retail, 900, :'anchor', 75), lab.slot_ts(r, :n_retail, 900, :'anchor', 75)
FROM generate_series(1, :n_retail) AS r;

INSERT INTO organization_invitations (id, "organizationId", email, role, "tokenHash", "invitedById",
                                      "expiresAt", "acceptedAt", "createdAt")
SELECT lab.uid('invitation', o), lab.uid('org', o), 'invitee' || o || '@example.com', 'BUYER',
       md5('invitation-token:' || o), lab.uid('user', lab.member_user(o, 1)),
       lab.slot_ts(o, :n_orgs, 900, :'anchor', 69) + interval '7 days',
       CASE WHEN lab.rnd(o, 70) < 0.6 THEN lab.slot_ts(o, :n_orgs, 900, :'anchor', 69) + interval '1 day' END,
       lab.slot_ts(o, :n_orgs, 900, :'anchor', 69)
FROM generate_series(1, :n_orgs) AS o
WHERE o % 10 = 0;

INSERT INTO carts (id, "userId", "createdAt", "updatedAt")
SELECT lab.uid('cart', r), lab.uid('user', lab.retail_user(r, :n_orgs)),
       :'anchor'::timestamp - interval '3 days', :'anchor'::timestamp - interval '1 day'
FROM generate_series(1, :n_retail) AS r
WHERE lab.rnd(r, 141) < 0.1;

INSERT INTO cart_items (id, "cartId", "productId", quantity)
SELECT lab.uid('cart-item', r * 4 + j), lab.uid('cart', r),
       lab.uid('product', 1 + ((r * 7 + j * 13) % :n_products)), 1 + j
FROM generate_series(1, :n_retail) AS r CROSS JOIN generate_series(1, 3) AS j
WHERE lab.rnd(r, 141) < 0.1;

\echo '== quote requests (RFQs) and their lines'
CREATE TEMP VIEW rfq_model AS
SELECT i, r.created, r.web, r.org, r.status,
       CASE WHEN r.web THEN 0 ELSE lab.org_discount(r.org) END AS discount
FROM generate_series(1, :n_rfqs) AS i
CROSS JOIN LATERAL (
    SELECT c.created, lab.rfq_is_website(i) AS web, lab.skewed(:n_orgs, lab.rnd(i, 103), 2.5) AS org,
           lab.rfq_status(i, c.created, :'anchor') AS status
    FROM (SELECT lab.slot_ts(i, :n_rfqs, 730, :'anchor', 101) AS created) AS c) AS r;

INSERT INTO quote_requests (id, number, "organizationId", "requestedById", "assignedToId", status,
                            "projectReference", "shippingAddress", "requiredBy", notes,
                            "createdAt", "updatedAt", "companyName", "contactEmail",
                            "contactName", "contactPhone", source, "preferredContact")
SELECT lab.uid('rfq', m.i),
       'TF-RFQ-' || extract(year FROM m.created)::int || '-'
           || lpad((row_number() OVER (PARTITION BY extract(year FROM m.created) ORDER BY m.i))::text, 6, '0'),
       CASE WHEN NOT m.web THEN lab.uid('org', m.org) END,
       CASE WHEN NOT m.web THEN lab.uid('user', lab.member_user(m.org, 1 + floor(5 * lab.rnd(m.i, 104))::int)) END,
       CASE WHEN m.status <> 'SUBMITTED' THEN lab.uid('user', 3 + floor(10 * lab.rnd(m.i, 106))::int) END,
       m.status::"RfqStatus",
       CASE WHEN NOT m.web AND lab.rnd(m.i, 107) < 0.7 THEN lab.project_ref(10000000000 + m.i) END,
       'Site ' || (1 + floor(90 * lab.rnd(m.i, 108)))::int || ', ' || lab.project_ref(20000000000 + m.i),
       m.created + make_interval(days => 14 + floor(46 * lab.rnd(m.i, 109))::int),
       CASE WHEN lab.rnd(m.i, 110) < 0.2 THEN 'Please include delivery to site.' END,
       m.created,
       least(m.created + make_interval(days => floor(5 * lab.rnd(m.i, 117))::int), :'anchor'::timestamp),
       CASE WHEN m.web AND lab.rnd(m.i, 118) < 0.5 THEN lab.org_name(1000000 + m.i) END,
       CASE WHEN m.web THEN 'visitor' || m.i || '@example.net' END,
       CASE WHEN m.web THEN lab.person_name(1000000 + m.i) END,
       CASE WHEN m.web THEN lab.phone(1000000 + m.i) END,
       CASE WHEN m.web THEN 'WEBSITE' ELSE 'TRADE_PORTAL' END::"RfqSource",
       CASE WHEN m.web THEN lab.pick(ARRAY['PHONE','WHATSAPP','EMAIL'], lab.rnd(m.i, 119))::"ContactChannel" END
FROM rfq_model AS m;

INSERT INTO quote_request_items (id, "quoteRequestId", "productId", sku, "productName", quantity)
SELECT lab.uid('rfq-item', i * 8 + j), lab.uid('rfq', i), lab.uid('product', p.k),
       lab.product_sku(p.k), lab.product_name(p.k), 5 + floor(100 * lab.rnd(i * 8 + j, 121))::int
FROM generate_series(1, :n_rfqs) AS i
CROSS JOIN LATERAL generate_series(1, 1 + floor(5 * lab.rnd(i, 120))::int) AS j
CROSS JOIN LATERAL (SELECT lab.skewed(:n_products, lab.rnd(i * 8 + j, 122), 1.6) AS k) AS p;

\echo '== quotations and their lines'
INSERT INTO quotations (id, number, revision, "quoteRequestId", "organizationId", "customerId",
                        "createdById", status, "vatRateBps", subtotal, "discountTotal",
                        "deliveryFee", "vatAmount", total, "validUntil", terms, "sentAt",
                        "respondedAt", "respondedById", "purchaseOrderNumber", "createdAt",
                        "updatedAt")
SELECT lab.uid('quotation', m.i),
       'TF-QT-' || extract(year FROM q.created)::int || '-'
           || lpad((row_number() OVER (PARTITION BY extract(year FROM q.created) ORDER BY m.i))::text, 6, '0'),
       1 + (lab.rnd(m.i, 123) < 0.2)::int,
       lab.uid('rfq', m.i),
       CASE WHEN NOT m.web THEN lab.uid('org', m.org) END,
       CASE WHEN NOT m.web THEN lab.uid('user', lab.member_user(m.org, 1 + floor(5 * lab.rnd(m.i, 104))::int)) END,
       lab.uid('user', 3 + floor(10 * lab.rnd(m.i, 106))::int),
       q.status::"QuotationStatus", 500, t.subtotal, t.discount_total, 0, t.vat,
       t.subtotal + t.vat,
       q.created + interval '30 days',
       'Prices in AED, valid for 30 days. Delivery within the UAE.',
       CASE WHEN q.status <> 'DRAFT' THEN q.created END,
       CASE WHEN q.status IN ('ACCEPTED','REJECTED','REVISION_REQUESTED','PENDING_APPROVAL') THEN q.updated END,
       CASE WHEN q.status IN ('ACCEPTED','REJECTED','REVISION_REQUESTED','PENDING_APPROVAL') AND NOT m.web
            THEN lab.uid('user', lab.member_user(m.org, 1)) END,
       CASE WHEN q.status = 'ACCEPTED' AND NOT m.web THEN 'PO-' || lpad(m.org::text, 5, '0') || '-' || m.i END,
       q.created, q.updated
FROM rfq_model AS m
CROSS JOIN LATERAL (
    SELECT s.status, c.created,
           least(c.created + make_interval(days => floor(10 * lab.rnd(m.i, 124))::int), :'anchor'::timestamp)::timestamp(3) AS updated
    FROM (SELECT least(m.created + make_interval(hours => 24 + floor(48 * lab.rnd(m.i, 116))::int),
                       :'anchor'::timestamp)::timestamp(3) AS created) AS c
    CROSS JOIN LATERAL (SELECT lab.quotation_status(m.i, m.status, m.created, :'anchor') AS status) AS s
) AS q
CROSS JOIN LATERAL (
    SELECT sum(l.line_subtotal) AS subtotal, sum(l.line_vat) AS vat,
           sum((l.list_price - l.unit_price) * l.quantity) AS discount_total
    FROM lab.quotation_lines(m.i, :n_products, m.discount) AS l
) AS t
WHERE q.status IS NOT NULL;

-- Earlier revisions of re-issued quotations: same number, revision 1, superseded. They keep
-- their header only; the lab does not model their lines.
INSERT INTO quotations (id, number, revision, "quoteRequestId", "organizationId", "customerId",
                        "createdById", status, "vatRateBps", subtotal, "discountTotal",
                        "deliveryFee", "vatAmount", total, "validUntil", terms, "sentAt",
                        "createdAt", "updatedAt")
SELECT md5('quotation-rev1:' || q.id)::uuid::text,
       q.number, 1, q."quoteRequestId", q."organizationId", q."customerId", q."createdById",
       'SUPERSEDED', q."vatRateBps", q.subtotal, q."discountTotal", q."deliveryFee", q."vatAmount",
       q.total, q."validUntil" - interval '1 day', q.terms, q."createdAt" - interval '1 day',
       q."createdAt" - interval '1 day', q."createdAt"
FROM quotations AS q
WHERE q.revision = 2;

INSERT INTO quotation_items (id, "quotationId", "productId", sku, "productName", uom, quantity,
                             "listPrice", "discountRate", "unitPrice", "lineSubtotal",
                             "vatAmount", "lineTotal", "sortOrder")
SELECT lab.uid('quotation-item', m.i * 16 + l.line_no), lab.uid('quotation', m.i),
       lab.uid('product', l.product_no), lab.product_sku(l.product_no),
       lab.product_name(l.product_no), 'PIECE', l.quantity, l.list_price, l.discount_rate,
       l.unit_price, l.line_subtotal, l.line_vat, l.line_subtotal + l.line_vat, l.line_no
FROM rfq_model AS m
CROSS JOIN LATERAL lab.quotation_lines(m.i, :n_products, m.discount) AS l
WHERE lab.quotation_status(m.i, m.status, m.created, :'anchor') IS NOT NULL;

\echo '== orders'
CREATE TEMP VIEW order_model AS
SELECT i, a.created, a.b2b, a.org, a.retail,
       lab.order_status(i, a.created, :'anchor') AS status,
       CASE WHEN a.b2b THEN lab.org_discount(a.org) ELSE 0 END AS discount,
       CASE WHEN a.b2b THEN CASE WHEN lab.rnd(i, 8) < 0.7 THEN 'CREDIT_ACCOUNT' ELSE 'BANK_TRANSFER' END
            ELSE CASE WHEN lab.rnd(i, 8) < 0.6 THEN 'CASH_ON_DELIVERY' ELSE 'CARD' END END AS method
FROM generate_series(1, :n_orders) AS i
CROSS JOIN LATERAL (
    SELECT lab.slot_ts(i, :n_orders, 730, :'anchor', 1) AS created, lab.order_is_b2b(i) AS b2b,
           lab.skewed(:n_orgs, lab.rnd(i, 3), 2.5) AS org,
           lab.skewed(:n_retail, lab.rnd(i, 5), 1.5) AS retail) AS a;

INSERT INTO orders (id, "orderNumber", "userId", status, "totalAmount", currency,
                    "shippingAddress", "projectReference", "createdAt", "updatedAt",
                    "cancellationReason", "cancelledAt", channel, "confirmedAt", "deliveredAt",
                    "deliveryAddress", "deliveryFee", "discountTotal", "dispatchedAt",
                    "organizationId", "paidAt", "paymentMethod", "paymentReference",
                    "paymentStatus", "purchaseOrderNumber", subtotal, "trackingReference",
                    "vatAmount", "vatRateBps")
SELECT lab.uid('order', o.i),
       'TF-SO-' || extract(year FROM o.created)::int || '-'
           || lpad((row_number() OVER (PARTITION BY extract(year FROM o.created) ORDER BY o.i))::text, 6, '0'),
       CASE WHEN o.b2b THEN lab.uid('user', lab.member_user(o.org, 1 + floor(5 * lab.rnd(o.i, 9))::int))
            ELSE lab.uid('user', lab.retail_user(o.retail, :n_orgs)) END,
       o.status::"OrderStatus",
       t.subtotal + t.vat + f.fee, 'AED',
       'Plot ' || (1 + floor(300 * lab.rnd(o.i, 11)))::int || ', ' || lab.project_ref(30000000000 + o.i),
       CASE WHEN o.b2b AND lab.rnd(o.i, 10) < 0.7 THEN lab.project_ref(o.i) END,
       o.created,
       lab.status_reached_at(o.created, o.status, :'anchor'),
       CASE WHEN o.status = 'CANCELLED' THEN lab.pick(v.cancel_reasons, lab.rnd(o.i, 12)) END,
       CASE WHEN o.status = 'CANCELLED' THEN lab.status_reached_at(o.created, 'CANCELLED', :'anchor') END,
       CASE WHEN o.b2b THEN 'B2B' ELSE 'RETAIL' END::"OrderChannel",
       CASE WHEN o.status <> 'PENDING_PAYMENT' THEN lab.status_reached_at(o.created, 'CONFIRMED', :'anchor') END,
       CASE WHEN o.status = 'DELIVERED' THEN lab.status_reached_at(o.created, 'DELIVERED', :'anchor') END,
       jsonb_build_object('area', lab.project_ref(30000000000 + o.i),
                          'emirate', lab.emirate(30000000000 + o.i), 'country', 'AE'),
       f.fee, t.discount_total,
       CASE WHEN o.status IN ('DISPATCHED','DELIVERED') THEN lab.status_reached_at(o.created, 'DISPATCHED', :'anchor') END,
       CASE WHEN o.b2b THEN lab.uid('org', o.org) END,
       CASE WHEN p.status IN ('PAID','REFUNDED') THEN
            CASE WHEN o.method = 'CARD' THEN o.created
                 ELSE lab.status_reached_at(o.created, 'DELIVERED', :'anchor') END END,
       o.method::"PaymentMethod",
       CASE WHEN p.status IN ('PAID','REFUNDED') THEN 'PAY-' || lpad(o.i::text, 10, '0') END,
       p.status::"PaymentStatus",
       CASE WHEN o.b2b THEN 'PO-' || lpad(o.org::text, 5, '0') || '-' || lpad((o.i % 100000)::text, 5, '0') END,
       t.subtotal,
       CASE WHEN o.status IN ('DISPATCHED','DELIVERED') THEN 'TRK' || lpad(o.i::text, 10, '0') END,
       t.vat, 500
FROM order_model AS o
CROSS JOIN vocab AS v
CROSS JOIN LATERAL (
    SELECT sum(l.line_subtotal) AS subtotal, sum(l.line_vat) AS vat,
           sum((l.list_price - l.unit_price) * l.quantity) AS discount_total
    FROM lab.order_lines(o.i, :n_products, o.discount) AS l) AS t
CROSS JOIN LATERAL (SELECT CASE WHEN NOT o.b2b AND t.subtotal < 500 THEN 25.00 ELSE 0 END AS fee) AS f
CROSS JOIN LATERAL (
    SELECT CASE WHEN o.status = 'CANCELLED' THEN CASE WHEN o.method = 'CARD' THEN 'REFUNDED' ELSE 'UNPAID' END
                WHEN o.status = 'DELIVERED' THEN 'PAID'
                WHEN o.method = 'CARD' AND o.status <> 'PENDING_PAYMENT' THEN 'PAID'
                ELSE 'UNPAID' END AS status) AS p;

\echo '== order lines'
INSERT INTO order_items (id, "orderId", "productId", "productName", sku, "unitPrice", quantity,
                         "totalPrice", "discountRate", uom, "vatAmount")
SELECT lab.uid('order-item', o.i * 16 + l.line_no), lab.uid('order', o.i),
       lab.uid('product', l.product_no), lab.product_name(l.product_no),
       lab.product_sku(l.product_no), l.unit_price, l.quantity, l.line_subtotal, o.discount,
       'PIECE', l.line_vat
FROM order_model AS o
CROSS JOIN LATERAL lab.order_lines(o.i, :n_products, o.discount) AS l;

\echo '== order status events'
INSERT INTO order_status_events (id, "orderId", "fromStatus", "toStatus", "actorId", "createdAt")
SELECT lab.uid('order-event', o.i * 8 + s.n), lab.uid('order', o.i),
       (p.path)[s.n - 1]::"OrderStatus", (p.path)[s.n]::"OrderStatus",
       CASE WHEN s.n > 1 THEN lab.uid('user', 3 + floor(18 * lab.rnd(o.i * 8 + s.n, 13))::int) END,
       lab.status_reached_at(o.created, (p.path)[s.n], :'anchor')
FROM order_model AS o
CROSS JOIN LATERAL (SELECT lab.order_status_path(o.status) AS path) AS p
CROSS JOIN LATERAL generate_subscripts(p.path, 1) AS s (n);

\echo '== audit trail'
INSERT INTO audit_logs (id, "userId", action, "entityType", "entityId", details, "createdAt",
                        "ipAddress", "organizationId")
SELECT lab.uid('audit', i), lab.uid('user', lab.skewed(:n_users, lab.rnd(i, 53), 2.0)),
       b.action, b.entity_type,
       CASE b.entity_type
            WHEN 'Order' THEN lab.uid('order', 1 + floor(:n_orders * lab.rnd(i, 54))::bigint)
            WHEN 'Quotation' THEN lab.uid('quotation', 1 + floor(:n_rfqs * lab.rnd(i, 54))::bigint)
            WHEN 'QuoteRequest' THEN lab.uid('rfq', 1 + floor(:n_rfqs * lab.rnd(i, 54))::bigint)
            WHEN 'Product' THEN lab.uid('product', 1 + floor(:n_products * lab.rnd(i, 54))::bigint)
            WHEN 'Organization' THEN lab.uid('org', 1 + floor(:n_orgs * lab.rnd(i, 54))::bigint)
            ELSE lab.uid('user', 1 + floor(:n_users * lab.rnd(i, 54))::bigint)
       END,
       jsonb_build_object('requestId', left(lab.uid('request', i), 8),
                          'client', lab.pick(ARRAY['web','mobile','back-office'], lab.rnd(i, 55))),
       lab.slot_ts(i, :n_audit, 730, :'anchor', 56),
       '10.' || floor(256 * lab.rnd(i, 57))::int || '.' || floor(256 * lab.rnd(i, 60))::int || '.'
           || floor(256 * lab.rnd(i, 76))::int,
       CASE WHEN lab.rnd(i, 58) < 0.5 THEN lab.uid('org', lab.skewed(:n_orgs, lab.rnd(i, 59), 2.5)) END
FROM generate_series(1, :n_audit) AS i
CROSS JOIN LATERAL (SELECT action, entity_type FROM lab.audit_action_buckets
                    WHERE bucket = floor(100 * lab.rnd(i, 51))::int) AS b;

\echo '== document sequences'
INSERT INTO document_sequences (key, value, "updatedAt")
SELECT 'TF-SO-' || extract(year FROM "createdAt")::int, count(*), max("createdAt") FROM orders GROUP BY 1
UNION ALL
SELECT 'TF-QT-' || extract(year FROM "createdAt")::int, count(*), max("createdAt") FROM quotations WHERE status <> 'SUPERSEDED' GROUP BY 1
UNION ALL
SELECT 'TF-RFQ-' || extract(year FROM "createdAt")::int, count(*), max("createdAt") FROM quote_requests GROUP BY 1;

\echo '== rebuilding keys, indexes and foreign keys'
SET maintenance_work_mem = '256MB';
SELECT ddl FROM lab.pending_bulk_load_ddl() AS ddl \gexec
SELECT lab.finish_bulk_load();

\echo '== vacuum and analyse'
VACUUM (ANALYZE) users, categories, products, carts, cart_items, orders, order_items, audit_logs,
       organizations, organization_members, quote_requests, quote_request_items,
       organization_invitations, addresses, quotations, quotation_items, order_status_events,
       document_sequences;

\echo '== done'
SELECT relname AS table_name, n_live_tup AS rows
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;
