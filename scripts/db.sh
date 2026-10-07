#!/usr/bin/env bash
# Database operations on the shared Postgres.
#
#   infra db list
#   infra db psql     <app> <env>
#   infra db dump     <app> <env> [out-file]       custom-format dump (pg_restore-able)
#   infra db restore  <app> <env> <dump-file>      OVERWRITES that environment's data
#   infra db template <app> <dump-file>            set the seed previews are cloned from
#   infra db drop-template <app>
#
# The template must come from a SANITISED dump (no real user data). Previews get
# `CREATE DATABASE ... TEMPLATE <app>__template`, which is near-instant.
SCRIPT_NAME=db
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/db.sh
source "$INFRA_ROOT/scripts/lib/db.sh"

action=${1:-}
if [[ -z $action || $action == -h || $action == --help ]]; then usage; fi
shift
load_infra_env
pg_wait

env_db() { validate_name app "$1"; validate_name env "$2"; db_ident "${1}_${2}"; }

case $action in
  list)
    psql_admin -c "SELECT datname AS database,
                          pg_size_pretty(pg_database_size(datname)) AS size,
                          (SELECT count(*) FROM pg_stat_activity a WHERE a.datname = d.datname) AS connections
                   FROM pg_database d WHERE NOT datistemplate ORDER BY 1"
    ;;

  psql)
    db=$(env_db "${1:?app}" "${2:?env}")
    exec docker exec -it "$PG_CONTAINER" psql -U postgres -d "$db"
    ;;

  dump)
    db=$(env_db "${1:?app}" "${2:?env}")
    out=${3:-$db-$(date +%Y%m%d-%H%M%S).dump}
    docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc "$db" > "$out"
    log "wrote $out ($(du -h "$out" | cut -f1))"
    ;;

  restore)
    db=$(env_db "${1:?app}" "${2:?env}")
    file=${3:?dump file required}
    [[ -f $file ]] || die "no such file: $file"
    db_exists "$db" || die "database $db does not exist (deploy the environment first)"
    log "restoring $file into $db"
    docker exec -i "$PG_CONTAINER" pg_restore -U postgres -d "$db" --clean --if-exists \
      --no-owner --role="$db" < "$file"
    ;;

  template)
    app=${1:?app}; file=${2:?dump file required}
    validate_name app "$app"
    [[ -f $file ]] || die "no such file: $file"
    tpl=$(db_template_name "$app"); owner=$(db_template_owner "$app")
    if ! role_exists "$owner"; then psql_admin -c "CREATE ROLE \"$owner\" NOLOGIN"; fi
    psql_admin -c "DROP DATABASE IF EXISTS \"$tpl\" WITH (FORCE)"
    psql_admin -c "CREATE DATABASE \"$tpl\" OWNER \"$owner\""
    docker exec -i "$PG_CONTAINER" pg_restore -U postgres -d "$tpl" --no-owner --role="$owner" < "$file"
    psql_admin -c "ALTER DATABASE \"$tpl\" WITH ALLOW_CONNECTIONS false"
    log "template $tpl ready — new previews of $app will be cloned from it"
    ;;

  drop-template)
    app=${1:?app}; validate_name app "$app"
    tpl=$(db_template_name "$app")
    psql_admin -c "DROP DATABASE IF EXISTS \"$tpl\" WITH (FORCE)"
    owner=$(db_template_owner "$app")
    if role_exists "$owner"; then psql_admin -c "DROP ROLE \"$owner\""; fi
    ;;

  *) die "unknown action: $action (see --help)" ;;
esac
