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
  : "${HOST_MODE:=shared}"
  : "${STACK_PREFIX:=infra}"
  : "${TRAEFIK_BIND:=0.0.0.0}"
  : "${TRAEFIK_HTTP_PORT:=80}"
  : "${TRAEFIK_HTTPS_PORT:=443}"
  # TLS_MODE=external: the host's existing proxy terminates TLS and forwards plain HTTP to Traefik.
  if [[ $TLS_MODE == external ]]; then ROUTER_TLS=false; else ROUTER_TLS=true; fi
  # Public URLs need the port when Traefik can't have 443 (e.g. https://shop.example.com:8443).
  URL_PORT_SUFFIX=""
  if [[ $TLS_MODE != external && $TRAEFIK_HTTPS_PORT != 443 ]]; then URL_PORT_SUFFIX=":$TRAEFIK_HTTPS_PORT"; fi
  set +a
}

# Write KEY='value' — readable by both `source` and `docker compose --env-file`.
write_kv() {
  local file=$1 key=$2 val=${3-}
  [[ $val != *"'"* && $val != *$'\n'* ]] || die "value for $key contains a quote or newline"
  printf "%s='%s'\n" "$key" "$val" >> "$file"
}

# Parse a repo's manifest.env WITHOUT executing it. The manifest comes from the app repo — on a
# multi-tenant host it is untrusted input, so it's never `source`d. Only known keys are accepted,
# values are taken literally (no $(), no ${}, no backticks), and every value is format-checked.
MANIFEST_KEYS='^(APP_NAME|TYPE|IMAGE_REPO|MIGRATE_CMD|MIGRATE_SERVICE|PREVIEW_AUTH|API_PREVIEW_AUTH|EXTRA_MIDDLEWARES|PREVIEW_MEM_LIMIT|MAX_PREVIEWS_PER_APP|WATCH_PATHS|(APP|WEB|API)_(IMAGE|PORT|MEM_LIMIT|CPUS|CONTEXT|DOCKERFILE|REQUIRED_ENV)|(APP|WEB|API)_HOST_[A-Z0-9_]+)$'
load_manifest() {
  local file=$1 line key val n=0
  [[ -f $file ]] || die "manifest not found: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] \
      || die "manifest line $n: not KEY=value: $line"
    key=${BASH_REMATCH[2]}; val=${BASH_REMATCH[3]}
    if [[ $val =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then val=${BASH_REMATCH[1]}
    elif [[ $val =~ ^\"([^\"\$\`\\]*)\"[[:space:]]*(#.*)?$ ]]; then val=${BASH_REMATCH[1]}
    else
      val=${val%%[[:space:]]#*}; val=${val%"${val##*[![:space:]]}"}
      [[ $val != *[\$\`\"\'\\]* ]] || die "manifest line $n ($key): quote values containing special characters with '…'"
    fi
    if [[ ! $key =~ $MANIFEST_KEYS ]]; then warn "manifest: ignoring unknown key $key"; continue; fi
    case $key in
      APP_NAME)                [[ -z $val || $val =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] ;;
      TYPE)                    [[ $val =~ ^(monolith|frontend|backend|split)$ ]] ;;
      *_PORT)                  [[ $val =~ ^[0-9]{1,5}$ ]] ;;
      *_MEM_LIMIT)             [[ $val =~ ^[0-9]+[kmgKMG]?$ ]] ;;
      *_CPUS)                  [[ $val =~ ^[0-9]+(\.[0-9]+)?$ ]] ;;
      *_HOST_*)                [[ $val =~ ^[a-z0-9.-]+$ ]] ;;
      IMAGE_REPO|*_IMAGE)      [[ -z $val || $val =~ ^[a-zA-Z0-9._/:@{}-]+$ ]] ;;
      EXTRA_MIDDLEWARES)       [[ -z $val || $val =~ ^[a-zA-Z0-9@,_-]+$ ]] ;;
      PREVIEW_AUTH|API_PREVIEW_AUTH) [[ $val =~ ^(true|false)$ ]] ;;
      MAX_PREVIEWS_PER_APP) [[ $val =~ ^[0-9]+$ ]] ;;
      *)                       true ;;
    esac || die "manifest line $n: invalid value for $key: $val"
    printf -v "$key" '%s' "$val"
  done < "$file"
}

# Read one key from an env file without leaking anything into the caller.
meta_get() { ( set +u; . "$1"; printf '%s' "${!2-}" ); }

cat_existing() {
  local f line key
  local platform_keys=' APP_NAME APP_ENV ENV_CLASS IS_PREVIEW PORT PUBLIC_URL INFRA_DOMAIN IMAGE_TAG GIT_BRANCH GIT_COMMIT '
  for f in "$@"; do
    if [[ -f $f ]]; then
      printf '\n# --- from %s\n' "$f"
      while IFS= read -r line || [[ -n $line ]]; do
        key=${line%%=*}
        key=${key#export }
        if [[ $line == *=* && $platform_keys == *" $key "* ]]; then
          warn "ignoring platform-managed variable $key in $f"
          continue
        fi
        printf '%s\n' "$line"
      done < "$f"
      printf '\n'
    fi
  done
}

# --------------------------------------------------------------------------- naming

validate_name() {
  [[ $2 =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] \
    || die "invalid $1 '$2' (lowercase letters, digits and dashes, max 30 chars)"
}

is_preview() { [[ $1 == pr-* ]]; }
env_class()  { case $1 in pr-*) echo preview ;; *) echo "$1" ;; esac; }
# Compose project name. The prefix keeps us clear of other people's projects on a shared host.
stack_name() { echo "$STACK_PREFIX-$1-$2"; }
stack_dir()  { echo "$DEPLOY_ROOT/$1/$2"; }

# Every container we create carries this label; nothing without it is ever touched.
MANAGED_LABEL="infra.managed=true"

# IDs of containers in compose project $1 that we did NOT create.
foreign_in_project() {
  local id
  for id in $(docker ps -aq --filter "label=com.docker.compose.project=$1"); do
    if [[ $(docker inspect -f '{{index .Config.Labels "infra.managed"}}' "$id") != true ]]; then echo "$id"; fi
  done
}

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
  COMPOSE=(env -i "PATH=$PATH" "HOME=${HOME:-/root}" "DOCKER_CONFIG=${DOCKER_CONFIG:-${HOME:-/root}/.docker}" docker compose
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

# ----------------------------------------------------------------------------- per-environment networks
# Every environment gets its own private bridge network "<stack>_net". Only that environment's
# containers, Traefik, and (if it uses the DB) Postgres are on it — so no app can reach another
# project's or another environment's containers directly, bypassing Traefik and preview auth.
# Traefik/Postgres connections are made at runtime; `infra networks reconnect` restores them
# after the platform containers are recreated.

TRAEFIK_CONTAINER=infra-traefik
stack_network() { echo "$(stack_name "$1" "$2")_net"; }

net_has()        { docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }
net_connect()    { net_has "$1" "$2" || docker network connect "$1" "$2"; }
net_disconnect() { if net_has "$1" "$2"; then docker network disconnect "$1" "$2"; fi; }

# ensure_stack_network <net> <app> <env> <uses_pg:true|false>
ensure_stack_network() {
  local net=$1 app=$2 env=$3 uses_pg=$4
  if docker network inspect "$net" >/dev/null 2>&1; then
    [[ $(docker network inspect -f '{{index .Labels "infra.managed"}}' "$net") == true ]] \
      || die "network $net exists and was not created by infra — not touching it"
  else
    docker network create --driver bridge --label infra.managed=true \
      --label "infra.app=$app" --label "infra.env=$env" "$net" >/dev/null
  fi
  net_connect "$net" "$TRAEFIK_CONTAINER"
  if [[ $uses_pg == true ]]; then net_connect "$net" "$PG_CONTAINER"; else net_disconnect "$net" "$PG_CONTAINER"; fi
}

remove_stack_network() {
  local net=$1
  docker network inspect "$net" >/dev/null 2>&1 || return 0
  [[ $(docker network inspect -f '{{index .Labels "infra.managed"}}' "$net") == true ]] || return 0
  net_disconnect "$net" "$TRAEFIK_CONTAINER"
  net_disconnect "$net" "$PG_CONTAINER"
  docker network rm "$net" >/dev/null || warn "could not remove network $net (still in use?)"
}

# Remember images that weren't on the host before we pulled them — cleanup only ever
# removes images from this list, never anything another user pulled.
record_owned_images() {
  local img
  mkdir -p "$STATE_DIR"
  for img in "$@"; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "$(date +%s) $img" >> "$STATE_DIR/owned-images"
    fi
  done
}

registry_login() {
  # A registered project can bring its own pull token (private images in its own org).
  # It gets a separate Docker config so projects never share or overwrite credentials.
  local user=${REGISTRY_USER:-} token=${REGISTRY_TOKEN:-} pf="$STATE_DIR/projects/${APP:-none}.env"
  if [[ -f $pf && -n $(meta_get "$pf" REGISTRY_TOKEN) ]]; then
    user=$(meta_get "$pf" REGISTRY_USER); token=$(meta_get "$pf" REGISTRY_TOKEN)
    export DOCKER_CONFIG="$STATE_DIR/docker/$APP"
    mkdir -p "$DOCKER_CONFIG"; chmod 700 "$DOCKER_CONFIG"
  fi
  [[ -n $user && -n $token ]] || return 0
  printf '%s' "$token" | docker login "${REGISTRY:-ghcr.io}" -u "$user" --password-stdin >/dev/null
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
