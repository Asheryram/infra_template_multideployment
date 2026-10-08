#!/usr/bin/env bash
# Nightly housekeeping (cron):
#   1. destroy previews whose PR is closed (needs GH_TOKEN) or older than PREVIEW_TTL_DAYS
#   2. remove images WE pulled that are no longer used (never touches other users' images)
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

# No global `docker * prune` — this host may run other people's containers.
# We only remove images WE pulled (recorded in owned-images) that no container uses
# and that we haven't pulled for PRUNE_IMAGES_DAYS. Our networks/volumes are already
# removed by `compose down -v` in destroy.
f="$STATE_DIR/owned-images"
if [[ -f $f ]]; then
  cutoff=$(( now - ${PRUNE_IMAGES_DAYS:-7} * 86400 ))
  in_use=$(docker ps -a --format '{{.Image}}' | sort -u)
  removed=0
  : > "$f.tmp"
  # newest record per image only
  while read -r ts img; do
    if grep -qxF "$img" <<<"$in_use" || (( ts > cutoff )); then echo "$ts $img" >> "$f.tmp"; continue; fi
    if ! docker image inspect "$img" >/dev/null 2>&1; then continue; fi        # already gone
    if (( DRY )); then
      log "[dry-run] would remove image $img"; echo "$ts $img" >> "$f.tmp"
    elif docker rmi "$img" >/dev/null 2>&1; then
      log "removed image $img"; removed=$((removed + 1))
    else
      echo "$ts $img" >> "$f.tmp"
    fi
  done < <(sort -k1,1nr "$f" | awk '!seen[$2]++')
  mv "$f.tmp" "$f"
  log "removed $removed image(s) we owned"
fi

log "OK  disk now: $(df -h --output=pcent / | tail -1 | tr -d ' ') used"
