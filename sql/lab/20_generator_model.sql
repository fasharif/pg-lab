-- Data model of the generator: pure functions of a row number, so every value can be
-- recomputed anywhere (order totals equal the sum of their lines, events follow the order's
-- status) without joins. All names, brands and companies are fictional; e-mail domains use
-- the reserved example.com / example.net / .example names.
-- Idempotent: ./lab migrate re-applies it on every run.
--
-- The functions are deliberately not STRICT: PostgreSQL only inlines a STRICT SQL function
-- when its body is strict too, and CASE is not. Inlined, they cost about as much as the
-- expressions they contain; called through the SQL-function executor, the generator was
-- several times slower.

-- Row counts for a SCALE (the approximate number of order lines).
CREATE OR REPLACE FUNCTION lab.dataset_size(scale bigint)
RETURNS TABLE (n_products int, n_orgs int, n_staff int, n_retail int, n_users int,
               n_orders bigint, n_rfqs bigint, n_audit bigint)
LANGUAGE sql IMMUTABLE
AS $$
    SELECT greatest(1000, least(50000, scale / 200))::int,
           greatest(50, scale / 2000)::int,
           20,
           greatest(200, scale / 100)::int,
           20 + 5 * greatest(50, scale / 2000)::int + greatest(200, scale / 100)::int,
           greatest(1000, scale / 5),
           greatest(500, scale / 8),
           greatest(1000, scale)
$$;

-- 1..n, skewed towards 1 (power > 1 gives a few large customers and a long tail).
CREATE OR REPLACE FUNCTION lab.skewed(n bigint, r double precision, power double precision)
RETURNS bigint LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT 1 + floor(n * (r ^ power))::bigint $$;

-- Evenly spread, strictly increasing timestamps over the last span_days before the anchor:
-- rows are inserted in time order, like a real append-only table.
CREATE OR REPLACE FUNCTION lab.slot_ts(i bigint, n bigint, span_days int, anchor timestamp, salt bigint)
RETURNS timestamp(3) LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT (anchor - make_interval(days => span_days)
            + make_interval(secs => ((i - 1) + lab.rnd(i, salt)) * (span_days * 86400.0 / n)))::timestamp(3)
$$;

CREATE OR REPLACE FUNCTION lab.age_days(ts timestamp, anchor timestamp)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT extract(epoch FROM anchor - ts) / 86400.0 $$;

