# Test fixtures

## plans/

`EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY OFF, FORMAT JSON)` output recorded from the
lab at SCALE=1000000 on 2026-09-25 (PostgreSQL 18.6), for four casebook statements before
and after their fixes. `<workload id>.before.json` is the baseline schema (TopFlow's own
indexes) and `<workload id>.after.json` the tuned schema. Keys holding durations (I/O timings)
were removed when recording, so the files contain plan shape, row counts and buffer counts
only. The unit tests use them to check plan parsing and the plan checks without a database.

## exporter-metrics.txt

Metric names exposed by postgres_exporter v0.20.1 against a lab node, used to check that
every metric referenced by the Grafana dashboard and the Prometheus alert rules exists.
