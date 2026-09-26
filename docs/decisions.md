# Decisions

Short records of the choices that shaped the lab: the context, the decision and what it costs.

## 1. PostgreSQL 18

**Context.** The lab should show current practice. PostgreSQL 19 is in beta; 18 has had a year
of minor releases.

**Decision.** `postgres:18.6-trixie` from Docker Hub, pinned to the minor version. pgBackRest and
pgTAP come from the PGDG repository that the image already trusts.

**Consequences.** Data checksums are on by default (PostgreSQL 18 initdb), which pg_rewind can
use. Dependabot proposes minor updates; major upgrades are ignored on purpose because they need
`pg_upgrade` or a dump and restore.

## 2. One bash entry point, everything else in containers

**Context.** The host has Docker and nothing else that the lab can rely on: no `make`, no `psql`,
and on Windows only Git Bash.

**Decision.** `./lab` (bash) drives `docker compose`. SQL runs in the node containers or in a
`runner` container with psql, pg_prove and the locked Python environment. The repository is
mounted into the runner, so code changes need no image rebuild.

**Consequences.** The same commands work on Linux, macOS and Git Bash on Windows, and CI runs
`./lab ci` unchanged. Git Bash rewrites arguments that look like paths, so `./lab` exports
`MSYS_NO_PATHCONV=1`. On the Windows machine used here, Docker Desktop could not read some
nested bind mounts, so the Prometheus and Grafana configuration is baked into small images
instead of mounted (ADR 13).

## 3. TopFlow's migrations, unchanged, and the lab's objects in their own schemas

**Context.** The schema must be TopFlow Hub's real design, and it must stay recognisable.

**Decision.** The four Prisma migrations are copied byte for byte (`sql/topflow/`, SHA-256
checked by a unit test) and applied as the migrator, as Prisma would. Everything the lab adds
lives in schemas `lab` (generator, heartbeat), `app` (RLS helpers) and `part` (partitioning),
except the casebook's indexes and the policies, which belong on TopFlow's tables.

**Consequences.** Index names follow Prisma's convention, so a fix can move into
`schema.prisma` where Prisma supports it; `INCLUDE`, operator classes and partial predicates need
raw SQL migrations, which the casebook notes case by case.

## 4. A data generator in SQL, with hash-based values

**Context.** The target is 10 million order lines (50 million as an option, not yet run), and
CI loads about 100,000 on every run, so loading must not dominate the pipeline. Rows must be
reproducible so that plans can be compared between runs.

**Decision.** `generate_series` and pure SQL functions of the row number: `hashint8extended` for
pseudo-random numbers, `md5` for UUID-shaped ids. Order totals are computed from the same line
function that fills `order_items`, so headers always match their lines. Secondary indexes and
foreign keys are dropped for the load and rebuilt afterwards. The functions are not `STRICT`,
because PostgreSQL does not inline a strict SQL function whose body contains `CASE` and would
call it through the SQL-function executor for every row (`EXPLAIN VERBOSE` shows the call).
How long the load takes at the target size is part of the measured run.

**Consequences.** The data never leaves the server and there is no Python dependency for loading.
The same SCALE and anchor give the same rows. Names, companies and brands are fictional and all
e-mail domains are reserved example domains.

## 5. Rank the workload by buffers, publish timings only from measured runs

**Context.** This machine is shared with other builds; durations measured here would mislead.

**Decision.** The workload is ranked by shared buffers touched (`EXPLAIN (ANALYZE, BUFFERS)`),
which depends on data and plan, not on load. Default runs use `TIMING OFF, SUMMARY OFF` and
strip the `I/O Timings` lines, so no duration reaches a report. `--measure` records the median of
N runs of server-side planning plus execution time, with the result rows serialised to text
(`EXPLAIN (ANALYZE, SERIALIZE TEXT, TIMING OFF, SUMMARY ON)`), for a quiet machine.

**Consequences.** Reports can be generated anywhere and compared. Every timing column in the
committed reports says "pending a measured run" (docs/benchmarking.md).

## 6. The casebook is data, and CI checks plan shape

**Context.** "Faster" is not testable on a shared CI runner; "uses the intended index" is.

**Decision.** Each case is a TOML file: the workload query, the fix as separate statements, the
revert, an optional rewrite and the expected plan before and after (indexes used, nodes present
or absent, sequential scans). Index fixes use `CREATE INDEX CONCURRENTLY IF NOT EXISTS`. When one
index fixes several statements, the other cases say `fixed_by` instead of repeating it.

