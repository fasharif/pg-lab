# Benchmarking: what is measured, and what is pending

## Functional runs and measured runs

Every report in `reports/` comes from a script. Each one states the command, the data scale, the
server version and the environment at the top.

| Kind of run | What it records | How |
| --- | --- | --- |
| Functional (default) | Plans, actual row counts, shared buffers, logical checks, index sizes, WAL volumes, row counts and checksums | `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY OFF)`; the `I/O Timings` lines that `track_io_timing` adds are removed |
| Measured (`--measure`) | Everything above plus durations | Median of N runs (default 15) after one warm-up run of planning plus execution time, from `EXPLAIN (ANALYZE, SERIALIZE TEXT, TIMING OFF, SUMMARY ON)`; drill durations measured by the drill scripts |

What a measured time includes: planning (the partitioning report shows it separately, because
pruning and the number of partitions add planning work and a generic plan prunes when it starts
executing), execution, and, through `SERIALIZE TEXT`, converting the result rows to text as the
server would for a client. It does not include sending the rows over the network or the
client's own work, and `TIMING OFF` keeps per-node timing overhead out of the total.

The committed reports are functional runs made on a laptop that was building other projects at
the same time. Their timing columns say **pending a measured run**. Buffer counts, index sizes
and WAL volumes do not depend on how busy the machine is, so they are published.

## The reference measurement (to do)

The published timings will come from one run on a quiet machine at the documented target size.

1. A Linux host (bare metal or a dedicated VM) with at least 8 CPUs, 16 GB of memory and an SSD
   with 60 GB free. Nothing else running.
2. In `.env`: `LAB_SCALE=10000000`, `LAB_PG_MEM_LIMIT=8g`, `LAB_SHARED_BUFFERS=2GB`,
   `LAB_EFFECTIVE_CACHE_SIZE=6GB`, `LAB_MAINTENANCE_WORK_MEM=1GB`, `LAB_WORK_MEM=32MB`.
3. Commands:

   ```bash
   ./lab up && ./lab seed --scale 10000000
   ./lab workload --measure
   ./lab casebook --measure
   ./lab indexing
   ./lab partition --measure
   ./lab pitr-drill --measure
   ./lab replica up && ./lab switchover --measure && ./lab switchover --measure
   ```

4. Set `LAB_ENVIRONMENT_NOTE` to a short description of the host (CPU model, disk) before step 3
   so that it appears in every report header.

Every table except the catalogue grows linearly with SCALE (sizes in `lab.dataset_size`). The
row count of the committed data set is in `reports/dataset.md` (written by `./lab seed`); expect
about ten times as many rows at the target. The generator accepts SCALE up to 100000000;
SCALE=50000000 has not been run, and would need five times the disk space and time of the
target again.

## Why buffers rank the workload

Shared buffers touched (pages found in or read into PostgreSQL's cache) measure the work a plan
does. They stay the same when the machine is busy, so the ranking in `reports/workload.md` can be
reproduced anywhere with the same data. Two queries with the same buffer count can still differ
in time (CPU-heavy filters, sorts in memory), which is one reason the measured run matters.

## Durations in drills

The PITR drill measures recovery time (stop the damaged primary until the restored one accepts
writes) and the data-loss window before the recovery target; the switchover drill measures the
longest gap between two writes acknowledged to the client. Functional runs record these values
in `out/drills/<run>/facts.env` for debugging, and the reports show them only with `--measure`.
