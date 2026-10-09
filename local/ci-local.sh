#!/usr/bin/env bash
# Play GitHub Actions for a LOCAL repo: build its image(s) from the current commit on this server,
# then send the same signed webhook the real workflow sends. Run as root inside the WSL test host.
#
#   ci-local.sh <repo-dir> push              deploy the checked-out branch (develop/staging/main only)
#   ci-local.sh <repo-dir> pr <number>       deploy the checked-out branch as preview pr-<number>
#   ci-local.sh <repo-dir> close <number>    destroy preview pr-<number>
#
# The project must be registered first:  sudo -u deploy infra project add <APP_NAME> --repo local/<APP_NAME>
# and its secret saved:                   echo '<secret>' > /root/.infra-secrets/<APP_NAME>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=${1:?repo dir}; EVENT=${2:?push|pr|close}; N=${3:-}
REPO_DIR=$(cd "$REPO_DIR" && pwd)
M="$REPO_DIR/.deploy/manifest.env"
[[ -f $M ]] || { echo "no .deploy/manifest.env in $REPO_DIR"; exit 1; }

val() { sed -nE "s/^[[:space:]]*$1=['\"]?([^'\"#[:space:]]*).*/\1/p" "$M" | head -1; }
APP=$(val APP_NAME); TYPE=$(val TYPE); IMG=$(val IMAGE_REPO)
set -a; . /etc/infra/infra.env; set +a
S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
export INFRA_WEBHOOK_URL="https://hooks.$DOMAIN$S/webhook"
export INFRA_WEBHOOK_SECRET=${INFRA_WEBHOOK_SECRET:-$(cat "/root/.infra-secrets/$APP" 2>/dev/null || true)}
[[ -n $INFRA_WEBHOOK_SECRET ]] || { echo "no secret for $APP — save it to /root/.infra-secrets/$APP (from 'infra project add')"; exit 1; }

git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
sha=$(git -C "$REPO_DIR" rev-parse HEAD); tag="sha-${sha:0:12}"
if [[ -n $(git -C "$REPO_DIR" status --porcelain) ]]; then echo "note: uncommitted changes are included in this build"; fi

case $EVENT in
  push)
    case $branch in main) env=prod ;; staging) env=staging ;; develop) env=develop ;;
      *) echo "branch '$branch' has no environment — open a PR instead: $0 $REPO_DIR pr <number>"; exit 0 ;; esac ;;
  pr)    env="pr-${N:?PR number}" ;;
  close) env="pr-${N:?PR number}" ;;
  *) echo "event must be push, pr or close"; exit 1 ;;
esac

send=(bash "$HERE/../scripts/webhook-send.sh" --insecure --app "$APP" --repo "local/$APP" --manifest-dir "$REPO_DIR/.deploy")
if [[ $EVENT == close ]]; then
  echo "▶ PR #$N closed → destroying $APP/$env"
  "${send[@]}" --action destroy --env "$env" | jq -r '.status'
  exit
fi

case $TYPE in monolith) comps=app ;; frontend) comps=web ;; backend) comps=api ;; split) comps="web api" ;; esac
for c in $comps; do
  ctx=$(val "${c^^}_CONTEXT"); ctx=${ctx:-.}
  echo "▶ build $IMG/$c:$tag  ($branch @ ${sha:0:8})"
  docker build -q -t "$IMG/$c:$tag" "$REPO_DIR/$ctx" >/dev/null
done
echo "▶ signed webhook → deploy $APP/$env"
result=$("${send[@]}" --action deploy --env "$env" --tag "$tag" --branch "$branch" --commit "$sha") || {
  echo "$result" | jq -r '.output // .' 2>/dev/null || echo "$result"; exit 1; }
echo "$result" | jq -r '"✔ \(.status): \(.url)" + (if .upstream_api_url != "" then "   (uses API \(.upstream_api_url))" else "" end)'
