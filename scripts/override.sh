#!/usr/bin/env bash
# DevOps overrides — take manual control of how an environment is wired.
# They survive CI redeploys, apply immediately, and are removed when the environment is destroyed.
#
#   infra link <app> <scope> --api <backend-app>/<env>     frontend → that backend environment
#   infra link <app> <scope> --api-url <url>               frontend → any URL (external/partner API)
#   infra link <app> <scope> --auto                        back to automatic (same branch → fallback)
#
#   infra attach-db <app> <scope> --share <app>/<env>      use another environment's database
#   infra attach-db <app> <scope> --url <postgres-url>     use any existing Postgres
#   infra attach-db <app> <scope> --own                    back to its own database (default)
#       --allow-prod   required whenever the target is a prod database
#       --migrate      also run MIGRATE_CMD against it (skipped by default when not own)
#
#   infra overrides [app]                                  show everything that's overridden
#
# <scope>: one environment (pr-12, develop, staging, prod...) or "preview" = all PRs of the app.
# An environment-specific override wins over "preview".
#
# Databases outside the platform: use a host the containers can reach, e.g.
#   postgres://user:pass@host.docker.internal:5433/mydb    a DB published on the server's port 5433
#   postgres://user:pass@10.0.0.5:5432/mydb                 a DB server elsewhere on the network
SCRIPT_NAME=override
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

action=${1:-}
if [[ -z $action || $action == -h || $action == --help ]]; then usage; fi
shift
load_infra_env
enable_file_log

# ----------------------------------------------------------------------------- helpers

set_keys() { # file key=value... (empty value removes the key)
  local f=$1; shift
  mkdir -p "$(dirname "$f")"
  touch "$f"; chmod 600 "$f"
  local kv k v
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    sed -i "/^$k=/d" "$f"
    if [[ -n $v ]]; then write_kv "$f" "$k" "$v"; fi
  done
  if [[ ! -s $f ]]; then rm -f "$f"; fi
}

valid_target() { [[ $1 =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || die "target must look like <app>/<env>, got '$1'"; }

affected_envs() { # app scope → deployed environments the override applies to
  local app=$1 scope=$2 m
  if [[ $scope == preview ]]; then
    for m in "$DEPLOY_ROOT/$app"/pr-*/meta.env; do basename "$(dirname "$m")"; done
  elif [[ -f $DEPLOY_ROOT/$app/$scope/meta.env ]]; then
    echo "$scope"
  fi
}

apply_now() {
  local app=$1 scope=$2 env n=0
  for env in $(affected_envs "$app" "$scope"); do
    log "applying to $app/$env"
    run_clean "$INFRA_ROOT/scripts/deploy.sh" --app "$app" --env "$env" --redeploy --no-pull \
      || warn "redeploy of $app/$env failed — check 'infra logs $app $env'"
    n=$((n + 1))
  done
  if (( n == 0 )); then log "saved — will apply when $app/$scope is next deployed"; fi
}

# ----------------------------------------------------------------------------- actions

case $action in
  link)
    app=${1:?app}; scope=${2:?scope (env name or 'preview')}; shift 2
    validate_name app "$app"; validate_name scope "$scope"
    f=$(overrides_file "$app" "$scope")
    case ${1:-} in
      --api)
        valid_target "${2:?backend <app>/<env>}"
        if [[ ! -f $DEPLOY_ROOT/${2%%/*}/${2#*/}/meta.env ]]; then warn "$2 is not deployed (yet) — API_URL stays empty until it is"; fi
        set_keys "$f" "API_TARGET=$2" "API_URL="
        log "$app/$scope → API of $2"
        ;;
      --api-url)
        [[ ${2:-} =~ ^https?:// ]] || die "--api-url needs an http(s) URL"
        set_keys "$f" "API_URL=$2" "API_TARGET="
        log "$app/$scope → API $2"
        ;;
      --auto)
        set_keys "$f" "API_TARGET=" "API_URL="
        log "$app/$scope → automatic API resolution"
        ;;
      *) die "link needs --api <app>/<env>, --api-url <url> or --auto" ;;
    esac
    apply_now "$app" "$scope"
    ;;

  attach-db)
    app=${1:?app}; scope=${2:?scope (env name or 'preview')}; shift 2
    validate_name app "$app"; validate_name scope "$scope"
    f=$(overrides_file "$app" "$scope")
    mode="" target="" url="" allow_prod=false migrate=false
    while (( $# )); do
      case $1 in
        --share) mode=share; target=${2:?<app>/<env>}; shift 2 ;;
        --url) mode=external; url=${2:?postgres url}; shift 2 ;;
        --own) mode=own; shift ;;
        --allow-prod) allow_prod=true; shift ;;
        --migrate) migrate=true; shift ;;
        *) die "unknown option $1" ;;
      esac
    done
    mig=""; if [[ $migrate == true ]]; then mig=true; fi
    case $mode in
      share)
        valid_target "$target"
        [[ $target != "$app/$scope" ]] || die "an environment can't share its own database"
        if [[ ${target#*/} == prod && $allow_prod != true ]]; then die "$target is a PROD database — add --allow-prod if you really mean it"; fi
        [[ -s $DEPLOY_ROOT/${target%%/*}/${target#*/}/.db_password ]] || die "$target isn't deployed or has no database of its own"
        set_keys "$f" "DB_MODE=share" "DB_SHARE_FROM=$target" "DB_URL=" "DB_MIGRATE=$mig"
        log "$app/$scope → database of $target (migrations: $migrate)"
        ;;
      external)
        [[ $url =~ ^postgres(ql)?:// ]] || die "--url must be a postgres:// URL"
        if [[ $url =~ prod && $allow_prod != true ]]; then die "that URL looks like a prod database — add --allow-prod if you really mean it"; fi
        set_keys "$f" "DB_MODE=external" "DB_URL=$url" "DB_SHARE_FROM=" "DB_MIGRATE=$mig"
        log "$app/$scope → external database ${url%%:*}://***@${url#*@}"
        ;;
      own)
        set_keys "$f" "DB_MODE=" "DB_SHARE_FROM=" "DB_URL=" "DB_MIGRATE="
        log "$app/$scope → its own database"
        ;;
      *) die "attach-db needs --share <app>/<env>, --url <postgres-url> or --own" ;;
    esac
    apply_now "$app" "$scope"
    ;;

  list)
    found=0
    printf '%-22s %-10s %s\n' APP SCOPE OVERRIDE
    for f in "$STATE_DIR"/overrides/${1:-*}/*.env; do
      found=1
      app=$(basename "$(dirname "$f")"); scope=$(basename "${f%.env}")
      sed -E "s/(DB_URL='[^:]*:\/\/[^:]*:)[^@]*@/\1***@/" "$f" | while IFS= read -r line; do
        printf '%-22s %-10s %s\n' "$app" "$scope" "$line"
      done
    done
    (( found )) || echo "(no overrides — everything is wired automatically)"
    ;;

  *) die "unknown action: $action" ;;
esac
