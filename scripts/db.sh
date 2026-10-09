#!/usr/bin/env bash
# Database operations on the shared Postgres.
#
#   Per-environment database — provisioned on demand, never wired automatically.
#   DevOps creates a DB when a branch needs one, then sets the connection URL as whatever
#   variable name the app reads (DB_URL, PG_DSN, POSTGRES_URI, …) in the console.
#   infra db info   <app> <env> [--json]
#   infra db create <app> <env>
#   infra db wipe   <app> <env>
#   infra db url    <app> <env>                print the connection URL to paste into the console
#   infra db use    <app> <env> --key <VAR> [--from <app>/<env>] [--scope <scope>] [--allow-prod]
#                                              set <VAR> on <app>/<env> to point at a DB
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

need_stack() { # app env → sets SD (stack dir); the environment must have been deployed
  SD=$(stack_dir "$1" "$2")
  [[ -d $SD ]] || die "$1/$2 is not deployed — deploy it first"
}
db_url_of() { # app env → URL (needs the env's password file)
  local db; db=$(env_db "$1" "$2")
  local pw="$(stack_dir "$1" "$2")/.db_password"
  [[ -s $pw ]] || die "$1/$2 has never had a database (create it first)"
  echo "postgres://$db:$(<"$pw")@$PG_CONTAINER:5432/$db"
}
attach_pg() { # connect Postgres to the env's private network so its containers can reach it
  local net; net=$(stack_network "$1" "$2")
  if docker network inspect "$net" >/dev/null 2>&1; then net_connect "$net" "$PG_CONTAINER"; fi
}
set_var() { # app scope key value → console variable file
  local f="$SECRETS_ROOT/$1/$2.env"
  mkdir -p "$SECRETS_ROOT/$1"; chmod 2770 "$SECRETS_ROOT/$1" 2>/dev/null || true
  touch "$f"; chmod 660 "$f"
  sed -i "/^$3=/d" "$f"
  echo "$3=$4" >> "$f"
}

case $action in
  info)
    app=${1:?app}; env=${2:?env}; need_stack "$app" "$env"; db=$(env_db "$app" "$env")
    exists=false size="" url=""
    if db_exists "$db"; then exists=true; size=$(sql_scalar "SELECT pg_size_pretty(pg_database_size('$db'))"); fi
    if [[ -s $SD/.db_password ]]; then url=$(db_url_of "$app" "$env"); fi
    connected=$(meta_get "$SD/meta.env" DB_CONNECTED 2>/dev/null || true)
    wiped=false; [[ -f $SD/.db_wiped ]] && wiped=true
    if [[ ${3:-} == --json ]]; then
      jq -cn --arg db "$db" --argjson exists "$exists" --arg size "$size" --arg url "$url" \
        --arg connected "${connected:-none}" --argjson wiped "$wiped" --argjson provisioned "$([[ -n $url ]] && echo true || echo false)" \
        '{name:$db, exists:$exists, size:$size, url:$url, connected:$connected, wiped:$wiped, provisioned:$provisioned}'
    else
      echo "database:  $db ($([[ $exists == true ]] && echo "exists, $size" || echo "does not exist${wiped:+}"))"
      echo "url:       ${url:+${url%%:*}://$db:••••@$PG_CONTAINER:5432/$db}"
      echo "app uses:  ${connected:-none}   (set the DB connection variable in the console, or: infra db use $app $env --key YOUR_VAR_NAME)"
    fi
    ;;

  create)
    app=${1:?app}; env=${2:?env}; need_stack "$app" "$env"; db=$(env_db "$app" "$env")
    if [[ ! -s $SD/.db_password ]]; then ( umask 077; openssl rand -hex 24 > "$SD/.db_password" ); fi
    db_ensure "$db" "$db" "$(<"$SD/.db_password")"
    rm -f "$SD/.db_wiped"
    attach_pg "$app" "$env"
    log "database $db ready — copy the URL into your app's DB connection variable in the console: infra db url $app $env"
    log "then: infra db use $app $env --key YOUR_VAR_NAME  (e.g. --key DB_URL or --key PG_DSN)"
    ;;

  wipe)
    app=${1:?app}; env=${2:?env}; need_stack "$app" "$env"; db=$(env_db "$app" "$env")
    if [[ $env == prod && ${3:-} != --i-really-mean-prod ]]; then die "refusing to wipe prod without --i-really-mean-prod"; fi
    acquire_lock "$(stack_name "$app" "$env")"
    if db_exists "$db"; then psql_admin -c "DROP DATABASE \"$db\" WITH (FORCE)"; fi
    touch "$SD/.db_wiped"            # later deploys must NOT bring it back — only `create` does
    log "database $db wiped — the app keeps running without it. Recreate (empty, same URL): infra db create $app $env"
    ;;

  url)
    app=${1:?app}; env=${2:?env}; need_stack "$app" "$env"; db_url_of "$app" "$env"
    ;;

  use)
    app=${1:?app}; env=${2:?env}; shift 2; need_stack "$app" "$env"
    from="$app/$env" key="" scope=$env allow_prod=false
    while (( $# )); do
      case $1 in
        --from)       from=${2:?}; shift 2 ;;
        --key)        key=${2:?}; shift 2 ;;
        --scope)      scope=${2:?}; shift 2 ;;
        --allow-prod) allow_prod=true; shift ;;
        *) die "unknown option $1" ;;
      esac
    done
    [[ -n $key ]] || die "--key is required: the variable name the app reads its DB URL from (e.g. --key DB_URL)"
    [[ $from =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || die "--from must be <app>/<env>"
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad key"
    [[ $scope =~ ^[a-z0-9-]+(\.(app|web|api))?$ ]] || die "bad scope"
    if [[ ${from#*/} == prod && $from != "$app/$env" && $allow_prod != true ]]; then
      die "$from is a PROD database — add --allow-prod if you really mean to point $app/$env at it"
    fi
    url=$(db_url_of "${from%%/*}" "${from#*/}")
    set_var "$app" "$scope" "$key" "$url"
    attach_pg "$app" "$env"
    log "$app/$env: $key → database of $from (scope $scope). Apply with: infra redeploy $app $env"
    ;;

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
