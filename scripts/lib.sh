#!/usr/bin/env bash
# Shared helpers for ./lab and the drill scripts. Sourced, never executed.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

LAB_NODES=(pg1 pg2)
PGDATA_PATH=/var/lib/postgresql/18/docker

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

# Seconds since the epoch with milliseconds, for drill timings. GNU date (Linux, Git Bash)
# supports %N; BSD date on macOS does not, so fall back to perl there.
now_s() {
  local t
  t=$(date +%s.%3N)
  case $t in
    *N*) perl -MTime::HiRes=time -e 'printf "%.3f", time' ;;
    *) printf '%s' "$t" ;;
  esac
}
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }

compose() { docker compose --project-directory "$LAB_ROOT_HOST" "$@"; }
compose_all() { compose --profile replica --profile monitoring "$@"; }

# Names of the Compose project, its containers and volumes. LAB_PROJECT comes from the shell
# or .env (default pg-lab); compose.yaml builds every name from the same variable. The runner
# container runs as the calling user (LAB_UID:LAB_GID), so the files it writes into the
# repository are not owned by root on a Linux host.
lab_names() {
  LAB_PROJECT=${LAB_PROJECT:-$(env_value LAB_PROJECT pg-lab)}
  [[ $LAB_PROJECT =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    die "LAB_PROJECT must be lower-case letters, digits, '-' or '_' (got '$LAB_PROJECT')"
  LAB_UID=$(id -u)
  LAB_GID=$(id -g)
  export LAB_PROJECT LAB_UID LAB_GID
}

container_name() { printf '%s-%s' "$LAB_PROJECT" "$1"; }
volume_name() { printf '%s_%s' "$LAB_PROJECT" "$1"; }

# Output folders are created on the host before any container writes into them. A container
# that created them would make them belong to its own user, and the host could no longer add
# drill folders (on Linux hosts, where bind mounts keep ownership).
ensure_output_dirs() {
  mkdir -p "$LAB_ROOT/out/reports" "$LAB_ROOT/out/drills" "$LAB_ROOT/out/sqlserver"
}

# Removes a named volume of the project; a volume that is still in use is an error, never
# skipped, so that a new standby cannot start on an old data directory.
remove_volume() {
  local volume
  volume=$(volume_name "$1")
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    docker volume rm "$volume" >/dev/null || die "could not remove volume $volume"
  fi
}

require_env() {
  [ -f "$LAB_ROOT/.env" ] || die "no .env file: run ./lab init first"
}

# Reads one KEY=value from .env without sourcing the whole file.
env_value() {
  local key=$1 default=${2:-}
  local line
  line=$(grep -E "^${key}=" "$LAB_ROOT/.env" 2>/dev/null | tail -n 1 || true)
  if [ -n "$line" ]; then printf '%s' "${line#*=}"; else printf '%s' "$default"; fi
}

is_running() {
  local name=$1
  [ "$(docker inspect -f '{{.State.Running}}' "$(container_name "$name")" 2>/dev/null || true)" = "true" ]
}

wait_healthy() {
  local service=$1 timeout=${2:-180} waited=0 state name
  name=$(container_name "$service")
  while :; do
    state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo missing)
    case $state in
      healthy | running) return 0 ;;
      exited | dead | missing) die "container $name is $state; see: docker logs $name" ;;
    esac
    [ "$waited" -ge "$timeout" ] && die "$name not healthy after ${timeout}s (state: $state)"
    sleep 1
    waited=$((waited + 1))
  done
}

ensure_runner() {
  is_running runner || compose up -d --wait runner >/dev/null
}

# Host name of the node that accepts writes, falling back to pg1 when none answers yet.
# Cached for the life of one ./lab command.
primary_host() {
  if [ -z "${LAB_PRIMARY_HOST:-}" ]; then
    LAB_PRIMARY_HOST=$(current_primary || echo pg1)
  fi
  printf '%s' "$LAB_PRIMARY_HOST"
}

# Runs a command in the tools container (non-interactive), pointed at the current primary.
# Naming the host avoids libpq resolving a node that is not running (seconds per connection).
runner() { compose exec -T -e PGHOST="$(primary_host)" -e PGPORT=5432 runner "$@"; }