**Consequences.** A regression that changes a plan fails CI at SCALE=100000; the same checks pass
at SCALE=1000000. Checks cannot prove a fix is fast enough, which is what the measured run is for.

## 7. A covering B-tree on `orders.createdAt`, not BRIN or a materialised view

**Context.** Three dashboard statements read `orders` by `createdAt`: two 30-day aggregates and
the eight newest orders.

**Decision.** One B-tree on `createdAt` with `INCLUDE (status, totalAmount)`.

**Consequences.** Index-only scans for the aggregates and an ordered scan for the newest orders.
BRIN would be far smaller (measured in `reports/indexing.md`) but cannot return rows in order,
so the newest-orders statement would still need a B-tree. A materialised view would answer "the
last 30 calendar days as of the last refresh" and every refresh reads the table; with an
index-only scan over one month it is not justified.

## 8. pgBackRest rather than WAL-G

**Context.** The PITR drill needs WAL archiving, full backups and a restore to a timestamp, with
the repository on a local volume.

**Decision.** pgBackRest 2.59 from PGDG, repository on a Docker volume shared by both nodes.

**Consequences.** Delta restore (`--delta`) rewrites only changed files, which shortens recovery
of a large database; `check`, `info` and retention are built in; the package matches the
server's major version. WAL-G is a single binary with good object-storage support, but a local
repository and delta restore are what this lab exercises. Moving the repository to S3-compatible
storage is a configuration change (`repo1-type=s3`), listed under the roadmap.

## 9. Switchover through libpq, without a proxy or automatic failover

**Context.** Clients must follow the primary after a switchover, and the drill must measure the
write downtime they see.

**Decision.** Clients list both nodes (`host=pg1,pg2 target_session_attrs=read-write`); libpq
skips the node that is down or read-only. The drill stops the old primary cleanly, checks that
the standby has replayed its shutdown checkpoint, promotes the standby, runs pg_rewind and
restarts the old primary as a standby.

**Consequences.** No extra moving part for libpq-based clients (psql, psycopg, pgbench and
anything else built on libpq). TopFlow's API connects through node-postgres
(`@prisma/adapter-pg`), which implements the protocol itself rather than through libpq; the lab
does not test it, and a proxy or a DNS switch is the usual way to repoint such clients
(docs/replication.md). There is no automatic failover: Patroni or a similar manager would add
consensus and fencing, which is out of scope here.

## 10. Row-level security: an opaque tenant-row function plus a restrictive membership gate

**Context.** Tenant isolation must hold even when an API query forgets its `WHERE`, and it must
not cost the tenant queries their indexes. The API's queries already filter by organisation, so
every policy repeats a predicate the planner has already seen once.

**Decision.** On the tables where a row belongs to an organisation or to a customer without one,
the permissive policy calls `app.is_tenant_row(organisation, owner)`, a PL/pgSQL function
(`STABLE`, `COST 10`) over `current_setting`. A restrictive policy checks once per statement
(an InitPlan) that the user belongs to the organisation they claim. Case 8's index includes
`userId`, the policy's second column. Staff use a separate role, `topflow_backoffice`, with its
own pool.

**Alternatives.** The membership lookup inside the permissive policy (the first version) made the
planner expect 26 of 9,943 rows and read every order of the organisation for one page. A
transparent policy with inlined settings kept the index, but the planner applied the
organisation's share twice and expected 251 rows; the bitmap plan cost less than 1% more than
the index scan.

**Consequences.** A user who claims an organisation they do not belong to sees nothing. The
function gets a fixed default selectivity, so the estimate is a sixth of the real rows for every
organisation: wrong, but predictably so, and the bitmap plan costs 74 times the index scan
(`reports/rls-plans.md`). A function call per row costs CPU, which this functional run did not
measure. Registering a trade account, accepting an invitation and KYC cross tenants and belong
to the staff role in this model.

The context is self-asserted: any `topflow_app` session can set `app.user_id` and `app.org_id`.
The policies therefore protect against API queries that forget their tenant filter, not against
code that can run arbitrary SQL as `topflow_app` (SQL injection, a compromised API process).
Verifying a signed token inside a `SECURITY DEFINER` function, a role per tenant entered with
`SET ROLE`, or a pooler that injects the context would close that gap at the cost of more moving
parts (docs/security.md, "Trust boundary").

## 11. Partitioning shown next to the plain tables, not in place of them

**Context.** Partitioning `orders` changes keys: the primary key and unique constraints must
include `createdAt`, and foreign keys from `order_items` would need the order's `createdAt`.

