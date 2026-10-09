#!/usr/bin/env bash
# Simulate GitHub Actions one step at a time, mirroring app-kit/.github/workflows/deploy.yml.
# Run as root (or the deploy user) inside the WSL/VM test host.
#
#   ci-step.sh <repo-dir> plan   [push|pr <n>|close <n>]   # step 1 — compute env, tag, matrix
#   ci-step.sh <repo-dir> build                             # step 2 — build component images
#   ci-step.sh <repo-dir> deploy                            # step 3 — send signed webhook / deploy
#   ci-step.sh <repo-dir> destroy                           # step 3 (close) — destroy preview
#
# State is written to /tmp/ci-step-<APP>.env between steps so you can inspect it.
# The project must be registered first and its secret available (same as ci-local.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=${1:?repo dir}; STEP=${2:?plan|build|deploy|destroy}
REPO_DIR=$(cd "$REPO_DIR" && pwd)
M="$REPO_DIR/.deploy/manifest.env"
[[ -f $M ]] || { echo "no .deploy/manifest.env in $REPO_DIR"; exit 1; }

val() { sed -nE "s/^[[:space:]]*$1=['\"]?([^'\"#[:space:]]*).*/\1/p" "$M" | head -1; }
APP=$(val APP_NAME); TYPE=$(val TYPE); IMG=$(val IMAGE_REPO)
STATE_FILE="/tmp/ci-step-${APP}.env"

set -a; . /etc/infra/infra.env; set +a
S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
export INFRA_WEBHOOK_URL="https://hooks.$DOMAIN$S/webhook"
INFRA_WEBHOOK_SECRET=${INFRA_WEBHOOK_SECRET:-$(cat "/root/.infra-secrets/$APP" 2>/dev/null || true)}
if [[ -z $INFRA_WEBHOOK_SECRET ]]; then
  INFRA_WEBHOOK_SECRET=$(sed -nE "s/^SECRET='([0-9a-f]+)'$/\1/p" "${STATE_DIR:-/var/lib/infra}/projects/$APP.env" 2>/dev/null || true)
fi

git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
sha=$(git -C "$REPO_DIR" rev-parse HEAD); tag="sha-${sha:0:12}"

case $STEP in
# ── Step 1: plan ────────────────────────────────────────────────────────────────
plan)
  EVENT=${3:-push}; N=${4:-}
  case $EVENT in
    push)
      case $branch in
        main)    env_name=prod ;;
        staging) env_name=staging ;;
        develop) env_name=develop ;;
        *) echo "branch '$branch' has no environment — use: $0 $REPO_DIR plan pr <number>"; exit 0 ;;
      esac
      action=deploy ;;
    pr)
      env_name="pr-${N:?PR number}"; action=deploy ;;
    close)
      env_name="pr-${N:?PR number}"; action=destroy ;;
    *) echo "event must be push, pr or close"; exit 1 ;;
  esac

  case $TYPE in
    monolith) comps="app" ;; frontend) comps="web" ;; backend) comps="api" ;; split) comps="web api" ;;
    *) echo "TYPE must be monolith|frontend|backend|split"; exit 1 ;;
  esac

  matrix=""
  for c in $comps; do
    C=${c^^}
    ctx=$(val "${C}_CONTEXT"); ctx=${ctx:-.}
    df=$(val "${C}_DOCKERFILE"); df=${df:-$ctx/Dockerfile}
    matrix="$matrix $c:$ctx:$df"
  done

  cat > "$STATE_FILE" <<EOF
APP=$APP
TYPE=$TYPE
IMG=$IMG
BRANCH=$branch
SHA=$sha
TAG=$tag
ENV_NAME=$env_name
ACTION=$action
COMPS=$comps
MATRIX=$matrix
EOF
  echo "── plan ──────────────────────────────────────────"
  echo "  app       : $APP ($TYPE)"
  echo "  branch    : $branch @ ${sha:0:8}"
  echo "  tag       : $tag"
  echo "  env       : $env_name"
  echo "  action    : $action"
  echo "  components: $comps"
  echo "  state     → $STATE_FILE"
  ;;

# ── Step 2: build ───────────────────────────────────────────────────────────────
build)
  [[ -f $STATE_FILE ]] || { echo "run 'plan' first"; exit 1; }
  set -a; . "$STATE_FILE"; set +a
  [[ $ACTION == deploy ]] || { echo "action is '$ACTION' — nothing to build"; exit 0; }
  echo "── build ─────────────────────────────────────────"
  for entry in $MATRIX; do
    c=${entry%%:*}; rest=${entry#*:}; ctx=${rest%%:*}; df=${rest#*:}
    image="$IMG/$c:$TAG"
    echo "  building  $image"
    echo "  context   $REPO_DIR/$ctx"
    echo "  dockerfile $REPO_DIR/$df"
    docker build -t "$image" -f "$REPO_DIR/$df" "$REPO_DIR/$ctx"
    echo "  ✔ built   $image"
  done
  ;;

# ── Step 3a: deploy ─────────────────────────────────────────────────────────────
deploy)
  [[ -f $STATE_FILE ]] || { echo "run 'plan' first"; exit 1; }
  set -a; . "$STATE_FILE"; set +a
  [[ -n $INFRA_WEBHOOK_SECRET ]] || { echo "project $APP is not registered — add it in the console first"; exit 1; }
  echo "── deploy ────────────────────────────────────────"
  echo "  app : $APP  env : $ENV_NAME  tag : $TAG"
  send=(bash "$HERE/../scripts/webhook-send.sh" --insecure --app "$APP" --repo "local/$APP" --manifest-dir "$REPO_DIR/.deploy")
  result=$("${send[@]}" --action deploy --env "$ENV_NAME" --tag "$TAG" --branch "$BRANCH" --commit "$SHA") || {
    echo "$result" | jq -r '.output // .' 2>/dev/null || echo "$result"; exit 1; }
  echo "$result" | jq -r '"  ✔ \(.status): \(.url)" + (if .upstream_api_url != "" then "   (uses API \(.upstream_api_url))" else "" end)'
  ;;

# ── Step 3b: destroy ────────────────────────────────────────────────────────────
destroy)
  [[ -f $STATE_FILE ]] || { echo "run 'plan' first"; exit 1; }
  set -a; . "$STATE_FILE"; set +a
  [[ -n $INFRA_WEBHOOK_SECRET ]] || { echo "project $APP is not registered — add it in the console first"; exit 1; }
  echo "── destroy ───────────────────────────────────────"
  echo "  app : $APP  env : $ENV_NAME"
  send=(bash "$HERE/../scripts/webhook-send.sh" --insecure --app "$APP" --repo "local/$APP" --manifest-dir "$REPO_DIR/.deploy")
  result=$("${send[@]}" --action destroy --env "$ENV_NAME") || {
    echo "$result" | jq -r '.output // .' 2>/dev/null || echo "$result"; exit 1; }
  echo "$result" | jq -r '"  ✔ \(.status)"'
  ;;

*)
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1 ;;
esac
