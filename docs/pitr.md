# Backup and point-in-time recovery

Files: `docker/postgres/pgbackrest.conf`, `docker/postgres/postgresql.conf` (archiving),
`docker/postgres/initdb/20-pgbackrest-stanza.sh`, `scripts/drills.sh` (`pitr_drill`),
`src/pglab/drills.py`. Reports: `reports/pitr-drill.md` (restore to a recorded time) and
`reports/pitr-drill-name.md` (restore to a named restore point).

## Set-up

- pgBackRest 2.59 (PGDG package, not pinned to a build: each drill report records the version
  that made the backup) with one repository, a Docker volume mounted on both nodes at
  `/var/lib/pgbackrest`. Stanza `topflow`, created when the cluster is initialised.
- `archive_mode = on`, `archive_command = 'pgbackrest --stanza=topflow archive-push %p'`,
  `archive_timeout = 60s`: a busy primary archives at least once a minute.
- zstd compression, two processes, two full backups retained. Data checksums are on, and
  pgBackRest verifies page checksums during backups.
- Why pgBackRest rather than WAL-G: ADR 8 in docs/decisions.md.

## The drill

`./lab pitr-drill` rehearses the classic accident: someone runs a `DELETE` without a `WHERE`
clause in production, and the database has to go back to the moment just before it. By default
the drill records the time just before the accident and restores to that time, which is what an
operator has in a real incident (a time from the application's logs or from the person who ran
the statement). `--target name` restores to a named restore point instead, created just before
the accident: exact, but a luxury that only a drill has. `./lab ci` runs both.

| Step | What happens |
| --- | --- |
| 1 | Full backup (`pgbackrest --type=full backup`). |
| 2 | A client starts writing a heartbeat row every 0.1 s (it keeps going until step 5). |
| 3 | The drill fingerprints `order_items` (row count and the sum of 64-bit hashes of every row) and records the recovery target: the server's `clock_timestamp()` (default), or a named restore point (`pg_create_restore_point`). The same statement reads the newest heartbeat it can see and, for a time target, the WAL insert position once the time is taken. |
| 4 | The accident: `DELETE FROM order_items`, every line of every order. |
| 5 | `pg_switch_wal()`, then wait until `pg_stat_archiver` shows that segment archived; stop the client. |
| 6 | Stop the primary, `pgbackrest restore --delta --type=time --target=<recorded time> --target-action=promote` (or `--type=name --target=<restore point>`), start it, wait until it has replayed to the target and promoted itself. |
| 7 | Verify and write the report. |

The checks:

- the accident did remove every order line;
- after recovery `order_items` has the same row count **and** the same content checksum as
  before the accident;
- every heartbeat committed before the target is present, and no heartbeat that started after
  it was replayed;
- the server finished recovery on a new timeline and accepts writes.

Recovery to a time replays every transaction whose commit record carries a time at or before the
target and stops at the first commit after it (`recovery_target_inclusive` is on by default).
The `DELETE` commits after the recorded time, so a correct recovery stops before it.

How the heartbeat checks avoid comparing clocks. A write is *committed before* the target when
the statement that recorded the target could see it: whatever a snapshot sees has already
written its commit record and taken its commit time, both ahead of the restore point's record
or of the `clock_timestamp()` that the same statement reads. A write *started after* the target
when the WAL position the client read inside its own transaction
(`pg_current_wal_insert_lsn()`) is already past the position recorded at the target: its commit
record can only come later in the WAL and, for a time target, its commit time can only be later
than the recorded time, because that position was read after the time. At most one or two
writes fall in neither group, those running while the target was recorded; the report counts
them and either outcome is correct. An earlier version compared the heartbeat's `committed_at`
with the target instead, but that column is set when the row is inserted, not when it commits,
so a write inserted just before the target and committed just after it could fail the check for
no fault of the recovery.

The third way to name the target is the accident's own transaction: find its transaction id in
the archived WAL with `pg_waldump`, then restore with `--type=xid --target-exclusive`, which
stops just before its commit and keeps the writes that committed while the `DELETE` ran. The
drill does not script that yet (README, roadmap).

The committed `reports/pitr-drill-name.md` comes from the regeneration run at SCALE=1000000
(2026-09-26 03:37 UTC), made before the drill gained `--target`, when `./lab pitr-drill` always
restored to a restore point. The time-target report, `reports/pitr-drill.md`, is written by the
next run; `./lab ci` runs both targets.

## RTO and data loss

- **RTO** (recovery time objective): from stopping the damaged primary to the restored primary
  accepting writes. It is dominated by the delta restore and the WAL replay since the last
  backup, so it grows with the time since the last full or differential backup.
- **Data lost** (the RPO of this kind of recovery): a point-in-time restore *in place* takes the
  whole database back to the target, so every write the application made after the accident
  is lost with it. The report counts those acknowledged writes ("Data lost by restoring in
  place" in the drill reports) and, in measured runs, the window from the target to the last
  write lost. This is the number to compare with a recovery point objective, not the precision
  of the restore.
- **Precision**: how close recovery stopped to the target (the target minus the last write it
  kept). With a restore point it is exact by construction; with a time it is the gap to the last
  commit before that time. The report shows it in measured runs.

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
recovery_target_name = '<restore point>'   (or recovery_target_time for a time target)
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
./lab pitr-drill --measure                  # restore to the recorded time
./lab pitr-drill --target name --measure    # restore to a restore point
```

A standby, if running, is removed first (a recovery starts a new timeline it cannot follow);
`./lab replica up` clones it again afterwards.
