#!/usr/bin/env bash
# Nightly housekeeping (cron):
#   1. destroy previews whose PR is closed (needs GH_TOKEN) or older than PREVIEW_TTL_DAYS
#   2. prune unused Docker images, build cache, networks and anonymous volumes
#
#   infra cleanup [--dry-run]
SCRIPT_NAME=cleanup
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DRY=0
case ${1:-} in
  --dry-run) DRY=1 ;;
  -h|--help) usage ;;
esac
load_infra_env
enable_file_log

pr_is_closed() { # repo number → 0 if GitHub says the PR is closed
  [[ -n ${GH_TOKEN:-} && -n $1 ]] || return 1
  local state
  state=$(curl -fsS -m 10 -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$1/pulls/$2" | jq -r .state) || return 1
  [[ $state == closed ]]
}

now=$(date +%s)
ttl=$((PREVIEW_TTL_DAYS * 86400))
for meta in "$DEPLOY_ROOT"/*/pr-*/meta.env; do
  app=$(meta_get "$meta" APP)
  env=$(meta_get "$meta" ENV_NAME)
  age=$(( now - $(meta_get "$meta" DEPLOYED_AT) ))
  reason=""
  if pr_is_closed "$(meta_get "$meta" REPO)" "${env#pr-}"; then
    reason="PR closed"
  elif (( age > ttl )); then
    reason="not deployed for $((age / 86400)) days"
  fi
  [[ -n $reason ]] || continue
  if (( DRY )); then
    log "[dry-run] would destroy $app/$env ($reason)"
  else
    log "destroying $app/$env ($reason)"
    run_clean "$INFRA_ROOT/scripts/destroy.sh" --app "$app" --env "$env" || warn "failed to destroy $app/$env"
  fi
done

if (( DRY )); then
  log "[dry-run] skipping docker prune"
  exit 0
fi

log "pruning docker"
docker image prune -af --filter "until=${PRUNE_IMAGES_OLDER_THAN:-168h}" | tail -n1
docker builder prune -af --filter "until=168h" | tail -n1 || true
docker network prune -f >/dev/null
docker volume prune -f | tail -n1           # anonymous volumes only (Docker >= 23)
log "OK  disk now: $(df -h --output=pcent / | tail -1 | tr -d ' ') used"
