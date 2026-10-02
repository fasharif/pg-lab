# Benchmarking: what is measured, and how

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

The committed reports come from the measured run below. Functional runs, including CI's, record
everything except durations, and their timing columns say **pending a measured run**. Buffer
counts, index sizes and WAL volumes do not depend on how busy the machine is.

## The measured run (2026-10-02)

One run of the whole lab at SCALE=10000000 (10,000,837 order lines, 40,592,314 rows in the 18
TopFlow tables), on 2 October 2026 between 16:57 and 18:43 UTC.

**Machine.** An ASUS TUF Gaming A15 FA507RC laptop: AMD Ryzen 7 6800H (8 cores, 16 threads),
16 GB of RAM, an Intel SSDPEKNU512GZ 512 GB NVMe SSD, Windows 11 Home build 26200, on mains power
with the Performance power plan. Docker Desktop 29.8.1 runs the containers in its WSL 2 virtual
machine, which had 16 CPUs and 7.4 GiB of memory.

**Settings** in `.env`:

```text
LAB_SCALE=10000000
LAB_PG_MEM_LIMIT=3g        LAB_PG2_MEM_LIMIT=3g        LAB_RUNNER_MEM_LIMIT=512m
LAB_SHARED_BUFFERS=1GB     LAB_EFFECTIVE_CACHE_SIZE=2GB
LAB_MAINTENANCE_WORK_MEM=512MB                         LAB_WORK_MEM=16MB
```

Both nodes run during the drills, and the virtual machine's 7.4 GiB must hold them, the tools
container and Docker itself, so each node gets 3 GB with 1 GB of shared buffers. That is less
memory than the data: `audit_logs` alone is 2.6 GB and its indexes 1.8 GB
(`reports/indexing.md`), so the large scans read from the operating system's cache or the SSD.
A server with more memory would give different times.

**Commands**, in this order. `LAB_ENVIRONMENT_NOTE` adds the machine to every report's header.

```bash
export LAB_ENVIRONMENT_NOTE="ASUS TUF Gaming A15 FA507RC laptop (AMD Ryzen 7 6800H, 8 cores and 16 threads; 16 GB of RAM; Intel SSDPEKNU512GZ 512 GB NVMe SSD) on mains power with the Performance power plan, through Docker Desktop's WSL 2 virtual machine; what else ran on the machine during the measured run is recorded in docs/benchmarking.md"
./lab down && ./lab up && ./lab seed --scale 10000000
./lab workload --measure
./lab casebook --measure
./lab indexing
./lab partition --measure
./lab rls-plans --measure
./lab pitr-drill --measure && ./lab pitr-drill --target name --measure
./lab replica up
./lab switchover --measure && ./lab switchover --measure
./lab failover-drill --measure
./lab test                       # 186 pgTAP and 22 integration tests at this scale: all passed
./lab replica down && ./lab rls-plans --measure
./lab readme
```

`./lab rls-plans --measure` ran twice. The first run's report said `./lab rls-plans` in its
header, without `--measure`, which a later commit fixed; the committed report is the second run,
made after the drills with the standby removed again, as before the first.

**Time taken**, by the host's clock: the load 38 minutes, the workload ranking 3, the casebook 6,
the index report 7, the partitioning report 12, the row-level security report 1, each PITR drill
5 to 6, cloning the standby 5, each switchover and the failover under half a minute, the tests 3.5.
The data directory ended at 22.8 GB with the casebook's indexes and the partitioned copies, and
the pgBackRest repository at 18.6 GB.

**What else ran.** Two containers of another project (a PostgreSQL 17 server and a Node.js tools
container) were running when the run started, were gone from about 17:01 to 17:14 UTC and were
removed for good at 17:25, all during the load; they were busy for parts of it, at up to about
seven CPUs. Three short unit-test containers of this session also ran during the load, between
17:00 and 17:03. The load's 38 minutes are therefore not a clean measurement. No container
outside the lab ran during any timed step, from the workload ranking at 17:36 onwards: a sampler
recorded every container's CPU every 3 to 5 seconds throughout, and before each timed step the
run waited until no other container had used more than 5% CPU for a minute. That gate held the
second PITR drill back for three and a half minutes while two short-lived containers that were
not part of this run used up to five and a half CPUs (18:14 to 18:17 UTC). Desktop applications
(an editor, browsers and the Claude Code session that drove the run) stayed open.

**How far to trust it.** Statement times are medians of 15 runs after a warm-up run; the drills
ran once each, the switchover once in each direction. Nothing was repeated to measure the spread
between runs, so small differences between statements should not be read as findings.

## Why SCALE=10000000 and not more

The goal was the largest scale up to 50 million order lines that completes in about two hours
within Docker Desktop's memory. At 10 million the load alone took 38 minutes and the run about
an hour and three quarters. The generator's work grows with SCALE, so 20 million would, by
that measure, have needed well over two hours (an estimate; it was not tried), and both nodes
already share 7.4 GiB. SCALE=50000000 has not been run; the generator accepts it.

## Why buffers ranked the workload first

The task is to fix the slowest statements, and slowness can only be measured on a quiet machine,
which this laptop was not while the lab was being built. Until the measured run, shared buffers
touched (pages found in or read into PostgreSQL's cache) stood in for time: they measure the
pages a plan reads and do not depend on how busy the machine is, so the ranking can be
reproduced anywhere with the same data. Serial plans give the same count on every run. A
parallel plan's count varies a little with how the work is split between its workers, so the
same statement can show slightly different counts in two reports of one run (`audit-by-user`,
a parallel index scan, is the example in the committed reports).

Buffers are a proxy, not a measure of time. Two statements with the same buffer count can differ
in time, and a cheap-looking statement can be slow: a sequential scan that tests several
`ILIKE '%term%'` patterns on every row spends its time on CPU, not on pages.

## What the time ranking changed

`./lab workload --measure` ranks the workload by median time (planning plus execution). The rule
set before the measured run:

1. Every statement in the top ten by time that has no case gets one (or joins its page's case,
   if it is a pagination total), with its plan checks.
2. A case that falls out of the top ten by time stays in the casebook, and its section says that
   it was chosen by buffers.
3. The README and the casebook's introduction say how the cases were chosen.

What happened at SCALE=10000000 (`reports/workload.md`):

- The RFQ search and its pagination count, which test six `ILIKE` patterns on every quote
  request, ranked 7th and 8th by time (561 and 545 ms), although by buffers they rank only 11th
  and 12th at this scale and were 13th and 14th in the ranking at SCALE=1000000 that chose the
  first ten cases (`reports/workload.md` as committed before this run). They became case 11.
- Cases 1 to 7 stayed in the top ten.
- Cases 8, 9 and 10 fell to 15th, 19th and 16th (64, 37 and 60 ms). They stay, marked as chosen
  by buffers.
- `audit-count`, the exact count of the whole audit trail for the pager, ranked 11th (275 ms),
  just outside the top ten; it has no case.

## Durations in drills

The PITR drill measures recovery time (stop the damaged primary until the restored one accepts
writes), the data-loss window after the recovery target and how close recovery came to it. The
switchover and failover drills measure the write downtime the client sees (from one acknowledged
write to the next), the database side (stop or kill to promotion) and how long the client's first
write on the new primary took. Docker, the servers and the client share the clock of Docker
Desktop's virtual machine. Functional runs record these values in `out/drills/<run>/facts.env`
and the heartbeat log for debugging, and the reports show them only with `--measure`.
docs/pitr.md and docs/replication.md discuss the results.
