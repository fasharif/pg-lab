#!/usr/bin/env bash
# Entry point of a lab node.
#
# The node's data directory decides what happens:
#   - not empty: start PostgreSQL as it is (primary or standby, whatever the cluster says);
#   - empty and LAB_BOOTSTRAP=primary: initialise a new cluster (official entrypoint, initdb);
#   - empty and LAB_BOOTSTRAP=replica: clone the peer with pg_basebackup and start as a standby.
# Replication and pg_rewind credentials go to ~postgres/.pgpass, never to the command line.
set -Eeuo pipefail

: "${PGDATA:?PGDATA must be set}"
: "${LAB_NODE:?LAB_NODE must be set (pg1 or pg2)}"
: "${LAB_BOOTSTRAP:?LAB_BOOTSTRAP must be primary or replica}"
: "${LAB_REPLICATOR_PASSWORD:?LAB_REPLICATOR_PASSWORD must be set}"
: "${LAB_REWIND_PASSWORD:?LAB_REWIND_PASSWORD must be set}"

log() { printf '%s lab-entrypoint[%s]: %s\n' "$(date -u +%FT%TZ)" "$LAB_NODE" "$*" >&2; }

write_pgpass() {
  local pgpass=/var/lib/postgresql/.pgpass
  install -d -o postgres -g postgres -m 0755 /var/lib/postgresql
  (
    umask 077
    printf '*:5432:replication:replicator:%s\n*:5432:*:rewind:%s\n' \
      "$LAB_REPLICATOR_PASSWORD" "$LAB_REWIND_PASSWORD" >"$pgpass"
  )
  chown postgres:postgres "$pgpass"
}

clone_from_peer() {
  : "${LAB_PEER:?LAB_PEER must name the node to clone from}"
  log "empty data directory: cloning $LAB_PEER with pg_basebackup (slot $LAB_NODE)"
  gosu postgres pg_basebackup \
    --dbname="host=$LAB_PEER port=5432 user=replicator application_name=$LAB_NODE" \
    --pgdata="$PGDATA" --wal-method=stream --slot="$LAB_NODE" \
    --write-recovery-conf --checkpoint=fast --progress --no-password
  # A recovery target copied from the source (left by a point-in-time restore) would make
  # this standby stop at that point and promote itself.
  sed -i '/^recovery_target/d' "$PGDATA/postgresql.auto.conf"
  log "clone complete; starting as a standby of $LAB_PEER"
}

if [ "$(id -u)" = '0' ]; then
  write_pgpass
  # Created here rather than by the official entrypoint, which leaves the group as root;
  # pgBackRest then warns about an unknown group when it restores the directory.
  install -d -o postgres -g postgres -m 0700 "$PGDATA"
  if [ ! -s "$PGDATA/PG_VERSION" ] && [ "$LAB_BOOTSTRAP" = 'replica' ]; then
    clone_from_peer
  fi
fi

# cluster_name identifies the node in pg_stat_activity, logs and the drill heartbeat rows.
if [ "${1:-}" = 'postgres' ]; then
  set -- "$@" -c "cluster_name=$LAB_NODE"
fi
exec docker-entrypoint.sh "$@"
