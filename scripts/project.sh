#!/usr/bin/env bash
# Project registry — which repos may deploy to this server through signed webhooks.
#
#   infra project add <app> --repo <owner/repo> [--envs preview,develop,staging,prod]
#                     [--prod-branch main] [--registry-user U --registry-token T] [--gh-token T]
#   infra project list
#   infra project show <app>
#   infra project set <app> [--repo R] [--envs E] [--prod-branch B] [--registry-user U --registry-token T] [--gh-token T]
#   infra project rotate-secret <app>     new webhook secret (old one stops working immediately)
#   infra project remove <app>            revoke webhook access (environments keep running)
#
# <app> is the APP_NAME in the repo's manifest. A monorepo with several apps registers each one.
# Secrets live in $STATE_DIR/projects/<app>.env (0600, deploy user). They're printed once — give
# the repo INFRA_WEBHOOK_URL and INFRA_WEBHOOK_SECRET as GitHub Actions secrets.
SCRIPT_NAME=project
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

action=${1:-}
if [[ -z $action || $action == -h || $action == --help ]]; then usage; fi
shift
load_infra_env
# No enable_file_log here: this command prints webhook secrets, which must never reach a log file.
ACTOR=${INFRA_ACTOR:-${SUDO_USER:-${USER:-unknown}}}
audit() { mkdir -p "$LOG_DIR" 2>/dev/null; echo "$(date -u +%FT%TZ) [project] user=$ACTOR $*" >> "$LOG_DIR/project.log" 2>/dev/null || true; }

PDIR="$STATE_DIR/projects"
mkdir -p "$PDIR"; chmod 700 "$PDIR"
pfile() { echo "$PDIR/$1.env"; }
hook_url() { echo "https://hooks.$DOMAIN$URL_PORT_SUFFIX/webhook"; }
new_secret() { openssl rand -hex 32; }

save() { # app key=value… (rewrites the whole file)
  local f; f=$(pfile "$1"); shift
  local tmp="$f.tmp" kv
  ( umask 077; : > "$tmp" )
  for kv in "$@"; do write_kv "$tmp" "${kv%%=*}" "${kv#*=}"; done
  mv "$tmp" "$f"
}
get() { meta_get "$(pfile "$1")" "$2"; }

parse_opts() {
  REPO="" ENVS="" PROD_BRANCH="" REG_USER="" REG_TOKEN="" GH_TOKEN=""
  while (( $# )); do
    case $1 in
      --repo) REPO=${2:?}; shift 2 ;;
      --envs) ENVS=${2:?}; shift 2 ;;
      --prod-branch) PROD_BRANCH=${2:?}; shift 2 ;;
      --registry-user) REG_USER=${2:?}; shift 2 ;;
      --registry-token) REG_TOKEN=${2:?}; shift 2 ;;
      --gh-token) GH_TOKEN=${2:?}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  if [[ -n $REPO && ! $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then die "--repo must be owner/repo"; fi
  if [[ -n $ENVS && ! $ENVS =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then die "--envs must be a comma list, e.g. preview,develop"; fi
}

print_onboarding() { # app secret
  cat <<EOF

  Project $1 can now deploy via signed webhooks.
  Add these as GitHub Actions secrets in ${2:+the repo }$(get "$1" REPO):

    INFRA_WEBHOOK_URL     $(hook_url)
    INFRA_WEBHOOK_SECRET  $2

  The secret is shown only now. Lost it? infra project rotate-secret $1
EOF
}

case $action in
  add)
    app=${1:?app}; shift; validate_name app "$app"
    case $app in console|traefik|logs|status|hooks|grafana|www|api) die "app name '$app' is reserved by the platform" ;; esac
    [[ ! -f $(pfile "$app") ]] || die "project $app already exists (use 'infra project set')"
    parse_opts "$@"
    [[ -n $REPO ]] || die "--repo owner/repo is required"
    secret=$(new_secret)
    save "$app" "APP=$app" "REPO=$REPO" "ENVS=${ENVS:-preview,develop,staging,prod}" \
      "PROD_BRANCH=${PROD_BRANCH:-main}" "SECRET=$secret" \
      "REGISTRY_USER=$REG_USER" "REGISTRY_TOKEN=$REG_TOKEN" "GH_TOKEN=$GH_TOKEN" \
      "CREATED_AT=$(date +%s)" "CREATED_BY=$ACTOR"
    log "project $app registered for $REPO (envs: ${ENVS:-preview,develop,staging,prod})"; audit "add $app repo=$REPO envs=${ENVS:-preview,develop,staging,prod}"
    print_onboarding "$app" "$secret"
    ;;

  set)
    app=${1:?app}; shift; [[ -f $(pfile "$app") ]] || die "no project $app"
    parse_opts "$@"
    save "$app" "APP=$app" "REPO=${REPO:-$(get "$app" REPO)}" "ENVS=${ENVS:-$(get "$app" ENVS)}" \
      "PROD_BRANCH=${PROD_BRANCH:-$(get "$app" PROD_BRANCH)}" "SECRET=$(get "$app" SECRET)" \
      "REGISTRY_USER=${REG_USER:-$(get "$app" REGISTRY_USER)}" "REGISTRY_TOKEN=${REG_TOKEN:-$(get "$app" REGISTRY_TOKEN)}" \
      "GH_TOKEN=${GH_TOKEN:-$(get "$app" GH_TOKEN)}" \
      "CREATED_AT=$(get "$app" CREATED_AT)" "CREATED_BY=$(get "$app" CREATED_BY)"
    log "project $app updated"; audit "set $app"
    ;;

  rotate-secret)
    app=${1:?app}; [[ -f $(pfile "$app") ]] || die "no project $app"
    secret=$(new_secret)
    sed -i "s/^SECRET=.*/SECRET='$secret'/" "$(pfile "$app")"
    log "webhook secret rotated for $app — the old one no longer works"; audit "rotate-secret $app"
    print_onboarding "$app" "$secret"
    ;;

  remove)
    app=${1:?app}; [[ -f $(pfile "$app") ]] || die "no project $app"
    rm -f "$(pfile "$app")"
    audit "remove $app"; log "project $app removed — webhooks refused from now on. Its environments keep running; remove them with 'infra destroy'."
    ;;

  show)
    app=${1:?app}; f=$(pfile "$app"); [[ -f $f ]] || die "no project $app"
    sed -E "s/^(SECRET|REGISTRY_TOKEN|GH_TOKEN)='.+'/\1='••••••'/" "$f"
    echo "WEBHOOK_URL='$(hook_url)'"
    ;;

  list)
    printf '%-24s %-34s %-30s %s\n' PROJECT REPO ENVS ENVIRONMENTS
    for f in "$PDIR"/*.env; do
      app=$(meta_get "$f" APP)
      n=$( { find "$DEPLOY_ROOT/$app" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; } | wc -l)
      printf '%-24s %-34s %-30s %s\n' "$app" "$(meta_get "$f" REPO)" "$(meta_get "$f" ENVS)" "$n"
    done
    ;;

  *) die "unknown action: $action" ;;
esac
