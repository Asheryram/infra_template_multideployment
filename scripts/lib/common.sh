#!/usr/bin/env bash
# Shared helpers for every infra script. Source it; don't execute it.
# shellcheck disable=SC1090,SC1091,SC2034

set -Eeuo pipefail
shopt -s nullglob

INFRA_ROOT="${INFRA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
INFRA_ENV_FILE="${INFRA_ENV_FILE:-/etc/infra/infra.env}"
INFRA_SECRETS_FILE="${INFRA_SECRETS_FILE:-/etc/infra/platform.secrets.env}"
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "${0%.sh}")}"

# --------------------------------------------------------------------------- logging

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }
trap 'rc=$?; log "ERROR: command failed (exit $rc) at line $LINENO: $BASH_COMMAND"' ERR

# Print the comment block at the top of the calling script as help text.
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit "${1:-0}"; }

# Mirror stdout/stderr into /var/log/infra/<script>.log (rotated by logrotate).
enable_file_log() {
  [[ -z ${INFRA_NO_FILE_LOG:-} ]] || return 0
  if mkdir -p "$LOG_DIR" 2>/dev/null && [[ -w $LOG_DIR ]]; then
    exec > >(tee -a "$LOG_DIR/$SCRIPT_NAME.log") 2>&1
  fi
}

# --------------------------------------------------------------------------- env files

source_env() {
  [[ -f $1 ]] || die "env file not found: $1"
  set -a; . "$1"; set +a
}

load_infra_env() {
  source_env "$INFRA_ENV_FILE"
  if [[ -r $INFRA_SECRETS_FILE ]]; then source_env "$INFRA_SECRETS_FILE"; fi
  set -a
  : "${DOMAIN:?DOMAIN must be set in $INFRA_ENV_FILE}"
  : "${SERVER_NAME:=$(hostname)}"
  : "${TLS_MODE:=selfsigned}"
  : "${DEPLOY_USER:=deploy}"
  : "${DEPLOY_ROOT:=/srv/deployments}"
  : "${SECRETS_ROOT:=/etc/infra/secrets}"
  : "${BACKUP_DIR:=/srv/backups}"
  : "${BACKUP_RETENTION_DAYS:=7}"
  : "${STATE_DIR:=/var/lib/infra}"
  : "${LOG_DIR:=/var/log/infra}"
  : "${LOCK_DIR:=/run/lock/infra}"
  : "${MAX_PREVIEWS:=8}"
  : "${PREVIEW_TTL_DAYS:=7}"
  : "${PREVIEW_AUTH_ENABLED:=true}"
  : "${PG_CONTAINER:=infra-postgres}"
  : "${DISK_ALERT_PCT:=80}"
  set +a
}

# Write KEY='value' — readable by both `source` and `docker compose --env-file`.
write_kv() {
  local file=$1 key=$2 val=${3-}
  [[ $val != *"'"* && $val != *$'\n'* ]] || die "value for $key contains a quote or newline"
  printf "%s='%s'\n" "$key" "$val" >> "$file"
}

# Read one key from an env file without leaking anything into the caller.
meta_get() { ( set +u; . "$1"; printf '%s' "${!2-}" ); }

cat_existing() {
  local f
  for f in "$@"; do
    if [[ -f $f ]]; then printf '\n# --- from %s\n' "$f"; cat "$f"; printf '\n'; fi
  done
}

# --------------------------------------------------------------------------- naming

validate_name() {
  [[ $2 =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] \
    || die "invalid $1 '$2' (lowercase letters, digits and dashes, max 30 chars)"
}

is_preview() { [[ $1 == pr-* ]]; }
env_class()  { case $1 in pr-*) echo preview ;; *) echo "$1" ;; esac; }
stack_name() { echo "$1-$2"; }
stack_dir()  { echo "$DEPLOY_ROOT/$1/$2"; }

# Postgres-safe identifier: shop-api + pr-42 → shop_api_pr_42
db_ident() {
  local s
  s=$(tr '[:upper:]-' '[:lower:]_' <<<"$1")
  s=${s//[^a-z0-9_]/_}
  echo "${s:0:63}"
}

components_for() {
  case $1 in
    monolith) echo app ;;
    frontend) echo web ;;
    backend)  echo api ;;
    split)    echo "web api" ;;
    *) die "unknown TYPE '$1' (expected monolith | frontend | backend | split)" ;;
  esac
}

default_port() { case $1 in app) echo 3000 ;; web) echo 80 ;; api) echo 8080 ;; esac; }

