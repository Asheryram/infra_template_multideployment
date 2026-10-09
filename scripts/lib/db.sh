#!/usr/bin/env bash
# Postgres helpers. Talks to the shared infra-postgres container via `docker exec`
# (local socket, superuser) so no admin password ever leaves the server.
# Source after common.sh.

pg_running() { [[ $(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null) == true ]]; }

pg_wait() {
  local i
  for i in $(seq 1 30); do
    if docker exec "$PG_CONTAINER" pg_isready -U postgres -q 2>/dev/null; then return 0; fi
    sleep 2
  done
  die "postgres ($PG_CONTAINER) is not ready — is the platform up? (infra platform up)"
}

psql_admin() {
  docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -X -q -U postgres -d "${PGDB:-postgres}" "$@"
}

sql_scalar()  { psql_admin -tAc "$1"; }
db_exists()   { [[ $(sql_scalar "SELECT 1 FROM pg_database WHERE datname = '$1'") == 1 ]]; }
role_exists() { [[ $(sql_scalar "SELECT 1 FROM pg_roles WHERE rolname = '$1'") == 1 ]]; }

# The seed template previews are cloned from, and the role that owns its objects.
db_template_name()  { echo "$(db_ident "$1")__template"; }
db_template_owner() { echo "$(db_ident "$1")__tpl"; }

# db_ensure <db> <role> <password> [template-db] [env-class]
# Creates role + database if missing (cloning from template when given and present).
# Applies per-class connection limits and statement timeouts to the role:
#   preview  → 5 connections, 10 s statement timeout
#   develop  → 10 connections, 30 s statement timeout
#   staging  → 20 connections, no timeout
#   prod     → no limit, no timeout
db_ensure() {
  local db=$1 role=$2 pw=$3 tpl=${4:-} cls=${5:-}
  pg_wait

  # Per-class resource limits on the role.
  local conn_limit=-1 stmt_timeout=0
  case $cls in
    preview) conn_limit=5;  stmt_timeout=10000 ;;
    develop) conn_limit=10; stmt_timeout=30000 ;;
    staging) conn_limit=20; stmt_timeout=0     ;;
  esac

  if role_exists "$role"; then
    psql_admin -c "ALTER ROLE \"$role\" WITH LOGIN PASSWORD '$pw' CONNECTION LIMIT $conn_limit"
  else
    psql_admin -c "CREATE ROLE \"$role\" WITH LOGIN PASSWORD '$pw' CONNECTION LIMIT $conn_limit"
  fi
  # Statement timeout is a role-level default — overrides postgresql.conf for this role only.
  psql_admin -c "ALTER ROLE \"$role\" SET statement_timeout = $stmt_timeout"

  db_exists "$db" && return 0

  if [[ -n $tpl ]] && db_exists "$tpl"; then
    log "creating database $db from template $tpl"
    psql_admin -c "CREATE DATABASE \"$db\" OWNER \"$role\" TEMPLATE \"$tpl\""
    local owner=${tpl%__template}__tpl
    if role_exists "$owner"; then
      PGDB=$db psql_admin -c "REASSIGN OWNED BY \"$owner\" TO \"$role\""
    fi
  else
    log "creating empty database $db"
    psql_admin -c "CREATE DATABASE \"$db\" OWNER \"$role\""
  fi
  psql_admin -c "REVOKE ALL ON DATABASE \"$db\" FROM PUBLIC"
}

# db_drop <db> <role>
db_drop() {
  pg_running || { warn "postgres not running; skipping drop of $1"; return 0; }
  if db_exists "$1"; then
    log "dropping database $1"
    psql_admin -c "DROP DATABASE \"$1\" WITH (FORCE)"
  fi
  if role_exists "$2"; then psql_admin -c "DROP ROLE \"$2\""; fi
}
