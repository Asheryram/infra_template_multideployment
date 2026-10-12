#!/usr/bin/env bash
# Database operations on the shared Postgres.
#
# Databases are DECLARED in the repo's .infradeploy/infra.yml (per service) and CREATED on demand —
# deploying never creates one. Each declared database has an id "<service>:<inject_as>".
#
#   infra db info   <app> <env> [--json]          every declared database and whether it exists
#   infra db create <app> <env> [--db <id>]       create declared databases (all not-yet-created, or one)
#   infra db wipe   <app> <env> [--db <id>]       drop the data; stays gone until created again
#   infra db url    <app> <env> [--db <id>]       print a created database's connection URL
#   infra db use    <app> <env> --key <VAR> [--from <app>/<env>] [--db <id>] [--scope <scope>] [--allow-prod]
#                                                  set <VAR> to point at another environment's database
#   infra db list
#   infra db psql     <app> <env> [--db <id>]
#   infra db dump     <app> <env> [out-file] [--db <id>]
#   infra db restore  <app> <env> <dump-file> [--db <id>]     OVERWRITES that database's data
#   infra db template <app> <dump-file>            set the seed previews are cloned from
#   infra db drop-template <app>
#
# After create/wipe, apply with `infra redeploy <app> <env>` (the console does this for you).
# The template must come from a SANITISED dump (no real user data).
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

# --db <id> may appear anywhere; strip it into DBID
DBID=""; _args=()
while (( $# )); do
  case $1 in
    --db) DBID=${2:?--db needs <service>:<inject_as>}; shift 2 ;;
    *) _args+=("$1"); shift ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}
[[ -z $DBID || $DBID =~ ^[a-z0-9-]+:[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad --db id: $DBID"

need_stack() { # app env → sets SD (stack dir); the environment must have been deployed
  validate_name app "$1"; validate_name env "$2"
  SD=$(stack_dir "$1" "$2")
  [[ -d $SD ]] || die "$1/$2 is not deployed — deploy it first"
}
declared_of() { declared_dbs "$(stack_dir "$1" "$2")/deploy" "$1" "$2"; }   # app env
pick_row() { # app env → first declared row matching $DBID (or the first created one when no --db)
  local row sd; sd=$(stack_dir "$1" "$2")
  while IFS= read -r row; do
    [[ -n $row ]] || continue
    if [[ -n $DBID ]]; then [[ ${row%%|*} == "$DBID" ]] && { echo "$row"; return 0; }
    else IFS='|' read -r _ _ _ n _ <<< "$row"; db_is_created "$sd" "$n" && { echo "$row"; return 0; }; fi
  done < <(declared_of "$1" "$2")
  return 1
}
db_name_of() { local row; row=$(pick_row "$1" "$2") || die "$1/$2 has no ${DBID:-created} database (see: infra db info $1 $2)"; IFS='|' read -r _ _ _ n _ <<< "$row"; echo "$n"; }
db_url_of() { # app env → URL of a CREATED database
  local row n sd; sd=$(stack_dir "$1" "$2")
  row=$(pick_row "$1" "$2") || die "$1/$2 has no ${DBID:-created} database — create it first"
  IFS='|' read -r _ _ _ n _ <<< "$row"
  db_is_created "$sd" "$n" || die "database ${DBID:-$n} of $1/$2 is not created yet"
  db_url_for "$sd" "$n"
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
    app=${1:?app}; env=${2:?env}; need_stack "$app" "$env"
    rows=$(declared_of "$app" "$env"); items=()
    while IFS='|' read -r id svc inject name fixed; do
      [[ -n $id ]] || continue
      created=false; exists=false wiped=false; size=""
      db_is_created "$SD" "$name" && created=true
      [[ -e $SD/.db_wiped_$name ]] && wiped=true
      if db_exists "$name"; then exists=true; size=$(sql_scalar "SELECT pg_size_pretty(pg_database_size('$name'))"); fi
      items+=("$(jq -cn --arg id "$id" --arg service "$svc" --arg inject_as "$inject" --arg name "$name" --arg size "$size" \
        --arg url "$([[ $created == true ]] && db_url_for "$SD" "$name" || true)" \
        --argjson created "$created" --argjson exists "$exists" --argjson wiped "$wiped" \
        '{id:$id, service:$service, inject_as:$inject_as, name:$name, created:$created, exists:$exists, wiped:$wiped, size:$size, url:$url}')")
    done <<< "$rows"
    json=$(printf '%s\n' "${items[@]:-}" | jq -cs '[ .[] | select(. != null) ]')
    if [[ ${3:-} == --json ]]; then jq -cn --argjson databases "$json" '{databases:$databases}'
    else
      jq -r '.[] | "\(.id)  \(.name)  " + (if .created then "created" + (if .exists then ", " + .size else ", MISSING in postgres" end) elif .wiped then "wiped" else "not created" end)' <<< "$json"
      [[ $json != "[]" ]] || echo "no databases declared in infra.yml"
    fi
    ;;

  create)
    app=${1:?app}; env=${2:?env}; need_stack "$app" "$env"
    rows=$(declared_of "$app" "$env"); n=0
    [[ -n $rows ]] || die "infra.yml declares no databases for $app"
    while IFS='|' read -r id svc inject name fixed; do
      [[ -n $id ]] || continue
      [[ -z $DBID || $DBID == "$id" ]] || continue
      if [[ -z $DBID ]] && db_is_created "$SD" "$name"; then continue; fi    # all: only the missing ones
      log "creating $id → $name"
      db_provision "$SD" "$name" "$fixed" "$(env_class "$env")"
      n=$((n + 1))
    done <<< "$rows"
    (( n )) || { [[ -z $DBID ]] && { log "all declared databases already exist"; exit 0; }; die "no declared database '$DBID'"; }
    attach_pg "$app" "$env"
    log "$n database(s) ready — apply with: infra redeploy $app $env"
    ;;

  wipe)
    app=${1:?app}; env=${2:?env}; need_stack "$app" "$env"
    if [[ $env == prod && ${3:-} != --i-really-mean-prod ]]; then die "refusing to wipe prod without --i-really-mean-prod"; fi
    acquire_lock "$(stack_name "$app" "$env")"
    rows=$(declared_of "$app" "$env"); n=0
    while IFS='|' read -r id svc inject name fixed; do
      [[ -n $id ]] || continue
      [[ -z $DBID || $DBID == "$id" ]] || continue
      db_is_created "$SD" "$name" || continue
      if db_exists "$name"; then psql_admin -c "DROP DATABASE \"$name\" WITH (FORCE)"; fi
      touch "$SD/.db_wiped_$name"        # later deploys must NOT bring it back — only `create` does
      n=$((n + 1))
    done <<< "$rows"
    log "$n database(s) wiped — apply with: infra redeploy $app $env (the URL is no longer injected)"
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
    [[ -d $(stack_dir "${from%%/*}" "${from#*/}") ]] || die "$from is not deployed"
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad key"
    [[ $scope =~ ^[a-z0-9-]+(\.[a-z0-9-]+)?$ ]] || die "bad scope"
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
    db=$(db_name_of "${1:?app}" "${2:?env}")
    exec docker exec -it "$PG_CONTAINER" psql -U postgres -d "$db"
    ;;

  dump)
    db=$(db_name_of "${1:?app}" "${2:?env}")
    out=${3:-$db-$(date +%Y%m%d-%H%M%S).dump}
    docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc "$db" > "$out"
    log "wrote $out ($(du -h "$out" | cut -f1))"
    ;;

  restore)
    db=$(db_name_of "${1:?app}" "${2:?env}")
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
