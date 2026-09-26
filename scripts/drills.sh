#!/usr/bin/env bash
# Reliability drills: streaming replica, point-in-time recovery, planned switchover and
# unplanned failover.
# Sourced by ./lab (needs scripts/lib.sh); every step runs through docker compose.
# shellcheck disable=SC2034  # facts are read by the Python analysis

HEARTBEAT_INTERVAL=0.1

# ─── Drill bookkeeping ─────────────────────────────────────────────────────
drill_start() {
  DRILL_ID="$1-$(date -u +%Y%m%dT%H%M%SZ)"
  DRILL_DIR="out/drills/$DRILL_ID"
  mkdir -p "$LAB_ROOT/$DRILL_DIR"
  DRILL_FACTS="$LAB_ROOT/$DRILL_DIR/facts.env"
  : >"$DRILL_FACTS"
  record RUN_ID "$DRILL_ID"
  record HEARTBEAT_INTERVAL "$HEARTBEAT_INTERVAL"
  info "drill files: $DRILL_DIR"
}

record() { printf '%s=%s\n' "$1" "$2" >>"$DRILL_FACTS"; }

# Starts the client loop in the runner, detached. $1: comma-separated hosts.
heartbeat_start() {
  compose exec -d -T runner python -m pglab heartbeat --run-id "$DRILL_ID" --hosts "$1" \
    --out "/work/$DRILL_DIR/heartbeat.jsonl" --interval "$HEARTBEAT_INTERVAL" --duration 1800
  local waited=0
  until [ -s "$LAB_ROOT/$DRILL_DIR/heartbeat.jsonl" ]; do
    [ "$waited" -ge 30 ] && die "the heartbeat client did not start (see $DRILL_DIR)"
    sleep 1
    waited=$((waited + 1))
  done
}

heartbeat_stop() {
  touch "$LAB_ROOT/$DRILL_DIR/heartbeat.stop"
  local waited=0
  until [ -f "$LAB_ROOT/$DRILL_DIR/heartbeat.done" ]; do
    [ "$waited" -ge 60 ] && die "the heartbeat client did not stop"
    sleep 1
    waited=$((waited + 1))
  done
}

# Runs a program from the node image against a node's volumes while the node is stopped.
offline() {
  local node=$1
  shift
  compose run --rm --no-deps -T --user postgres --entrypoint "$1" "$node" "${@:2}"
}

wait_until() {
  local description=$1 timeout=$2 node=$3 sql=$4 waited=0
  until [ "$(node_query "$node" "$sql" 2>/dev/null || true)" = t ]; do
    [ "$waited" -ge "$timeout" ] && die "timed out after ${timeout}s waiting until $description"
    sleep 1
    waited=$((waited + 1))
  done
}

clear_recovery_target() {
  local node=$1 setting
  for setting in recovery_target recovery_target_time recovery_target_xid recovery_target_name \
    recovery_target_lsn recovery_target_action recovery_target_inclusive; do
    node_psql "$node" -c "ALTER SYSTEM RESET $setting" >/dev/null
  done
  node_psql "$node" -c 'SELECT pg_reload_conf()' >/dev/null
}

ensure_slot() {
  local node=$1 slot=$2
  node_psql "$node" -c "SELECT pg_create_physical_replication_slot('$slot')
                        WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '$slot')" >/dev/null
}

bootstrap_var() { printf 'LAB_%s_BOOTSTRAP' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# ─── Replica ───────────────────────────────────────────────────────────────
replica_up() {
  require_env
  local primary standby
  primary=$(current_primary) || die "no primary is running (./lab up)"
  standby=$(other_node "$primary")
  if is_running "$standby"; then
    info "$standby is already running"
    replica_status
    return 0
  fi
  log "cloning $primary into a new standby $standby (pg_basebackup through slot $standby)"
  ensure_slot "$primary" "$standby"
  compose rm -sf "$standby" >/dev/null 2>&1 || true
  remove_volume "${standby}-data"
  env "$(bootstrap_var "$standby")=replica" docker compose --project-directory "$LAB_ROOT_HOST" \
    --profile replica up -d --wait "$standby"
  wait_until "$standby streams from $primary" 120 "$primary" \
    "SELECT EXISTS (SELECT 1 FROM pg_stat_replication WHERE application_name = '$standby' AND state = 'streaming')"
  replica_status
}

replica_status() {
  local primary
  primary=$(current_primary) || die "no primary is running"
  info "primary: $primary"
  node_psql "$primary" -c "SELECT application_name AS standby, state, sync_state,
                                  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag
                           FROM pg_stat_replication"
}

replica_down() {
  local primary standby
  primary=$(current_primary) || die "no primary is running"
  standby=$(other_node "$primary")
  log "removing standby $standby and its slot"
  compose rm -sf "$standby" >/dev/null 2>&1 || true
  remove_volume "${standby}-data"
  node_psql "$primary" -c "SELECT pg_drop_replication_slot('$standby')
                           WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '$standby')" >/dev/null
}

