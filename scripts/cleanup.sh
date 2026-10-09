#!/usr/bin/env bash
# Nightly housekeeping (cron):
#   1. destroy previews whose PR is closed (needs GH_TOKEN) or older than PREVIEW_TTL_DAYS
#   2. remove images WE pulled that are no longer used (never touches other users' images)
#
#   infra cleanup [--dry-run]
SCRIPT_NAME=cleanup
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/db.sh
source "$INFRA_ROOT/scripts/lib/db.sh"

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

# Orphaned stacks: a directory exists under DEPLOY_ROOT with no meta.env and no running containers.
# This happens when a first deploy fails before writing meta.env (OOM, image pull error, etc.).
# The DB and role may have been provisioned — clean them up too.
for stack_dir in "$DEPLOY_ROOT"/*/*; do
  [[ -d $stack_dir ]] || continue
  app=$(basename "$(dirname "$stack_dir")")
  env=$(basename "$stack_dir")
  [[ -f $stack_dir/meta.env ]] && continue          # normal deployment, skip
  [[ -f $stack_dir/status.env ]] && continue        # blocked deploy waiting for secrets, skip
  # No meta and no status — check if any containers are running for this stack.
  stack=$(stack_name "$app" "$env")
  running=$(docker ps -q --filter "label=com.docker.compose.project=$stack" --filter "label=$MANAGED_LABEL" 2>/dev/null | wc -l)
  (( running == 0 )) || continue
  if (( DRY )); then
    log "[dry-run] would clean orphaned stack $app/$env (no meta.env, no running containers)"
  else
    log "cleaning orphaned stack $app/$env (failed first deploy)"
    db=$(db_ident "${app}_${env}")
    db_drop "$db" "$db"
    rm -rf "$stack_dir"
    rmdir "$DEPLOY_ROOT/$app" 2>/dev/null || true
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

# DB sprawl report: log how many databases exist per app vs how many environments are deployed.
# Surfaces orphaned DBs before they become a disk problem.
if pg_running; then
  log "--- database summary ---"
  for app_dir in "$DEPLOY_ROOT"/*/; do
    app=$(basename "$app_dir")
    deployed=$(find "$app_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    db_count=$(sql_scalar "SELECT count(*) FROM pg_database WHERE datname LIKE '$(db_ident "$app")%' AND NOT datistemplate" 2>/dev/null || echo '?')
    db_size=$(sql_scalar "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database WHERE datname LIKE '$(db_ident "$app")%' AND NOT datistemplate" 2>/dev/null || echo '?')
    log "  $app: $deployed environment(s) deployed, $db_count database(s), total $db_size"
  done
fi
