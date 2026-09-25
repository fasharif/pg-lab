#!/usr/bin/env bash
# Applies the schema as topflow_migrator. Runs inside the runner container (./lab migrate).
#
#   1. TopFlow's Prisma migrations (sql/topflow), once each, in name order. Each one is
#      recorded with its SHA-256; a changed file after it was applied is an error.
#   2. The lab's helper schema (sql/lab) and the security layer (sql/security). These files
#      are idempotent and are re-applied on every run.
set -Eeuo pipefail
cd /work

: "${LAB_MIGRATOR_PASSWORD:?LAB_MIGRATOR_PASSWORD is not set}"
export PGUSER=topflow_migrator PGPASSWORD="$LAB_MIGRATOR_PASSWORD" PGAPPNAME=pglab-migrate

psql_m() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

psql_m <<'SQL'
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS lab;
CREATE TABLE IF NOT EXISTS lab.schema_migrations (
    name       text PRIMARY KEY,
    sha256     text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

for file in sql/topflow/*.sql; do
  name=$(basename "$file" .sql)
  sum=$(sha256sum "$file" | cut -d ' ' -f 1)
  recorded=$(psql_m -At -v name="$name" <<<"SELECT sha256 FROM lab.schema_migrations WHERE name = :'name'")
  if [ -z "$recorded" ]; then
    echo "applying TopFlow migration $name"
    psql_m -v client_min_messages=warning -f "$file" >/dev/null
    psql_m -v name="$name" -v sum="$sum" <<<"INSERT INTO lab.schema_migrations (name, sha256) VALUES (:'name', :'sum')"
  elif [ "$recorded" != "$sum" ]; then
    echo "error: $file changed after it was applied (recorded $recorded, now $sum)" >&2
    exit 1
  fi
done

for file in sql/lab/*.sql sql/security/*.sql; do
  [ -e "$file" ] || continue
  echo "applying $file"
  PGOPTIONS='-c client_min_messages=warning' psql_m -f "$file" >/dev/null
done
echo "schema is up to date"
