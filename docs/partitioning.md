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

1. `part.create_monthly_partitions(parent, from, to)` creates the missing months (idempotent).
2. `part.partitions_to_detach(parent, retain, as_of)` lists partitions whose whole range is older
   than the retention window.
3. For each, `ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY` (which cannot run inside a
   function or transaction, so the Python command issues it) and `SET SCHEMA part_archive`.
4. `part.months_ready(parent, as_of)` must reach `--ahead`, or the command fails.

In production this would run daily from a scheduler (cron, a Kubernetes CronJob or pg_cron), and
an alert on `months_ready` below two would catch a job that stopped running.
