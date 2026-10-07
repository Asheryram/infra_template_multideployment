#!/usr/bin/env bash
# Remove one environment: containers, volumes, database, and its state directory.
#
#   infra destroy --app <app> --env <env> [--keep-db]
#   infra destroy --app <app> --env prod --i-really-mean-prod
#
# Frontend previews that were using this backend are relinked to their fallback.
SCRIPT_NAME=destroy
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/db.sh
source "$INFRA_ROOT/scripts/lib/db.sh"

APP="" ENV_NAME="" KEEP_DB=0 FORCE_PROD=0
while (( $# )); do
  case $1 in
    --app) APP=${2:?}; shift 2 ;;
    --env) ENV_NAME=${2:?}; shift 2 ;;
    --keep-db) KEEP_DB=1; shift ;;
    --i-really-mean-prod) FORCE_PROD=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_infra_env
enable_file_log
validate_name app "$APP"
validate_name env "$ENV_NAME"
if [[ $ENV_NAME == prod ]] && (( ! FORCE_PROD )); then
  die "refusing to destroy prod without --i-really-mean-prod"
fi

STACK=$(stack_name "$APP" "$ENV_NAME")
STACK_DIR=$(stack_dir "$APP" "$ENV_NAME")
acquire_lock "$STACK"

TYPE="" BRANCH="" DB_NAME=""
if [[ -f $STACK_DIR/stack.env ]]; then
  if [[ -f $STACK_DIR/meta.env ]]; then
    TYPE=$(meta_get "$STACK_DIR/meta.env" TYPE)
    BRANCH=$(meta_get "$STACK_DIR/meta.env" BRANCH)
    DB_NAME=$(meta_get "$STACK_DIR/meta.env" DB_NAME)
  fi
  load_stack "$APP" "$ENV_NAME"
  log "stopping $STACK"
  "${COMPOSE[@]}" down --volumes --remove-orphans --timeout 30 || warn "compose down reported errors"
else
  warn "no state for $STACK — removing anything labelled with its compose project"
  label="label=com.docker.compose.project=$STACK"
  docker ps -aq --filter "$label" | xargs -r docker rm -f
  docker network ls -q --filter "$label" | xargs -r docker network rm
  docker volume ls -q --filter "$label" | xargs -r docker volume rm
  DB_NAME=$(db_ident "${APP}_${ENV_NAME}")
fi

if (( ! KEEP_DB )) && [[ -n $DB_NAME ]]; then
  db_drop "$DB_NAME" "$DB_NAME"
fi

rm -rf "$STACK_DIR"
rmdir "$DEPLOY_ROOT/$APP" 2>/dev/null || true

if is_preview "$ENV_NAME" && [[ -n $BRANCH && $TYPE != frontend ]]; then
  relink_frontends "$APP" "$BRANCH"
fi

log "OK  $STACK destroyed"
