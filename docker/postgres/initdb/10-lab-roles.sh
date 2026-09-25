#!/usr/bin/env bash
# First start of a new cluster only (run by the official entrypoint as the postgres user).
# Creates the lab's roles with SCRAM passwords taken from the environment, the topflow
# database and the extensions the lab needs. Tables are created later by ./lab migrate.
set -Eeuo pipefail

for var in LAB_MIGRATOR_PASSWORD LAB_APP_PASSWORD LAB_ANALYST_PASSWORD \
  LAB_REPLICATOR_PASSWORD LAB_MONITOR_PASSWORD LAB_REWIND_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "10-lab-roles.sh: $var is not set (run ./lab init to create .env)" >&2
    exit 1
  fi
done

psql -v ON_ERROR_STOP=1 --no-psqlrc --username "$POSTGRES_USER" --dbname postgres \
  -v migrator_pw="$LAB_MIGRATOR_PASSWORD" \
  -v app_pw="$LAB_APP_PASSWORD" \
  -v analyst_pw="$LAB_ANALYST_PASSWORD" \
  -v replicator_pw="$LAB_REPLICATOR_PASSWORD" \
  -v monitor_pw="$LAB_MONITOR_PASSWORD" \
  -v rewind_pw="$LAB_REWIND_PASSWORD" <<'SQL'
SET password_encryption = 'scram-sha-256';

-- Owner of every TopFlow object. Nobody logs in as the owner.
CREATE ROLE topflow_owner NOLOGIN;

-- Runs migrations. Its sessions start as topflow_owner, so new objects belong to the owner
-- role and not to a person or a tool.
CREATE ROLE topflow_migrator LOGIN PASSWORD :'migrator_pw' CONNECTION LIMIT 3;
GRANT topflow_owner TO topflow_migrator WITH INHERIT TRUE, SET TRUE;
ALTER ROLE topflow_migrator SET role = 'topflow_owner';

-- The API's connection role: data access only, subject to row-level security.
CREATE ROLE topflow_app LOGIN PASSWORD :'app_pw' CONNECTION LIMIT 60;
ALTER ROLE topflow_app SET statement_timeout = '30s';
ALTER ROLE topflow_app SET idle_in_transaction_session_timeout = '60s';

-- Read-only reporting: every tenant, but no personal contact data (column privileges).
CREATE ROLE topflow_analyst LOGIN PASSWORD :'analyst_pw' CONNECTION LIMIT 5;
ALTER ROLE topflow_analyst SET default_transaction_read_only = on;
ALTER ROLE topflow_analyst SET statement_timeout = '5min';

-- Infrastructure roles.
CREATE ROLE replicator LOGIN REPLICATION PASSWORD :'replicator_pw' CONNECTION LIMIT 5;
CREATE ROLE monitor LOGIN PASSWORD :'monitor_pw' CONNECTION LIMIT 5;
GRANT pg_monitor TO monitor;
ALTER ROLE monitor SET statement_timeout = '10s';

-- pg_rewind without a superuser: the four functions it calls on the source server.
CREATE ROLE rewind LOGIN PASSWORD :'rewind_pw' CONNECTION LIMIT 2;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind;

CREATE DATABASE topflow OWNER topflow_owner;
REVOKE ALL ON DATABASE topflow FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE topflow TO topflow_migrator, topflow_app, topflow_analyst;
GRANT CONNECT ON DATABASE topflow TO monitor;

\connect topflow
REVOKE ALL ON SCHEMA public FROM PUBLIC;
-- Extensions need a superuser here; everything else is created by the migrator.
CREATE EXTENSION pg_trgm WITH SCHEMA public;
CREATE EXTENSION pg_stat_statements WITH SCHEMA public;
CREATE SCHEMA tap AUTHORIZATION postgres;
CREATE EXTENSION pgtap WITH SCHEMA tap;
GRANT USAGE ON SCHEMA tap TO topflow_migrator, topflow_app, topflow_analyst;
SQL
