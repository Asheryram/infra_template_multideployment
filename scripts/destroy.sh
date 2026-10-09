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

# Another environment is borrowing this one's database (infra attach-db --share)?
borrowers=$(override_dependents DB_SHARE_FROM "$APP/$ENV_NAME" | paste -sd' ' -)
if [[ -n $borrowers ]] && (( ! KEEP_DB )); then
  die "database of $APP/$ENV_NAME is shared with: $borrowers — repoint them first ('infra attach-db <app> <env> --own') or use --keep-db"
fi
api_users=$(override_dependents API_TARGET "$APP/$ENV_NAME" | paste -sd' ' -)
if [[ -n $api_users ]]; then warn "these are pinned to $APP/$ENV_NAME's API and will lose it: $api_users"; fi

# Only ever drop the database this environment OWNS (never a shared/external one).
DB_NAME=$(db_ident "${APP}_${ENV_NAME}")
TYPE="" BRANCH=""
if [[ -f $STACK_DIR/stack.env ]]; then
  if [[ -f $STACK_DIR/meta.env ]]; then
    TYPE=$(meta_get "$STACK_DIR/meta.env" TYPE)
    BRANCH=$(meta_get "$STACK_DIR/meta.env" BRANCH)
  fi
  load_stack "$APP" "$ENV_NAME"
  log "stopping $STACK"
  "${COMPOSE[@]}" down --volumes --remove-orphans --timeout 30 || warn "compose down reported errors"
else
  # Only ever remove containers that carry BOTH our project name and our managed label.
  warn "no state for $STACK — removing only containers labelled $MANAGED_LABEL in that project"
  foreign=$(foreign_in_project "$STACK")
  [[ -z $foreign ]] || die "project '$STACK' contains containers we did not create ($foreign) — not touching it"
  label="label=com.docker.compose.project=$STACK"
  docker ps -aq --filter "$label" --filter "label=$MANAGED_LABEL" | xargs -r docker rm -f
  docker network ls -q --filter "$label" | xargs -r docker network rm
  docker volume ls -q --filter "$label" | xargs -r docker volume rm
fi
# The environment's private network (compose treats it as external, so it's ours to remove).
remove_stack_network "$(stack_network "$APP" "$ENV_NAME")"

if (( ! KEEP_DB )); then
  db_drop "$DB_NAME" "$DB_NAME"        # IF EXISTS — no-op when it never had its own DB
fi

rm -rf "$STACK_DIR"
rm -f "$(overrides_file "$APP" "$ENV_NAME")"
# Variables set for exactly this preview (pr-12.env, pr-12.api.env) die with it — PR numbers are never reused.
# Long-lived scopes (common, preview, develop, staging, prod) are kept.
if is_preview "$ENV_NAME"; then
  rm -f "$SECRETS_ROOT/$APP/$ENV_NAME.env" "$SECRETS_ROOT/$APP/$ENV_NAME".*.env
fi
rmdir "$DEPLOY_ROOT/$APP" 2>/dev/null || true

if is_preview "$ENV_NAME" && [[ -n $BRANCH && $TYPE != frontend ]]; then
  relink_frontends "$APP" "$BRANCH"
fi

log "OK  $STACK destroyed"