-- ─── People and organisations ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lab.person_name(n bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT lab.pick(ARRAY['Aisha','Omar','Fatima','Yousef','Mariam','Khalid','Noura','Hassan',
                          'Layla','Rashid','Priya','Arjun','Sara','James','Emily','Daniel','Hiba',
                          'Tariq','Zainab','Imran','Maya','Rohan','Lina','Adam','Salma','Faisal',
                          'Reem','Kiran','Nadia','Samir'], lab.rnd(n, 71))
        || ' ' ||
           lab.pick(ARRAY['Al Mansoori','Al Hashimi','Khan','Rahman','Haddad','Nair','Sharma',
                          'Fernandes','Smith','Taylor','Al Suwaidi','Qureshi','Menon','Saleh',
                          'Farouk','Iyer','Hussain','Al Marri','Pereira','Patel'], lab.rnd(n, 72))
$$;

CREATE OR REPLACE FUNCTION lab.org_name(o bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT lab.pick(ARRAY['Green','Oasis','Desert','Palm','Crescent','Emerald','Sand','Falcon',
                          'Blue','Horizon','Garden','Delta','Pearl','Cedar','Summit','Coastal',
                          'Meadow','Harbour','Sunrise','Dune'], lab.rnd(o, 61))
        || ' ' ||
           lab.pick(ARRAY['Landscaping','Irrigation','Contracting','Facilities','Developments',
                          'Gardens','Agri Services','Technical Services','Projects','Maintenance'],
                    lab.rnd(o, 62))
        || ' ' ||
           lab.pick(ARRAY['LLC','FZE','FZ-LLC','Est.','Trading LLC'], lab.rnd(o, 63))
$$;

-- 0, 2.5, 5, 7.5 or 10 per cent trade discount, fixed per organisation.
CREATE OR REPLACE FUNCTION lab.org_discount(o bigint) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT (floor(lab.rnd(o, 42) * 5) * 2.5)::numeric(5, 2) $$;

-- User numbering: 1..20 staff, then five members per organisation, then retail customers.
CREATE OR REPLACE FUNCTION lab.member_user(o bigint, m int) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT 20 + (o - 1) * 5 + m $$;

CREATE OR REPLACE FUNCTION lab.retail_user(r bigint, n_orgs int) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT 20 + 5 * n_orgs + r $$;

CREATE OR REPLACE FUNCTION lab.project_ref(n bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT lab.pick(ARRAY['Al Reem','Saadiyat','Yas','Khalifa City','Mohammed Bin Zayed City',
                          'Al Raha','Jumeirah','Al Barsha','Dubai Hills','Al Ain','Ruwais','Masdar',
                          'Al Qusais','Mirdif','Sharjah Waterfront','Ajman Corniche',
                          'Fujairah Beach','Ras Al Khaimah Creek'], lab.rnd(n, 81))
        || ' ' ||
           lab.pick(ARRAY['Villa','Tower','Park','Compound','School','Mall','Hotel','Community',
                          'Farm','Clinic','Boulevard','Marina','Warehouse','Campus'], lab.rnd(n, 82))
        || ' ' || (1 + floor(lab.rnd(n, 83) * 40))::int
        || CASE WHEN lab.rnd(n, 84) < 0.3 THEN ' Phase ' || (1 + floor(lab.rnd(n, 85) * 3))::int ELSE '' END
$$;

CREATE OR REPLACE FUNCTION lab.emirate(n bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT lab.pick(ARRAY['ABU_DHABI','ABU_DHABI','DUBAI','DUBAI','DUBAI','SHARJAH','AJMAN',
                            'UMM_AL_QUWAIN','RAS_AL_KHAIMAH','FUJAIRAH'], lab.rnd(n, 91)) $$;

CREATE OR REPLACE FUNCTION lab.phone(n bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT '+9715' || (floor(lab.rnd(n, 92) * 10))::int || lpad(floor(lab.rnd(n, 93) * 10000000)::bigint::text, 7, '0') $$;

-- ─── Catalogue ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lab.product_sku(k bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT 'TFL-' || lpad(k::text, 6, '0') $$;

CREATE OR REPLACE FUNCTION lab.product_type(k bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT lab.pick(ARRAY['Pop-up Sprinkler','Gear-driven Rotor','Impact Sprinkler','Spray Nozzle',
                          'Drip Line','Dripper','Micro Sprayer','Bubbler','Solenoid Valve',
                          'Ball Valve','Gate Valve','Check Valve','Pressure Regulator','Disc Filter',
                          'Screen Filter','Sand Media Filter','HDPE Pipe','PVC Pipe','LDPE Tubing',
                          'Compression Fitting','Electrofusion Coupler','Electrofusion Elbow',
                          'Saddle Clamp','Irrigation Controller','Rain Sensor',
                          'Soil Moisture Sensor','Valve Box','Quick Coupling Valve','Booster Pump',
                          'Submersible Pump','Pressure Tank','Fertiliser Injector','Hose Reel',
                          'Garden Hose','Landscape Fabric'], lab.rnd(k, 21))
$$;

CREATE OR REPLACE FUNCTION lab.product_name(k bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT lab.product_type(k) || ' '
        || lab.pick(ARRAY['16 mm','20 mm','25 mm','32 mm','40 mm','50 mm','63 mm','75 mm','90 mm',
                          '110 mm','1/2 in','3/4 in','1 in','1.5 in','2 in','4 station',
                          '6 station','12 station','24 station'], lab.rnd(k, 22))
        || ' ' || lab.pick(ARRAY['Pro','Plus','Eco','HD','Max','Lite','Series 100','Series 300',
                                 'Series 500','Compact'], lab.rnd(k, 23))
$$;

CREATE OR REPLACE FUNCTION lab.product_brand(k bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT CASE WHEN lab.rnd(k, 24) < 0.1 THEN NULL
                ELSE lab.pick(ARRAY['Aqualine','Dunewell','Rainmark','Hydroseal','Verdant Flow',
                                    'Palmtech','Sahara Pro','Floraqua','IrriCore','Wadi Systems',
                                    'Blue Delta','Oasis Pro','Gulfpipe','TerraFlow','Nimbus',
                                    'Cedar Valve','Emirates Poly','Driptec','Aquanova','Greenspan'],
                              lab.rnd(k, 25)) END
$$;

-- List price in AED, net of VAT: most items are cheap, a few are pumps and controllers.
CREATE OR REPLACE FUNCTION lab.product_price(k bigint) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT round((5 + 1995 * (lab.rnd(k, 31) ^ 3))::numeric, 2) $$;

-- ─── Orders ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lab.order_is_b2b(i bigint) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT lab.rnd(i, 2) < 0.6 $$;

CREATE OR REPLACE FUNCTION lab.order_status(i bigint, created timestamp, anchor timestamp) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN lab.age_days(created, anchor) > 21 THEN
            CASE WHEN lab.rnd(i, 4) < 0.92 THEN 'DELIVERED' ELSE 'CANCELLED' END
        WHEN lab.age_days(created, anchor) > 7 THEN
            CASE WHEN lab.rnd(i, 4) < 0.60 THEN 'DELIVERED'
                 WHEN lab.rnd(i, 4) < 0.80 THEN 'DISPATCHED'
                 WHEN lab.rnd(i, 4) < 0.92 THEN 'PROCESSING'
                 ELSE 'CANCELLED' END
        ELSE
            CASE WHEN lab.rnd(i, 4) < 0.20 THEN 'PENDING_PAYMENT'
                 WHEN lab.rnd(i, 4) < 0.50 THEN 'CONFIRMED'
                 WHEN lab.rnd(i, 4) < 0.75 THEN 'PROCESSING'
                 WHEN lab.rnd(i, 4) < 0.90 THEN 'DISPATCHED'
                 WHEN lab.rnd(i, 4) < 0.95 THEN 'CANCELLED'
                 ELSE 'DELIVERED' END
    END
$$;

-- The statuses an order went through, oldest first (drives order_status_events).
CREATE OR REPLACE FUNCTION lab.order_status_path(status text) RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT CASE status
        WHEN 'PENDING_PAYMENT' THEN ARRAY['PENDING_PAYMENT']
        WHEN 'CONFIRMED'       THEN ARRAY['CONFIRMED']
        WHEN 'PROCESSING'      THEN ARRAY['CONFIRMED','PROCESSING']
        WHEN 'DISPATCHED'      THEN ARRAY['CONFIRMED','PROCESSING','DISPATCHED']
        WHEN 'DELIVERED'       THEN ARRAY['CONFIRMED','PROCESSING','DISPATCHED','DELIVERED']
        WHEN 'CANCELLED'       THEN ARRAY['CONFIRMED','CANCELLED']
    END
$$;

-- Hours after the order was placed at which it reached a status.
CREATE OR REPLACE FUNCTION lab.status_offset_hours(status text) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT CASE status WHEN 'PENDING_PAYMENT' THEN 0 WHEN 'CONFIRMED' THEN 1
                       WHEN 'PROCESSING' THEN 20 WHEN 'DISPATCHED' THEN 48
                       WHEN 'DELIVERED' THEN 96 WHEN 'CANCELLED' THEN 24 END
$$;

CREATE OR REPLACE FUNCTION lab.status_reached_at(created timestamp, status text, anchor timestamp)
RETURNS timestamp(3) LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT least(created + make_interval(hours => lab.status_offset_hours(status)), anchor)::timestamp(3) $$;

CREATE OR REPLACE FUNCTION lab.order_item_count(i bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT 1 + floor(9 * lab.rnd(i, 7))::int $$;

-- Lines of order i. Used both to insert order_items and to compute the order's totals, so
-- the header always equals the sum of its lines.
CREATE OR REPLACE FUNCTION lab.order_lines(i bigint, n_products int, discount numeric)
RETURNS TABLE (line_no int, product_no bigint, quantity int, list_price numeric,
               unit_price numeric, line_subtotal numeric, line_vat numeric)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT j, x.k, x.qty, x.list_price, x.unit_price,
           round(x.unit_price * x.qty, 2),
           round(x.unit_price * x.qty * 0.05, 2)
    FROM generate_series(1, lab.order_item_count(i)) AS j,
         LATERAL (SELECT lab.skewed(n_products, lab.rnd(i * 16 + j, 26), 1.6) AS k,
                         1 + floor(20 * lab.rnd(i * 16 + j, 27))::int AS qty) AS p,
         LATERAL (SELECT p.k, p.qty, lab.product_price(p.k) AS list_price,
                         round(lab.product_price(p.k) * (1 - discount / 100), 2) AS unit_price) AS x
$$;

-- ─── Quote requests (RFQs) and quotations ──────────────────────────────────
CREATE OR REPLACE FUNCTION lab.rfq_is_website(i bigint) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT lab.rnd(i, 102) < 0.25 $$;

CREATE OR REPLACE FUNCTION lab.rfq_status(i bigint, created timestamp, anchor timestamp) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN lab.age_days(created, anchor) > 30 THEN
            CASE WHEN lab.rnd(i, 105) < 0.65 THEN 'CLOSED'
                 WHEN lab.rnd(i, 105) < 0.87 THEN 'QUOTED'
                 ELSE 'CANCELLED' END
        WHEN lab.age_days(created, anchor) > 7 THEN
            CASE WHEN lab.rnd(i, 105) < 0.50 THEN 'QUOTED'
                 WHEN lab.rnd(i, 105) < 0.75 THEN 'CLOSED'
                 WHEN lab.rnd(i, 105) < 0.90 THEN 'IN_REVIEW'
                 ELSE 'CANCELLED' END
        ELSE
            CASE WHEN lab.rnd(i, 105) < 0.45 THEN 'SUBMITTED'
                 WHEN lab.rnd(i, 105) < 0.80 THEN 'IN_REVIEW'
                 ELSE 'QUOTED' END
    END
$$;

-- The quotation issued for an RFQ (NULL when none was prepared).
CREATE OR REPLACE FUNCTION lab.quotation_status(i bigint, rfq_status text, created timestamp, anchor timestamp)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT CASE rfq_status
        WHEN 'IN_REVIEW' THEN CASE WHEN lab.rnd(i, 111) < 0.4 THEN 'DRAFT' END
        WHEN 'CLOSED' THEN
            CASE WHEN lab.rnd(i, 112) < 0.60 THEN 'ACCEPTED'
                 WHEN lab.rnd(i, 112) < 0.80 THEN 'REJECTED'
                 ELSE 'EXPIRED' END
        WHEN 'QUOTED' THEN
            CASE WHEN lab.age_days(created, anchor) > 30 THEN
                     CASE WHEN lab.rnd(i, 112) < 0.45 THEN 'SENT'
                          WHEN lab.rnd(i, 112) < 0.80 THEN 'EXPIRED'
                          WHEN lab.rnd(i, 112) < 0.90 THEN 'REVISION_REQUESTED'
                          ELSE 'PENDING_APPROVAL' END
                 ELSE
                     CASE WHEN lab.rnd(i, 112) < 0.60 THEN 'SENT'
                          WHEN lab.rnd(i, 112) < 0.80 THEN 'PENDING_APPROVAL'
                          ELSE 'REVISION_REQUESTED' END
            END
    END
$$;

CREATE OR REPLACE FUNCTION lab.quotation_lines(i bigint, n_products int, discount numeric)
RETURNS TABLE (line_no int, product_no bigint, quantity int, list_price numeric,
               discount_rate numeric, unit_price numeric, line_subtotal numeric,
               line_vat numeric)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT j, x.k, x.qty, x.list_price, discount, x.unit_price,
           round(x.unit_price * x.qty, 2),
           round(x.unit_price * x.qty * 0.05, 2)
    FROM generate_series(1, 2 + floor(5 * lab.rnd(i, 113))::int) AS j,
         LATERAL (SELECT lab.skewed(n_products, lab.rnd(i * 16 + j, 114), 1.6) AS k,
                         5 + floor(200 * lab.rnd(i * 16 + j, 115))::int AS qty) AS p,
         LATERAL (SELECT p.k, p.qty, lab.product_price(p.k) AS list_price,
                         round(lab.product_price(p.k) * (1 - discount / 100), 2) AS unit_price) AS x
$$;

-- ─── Audit trail ────────────────────────────────────────────────────────────
-- 100 buckets with the relative frequency of each action (TopFlow's audit-actions.ts).
CREATE TABLE IF NOT EXISTS lab.audit_action_buckets (
    bucket      int PRIMARY KEY,
    action      text NOT NULL,
    entity_type text NOT NULL
);

TRUNCATE lab.audit_action_buckets;
INSERT INTO lab.audit_action_buckets (bucket, action, entity_type)
SELECT row_number() OVER (ORDER BY w.ord, g) - 1, w.action, w.entity_type
FROM (VALUES
    (1,  'auth.login',                               'User',         15),
    (2,  'orders.status_changed',                    'Order',        20),
    (3,  'orders.placed',                            'Order',        10),
    (4,  'orders.payment_recorded',                  'Order',         5),
    (5,  'orders.cancelled',                         'Order',         2),
    (6,  'procurement.rfq_submitted',                'QuoteRequest',  8),
    (7,  'procurement.rfq_updated',                  'QuoteRequest',  6),
    (8,  'procurement.quotation_created',            'Quotation',     6),
    (9,  'procurement.quotation_sent',               'Quotation',     6),
    (10, 'procurement.quotation_responded',          'Quotation',     5),
    (11, 'procurement.quotation_revised',            'Quotation',     2),
    (12, 'procurement.quotation_approval_decided',   'Quotation',     1),
    (13, 'catalog.stock_adjusted',                   'Product',       5),
    (14, 'catalog.product_updated',                  'Product',       2),
    (15, 'organizations.updated',                    'Organization',  2),
    (16, 'organizations.member_invited',             'Organization',  1),
    (17, 'organizations.reviewed',                   'Organization',  1),
    (18, 'users.updated',                            'User',          2),
    (19, 'auth.user_registered',                     'User',          1)
) AS w (ord, action, entity_type, weight)
CROSS JOIN LATERAL generate_series(1, w.weight) AS g;
