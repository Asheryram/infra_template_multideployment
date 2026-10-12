#!/usr/bin/env bash
# End-to-end check of the platform using tiny public images (traefik/whoami) instead
# of real apps. Run INSIDE the VM after bootstrap + `infra platform up`:
#
#   sudo -u deploy bash /opt/infra/local/smoke-test.sh          run and clean up
#   sudo -u deploy bash /opt/infra/local/smoke-test.sh --keep   leave stacks running to poke at
#
# Covers: every project type, routing + TLS, preview basic-auth, explicitly provisioned DB,
# and environment isolation.
set -Eeuo pipefail

KEEP=0; [[ ${1:-} == --keep ]] && KEEP=1
EX=/opt/infra/local/examples
set -a; . /etc/infra/infra.env; set +a
AUTH=${PREVIEW_AUTH_PLAIN:-preview:preview}
# port suffix when Traefik is not on 443 (e.g. a shared host where 443 is taken)
S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
pass=0; fail=0

ok()   { echo "  PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail + 1)); }
step() { echo; echo "== $*"; }

http_code() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }
meta()      { ( . "$DEPLOY_ROOT/$1/$2/meta.env"; printf '%s' "${!3}" ); }
DEPLOY_ROOT=${DEPLOY_ROOT:-/srv/deployments}

expect_code() { # expected url [curl args...]
  local want=$1 url=$2; shift 2
  local got; got=$(http_code "$@" "$url")
  if [[ $got == "$want" ]]; then ok "$url → $got"; else bad "$url → $got (expected $want)"; fi
}

cleanup() {
  (( KEEP )) && return 0
  step "cleanup"
  for s in smoke-web:pr-2 smoke-api:pr-1 smoke-api:develop smoke-split:pr-3 smoke-mono:pr-4 smoke-mono:staging; do
    infra destroy --app "${s%%:*}" --env "${s##*:}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

step "platform"
expect_code 401 "https://traefik.$DOMAIN$S/"
expect_code 200 "https://traefik.$DOMAIN$S/dashboard/" -u "${DASHBOARD_AUTH_PLAIN:-admin:admin}"

step "monolith: staging (no auth) + preview (auth)"
infra deploy --manifest "$EX/monolith" --env staging --tag smoke >/dev/null
infra deploy --manifest "$EX/monolith" --env pr-4 --tag smoke --branch smoke/mono >/dev/null
if infra db list | grep -q smoke_mono_pr_4; then bad "database must not exist before it is created"; else ok "declared database not created by deploy"; fi
infra db create smoke-mono pr-4 >/dev/null
infra redeploy smoke-mono pr-4 >/dev/null
expect_code 200 "https://smoke-mono-staging.$DOMAIN$S/"
expect_code 401 "https://smoke-mono-pr-4.$DOMAIN$S/"
expect_code 200 "https://smoke-mono-pr-4.$DOMAIN$S/" -u "$AUTH"
if infra db list | grep -q smoke_mono_pr_4; then ok "database created on demand"; else bad "database smoke_mono_pr_4 missing"; fi

infra destroy --app smoke-mono --env pr-4 >/dev/null 2>&1 || true   # free a preview slot (shared hosts cap previews)

step "split: web + api in one stack"
infra deploy --manifest "$EX/split" --env pr-3 --tag smoke --branch smoke/split >/dev/null
expect_code 200 "https://smoke-split-pr-3.$DOMAIN$S/" -u "$AUTH"
expect_code 200 "https://api-smoke-split-pr-3.$DOMAIN$S/"
[[ $(meta smoke-split pr-3 URLS) == *"api=https://api-smoke-split-pr-3.$DOMAIN$S"* ]] \
  && ok "every service URL is recorded in metadata" || bad "service URLs missing from metadata"
infra destroy --app smoke-split --env pr-3 >/dev/null 2>&1 || true   # free a preview slot

step "frontend and backend deploy independently"
infra deploy --manifest "$EX/backend" --env develop --tag smoke --branch develop >/dev/null
infra deploy --manifest "$EX/frontend" --env pr-2 --tag smoke --branch feature/login >/dev/null
if infra env smoke-web pr-2 web | grep -q '^API_URL='; then
  bad "frontend API_URL was unexpectedly injected"
else
  ok "frontend API_URL is app configuration, not platform-injected"
fi

infra deploy --manifest "$EX/backend" --env pr-1 --tag smoke --branch feature/login >/dev/null
if infra env smoke-web pr-2 web | grep -q '^API_URL='; then
  bad "backend deploy unexpectedly changed frontend API_URL"
else
  ok "backend deploy does not silently change frontend configuration"
fi

infra destroy --app smoke-api --env pr-1 >/dev/null
if infra env smoke-web pr-2 web | grep -q '^API_URL='; then
  bad "backend destroy unexpectedly changed frontend API_URL"
else
  ok "backend destroy leaves frontend configuration unchanged"
fi

step "redeploy / rollback"
infra deploy --manifest "$EX/monolith" --env staging --tag smoke2 >/dev/null
infra rollback smoke-mono staging >/dev/null
[[ $(meta smoke-mono staging TAG) == smoke ]] && ok "rollback restored previous tag" || bad "rollback tag: $(meta smoke-mono staging TAG)"

step "log rotation configured on containers"
opts=$(docker inspect -f '{{json .HostConfig.LogConfig}}' "${STACK_PREFIX:-infra}-smoke-mono-staging-app-1")
[[ $opts == *max-size* ]] && ok "container log limits: $opts" || bad "no log limits on container"

step "everything we created is labelled as ours"
unlabelled=$(docker ps -a --filter "label=com.docker.compose.project" --format '{{.Names}}\t{{.Label "infra.managed"}}\t{{.Label "com.docker.compose.project"}}' \
  | awk -F'\t' '$3 ~ /^(infra-|'"${STACK_PREFIX:-infra}"'-)/ && $2 != "true" {print $1}')
[[ -z $unlabelled ]] && ok "all platform + app containers carry infra.managed=true" || bad "unlabelled: $unlabelled"

step "housekeeping only touches our resources"
infra cleanup >/dev/null && ok "infra cleanup ran" || bad "infra cleanup failed"

echo
infra list
echo
echo "passed: $pass   failed: $fail"
echo "Now prove the existing workload was untouched:  sudo bash /opt/infra/local/verify-isolation.sh"
(( fail == 0 ))