# A setting as Compose resolves it: the shell's value wins over .env, then the default.
lab_setting() {
  local key=$1 default=$2
  if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; else env_value "$key" "$default"; fi
}

# One-line description of where the lab runs, printed at the top of generated reports: the
# Docker host, every container memory limit and the server's memory settings.
# LAB_ENVIRONMENT_NOTE (optional, from the shell) adds context such as "machine shared with
# other workloads".
lab_environment() {
  local info docker os build
  info=$(docker info --format '{{.OperatingSystem}}|{{.ServerVersion}}|{{.NCPU}}|{{.MemTotal}}' 2>/dev/null || true)
  if [ -n "$info" ]; then
    docker=$(printf '%s' "$info" | awk -F'|' '{ printf "%s (Docker %s), %s CPUs and %.1f GiB of memory for all containers", $1, $2, $3, $4 / 1073741824 }')
  else
    docker="Docker (details unavailable)"
  fi
  case $(uname -s 2>/dev/null) in
    MINGW* | MSYS*)
      # uname -s reads MINGW64_NT-10.0-26200: Windows 11 reports NT 10.0 too, from build 22000.
      build=$(uname -s | sed -e 's/^.*-//')
      if [[ $build =~ ^[0-9]+$ ]] && ((build >= 22000)); then
        os="Windows 11 build $build (Git Bash)"
      else
        os="Windows NT $(uname -s | sed -e 's/^[A-Z0-9]*_NT-//' -e 's/-/ build /') (Git Bash)"
      fi
      ;;
    Darwin) os="macOS $(sw_vers -productVersion 2>/dev/null)" ;;
    *) os="$(uname -sr 2>/dev/null)" ;;
  esac
  printf '%s on %s; memory limits pg1 %s, pg2 %s, runner %s; shared_buffers %s, ' \
    "$docker" "$os" "$(lab_setting LAB_PG_MEM_LIMIT 1g)" "$(lab_setting LAB_PG2_MEM_LIMIT 768m)" \
    "$(lab_setting LAB_RUNNER_MEM_LIMIT 512m)" "$(lab_setting LAB_SHARED_BUFFERS 256MB)"
  printf 'effective_cache_size %s, maintenance_work_mem %s, work_mem %s' \
    "$(lab_setting LAB_EFFECTIVE_CACHE_SIZE 768MB)" "$(lab_setting LAB_MAINTENANCE_WORK_MEM 128MB)" \
    "$(lab_setting LAB_WORK_MEM 8MB)"
  if [ -n "${LAB_ENVIRONMENT_NOTE:-}" ]; then printf '; %s' "$LAB_ENVIRONMENT_NOTE"; fi
}

# python -m pglab in the runner, with the report label and environment description.
pglab() {
  local label=${1% }
  shift
  compose exec -T -e LAB_ENVIRONMENT="$(lab_environment)" -e PGHOST="$(primary_host)" -e PGPORT=5432 \
    -e LAB_REPORTS_DIR="${LAB_REPORTS_DIR:-}" runner python -m pglab --label "$label" "$@"
}

# psql as the postgres superuser inside a node container (Unix socket, peer authentication).
node_psql() {
  local node=$1
  shift
  compose exec -T -u postgres "$node" psql -X -q -v ON_ERROR_STOP=1 -d topflow "$@"
}

# Single value from a node, trimmed.
node_query() {
  local node=$1 sql=$2
  node_psql "$node" -At -c "$sql" | tr -d '[:space:]'
}

# Prints the node that currently accepts writes (pg1 or pg2); fails if none does.
current_primary() {
  local node
  for node in "${LAB_NODES[@]}"; do
    if is_running "$node" && [ "$(node_query "$node" 'SELECT pg_is_in_recovery()' 2>/dev/null || true)" = "f" ]; then
      printf '%s' "$node"
      return 0
    fi
  done
  return 1
}

other_node() { if [ "$1" = pg1 ]; then printf pg2; else printf pg1; fi; }

# Waits until a node accepts connections (after a restart or promotion).
wait_ready() {
  local node=$1 timeout=${2:-120} waited=0
  until compose exec -T -u postgres "$node" pg_isready -q -d postgres 2>/dev/null; do
    [ "$waited" -ge "$timeout" ] && die "$node did not accept connections within ${timeout}s"
    sleep 1
    waited=$((waited + 1))
  done
}
