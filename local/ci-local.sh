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
M="$REPO_DIR/.infradeploy/infra.yml"
[[ -f $M ]] || { echo "no .infradeploy/infra.yml in $REPO_DIR"; exit 1; }

val() { python3 "$HERE/../scripts/parse-manifest.py" "$M" | sed -nE "s/^$1='(.*)'$/\1/p"; }
APP=$(val APP_NAME); SERVICES=$(val SERVICES)
set -a; . /etc/infra/infra.env; set +a
S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
export INFRA_WEBHOOK_URL="https://hooks.$DOMAIN$S/webhook"
# Real GitHub keeps the secret as a repo secret. Locally this script runs ON the server, so it can
# read the project's secret straight from the registry — register the project in the console and go.
export INFRA_WEBHOOK_SECRET=${INFRA_WEBHOOK_SECRET:-$(cat "/root/.infra-secrets/$APP" 2>/dev/null || true)}
if [[ -z $INFRA_WEBHOOK_SECRET ]]; then
  INFRA_WEBHOOK_SECRET=$(sed -nE "s/^SECRET='([0-9a-f]+)'$/\1/p" "${STATE_DIR:-/var/lib/infra}/projects/$APP.env" 2>/dev/null || true)
fi
[[ -n $INFRA_WEBHOOK_SECRET ]] || { echo "project $APP is not registered — add it in the console (Projects tab) first"; exit 1; }

# the repo the project is registered with (the webhook only accepts that one); override with INFRA_REPO
REPO=${INFRA_REPO:-$(sed -nE "s/^REPO='(.*)'$/\1/p" "${STATE_DIR:-/var/lib/infra}/projects/$APP.env" 2>/dev/null || true)}
REPO=${REPO:-local/$APP}
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

send=(bash "$HERE/../scripts/webhook-send.sh" --insecure --app "$APP" --repo "$REPO" --manifest-dir "$REPO_DIR/.infradeploy")
if [[ $EVENT == close ]]; then
  echo "▶ PR #$N closed → destroying $APP/$env"
  "${send[@]}" --action destroy --env "$env" | jq -r '.status'
  exit
fi

for svc in $SERVICES; do
  S=${svc^^}; S=${S//-/_}
  img=$(val "${S}_IMAGE"); ctx=$(val "${S}_BUILD_CONTEXT"); ctx=${ctx:-.}
  df=$(val "${S}_DOCKERFILE"); df=${df:-$ctx/Dockerfile}
  echo "▶ build $img:$tag  ($branch @ ${sha:0:8})"
  docker build -q -t "$img:$tag" -f "$REPO_DIR/$df" "$REPO_DIR/$ctx" >/dev/null
done
echo "▶ signed webhook → deploy $APP/$env"
result=$("${send[@]}" --action deploy --env "$env" --tag "$tag" --branch "$branch" --commit "$sha") || {
  echo "$result" | jq -r '.output // .' 2>/dev/null || echo "$result"; exit 1; }
echo "$result" | jq -r '"✔ \(.status): \(.url)"'