# ─── Point-in-time recovery drill ──────────────────────────────────────────
pitr_drill() {
  require_env
  ensure_runner
  local measure=() target_type=time target_args=() primary standby label target deleted seg t0 t1
  local count checksum last_seq target_lsn target_time target_epoch
  while [ $# -gt 0 ]; do
    case $1 in
      --measure) measure=(--measure); shift ;;
      --target) target_type=${2:?--target needs time or name}; shift 2 ;;
      *) die "pitr-drill: unknown option $1" ;;
    esac
  done
  case $target_type in
    time | name) ;;
    *) die "pitr-drill: --target must be time or name (got '$target_type')" ;;
  esac
  primary=$(current_primary) || die "no primary is running (./lab up)"
  standby=$(other_node "$primary")
  if is_running "$standby"; then
    warn "$standby is a standby of $primary; recovery starts a new timeline, so it is removed" \
      "(./lab replica up clones it again afterwards)"
    replica_down
  fi
  drill_start pitr
  record NODE "$primary"
  record TARGET_TYPE "$target_type"

  log "1/7 full backup with pgBackRest"
  compose exec -T -u postgres "$primary" pgbackrest --stanza=topflow --type=full \
    --log-level-console=warn backup
  label=$(compose exec -T -u postgres "$primary" pgbackrest --stanza=topflow info |
    grep -oE '[0-9]{8}-[0-9]{6}F' | tail -n 1)
  record BACKUP_LABEL "$label"
  record TIMELINE_BEFORE "$(node_query "$primary" 'SELECT timeline_id FROM pg_control_checkpoint()')"

  log "2/7 the application keeps writing (a heartbeat row every ${HEARTBEAT_INTERVAL}s)"
  heartbeat_start "$primary"
  sleep 3

  log "3/7 recording the state of order_items and the recovery target ($target_type)"
  read -r count checksum < <(runner python -m pglab fingerprint)
  record COUNT_BEFORE "$count"
  record CHECKSUM_BEFORE "$checksum"
  sleep 1
  case $target_type in
    time)
      # What an operator has after an accident: the time just before it. The same statement
      # reads the newest heartbeat it can see, so every write up to that one committed before
      # the recorded time. The WAL position read afterwards marks the writes that started
      # later: their commit time can only be later still (src/pglab/drills.py).
      target=$(node_psql "$primary" -At -F '|' -c \
        "WITH t AS MATERIALIZED (
           SELECT (SELECT coalesce(max(seq), 0) FROM lab.heartbeat WHERE run_id = '$DRILL_ID')
                    AS last_seq,
                  clock_timestamp() AS at)
         SELECT last_seq, at, extract(epoch FROM at) FROM t")
      IFS='|' read -r last_seq target_time target_epoch <<<"$target"
      target_lsn=$(node_query "$primary" 'SELECT pg_current_wal_insert_lsn()')
      target_args=(--type=time "--target=$target_time")
      info "recovery target: time $target_time (WAL insert position $target_lsn right after it)"
      ;;
    name)
      # A named restore point is an exact position in the WAL, created just before the
      # accident: a luxury only a drill has. The same statement reads the newest heartbeat it
      # can see: every write up to that one committed before the restore point.
      target=$(node_psql "$primary" -At -F '|' -c \
        "SELECT (SELECT coalesce(max(seq), 0) FROM lab.heartbeat WHERE run_id = '$DRILL_ID'),
                lsn, clock_timestamp(), extract(epoch FROM clock_timestamp())
         FROM pg_create_restore_point('$DRILL_ID') AS lsn")
      IFS='|' read -r last_seq target_lsn target_time target_epoch <<<"$target"
      target_args=(--type=name "--target=$DRILL_ID")
      record TARGET_NAME "$DRILL_ID"
      info "recovery target: restore point $DRILL_ID at $target_lsn ($target_time)"
      ;;
  esac
  if [ -z "$target_lsn" ] || [ -z "$target_time" ]; then
    die "could not record the recovery target"
  fi
  record TARGET_LSN "$target_lsn"
  record LAST_SEQ_BEFORE_TARGET "$last_seq"
  record TARGET_TIME "$target_time"
  record TARGET_EPOCH "$target_epoch"

  log "4/7 the accident: DELETE FROM order_items (no WHERE clause)"
  deleted=$(node_psql "$primary" -At -c 'WITH d AS (DELETE FROM order_items RETURNING 1) SELECT count(*) FROM d')
  record ROWS_DELETED "$deleted"
  info "deleted $deleted order lines; the application goes on writing"
  sleep 3

  log "5/7 archiving the WAL segment that holds the accident"
  seg=$(node_query "$primary" 'SELECT pg_walfile_name(pg_switch_wal())')
  wait_until "segment $seg is archived" 120 "$primary" \
    "SELECT coalesce(last_archived_wal >= '$seg', false) FROM pg_stat_archiver"
  heartbeat_stop

  log "6/7 restoring $primary to the recovery target (stop, pgbackrest restore --delta, start)"
  t0=$(now_s)
  compose stop -t 60 "$primary" >/dev/null
  offline "$primary" pgbackrest --stanza=topflow --delta "${target_args[@]}" \
    --target-action=promote --log-level-console=warn restore
  compose start "$primary" >/dev/null
  wait_ready "$primary" 600
  wait_until "$primary finishes recovery and is promoted" 600 "$primary" 'SELECT NOT pg_is_in_recovery()'
  t1=$(now_s)
  record RTO_SECONDS "$(elapsed "$t0" "$t1")"
  record RECOVERY_DONE 1
  # pgBackRest wrote the recovery target into postgresql.auto.conf. It is inert on a primary,
  # but any clone of this node (pg_basebackup copies the file) would stop at the old target
  # and promote itself. Remove it now that recovery is over.
  clear_recovery_target "$primary"
  node_psql "$primary" -c 'CHECKPOINT' >/dev/null
  record TIMELINE_AFTER "$(node_query "$primary" 'SELECT timeline_id FROM pg_control_checkpoint()')"

  log "7/7 verifying the recovered database"
  LAB_PRIMARY_HOST=$primary
  pglab "./lab pitr-drill --target $target_type ${measure[*]}" drill-report pitr \
    --dir "/work/$DRILL_DIR" "${measure[@]}"
}

