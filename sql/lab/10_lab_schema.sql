-- pg-lab helper schema. Idempotent: ./lab migrate re-applies it on every run.
-- Nothing here changes TopFlow's own tables; the lab keeps its state in schema "lab".

CREATE SCHEMA IF NOT EXISTS lab;
COMMENT ON SCHEMA lab IS 'pg-lab helpers: data generator functions, dataset settings, drill heartbeat';

CREATE TABLE IF NOT EXISTS lab.settings (
    key   text PRIMARY KEY,
    value text NOT NULL
);

-- The instant the generated history ends. Queries that the API parameterises with "now"
-- (for example the dashboard's last 30 days) use this value, so plans and results do not
-- drift with the wall clock.
CREATE OR REPLACE FUNCTION lab.anchor() RETURNS timestamp(3)
LANGUAGE sql STABLE PARALLEL SAFE
AS $$ SELECT value::timestamp(3) FROM lab.settings WHERE key = 'anchor' $$;

-- The SCALE the current data set was generated with, and its derived row counts.
CREATE OR REPLACE FUNCTION lab.scale() RETURNS bigint
LANGUAGE sql STABLE PARALLEL SAFE
AS $$ SELECT value::bigint FROM lab.settings WHERE key = 'scale' $$;

-- Deterministic uniform number in [0, 1) derived from (n, salt). Hash based, so it is the
-- same on every run and in parallel workers, unlike random().
CREATE OR REPLACE FUNCTION lab.rnd(n bigint, salt bigint) RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT ((hashint8extended(n, salt) >> 11) & 9007199254740991)::double precision / 9007199254740992.0 $$;

-- Deterministic UUID-shaped text id, the same shape as Prisma's uuid() ids.
CREATE OR REPLACE FUNCTION lab.uid(kind text, n bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT md5(kind || ':' || n)::uuid::text $$;

-- Picks one element of an array with a number in [0, 1).
CREATE OR REPLACE FUNCTION lab.pick(items text[], r double precision) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT items[1 + floor(r * cardinality(items))::int] $$;

-- Heartbeat rows written by the client loop during the PITR and switchover drills.
CREATE TABLE IF NOT EXISTS lab.heartbeat (
    run_id       text        NOT NULL,
    seq          bigint      NOT NULL,
    sent_at      timestamptz NOT NULL,
    committed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    node         text        NOT NULL DEFAULT current_setting('cluster_name'),
    PRIMARY KEY (run_id, seq)
);

-- ─── Bulk-load helpers ──────────────────────────────────────────────────────
-- Loading millions of rows is much faster without secondary indexes and foreign keys.
-- begin_bulk_load() records their definitions and drops them; end_bulk_load() recreates
-- them in dependency order (keys, then indexes, then foreign keys).
CREATE TABLE IF NOT EXISTS lab.deferred_ddl (
    seq        serial PRIMARY KEY,
    phase      int  NOT NULL,          -- 1 primary/unique keys, 2 indexes, 3 foreign keys
    table_name text NOT NULL,
    object     text NOT NULL,
    ddl        text NOT NULL
);

CREATE OR REPLACE FUNCTION lab.deferred_object_exists(phase int, table_name text, object text)
RETURNS boolean LANGUAGE sql STABLE
AS $$
    SELECT CASE WHEN phase = 2 THEN to_regclass('public.' || quote_ident(object)) IS NOT NULL
                ELSE EXISTS (SELECT 1 FROM pg_constraint c
                             WHERE c.conname = object AND c.conrelid = to_regclass(table_name))
           END
$$;

CREATE OR REPLACE FUNCTION lab.begin_bulk_load() RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    item record;
    dropped integer := 0;
BEGIN
    -- A non-empty list means an earlier load stopped half way: keep the saved definitions
    -- (the live catalogue may already miss some objects) and carry on from there.
    IF NOT EXISTS (SELECT 1 FROM lab.deferred_ddl) THEN
        INSERT INTO lab.deferred_ddl (phase, table_name, object, ddl)
        SELECT CASE c.contype WHEN 'f' THEN 3 ELSE 1 END,
               c.conrelid::regclass::text, c.conname,
               format('ALTER TABLE %s ADD CONSTRAINT %I %s', c.conrelid::regclass, c.conname,
                      pg_get_constraintdef(c.oid))
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relnamespace = 'public'::regnamespace AND t.relkind = 'r'
          AND c.contype IN ('p', 'u', 'f');

        INSERT INTO lab.deferred_ddl (phase, table_name, object, ddl)
        SELECT 2, i.indrelid::regclass::text, ic.relname, pg_get_indexdef(i.indexrelid)
        FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_class t ON t.oid = i.indrelid
        WHERE t.relnamespace = 'public'::regnamespace AND t.relkind = 'r'
          AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid);
    END IF;

    FOR item IN SELECT d.* FROM lab.deferred_ddl d
                WHERE d.phase = 3 AND lab.deferred_object_exists(d.phase, d.table_name, d.object)
                ORDER BY d.seq LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', item.table_name, item.object);
        dropped := dropped + 1;
    END LOOP;
    FOR item IN SELECT d.* FROM lab.deferred_ddl d
                WHERE d.phase = 2 AND lab.deferred_object_exists(d.phase, d.table_name, d.object)
                ORDER BY d.seq LOOP
        EXECUTE format('DROP INDEX public.%I', item.object);
        dropped := dropped + 1;
    END LOOP;
    FOR item IN SELECT d.* FROM lab.deferred_ddl d
                WHERE d.phase = 1 AND lab.deferred_object_exists(d.phase, d.table_name, d.object)
                ORDER BY d.seq LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', item.table_name, item.object);
        dropped := dropped + 1;
    END LOOP;
    RETURN dropped;
END
$$;

-- Returns the statements to run, in order. The generator script runs them one by one from
-- psql (\gexec) so that each index build can use parallel workers and shows progress.
CREATE OR REPLACE FUNCTION lab.pending_bulk_load_ddl() RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
    SELECT d.ddl FROM lab.deferred_ddl d
    WHERE NOT lab.deferred_object_exists(d.phase, d.table_name, d.object)
    ORDER BY d.phase, d.seq
$$;

CREATE OR REPLACE FUNCTION lab.finish_bulk_load() RETURNS void
LANGUAGE sql
AS $$ DELETE FROM lab.deferred_ddl $$;
