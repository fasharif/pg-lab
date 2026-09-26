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
| 3 | The drill fingerprints `order_items` (row count and the sum of 64-bit hashes of every row) and records `clock_timestamp()` as the recovery target. |
| 4 | The accident: `DELETE FROM order_items`, every line of every order. |
| 5 | `pg_switch_wal()`, then wait until `pg_stat_archiver` shows that segment archived; stop the client. |
| 6 | Stop the primary, `pgbackrest restore --delta --type=time --target=<recorded time> --target-action=promote`, start it, wait until it has replayed to the target and promoted itself. |
| 7 | Verify and write the report. |

The checks:

- the accident did remove every order line;
- after recovery `order_items` has the same row count **and** the same content checksum as
  before the accident;
- every heartbeat the client saw acknowledged before the target is present, and nothing
  committed after the target was replayed;
- the server finished recovery on a new timeline and accepts writes.

Heartbeats acknowledged after the target are discarded by design: the report counts them, and
in a real incident they would have to be re-entered from another source (application logs, the
audit trail of the other system).

## RTO and RPO

- **RTO** (recovery time objective): from stopping the damaged primary to the restored primary
  accepting writes. It is dominated by the delta restore and the WAL replay since the last
  backup, so it grows with the time since the last full or differential backup.
- **RPO** (recovery point objective): in this drill the loss before the target is bounded by the
  heartbeat interval, because the target is chosen just before the accident and all WAL is
  archived. The measured value is the target minus the last recovered commit. In a real failure
  the archive lag matters more: WAL not yet archived when the server is lost is gone, which is
  what `archive_timeout` and a streaming standby limit.

Both durations are shown only in measured runs (docs/benchmarking.md).

## A lesson from the drill

pgBackRest writes the recovery target into `postgresql.auto.conf`:

```text
restore_command = 'pgbackrest --stanza=topflow archive-get %f "%p"'
recovery_target_time = '<target>'
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
