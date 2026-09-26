#!/usr/bin/env bash
# SQL Server chapter: ./lab sqlserver up|seed|casebook|down. Sourced by ./lab.
#
# Written, not run in this repository. SQL Server is Microsoft software under its own licence;
# the container starts only when you accept it yourself with MSSQL_ACCEPT_EULA=Y.

MSSQL_TOOLS=/opt/mssql-tools18/bin/sqlcmd

mssql_compose() {
  docker compose --project-directory "$LAB_ROOT_HOST/sqlserver" \
    -f "$LAB_ROOT_HOST/sqlserver/compose.yaml" --env-file "$LAB_ROOT_HOST/.env" "$@"
}

require_eula() {
  if [ "${MSSQL_ACCEPT_EULA:-}" != "Y" ]; then
    die "SQL Server runs only if you accept Microsoft's licence terms yourself.
       Read them (linked from https://learn.microsoft.com/sql/linux/quickstart-install-connect-docker),
       then, only if you accept them:
         MSSQL_ACCEPT_EULA=Y ./lab sqlserver up"
  fi
}

# sqlcmd inside the container; the password travels in SQLCMDPASSWORD, not on the command line.
mssql_sqlcmd() {
  mssql_compose exec -T -e SQLCMDPASSWORD="$(env_value LAB_MSSQL_SA_PASSWORD)" mssql \
    "$MSSQL_TOOLS" -S localhost -U sa -C -b -y 0 "$@"
}

mssql_copy_scripts() {
  mssql_compose exec -T -u root mssql rm -rf /tmp/lab-sql
  mssql_compose cp "$LAB_ROOT_HOST/sqlserver/sql" mssql:/tmp/lab-sql >/dev/null
}

cmd_sqlserver() {
  require_env
  local action=${1:-help} scale
  [ $# -gt 0 ] && shift
  case $action in
    up)
      require_eula
      log "building and starting SQL Server 2022 Developer edition ($LAB_PROJECT-mssql)"
      MSSQL_ACCEPT_EULA=Y mssql_compose up -d --build --wait mssql
      ;;
    seed)
      require_eula
      scale=$(env_value LAB_SCALE 100000)
      if [ "${1:-}" = --scale ]; then scale=${2:?--scale needs a number}; fi
      [[ $scale =~ ^[0-9]+$ ]] || die "sqlserver seed: --scale must be a whole number"
      mssql_copy_scripts
      log "schema"
      mssql_sqlcmd -i /tmp/lab-sql/01_schema.sql
      mssql_sqlcmd -d topflow -Q "INSERT INTO dbo.lab_settings ([key], [value]) VALUES ('scale', N'$scale')"
      log "generating data at SCALE=$scale"
      mssql_sqlcmd -d topflow -i /tmp/lab-sql/02_generate.sql
      ;;
    casebook)
      require_eula
      mkdir -p "$LAB_ROOT/out/sqlserver"
      mssql_copy_scripts
      log "plans before the fixes"
      mssql_sqlcmd -d topflow -i /tmp/lab-sql/10_queries_before.sql >"$LAB_ROOT/out/sqlserver/before.txt"
      log "applying the fixes"
      mssql_sqlcmd -d topflow -i /tmp/lab-sql/20_fixes.sql
      log "plans after the fixes"
      mssql_sqlcmd -d topflow -i /tmp/lab-sql/11_queries_after.sql >"$LAB_ROOT/out/sqlserver/after.txt"
      ensure_runner
      pglab "./lab sqlserver casebook" mssql-report --before /work/out/sqlserver/before.txt \
        --after /work/out/sqlserver/after.txt
      ;;
    down)
      mssql_compose down --volumes --remove-orphans
      ;;
    *) die "sqlserver: expected up, seed [--scale N], casebook or down" ;;
  esac
}
