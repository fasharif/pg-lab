# Test fixtures

## plans/

`EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY OFF, FORMAT JSON)` output recorded from the
lab at SCALE=1000000 on 2026-09-25 (PostgreSQL 18.6), for four casebook statements before
and after their fixes. `<workload id>.before.json` is the baseline schema (TopFlow's own
indexes) and `<workload id>.after.json` the tuned schema. Keys holding durations (I/O timings)
were removed when recording, so the files contain plan shape, row counts and buffer counts
only. The unit tests use them to check plan parsing and the plan checks without a database.

`orders-admin-search-count.*.json` are case 4's pagination total, recorded the same way at
SCALE=1000000 on 2026-09-27: `before` is the count on the baseline schema,
`tuned-without-rewrite` the same count with the casebook's indexes, and `after` the rewritten
count on the tuned schema.

`rfq-admin-search.*.json` and `rfq-admin-search-count.*.json` are case 11, the RFQ search and
its pagination total, with the same three variants. They were recorded the same way at
SCALE=10000000 on 2026-10-02, at the end of the measured run that added case 11: `before` on the
baseline schema (`./lab untune`), the other two on the tuned schema (`./lab tune`).

## exporter-metric-names.txt

Metric names exposed by postgres_exporter v0.20.1 against a lab node, used to check that
every metric referenced by the Grafana dashboard and the Prometheus alert rules exists.

## mssql/sqlcmd-output-synthetic.txt

Hand-written, not captured: SQL Server was not run in this repository (docs/sqlserver.md). It
follows the documented shape of sqlcmd output with `SET STATISTICS IO ON` and
`SET STATISTICS XML ON` (a "Table 'x'. Scan count n, logical reads n" line per table and one
showplan XML document per statement) and exists only to test the parser in `pglab.mssql`.
