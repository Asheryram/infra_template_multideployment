#!/usr/bin/env bash
# Remove one environment: containers, volumes, database, and its state directory.
#
#   infra destroy --app <app> --env <env> [--keep-db]
#   infra destroy --app <app> --env prod --i-really-mean-prod
#
# Refused while another environment's variables still point at this environment's database.
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

# Other environments whose variables point at THIS environment's database (set by DevOps,
# e.g. a preview using develop's DB). Dropping it would break them.
# Every database this environment created: whatever has a password file (declared in infra.yml and created
# through `infra db create`), plus what the last deploy recorded. Declared-but-never-created ones are not touched.
DB_NAMES=()
[[ -f $STACK_DIR/meta.env ]] && read -r -a DB_NAMES <<< "$(meta_get "$STACK_DIR/meta.env" DB_LIST)"
for pwf in "$STACK_DIR"/.db_password_*; do [[ -e $pwf ]] && DB_NAMES+=("${pwf##*/.db_password_}"); done
for DB_NAME in "${DB_NAMES[@]}"; do
  users=""
  for f in "$SECRETS_ROOT"/*/*.env "$DEPLOY_ROOT"/*/*/runtime/*.env; do
    case $f in "$STACK_DIR"/*|"$SECRETS_ROOT/$APP/$ENV_NAME".*) continue ;; esac
    if grep -qE "@$PG_CONTAINER(:[0-9]+)?/$DB_NAME([?[:space:]]|$)" "$f" 2>/dev/null; then f=${f#"$SECRETS_ROOT/"}; users+=" ${f#"$DEPLOY_ROOT/"}"; fi
  done
  if [[ -n $users ]] && (( ! KEEP_DB )); then
    die "other environments' variables use the database $DB_NAME:$users — change them first, or use --keep-db"
  fi
done

# Only ever drop the database this environment OWNS (never a shared/external one).
BRANCH=""
if [[ -f $STACK_DIR/stack.env ]]; then
  if [[ -f $STACK_DIR/meta.env ]]; then
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
  for DB_NAME in "${DB_NAMES[@]}"; do db_drop "$DB_NAME" "$DB_NAME"; done   # IF EXISTS — only databases this env created
fi

rm -rf "$STACK_DIR"
# Variables set for exactly this preview (pr-12.env, pr-12.api.env) die with it — PR numbers are never reused.
# Long-lived scopes (common, preview, develop, staging, prod) are kept.
if is_preview "$ENV_NAME"; then
  rm -f "$SECRETS_ROOT/$APP/$ENV_NAME.env" "$SECRETS_ROOT/$APP/$ENV_NAME".*.env
fi
rmdir "$DEPLOY_ROOT/$APP" 2>/dev/null || true

log "OK  $STACK destroyed"
