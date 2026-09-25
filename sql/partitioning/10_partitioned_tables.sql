-- Monthly range partitioning of orders and audit_logs (declarative partitioning).
--
-- The lab builds the partitioned tables next to TopFlow's own (schema "part") so that the
-- same queries can be compared on both. Applied by ./lab partition as topflow_migrator; it
-- drops and recreates schema part, so it is safe to re-run.
--
-- What partitioning changes for TopFlow (see docs/partitioning.md):
--   * Primary keys and unique constraints must include the partition key, so "id" alone and
--     "orderNumber" alone are no longer enforced unique across partitions.
--   * A foreign key can only reference a partitioned table through a unique constraint that
--     includes the partition key: order_items and order_status_events would need an
--     "orderCreatedAt" column to keep their foreign keys to orders.
--   * There is no DEFAULT partition: a row outside every partition is rejected, so the
--     maintenance job must create partitions ahead of time (part.create_monthly_partitions).

DROP SCHEMA IF EXISTS part CASCADE;
DROP SCHEMA IF EXISTS part_archive CASCADE;
CREATE SCHEMA part;
CREATE SCHEMA part_archive;
COMMENT ON SCHEMA part IS 'pg-lab: monthly range-partitioned copies of orders and audit_logs';
COMMENT ON SCHEMA part_archive IS 'pg-lab: partitions detached by part maintenance, kept until archived';

CREATE TABLE part.orders (LIKE public.orders INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
    PARTITION BY RANGE ("createdAt");
ALTER TABLE part.orders ADD CONSTRAINT orders_pkey PRIMARY KEY (id, "createdAt");
ALTER TABLE part.orders ADD CONSTRAINT "orders_orderNumber_createdAt_key" UNIQUE ("orderNumber", "createdAt");
CREATE INDEX "orders_organizationId_createdAt_idx" ON part.orders ("organizationId", "createdAt");
CREATE INDEX "orders_createdAt_idx" ON part.orders ("createdAt") INCLUDE (status, "totalAmount");
CREATE INDEX "orders_userId_idx" ON part.orders ("userId");
CREATE INDEX "orders_status_idx" ON part.orders (status);

CREATE TABLE part.audit_logs (LIKE public.audit_logs INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
    PARTITION BY RANGE ("createdAt");
ALTER TABLE part.audit_logs ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id, "createdAt");
CREATE INDEX "audit_logs_createdAt_idx" ON part.audit_logs ("createdAt");
CREATE INDEX "audit_logs_userId_createdAt_idx" ON part.audit_logs ("userId", "createdAt");
CREATE INDEX "audit_logs_entityType_entityId_idx" ON part.audit_logs ("entityType", "entityId");
CREATE INDEX "audit_logs_action_pattern_idx" ON part.audit_logs (action text_pattern_ops);

-- Partitions of a parent with their month and bounds, oldest first. Partition names follow
-- <table>_pYYYY_MM; bounds are read from the catalogue, not from the name.
CREATE FUNCTION part.partitions(parent regclass)
RETURNS TABLE (partition regclass, month date, lower_bound timestamp, upper_bound timestamp)
LANGUAGE sql STABLE
AS $$
    SELECT c.oid::regclass,
           date_trunc('month', b.lower_bound)::date,
           b.lower_bound,
           b.upper_bound
    FROM pg_inherits AS i
    JOIN pg_class AS c ON c.oid = i.inhrelid
    CROSS JOIN LATERAL (
        SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid),
                             'FROM \(''([^'']+)''\) TO \(''([^'']+)''\)')) AS m
    ) AS r
    CROSS JOIN LATERAL (SELECT r.m[1]::timestamp AS lower_bound, r.m[2]::timestamp AS upper_bound) AS b
    WHERE i.inhparent = parent
    ORDER BY b.lower_bound
$$;

-- Creates the missing monthly partitions from first_month to last_month (inclusive) and
-- returns the names it created. Idempotent: existing months are skipped.
CREATE FUNCTION part.create_monthly_partitions(parent regclass, first_month date, last_month date)
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    current_month date := date_trunc('month', first_month)::date;
    stop_month date := date_trunc('month', last_month)::date;
    parent_schema text;
    parent_name text;
    child text;
BEGIN
    IF first_month > last_month THEN
        RAISE EXCEPTION 'first_month % is after last_month %', first_month, last_month;
    END IF;
    SELECT n.nspname, c.relname INTO parent_schema, parent_name
    FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE c.oid = parent AND c.relkind = 'p';
    IF parent_name IS NULL THEN
        RAISE EXCEPTION '% is not a partitioned table', parent;
    END IF;
    WHILE current_month <= stop_month LOOP
        child := format('%s_p%s', parent_name, to_char(current_month, 'YYYY_MM'));
        IF NOT EXISTS (SELECT 1 FROM part.partitions(parent) AS p WHERE p.month = current_month) THEN
            EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                           parent_schema, child, parent, current_month::timestamp,
                           (current_month + interval '1 month')::timestamp);
            RETURN NEXT format('%I.%I', parent_schema, child);
        END IF;
        current_month := (current_month + interval '1 month')::date;
    END LOOP;
END
$$;

-- Partitions whose whole range is older than the retention window (keep_months full months
-- before the month of as_of). They are the candidates for DETACH PARTITION ... CONCURRENTLY,
-- which cannot run inside a function or transaction, so the caller issues it.
CREATE FUNCTION part.partitions_to_detach(parent regclass, keep_months int, as_of date)
RETURNS SETOF regclass
LANGUAGE sql STABLE
AS $$
    SELECT p.partition
    FROM part.partitions(parent) AS p
    WHERE p.upper_bound <= (date_trunc('month', as_of) - make_interval(months => keep_months))
    ORDER BY p.lower_bound
$$;

-- Number of whole months after the month of as_of that already have a partition. The
-- maintenance command fails when it is below the number of months it was asked to keep ready.
CREATE FUNCTION part.months_ready(parent regclass, as_of date)
RETURNS int
LANGUAGE sql STABLE
AS $$
    SELECT count(*)::int
    FROM part.partitions(parent) AS p
    WHERE p.month > date_trunc('month', as_of)::date
$$;
