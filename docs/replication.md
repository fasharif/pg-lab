# Replication, the planned switchover and the unplanned failover

Files: `docker/postgres/lab-entrypoint.sh` (clone on first start), `scripts/drills.sh`
(`replica_up`, `switchover`, `failover_drill`), `src/pglab/heartbeat.py` (client loop),
`src/pglab/drills.py` (analysis). Reports: `reports/switchover-drill.md`,
`reports/failover-drill.md`.

## The standby

`./lab replica up` makes the second node a streaming standby of whichever node is the primary:

1. create a physical replication slot named after the standby on the primary, so the primary
   keeps the WAL the standby still needs;
2. start the standby's container with an empty volume: its entrypoint runs
   `pg_basebackup --wal-method=stream --slot=<node> --write-recovery-conf` as `replicator`,
   removes any `recovery_target*` setting the copy carried (see "A lesson from the PITR drill"
   in docs/pitr.md) and starts PostgreSQL as a hot standby;
3. wait until `pg_stat_replication` on the primary shows the standby `streaming`.

Replication is asynchronous. The standby also has pgBackRest's `restore_command`, so it can catch
up from the archive if it falls behind the slot. `hot_standby_feedback` is on, which avoids query
cancellations on the standby at the cost of some bloat on the primary.

The feedback also showed up while the lab was being built. In a run of `./lab partition` with a
standby attached, the partitions copied and vacuumed a moment earlier were not marked
all-visible: the index-only scans made heap fetches and read more buffers than in the same run
without a standby, which made none. The likely cause is the standby's reported `xmin`, held in
its replication slot, which keeps rows that recent from counting as visible to everyone until
the next feedback message. That run's output was not kept; to see the effect, run
`./lab replica up` and then `./lab partition`, and compare the `Heap Fetches` lines with
`reports/partitioning.md`. The lab's reports are therefore generated before a standby is
attached, as `./lab ci` orders them.

## The switchover drill

`./lab switchover` swaps the roles of the two nodes while a client keeps writing; running it
twice returns to the original layout. The client is `python -m pglab heartbeat`: it inserts a row
into `lab.heartbeat` every 0.1 s as `topflow_app` and logs every attempt with its outcome. It
connects with libpq's multi-host syntax,

```text
host=pg1,pg2 port=5432,5432 target_session_attrs=read-write
```

so after a failed write it reconnects to whichever node accepts writes, with no configuration
change. The steps:

| Step | What happens | Why |
| --- | --- | --- |
| 1 | `CHECKPOINT` on the old primary | the shutdown checkpoint has little left to write |
| 2 | Stop the old primary (fast shutdown) | a clean shutdown sends all WAL, including the shutdown checkpoint, to the standby |
| 3 | Read the old primary's last checkpoint (`pg_controldata`) and wait until the standby has replayed past it | proves no committed transaction is left behind |
| 4 | `pg_promote()` on the standby; create a slot for the old primary on it | the new primary starts a new timeline |
| 5 | `pg_rewind` the old primary against the new one, as the `rewind` role | makes the old data directory a valid ancestor of the new timeline |
| 6 | Add `standby.signal`, `primary_conninfo` and `primary_slot_name`, start it, drop its stale slot | it streams from the new primary |
| 7 | Stop the client and check | see below |

The checks in the report:

- the promoted node accepts writes;
- the client moved from the old primary to the new one on its own (the sequence of nodes that
  acknowledged writes, for example `pg1 -> pg2`);
- every write acknowledged to the client is on the new primary;
- no write reached the old primary after the promotion (no split brain);
- pg_rewind ran, and the old primary streams from the new one.

In a planned switchover like this, pg_rewind reports `no rewind required`: the old primary
stopped cleanly and the standby replayed everything, so the timelines diverge only after the old
primary's last record. The step is kept because the same runbook must also work after a failover,
where the old primary may have written WAL that the new timeline does not contain. The failover
drill below is that case.

## The unplanned failover drill

`./lab failover-drill` rehearses a failover without fencing: the standby is promoted while the
primary is still running and accepting writes, as happens when a failover is triggered by a
network partition or a monitoring mistake rather than a dead primary.

| Step | What happens |
| --- | --- |
| 1 | `pg_promote()` on the standby while the old primary keeps running: two primaries on diverging timelines |
| 2 | The old primary commits a transaction of 500 rows that the new primary never receives; the new primary takes one write of its own |
| 3 | Stop the old primary (the fencing that should have come before step 1) |
| 4 | `pg_rewind` the old primary against the new one, connected as `rewind` |
| 5 | Restart it as a standby of the new primary (the same steps as the switchover) |
| 6 | Check and write the report |

The checks:

- the promoted node accepts writes;
- none of the 500 rows is on the new primary;
- pg_rewind found the divergence (`servers diverged at WAL location ...`) and rewound the old
  primary, rather than reporting `no rewind required`;
- the role pg_rewind connected as is not a superuser: `rewind` has `EXECUTE` on
  `pg_ls_dir`, `pg_stat_file` and the two `pg_read_binary_file` functions, as the pg_rewind
  documentation lists, and nothing else. This drill is where those grants are exercised. The
  functions read any file of the data directory, so the drills let the role log in only while
  pg_rewind runs (`ALTER ROLE rewind LOGIN`, then `NOLOGIN`; docs/security.md);
- the old primary streams from the new one again, has the new primary's write and none of the
  500 rows.

The 500 rows are gone for good. That is the lesson of the drill: once a standby is promoted,
every write the old primary accepts is lost when it is rewound, so a failover must first make
sure the old primary cannot accept writes (stop it, or cut it off from clients). The planned
switchover stops it first and loses nothing. Automatic failover managers such as Patroni do the
fencing with a lock held in a consensus store; the lab has none (see the roadmap).

## Measured values

With `--measure`, the report shows the write downtime seen by the client (the longest gap between
two acknowledged writes) and the time from stopping the old primary to the promotion. Functional
runs leave them pending (docs/benchmarking.md).

## Clients that are not libpq

TopFlow's API connects through node-postgres (`@prisma/adapter-pg`), which implements the
PostgreSQL protocol itself instead of using libpq, so the multi-host behaviour above is not
something the lab has tested for it. The usual options are a TCP proxy with a health check
(HAProxy calling a small "am I the primary" endpoint, or PgBouncer pointed at the primary) or a
DNS name that the switchover updates. Either adds a step between 4 and 5: repoint the proxy or
the name, then wait for its time-to-live.
