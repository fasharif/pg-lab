-- The partition maintenance functions (sql/partitioning), on a temporary partitioned table.
-- Needs schema part, created by ./lab partition; skipped when it does not exist.
BEGIN;
SET LOCAL search_path = public, tap;
SELECT to_regnamespace('part') IS NOT NULL AS has_part \gset

\if :has_part
SELECT plan(8);

CREATE TABLE pg_temp.events (id int, at timestamp) PARTITION BY RANGE (at);

SELECT is(
    (SELECT count(*) FROM part.create_monthly_partitions('pg_temp.events'::regclass, '2026-01-15', '2026-04-01')),
    4::bigint,
    'creates one partition per month, both ends included'
);
SELECT is(
    (SELECT count(*) FROM part.create_monthly_partitions('pg_temp.events'::regclass, '2026-01-01', '2026-05-01')),
    1::bigint,
    'is idempotent: a second call only adds the missing month'
);
SELECT results_eq(
    $$SELECT month, lower_bound, upper_bound FROM part.partitions('pg_temp.events'::regclass) LIMIT 2$$,
    $$VALUES ('2026-01-01'::date, '2026-01-01'::timestamp, '2026-02-01'::timestamp),
             ('2026-02-01'::date, '2026-02-01'::timestamp, '2026-03-01'::timestamp)$$,
    'lists partitions oldest first with bounds read from the catalogue'
);
SELECT results_eq(
    $$SELECT p.month
      FROM part.partitions_to_detach('pg_temp.events'::regclass, 2, '2026-05-10') AS d
      JOIN part.partitions('pg_temp.events'::regclass) AS p ON p.partition = d$$,
    $$VALUES ('2026-01-01'::date), ('2026-02-01'::date)$$,
    'keeping two full months before May detaches January and February only'
);
SELECT is(part.months_ready('pg_temp.events'::regclass, '2026-03-10'), 2,
          'counts the months that already have a partition after the current one');
SELECT throws_ok(
    $$SELECT part.create_monthly_partitions('pg_temp.events'::regclass, '2026-06-01', '2026-05-01')$$,
    'P0001', NULL, 'rejects a reversed range'
);
SELECT throws_ok(
    $$SELECT part.create_monthly_partitions('public.orders'::regclass, '2026-01-01', '2026-01-01')$$,
    'P0001', NULL, 'refuses a table that is not partitioned'
);
SELECT throws_ok(
    $$INSERT INTO pg_temp.events VALUES (1, '2027-01-01')$$,
    '23514', NULL, 'rows outside every partition are rejected (there is no default partition)'
);
\else
SELECT plan(1);
SELECT skip('schema part does not exist: run ./lab partition first', 1);
\endif

SELECT * FROM finish();
ROLLBACK;
