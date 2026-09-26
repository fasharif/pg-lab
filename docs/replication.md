# Replication and the planned switchover

Files: `docker/postgres/lab-entrypoint.sh` (clone on first start), `scripts/drills.sh`
(`replica_up`, `switchover`), `src/pglab/heartbeat.py` (client loop), `src/pglab/drills.py`
(analysis). Report: `reports/switchover-drill.md`.

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
where the old primary may have written WAL that the new timeline does not contain; that case is
not exercised by the lab (see the roadmap in the README).

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
