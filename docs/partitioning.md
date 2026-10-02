# Partitioning

Files: `sql/partitioning/10_partitioned_tables.sql`, `src/pglab/partitioning.py`.
Report: `reports/partitioning.md`. Tests: `tests/pgtap/05_partition_functions.sql`.

## What the lab builds

`./lab partition` creates schema `part` with two tables partitioned by month on `createdAt`
(declarative range partitioning), fills them from TopFlow's tables and compares the two:

- `part.orders` and `part.audit_logs`, one partition per month (`orders_p2025_09`, ...), from the
  oldest row to three months after the data's anchor date;
- the same indexes as the tuned plain tables (TopFlow's plus the casebook's), created on the
  parents so that every partition gets them;
- no `DEFAULT` partition. A row outside every partition is rejected (a pgTAP test checks this),
  so partitions must exist before the data arrives; that is the maintenance job's task.

The plain tables stay as they are: TopFlow's foreign keys keep working and the casebook still
runs on them.

## What partitioning would change in TopFlow

| Constraint today | On a table partitioned by `createdAt` |
| --- | --- |
| `orders.id` is the primary key | The key must include the partition key: `(id, "createdAt")`. `id` alone is no longer enforced unique across partitions. |
| `orderNumber` is unique | Only `("orderNumber", "createdAt")` can be declared. TopFlow's numbering service already guarantees uniqueness, but the database no longer does. |
| `order_items.orderId` and `order_status_events.orderId` reference `orders.id` | A foreign key to a partitioned table must reference a unique key that includes `createdAt`, so both child tables would need an `orderCreatedAt` column (or no foreign key). |

`audit_logs` has none of these problems: nothing references it, it only grows, and old entries
are removed by age. It is the table to partition first. `orders` should follow only when its size
makes vacuum or retention a problem.

## Pruning

The report checks, for each time-bounded statement, that the plan scans exactly the partitions
whose range overlaps the statement's time window:

| Statement | Pruning |
| --- | --- |
| Dashboard revenue of the last 30 days | at plan time, to the partitions from 30 days ago onwards (including the empty future ones) |
| One organisation's orders in the last full month | at plan time, to one partition |
| Audit entries of one day | at plan time, to one partition |
| Orders of the last 7 days as a prepared statement with a generic plan | at execution start ("Subplans Removed"), because the bound is a parameter, which is how Prisma sends it |
| An organisation's order history with no date filter | none: every partition is read |

Each statement is also run on the plain table, first with TopFlow's own indexes and then with
the casebook's. With the casebook's indexes, the plain table reads about as few pages as the
partitioned one for these statements, and the last statement shows the cost of partitioning: a
query without the partition key visits every partition's index.

The measured run at SCALE=10000000 (`./lab partition --measure`, medians of 15 runs of planning
plus execution) confirms it in time:

| Statement | Plain, TopFlow's indexes | Plain, casebook's indexes | Partitioned |
| --- | ---: | ---: | ---: |
| Dashboard revenue of the last 30 days | 337 ms | 9.5 ms | 11.2 ms |
| One organisation's orders in the last full month | 48.6 ms | 3.4 ms | 3.0 ms |
| Audit entries of one day | 1.5 ms | 1.3 ms | 0.098 ms |
| Orders of the last 7 days, generic plan | 356 ms | 7.5 ms | 8.5 ms |
| Order history with no date filter | 65.2 ms | 0.101 ms | 0.845 ms |

The indexes, not the partitions, remove most of the time. The one-day audit lookup is faster on
the partitioned table mainly because its planning is: 1.2 ms of the plain table's 1.3 ms is
planning, against 0.056 ms on the partitions. The query without the partition key pays for the
28 partitions in planning (0.732 ms of its 0.845 ms). Retention is where partitioning clearly
wins: detaching the oldest month of 410,960 audit entries wrote 30,072 bytes of WAL, deleting
them from the plain table 72,959,563 bytes.

## Retention

The report compares two ways of removing the oldest full month of audit entries: a `DELETE` on
the plain table (measured with `EXPLAIN (ANALYZE, WAL)` and rolled back) and
`DETACH PARTITION` on the partitioned one (WAL position before and after). The detached partition
is an ordinary table that can be dumped, archived and dropped; the `DELETE` also leaves every row
behind as a dead tuple for vacuum.

## Maintenance

```bash
./lab partition-maintain --ahead 3 --retain 24          # defaults
./lab partition-maintain --ahead 4 --retain 12 --as-of 2026-10-01
```

1. First it finishes what an interrupted run left. `DETACH ... CONCURRENTLY` commits in two
   steps; cancelled between them, it leaves the partition "detach pending"
   (`pg_inherits.inhdetachpending`), and every later detach of it fails until
   `ALTER TABLE ... DETACH PARTITION ... FINALIZE` completes it. The command runs `FINALIZE` for
   such partitions, then moves to `part_archive` any detached table still in schema `part` (a
   run that stopped between the detach and the move).
2. `part.create_monthly_partitions(parent, from, to)` creates the missing months (idempotent).
3. `part.partitions_to_detach(parent, retain, as_of)` lists partitions whose whole range is older
   than the retention window.
4. For each, `ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY` (which cannot run inside a
   function or transaction, so the Python command issues it) and `SET SCHEMA part_archive`.
5. `part.months_ready(parent, as_of)` must reach `--ahead`, or the command fails.

`tests/integration/test_partition_maintenance.py` cancels a concurrent detach half-way (a
statement timeout while another transaction still reads the table), leaves a detached table
behind, and checks that the next run recovers both and that a run after that changes nothing.

In production this would run daily from a scheduler (cron, a Kubernetes CronJob or pg_cron), and
an alert on `months_ready` below two would catch a job that stopped running.