# --------------------------------------------------------------------------- stacks

# Sets STACK, STACK_DIR and the COMPOSE command array for an existing deployment.
# Compose runs with a clean environment so only stack.env drives interpolation.
load_stack() {
  STACK=$(stack_name "$1" "$2")
  STACK_DIR=$(stack_dir "$1" "$2")
  [[ -f $STACK_DIR/stack.env && -f $STACK_DIR/compose-files ]] \
    || die "no deployment found for $1/$2 (looked in $STACK_DIR)"
  COMPOSE=(env -i "PATH=$PATH" "HOME=${HOME:-/root}" docker compose
           -p "$STACK" --project-directory "$STACK_DIR" --env-file "$STACK_DIR/stack.env")
  local line
  while IFS= read -r line; do
    case $line in
      tpl:*)   COMPOSE+=(-f "$INFRA_ROOT/templates/${line#tpl:}") ;;
      stack:*) COMPOSE+=(-f "$STACK_DIR/${line#stack:}") ;;
      '') ;;
      *) die "bad entry in $STACK_DIR/compose-files: $line" ;;
    esac
  done < "$STACK_DIR/compose-files"
}

count_previews() {
  local n=0 m
  for m in "$DEPLOY_ROOT"/*/pr-*/meta.env; do n=$((n + 1)); done
  echo "$n"
}

acquire_lock() {
  mkdir -p "$LOCK_DIR"
  exec 9>"$LOCK_DIR/$1.lock"
  flock -w "${2:-600}" 9 || die "timed out waiting for lock '$1' (another deploy running?)"
}

# Run another infra script with a clean environment (no leaked manifest variables).
run_clean() {
  env -i "PATH=$PATH" "HOME=${HOME:-/root}" "INFRA_ROOT=$INFRA_ROOT" \
    "INFRA_ENV_FILE=$INFRA_ENV_FILE" "INFRA_SECRETS_FILE=$INFRA_SECRETS_FILE" \
    bash "$@"
}

# Redeploy frontend previews that track <backend_app> on <branch>, so they pick up
# a newly created (or just destroyed) backend preview. Skips ones already on <url>.
relink_frontends() {
  local backend=$1 branch=$2 current=${3:-} meta app env
  for meta in "$DEPLOY_ROOT"/*/pr-*/meta.env; do
    [[ $(meta_get "$meta" TYPE) == frontend ]] || continue
    [[ $(meta_get "$meta" BACKEND_APP) == "$backend" ]] || continue
    [[ $(meta_get "$meta" BRANCH) == "$branch" ]] || continue
    if [[ -n $current && $(meta_get "$meta" UPSTREAM_API_URL) == "$current" ]]; then continue; fi
    app=$(meta_get "$meta" APP)
    env=$(meta_get "$meta" ENV_NAME)
    log "relinking frontend $app/$env (branch '$branch' → backend $backend)"
    run_clean "$INFRA_ROOT/scripts/deploy.sh" --app "$app" --env "$env" --redeploy --no-pull \
      || warn "relink of $app/$env failed"
  done
}

registry_login() {
  [[ -n ${REGISTRY_USER:-} && -n ${REGISTRY_TOKEN:-} ]] || return 0
  printf '%s' "$REGISTRY_TOKEN" \
    | docker login "${REGISTRY:-ghcr.io}" -u "$REGISTRY_USER" --password-stdin >/dev/null
}

# --------------------------------------------------------------------------- alerts

# Posts to ALERT_WEBHOOK_URL. Payload works for Slack, Discord, Teams and Mattermost.
alert() {
  local msg="[$SERVER_NAME] $*"
  log "ALERT: $*"
  [[ -n ${ALERT_WEBHOOK_URL:-} ]] || return 0
  curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg t "$msg" '{text: $t, content: $t}')" \
    "$ALERT_WEBHOOK_URL" >/dev/null || warn "alert webhook failed"
}

# Same as alert, but at most once per ALERT_REPEAT_MINUTES for a given key.
alert_throttled() {
  local key=$1; shift
  local f="$STATE_DIR/alerts/$key" now
  now=$(date +%s)
  mkdir -p "$STATE_DIR/alerts"
  if [[ -f $f ]] && (( now - $(<"$f") < ${ALERT_REPEAT_MINUTES:-60} * 60 )); then return 0; fi
  echo "$now" > "$f"
  alert "$@"
}

alert_clear() { rm -f "$STATE_DIR/alerts/$1"; }
