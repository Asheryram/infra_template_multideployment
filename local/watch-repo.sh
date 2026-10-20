#!/usr/bin/env bash
# GitOps poller — watches every registered project's real GitHub repo and deploys
# automatically on every push, exactly as the app-kit GitHub Actions workflow would.
#
# Reads /var/lib/infra/projects/*.env on every cycle, so newly registered projects
# are picked up without restarting this script.
#
# For each project it polls GitHub every INTERVAL seconds:
#   push to PROD_BRANCH   → deploy prod      (only if 'prod'    in project ENVS)
#   push to staging       → deploy staging   (only if 'staging' in project ENVS)
#   push to develop       → deploy develop   (only if 'develop' in project ENVS)
#   new commit on open PR → deploy pr-<n>    (only if 'preview' in project ENVS)
#   PR closed             → destroy pr-<n>
#
# Usage (run as the deploy user inside the VM/WSL):
#   bash /opt/infra/local/watch-repo.sh [--interval 30] [--app shop-api] [--once]
#
#   --interval <s>   poll every <s> seconds (default: 30)
#   --app <name>     watch only this one registered project (default: all)
#   --once           one poll cycle then exit (useful for testing)
#
# For private repos: add --gh-token when registering the project (infra project add ... --gh-token ghp_xxx)
# Public repos need no token.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$HERE/.." && pwd)"

INTERVAL=30; FILTER_APP=""; ONCE=0
while (( $# )); do
  case $1 in
    --interval) INTERVAL=${2:?}; shift 2 ;;
    --app)      FILTER_APP=${2:?}; shift 2 ;;
    --once)     ONCE=1; shift ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

# ── load platform config ────────────────────────────────────────────────────
set -a; . /etc/infra/infra.env; set +a

PROJECTS_DIR="${STATE_DIR:-/var/lib/infra}/projects"
POLL_STATE="/tmp/infra-gitops"
mkdir -p "$POLL_STATE"

S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
WEBHOOK_BASE=${INFRA_GITOPS_WEBHOOK_BASE:-"https://hooks.$DOMAIN$S"}

log()  { printf '\033[36m[%s gitops]\033[0m %s\n'   "$(date '+%H:%M:%S')" "$*"; }
ok()   { printf '\033[32m[%s gitops]\033[0m ✔ %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\033[33m[%s gitops]\033[0m ⚠ %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
err()  { printf '\033[31m[%s gitops]\033[0m ✘ %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# ── GitHub API (token is per-project, empty = public repo) ─────────────────
gh() {  # token path → json
  local token=$1 path=$2
  local auth=()
  [[ -n $token ]] && auth=(-H "Authorization: Bearer $token")
  curl -fsSL --max-time 15 \
    "${auth[@]}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com$path"
}

gh_branch_sha() {  # token owner/repo branch → sha or empty
  gh "$1" "/repos/$2/branches/$3" 2>/dev/null | jq -r '.commit.sha // empty'
}

gh_open_prs() {  # token owner/repo → [{number, branch, sha}]
  gh "$1" "/repos/$2/pulls?state=open&per_page=100" 2>/dev/null \
    | jq -c '[.[] | {number:.number, branch:.head.ref, sha:.head.sha}]'
}

gh_file() {  # token owner/repo ref path → decoded content or empty
  gh "$1" "/repos/$2/contents/$4?ref=$3" 2>/dev/null | jq -r '.content // empty' | base64 -d 2>/dev/null || true
}

# ── manifest value parser ───────────────────────────────────────────────────
mval() { sed -nE "s/^[[:space:]]*$1=['\"]?([^'\"#[:space:]]*).*/\1/p" <<< "$2" | head -1; }

components_for() {
  case $1 in monolith) echo app;; frontend) echo web;; backend) echo api;; split) echo "web api";; esac
}

