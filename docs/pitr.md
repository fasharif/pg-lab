# Backup and point-in-time recovery

Files: `docker/postgres/pgbackrest.conf`, `docker/postgres/postgresql.conf` (archiving),
`docker/postgres/initdb/20-pgbackrest-stanza.sh`, `scripts/drills.sh` (`pitr_drill`),
`src/pglab/drills.py`. Report: `reports/pitr-drill.md`.

## Set-up

- pgBackRest 2.59 (PGDG package) with one repository, a Docker volume mounted on both nodes at
  `/var/lib/pgbackrest`. Stanza `topflow`, created when the cluster is initialised.
- `archive_mode = on`, `archive_command = 'pgbackrest --stanza=topflow archive-push %p'`,
  `archive_timeout = 60s`: a busy primary archives at least once a minute.
- zstd compression, two processes, two full backups retained. Data checksums are on, and
  pgBackRest verifies page checksums during backups.
- Why pgBackRest rather than WAL-G: ADR 8 in docs/decisions.md.

## The drill

`./lab pitr-drill` rehearses the classic accident: someone runs a `DELETE` without a `WHERE`
clause in production, and the database has to go back to the moment just before it.

| Step | What happens |
| --- | --- |
| 1 | Full backup (`pgbackrest --type=full backup`). |
| 2 | A client starts writing a heartbeat row every 0.1 s (it keeps going until step 5). |
| 3 | The drill fingerprints `order_items` (row count and the sum of 64-bit hashes of every row) and creates the recovery target: a named restore point (`pg_create_restore_point`). The same statement reads the newest heartbeat it can see. |
| 4 | The accident: `DELETE FROM order_items`, every line of every order. |
| 5 | `pg_switch_wal()`, then wait until `pg_stat_archiver` shows that segment archived; stop the client. |
| 6 | Stop the primary, `pgbackrest restore --delta --type=name --target=<restore point> --target-action=promote`, start it, wait until it has replayed to the target and promoted itself. |
| 7 | Verify and write the report. |

The checks:

- the accident did remove every order line;
- after recovery `order_items` has the same row count **and** the same content checksum as
  before the accident;
- every heartbeat committed before the restore point is present, and no heartbeat that started
  after it was replayed;
- the server finished recovery on a new timeline and accepts writes.

How the heartbeat checks avoid clocks. A write is *committed before* the restore point when the
statement that created the point could see it: whatever a snapshot sees has its commit record
in the WAL already, ahead of the restore point's record. A write *started after* the restore
point when the WAL position the client read inside its own transaction
(`pg_current_wal_insert_lsn()`) is already past the point: its commit record can only come later.
At most one write can be in neither group, the one running while the point was created; the
report counts it and either outcome is correct. An earlier version compared timestamps instead:
the heartbeat's `committed_at` is taken when the row is inserted, not when it commits, while
`recovery_target_time` compares commit times, so a write inserted just before the target and
committed just after it could fail the check for no fault of the recovery.

A restore point is a luxury of a drill. In a real incident the target comes from what is known:
a time from the application's logs, or the accident's own transaction found with `pg_waldump`,
followed by `--type=xid` (or `--type=lsn`) with `--target-exclusive` to stop just before it.

## RTO and data loss

- **RTO** (recovery time objective): from stopping the damaged primary to the restored primary
  accepting writes. It is dominated by the delta restore and the WAL replay since the last
  backup, so it grows with the time since the last full or differential backup.
- **Data lost** (the RPO of this kind of recovery): a point-in-time restore *in place* takes the
  whole database back to the target, so every write the application made after the accident
  is lost with it. The report counts those acknowledged writes ("Data lost by restoring in
  place" in `reports/pitr-drill.md`) and, in measured runs, the window from the target to the
  last write lost. This is the number to compare with a recovery point objective, not the
  precision of the restore.
- **Precision**: how close recovery stopped to the target (the target minus the last write it
  kept). With a restore point it is exact by construction; the report shows it in measured runs.

To avoid losing the later writes, restore a copy to a side instance instead (`pgbackrest restore`
into another data directory with the same target), then copy the deleted rows back into the live
database with `INSERT ... SELECT` over `postgres_fdw` or a `COPY` export. The service keeps
running and nothing after the accident is lost; the price is a longer and manual repair, and
care with rows that the application changed again in the meantime.

In a real failure the archive lag matters too: WAL not yet archived when the server is lost is
gone, which is what `archive_timeout` and a streaming standby limit.

Durations are shown only in measured runs (docs/benchmarking.md).

## A lesson from the drill

pgBackRest writes the recovery target into `postgresql.auto.conf`:

```text
restore_command = 'pgbackrest --stanza=topflow archive-get %f "%p"'
recovery_target_name = '<restore point>'
recovery_target_action = 'promote'
```

The settings are inert once the server has left recovery, but `pg_basebackup` copies the file. A
standby cloned later from the restored primary started, replayed to the old target, promoted
itself and pushed a new timeline into the shared archive: two primaries, one of them silent. The
drill now removes the settings with `ALTER SYSTEM RESET` as soon as recovery is over, and the
clone step strips any `recovery_target*` line it copies. The runbook item: **after a
point-in-time recovery, clear the recovery target before anything clones the server.**

## Running it on real data

```bash
./lab seed --scale 10000000
./lab pitr-drill --measure
```

A standby, if running, is removed first (a recovery starts a new timeline it cannot follow);
`./lab replica up` clones it again afterwards.