# Runs pg_rewind on the stopped node $1 against the running primary $2 and prints its output.
# pg_rewind connects as the role rewind, whose file functions can read every file of the data
# directory, so the role may log in only for the length of this call (docs/security.md).
rewind_against() {
  local target=$1 source=$2 output status=0
  node_psql "$source" -c 'ALTER ROLE rewind LOGIN' >/dev/null
  output=$(offline "$target" pg_rewind --target-pgdata="$PGDATA_PATH" \
    --source-server="host=$source port=5432 user=rewind dbname=postgres" 2>&1) || status=$?
  node_psql "$source" -c 'ALTER ROLE rewind NOLOGIN' >/dev/null
  [ "$status" -eq 0 ] || die "pg_rewind failed: $output"
  printf '%s\n' "$output"
}

# Restarts a stopped former primary (already rewound) as a streaming standby of $2.
rejoin_as_standby() {
  local node=$1 primary=$2
  offline "$node" bash -c "
    set -e
    touch '$PGDATA_PATH/standby.signal'
    sed -i -e '/^primary_conninfo/d' -e '/^primary_slot_name/d' '$PGDATA_PATH/postgresql.auto.conf'
    printf \"primary_conninfo = 'host=%s port=5432 user=replicator application_name=%s'\nprimary_slot_name = '%s'\n\" \
      '$primary' '$node' '$node' >>'$PGDATA_PATH/postgresql.auto.conf'"
  compose start "$node" >/dev/null
  wait_ready "$node" 300
  # The slot $node kept for $primary when it was the primary would now hold WAL for nothing.
  node_psql "$node" -c "SELECT pg_drop_replication_slot('$primary')
                        WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '$primary')" >/dev/null
  wait_until "$node streams from $primary" 120 "$primary" \
    "SELECT EXISTS (SELECT 1 FROM pg_stat_replication WHERE application_name = '$node' AND state = 'streaming')"
}