**Decision.** Build `part.orders` and `part.audit_logs` (monthly ranges, same indexes) beside the
plain tables and compare. No default partition; a maintenance command creates partitions ahead
and detaches old ones with `DETACH PARTITION ... CONCURRENTLY`.

**Consequences.** The comparison is honest about the cost: with good indexes, time-bounded reads
barely change, and a query without the partition key reads every partition. The clear gain is
retention (`reports/partitioning.md`). The recommendation is to partition `audit_logs` first.

## 12. Five application roles, three infrastructure roles and SCRAM everywhere

**Context.** Least privilege for an API, reporting and migrations; no password hashes an
attacker could replay.

**Decision.** An owner that nobody logs in as, a migrator whose sessions become the owner, the
customer-facing app, the back office and a read-only analyst, plus infrastructure roles
(replicator, monitor, rewind). Only SCRAM-SHA-256 in `pg_hba.conf`; the superuser is rejected from
outside the Docker network. pg_rewind's role reads the data directory through file functions, so
it may connect only to the maintenance database from the Docker network, and it is `NOLOGIN`
except while a drill runs pg_rewind. Passwords are random, generated by `./lab init` into an
untracked `.env`.

**Consequences.** Audit entries and order history are append-only for every application role,
and customers append to an order's history only the events their own flows write; customers
cannot change their role, credit limit or discount (column privileges; ADR 16 for the rest of
the customer writes). TLS is not configured, so passwords are protected by SCRAM but
traffic is not encrypted (a limitation).

## 13. Monitoring configuration baked into images

**Context.** Prometheus and Grafana need their configuration at start; bind mounts of nested
folders failed on the Windows machine used here.

**Decision.** Two small Dockerfiles copy `monitoring/` into the official images. `./lab monitor up`
rebuilds them.

**Consequences.** The configuration in a running container is exactly what is committed. Editing
a dashboard means changing the JSON and running `./lab monitor up` again.

## 14. SQL Server chapter written, not run

**Context.** Running SQL Server requires accepting Microsoft's licence (`ACCEPT_EULA=Y`), which is
Farah's decision, not the tooling's.

**Decision.** Ship the scripts (schema, generator, the ten statements, the fixes, a Dockerfile
with Full-Text Search) and a guard: `./lab sqlserver` stops unless the user sets
`MSSQL_ACCEPT_EULA=Y`. The T-SQL is syntax-checked with sqlfluff and the plan parser is
unit-tested on a synthetic fixture.

**Consequences.** Nothing about SQL Server's behaviour is claimed as measured.
`sqlserver/expectations.toml` holds the expected plans, to be confirmed by the first run.

## 15. Python 3.14 with uv, mypy --strict and ruff

**Context.** The tooling parses plans, renders reports and runs drills; it has to be typed and
tested.

**Decision.** One dependency at run time (psycopg 3.3 with its binary wheel), locked with uv.
Development tools: pytest, mypy in strict mode, ruff, sqlfluff.

**Consequences.** Unit tests run without a database from plans recorded at SCALE=1000000;
integration tests and pgTAP suites run against the lab.

## 16. Customer writes: column privileges, state policies, a definer function for numbers

**Context.** Tenant policies decide which rows the customer-facing role reaches, not what it does
to them. With table-wide `UPDATE`, a customer could mark their own order paid and delivered at
any price, extend and accept a quotation, add another organisation's user to their own and read
that user's profile, or reset the document counters that every tenant shares. With a plain
`INSERT` on the child tables, a customer could add lines to their own delivered and paid order,
or write a status event that says staff cancelled it.

**Decision.** `UPDATE` is granted per column, only on the columns each TopFlow customer flow
changes. Restrictive policies limit the states a row may leave and enter (cancel an open, unpaid
order; answer an open quotation, approvals in the caller's own name, never an expired one) and
what a customer appends to an order: lines only while placing it (an open, unpaid order with no
history yet), and status events only in their own name, continuing the order's timeline and
ending in its current status (`app.continues_order_timeline()`, a `SECURITY DEFINER` function,
because a policy cannot query its own table). Only
the organisation's owner changes or removes members; joining an organisation and registering
one are staff flows, so the customer role has no `INSERT` on either table. Document numbers come
from `app.next_document_number(key)`, a `SECURITY DEFINER` function; the API roles have no
privilege on `document_sequences`.

**Consequences.** Each attack above is a pgTAP test that must fail. The policies check states,
not every transition pair, so the API's state machines stay the reference. Values the API
computes at creation (prices, lines) are still trusted: checking them would repeat the pricing
in SQL. TopFlow's `NumberingService` and its invitation and registration flows would change to
use the function and the staff role (docs/security.md, "Limitations").