# ── build one component image from GitHub source ────────────────────────────
build_component() {  # token repo branch component context dockerfile image
  local token=$1 repo=$2 branch=$3 comp=$4 ctx=$5 df=$6 image=$7
  local clone_dir; clone_dir=$(mktemp -d)
  local clone_error; clone_error=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -rf '$clone_dir' '$clone_error'" RETURN

  local clone_url
  if [[ -n $token ]]; then
    clone_url="https://x-access-token:${token}@github.com/$repo.git"
  else
    clone_url="https://github.com/$repo.git"
  fi

  log "  clone $repo ($branch) for $comp"
  if ! git clone -q --depth 1 --branch "$branch" "$clone_url" "$clone_dir" 2>"$clone_error"; then
    err "  clone failed: $repo @ $branch"
    while IFS= read -r line; do
      [[ -n $token ]] && line=${line//"$token"/[REDACTED]}
      line=${line//"$clone_url"/"https://github.com/$repo.git"}
      err "    $line"
    done < "$clone_error"
    return 1
  fi

  log "  build $image"
  docker build -q -t "$image" -f "$clone_dir/$df" "$clone_dir/$ctx" >/dev/null \
    || { err "  build failed: $image"; return 1; }
  ok "  built $image"
}


# ── deploy or destroy via signed webhook ────────────────────────────────────
fire_webhook() {  # secret app repo action env [tag branch sha manifest_dir]
  local secret=$1 app=$2 repo=$3 action=$4 env=$5; shift 5
  local args=(bash "$INFRA_ROOT/scripts/webhook-send.sh" --insecure
    --app "$app" --repo "$repo" --action "$action" --env "$env")
  [[ $action == deploy ]] && args+=("$@")
  INFRA_WEBHOOK_URL="$WEBHOOK_BASE/webhook" INFRA_WEBHOOK_SECRET="$secret" \
    "${args[@]}" 2>/dev/null
}

# ── handle one branch/PR change ─────────────────────────────────────────────
deploy_ref() {  # token app secret repo env branch sha
  local token=$1 app=$2 secret=$3 repo=$4 env=$5 branch=$6 sha=$7
  local tag="sha-${sha:0:12}"

  log "$app: $branch → $env ($tag)"

  # fetch manifest from GitHub at this exact sha
  local manifest; manifest=$(gh_file "$token" "$repo" "$sha" ".infradeploy/infra.yml")
  if [[ -z $manifest ]]; then
    warn "$app: no .infradeploy/infra.yml at $sha — skipping"
    return 1
  fi
  local mdir; mdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$mdir'" RETURN
  echo "$manifest" > "$mdir/infra.yml"
  # The per-environment settings that live next to it (.infradeploy/env/*.env), from the SAME commit. The webhook sends the
  # whole folder; without this the watcher sent only infra.yml and every setting in those files was silently ignored.
  local envlist envname
  envlist=$(gh "$token" "/repos/$repo/contents/.infradeploy/env?ref=$sha" 2>/dev/null \
            | jq -r '.[]? | select(.type == "file") | .name' 2>/dev/null) || envlist=""
  if [[ -n $envlist ]]; then
    mkdir -p "$mdir/env"
    while IFS= read -r envname; do
      [[ $envname =~ ^[A-Za-z0-9._-]+\.env$ ]] || continue
      gh_file "$token" "$repo" "$sha" ".infradeploy/env/$envname" > "$mdir/env/$envname"
    done <<< "$envlist"
  fi
  local parsed; parsed=$(python3 "$INFRA_ROOT/scripts/parse-manifest.py" "$mdir/infra.yml")     || { err "$app: infra.yml is invalid"; return 1; }

  # build each service (the parsed output is shell-quoted by the validating parser)
  local SERVICES
  eval "$parsed"
  local svc S
  for svc in $SERVICES; do
    S=${svc^^}; S=${S//-/_}
    local img_var="${S}_IMAGE" ctx_var="${S}_BUILD_CONTEXT" df_var="${S}_DOCKERFILE"
    local ctx=${!ctx_var:-.} df=${!df_var:-}
    df=${df:-$ctx/Dockerfile}
    build_component "$token" "$repo" "$branch" "$svc" "$ctx" "$df" "${!img_var}:$tag" || return 1
  done

  local result
  result=$(fire_webhook "$secret" "$app" "$repo" deploy "$env" \
    --tag "$tag" --branch "$branch" --commit "$sha" --manifest-dir "$mdir") \
    || { err "$app/$env: deploy failed"; return 1; }

  ok "$app/$env: $(echo "$result" | jq -r '"\(.status): \(.url)"' 2>/dev/null || echo "$result")"
}

# ── poll one registered project ─────────────────────────────────────────────
poll_project() {
  local pfile=$1
  # parse the project registry file (never source — it contains secrets)
  local app repo envs prod_branch secret token
  app=$(sed -nE "s/^APP='?([^'#]+)'?.*/\1/p"              "$pfile" | head -1 | tr -d ' ')
  repo=$(sed -nE "s/^REPO='?([^'#]+)'?.*/\1/p"             "$pfile" | head -1 | tr -d ' ')
  envs=$(sed -nE "s/^ENVS='?([^'#]+)'?.*/\1/p"             "$pfile" | head -1 | tr -d ' ')
  prod_branch=$(sed -nE "s/^PROD_BRANCH='?([^'#]+)'?.*/\1/p" "$pfile" | head -1 | tr -d ' ')
  secret=$(sed -nE "s/^SECRET='?([^'#]+)'?.*/\1/p"         "$pfile" | head -1 | tr -d ' ')
  token=$(sed -nE "s/^GH_TOKEN='?([^'#]+)'?.*/\1/p"        "$pfile" | head -1 | tr -d ' ')
  prod_branch=${prod_branch:-main}
  # token is empty for public repos — that's fine

  [[ -n $app && -n $repo && -n $secret ]] || return 0
  [[ -z $FILTER_APP || $FILTER_APP == "$app" ]] || return 0

  # confirm an infra.yml exists — try prod branch, then develop, then staging,
  # then any open PR branch. This lets projects onboard via a PR before anything lands on main.
  local base_manifest="" ref
  for ref in "$prod_branch" develop staging; do
    local sha; sha=$(gh_branch_sha "$token" "$repo" "$ref" 2>/dev/null || true)
    [[ -n $sha ]] || continue
    local m; m=$(gh_file "$token" "$repo" "$sha" ".infradeploy/infra.yml")
    if [[ -n $m ]]; then base_manifest=$m; break; fi
  done
  # still empty — try open PR branches
  if [[ -z $base_manifest ]]; then
    local prs; prs=$(gh_open_prs "$token" "$repo" 2>/dev/null || true)
    while IFS= read -r pr; do
      local pr_sha pr_branch
      pr_sha=$(echo "$pr" | jq -r '.sha')
      pr_branch=$(echo "$pr" | jq -r '.branch')
      local m; m=$(gh_file "$token" "$repo" "$pr_sha" ".infradeploy/infra.yml")
      if [[ -n $m ]]; then base_manifest=$m; break; fi
    done < <(echo "$prs" | jq -c '.[]' 2>/dev/null || true)
  fi
  if [[ -z $base_manifest ]]; then warn "$app: can't reach $repo — skipping"; return 0; fi

  local state_dir="$POLL_STATE/$app"
  mkdir -p "$state_dir"

  env_allowed() { echo "$envs" | tr ',' '\n' | grep -qx "$1"; }

  # ── named branches ──────────────────────────────────────────────────────
  declare -A BRANCH_ENV=([develop]=develop [staging]=staging)
  BRANCH_ENV[$prod_branch]=prod

  for branch in "${!BRANCH_ENV[@]}"; do
    local env_name=${BRANCH_ENV[$branch]}
    env_allowed "$env_name" || continue

    local sha; sha=$(gh_branch_sha "$token" "$repo" "$branch") || continue
    [[ -n $sha ]] || continue

    local state_file="$state_dir/${env_name}.sha"
    local prev; prev=$(cat "$state_file" 2>/dev/null || true)
    [[ $sha != "$prev" ]] || continue

    deploy_ref "$token" "$app" "$secret" "$repo" "$env_name" "$branch" "$sha" \
      && echo "$sha" > "$state_file" || true
  done

  # ── open PRs ────────────────────────────────────────────────────────────
  env_allowed "preview" || return 0

  local prs_json; prs_json=$(gh_open_prs "$token" "$repo") || return 0
  local open_envs=()

  while IFS= read -r pr; do
    local pr_n pr_branch pr_sha
    pr_n=$(echo "$pr" | jq -r '.number')
    pr_branch=$(echo "$pr" | jq -r '.branch')
    pr_sha=$(echo "$pr" | jq -r '.sha')
    local env_name="pr-$pr_n"
    open_envs+=("$env_name")

    local state_file="$state_dir/${env_name}.sha"
    local prev; prev=$(cat "$state_file" 2>/dev/null || true)
    [[ $pr_sha != "$prev" ]] || continue

    deploy_ref "$token" "$app" "$secret" "$repo" "$env_name" "$pr_branch" "$pr_sha" \
      && echo "$pr_sha" > "$state_file" || true
  done < <(echo "$prs_json" | jq -c '.[]')

  # ── closed PRs → destroy ────────────────────────────────────────────────
  for state_file in "$state_dir"/pr-*.sha; do
    [[ -f $state_file ]] || continue
    local env_name; env_name=$(basename "$state_file" .sha)
    local still_open=0
    for e in "${open_envs[@]:-}"; do [[ $e == "$env_name" ]] && still_open=1 && break; done
    (( still_open )) && continue

    log "$app: $env_name PR closed → destroying"
    fire_webhook "$secret" "$app" "$repo" destroy "$env_name" && rm -f "$state_file" \
      && ok "$app/$env_name: destroyed" || true
  done
}

# ── main loop ───────────────────────────────────────────────────────────────
log "GitOps poller starting (interval: ${INTERVAL}s)"
log "  webhook : $WEBHOOK_BASE"
log "  projects: $PROJECTS_DIR"
log "  state   : $POLL_STATE  (delete to force full redeploy)"
[[ -n $FILTER_APP ]] && log "  filter  : $FILTER_APP only"
(( ONCE )) || log "  Ctrl-C to stop"

while true; do
  shopt -s nullglob
  for pfile in "$PROJECTS_DIR"/*.env; do
    poll_project "$pfile" || warn "error polling $(basename "$pfile" .env)"
  done
  shopt -u nullglob
  (( ONCE )) && exit 0
  sleep "$INTERVAL"
done