# ─── Planned switchover drill ──────────────────────────────────────────────
switchover() {
  require_env
  ensure_runner
  local measure=() old new state ckpt t0 t1 rewind
  while [ $# -gt 0 ]; do
    case $1 in
      --measure) measure=(--measure); shift ;;
      *) die "switchover: unknown option $1" ;;
    esac
  done
  old=$(current_primary) || die "no primary is running (./lab up)"
  new=$(other_node "$old")
  is_running "$new" || die "there is no standby to switch to (./lab replica up)"
  state=$(node_query "$old" "SELECT state FROM pg_stat_replication WHERE application_name = '$new'")
  [ "$state" = streaming ] || die "$new is not streaming from $old (state: ${state:-none})"

  drill_start switchover
  record OLD_PRIMARY "$old"
  record NEW_PRIMARY "$new"

  log "1/6 the application writes through host=pg1,pg2 target_session_attrs=read-write"
  heartbeat_start "pg1,pg2"
  sleep 3

  log "2/6 checkpoint on $old, then a fast shutdown"
  node_psql "$old" -c 'CHECKPOINT' >/dev/null
  t0=$(now_s)
  compose stop -t 60 "$old" >/dev/null
  ckpt=$(offline "$old" pg_controldata | awk -F': *' '/^Latest checkpoint location/ { print $2 }')
  [ -n "$ckpt" ] || die "could not read the shutdown checkpoint of $old"
  info "$old stopped cleanly at checkpoint $ckpt"

  log "3/6 $new has received and replayed everything, then promote it"
  wait_until "$new has replayed past $ckpt" 60 "$new" \
    "SELECT pg_last_wal_replay_lsn() > '$ckpt'::pg_lsn"
  node_psql "$new" -c 'SELECT pg_promote(wait => true, wait_seconds => 60)' >/dev/null
  t1=$(now_s)
  record PROMOTE_SECONDS "$(elapsed "$t0" "$t1")"
  ensure_slot "$new" "$old"
  LAB_PRIMARY_HOST=$new

  log "4/6 pg_rewind $old against $new"
  rewind=$(rewind_against "$old" "$new")
  printf '%s\n' "$rewind" | sed 's/^/    /' >&2
  record REWIND_OK 1
  record REWIND_SUMMARY "$(printf '%s' "$rewind" | tail -n 1 | tr -d '\r')"

  log "5/6 restart $old as a standby of $new"
  rejoin_as_standby "$old" "$new"
  record STANDBY_STATE streaming

  log "6/6 stop the client and verify"
  sleep 2
  heartbeat_stop
  pglab "./lab switchover ${measure[*]}" drill-report switchover --dir "/work/$DRILL_DIR" "${measure[@]}"
}

# ─── Unplanned failover drill ──────────────────────────────────────────────
# The standby is promoted while the primary still accepts writes (a failover without fencing),
# the old primary commits a transaction the new timeline never sees, and pg_rewind, connected as
# the non-superuser role rewind, has real work to do before the old primary can follow.
FAILOVER_LOST_ROWS=500
FAILOVER_NEW_SEQ=1000000

failover_drill() {
  require_env
  ensure_runner
  local old new state rewind diverged
  [ $# -eq 0 ] || die "failover-drill: unknown option $1"
  old=$(current_primary) || die "no primary is running (./lab up)"
  new=$(other_node "$old")
  is_running "$new" || die "there is no standby to fail over to (./lab replica up)"
  state=$(node_query "$old" "SELECT state FROM pg_stat_replication WHERE application_name = '$new'")
  [ "$state" = streaming ] || die "$new is not streaming from $old (state: ${state:-none})"

  drill_start failover
  record OLD_PRIMARY "$old"
  record NEW_PRIMARY "$new"
  record REWIND_ROLE rewind
  record LOST_ROWS "$FAILOVER_LOST_ROWS"
  record NEW_SEQ "$FAILOVER_NEW_SEQ"

  log "1/6 promote $new while $old keeps running (no fencing: two primaries)"
  node_psql "$new" -c 'SELECT pg_promote(wait => true, wait_seconds => 60)' >/dev/null
  LAB_PRIMARY_HOST=$new

  log "2/6 $old commits $FAILOVER_LOST_ROWS rows that $new never receives; $new takes one write"
  node_psql "$old" -c "INSERT INTO lab.heartbeat (run_id, seq, sent_at)
                       SELECT '$DRILL_ID', g, now() FROM generate_series(1, $FAILOVER_LOST_ROWS) AS g" >/dev/null
  node_psql "$new" -c "INSERT INTO lab.heartbeat (run_id, seq, sent_at)
                       VALUES ('$DRILL_ID', $FAILOVER_NEW_SEQ, now())" >/dev/null

  log "3/6 stop $old: the fencing that should have come before the promotion"
  compose stop -t 60 "$old" >/dev/null
  ensure_slot "$new" "$old"

  log "4/6 pg_rewind $old against $new as the non-superuser role rewind"
  rewind=$(rewind_against "$old" "$new")
  printf '%s\n' "$rewind" | sed 's/^/    /' >&2
  diverged=$(printf '%s\n' "$rewind" | grep -m 1 'servers diverged at' | sed 's/^pg_rewind: //' | tr -d '\r' || true)
  record REWIND_DIVERGED "$diverged"
  record REWIND_SUMMARY "$(printf '%s' "$rewind" | tail -n 1 | tr -d '\r')"

  log "5/6 restart $old as a standby of $new"
  rejoin_as_standby "$old" "$new"
  record STANDBY_STATE streaming
  wait_until "$old has replayed the write made on $new" 120 "$old" \
    "SELECT EXISTS (SELECT 1 FROM lab.heartbeat WHERE run_id = '$DRILL_ID' AND seq = $FAILOVER_NEW_SEQ)"

  log "6/6 verify"
  pglab "./lab failover-drill" drill-report failover --dir "/work/$DRILL_DIR"
}
