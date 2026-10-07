#!/usr/bin/env bash
# End-to-end check of the platform using tiny public images (traefik/whoami) instead
# of real apps. Run INSIDE the VM after bootstrap + `infra platform up`:
#
#   sudo -u deploy bash /opt/infra/local/smoke-test.sh          run and clean up
#   sudo -u deploy bash /opt/infra/local/smoke-test.sh --keep   leave stacks running to poke at
#
# Covers: every project type, routing + TLS, preview basic-auth, per-env databases,
# frontend→backend branch matching, relink on backend create/destroy, teardown.
set -Eeuo pipefail

KEEP=0; [[ ${1:-} == --keep ]] && KEEP=1
EX=/opt/infra/local/examples
set -a; . /etc/infra/infra.env; set +a
AUTH=${PREVIEW_AUTH_PLAIN:-preview:preview}
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
expect_code 401 "https://traefik.$DOMAIN/"
expect_code 200 "https://traefik.$DOMAIN/dashboard/" -u "${DASHBOARD_AUTH_PLAIN:-admin:admin}"

step "monolith: staging (no auth) + preview (auth)"
infra deploy --manifest "$EX/monolith" --env staging --tag smoke >/dev/null
infra deploy --manifest "$EX/monolith" --env pr-4 --tag smoke --branch smoke/mono >/dev/null
expect_code 200 "https://smoke-mono-staging.$DOMAIN/"
expect_code 401 "https://smoke-mono-pr-4.$DOMAIN/"
expect_code 200 "https://smoke-mono-pr-4.$DOMAIN/" -u "$AUTH"
if infra db list | grep -q smoke_mono_pr_4; then ok "database smoke_mono_pr_4 exists"; else bad "database smoke_mono_pr_4 missing"; fi

step "split: web + api in one stack"
infra deploy --manifest "$EX/split" --env pr-3 --tag smoke --branch smoke/split >/dev/null
expect_code 200 "https://smoke-split-pr-3.$DOMAIN/" -u "$AUTH"
expect_code 200 "https://api-smoke-split-pr-3.$DOMAIN/"
[[ $(meta smoke-split pr-3 UPSTREAM_API_URL) == "https://api-smoke-split-pr-3.$DOMAIN" ]] \
  && ok "web API_URL points at its own api" || bad "split API_URL wrong"

step "frontend ↔ backend branch matching"
infra deploy --manifest "$EX/backend" --env develop --tag smoke --branch develop >/dev/null
infra deploy --manifest "$EX/frontend" --env pr-2 --tag smoke --branch feature/login >/dev/null
[[ $(meta smoke-web pr-2 UPSTREAM_API_URL) == "https://smoke-api-develop.$DOMAIN" ]] \
  && ok "no backend preview yet → falls back to develop" || bad "fallback: $(meta smoke-web pr-2 UPSTREAM_API_URL)"

infra deploy --manifest "$EX/backend" --env pr-1 --tag smoke --branch feature/login >/dev/null
[[ $(meta smoke-web pr-2 UPSTREAM_API_URL) == "https://smoke-api-pr-1.$DOMAIN" ]] \
  && ok "backend preview on same branch → frontend relinked" || bad "relink: $(meta smoke-web pr-2 UPSTREAM_API_URL)"
if infra env smoke-web pr-2 web | grep -q "API_URL=https://smoke-api-pr-1.$DOMAIN"; then ok "container env has new API_URL"; else bad "container env not updated"; fi

infra destroy --app smoke-api --env pr-1 >/dev/null
[[ $(meta smoke-web pr-2 UPSTREAM_API_URL) == "https://smoke-api-develop.$DOMAIN" ]] \
  && ok "backend preview destroyed → frontend back on develop" || bad "unlink: $(meta smoke-web pr-2 UPSTREAM_API_URL)"

step "redeploy / rollback"
infra deploy --manifest "$EX/monolith" --env staging --tag smoke2 >/dev/null
infra rollback smoke-mono staging >/dev/null
[[ $(meta smoke-mono staging TAG) == smoke ]] && ok "rollback restored previous tag" || bad "rollback tag: $(meta smoke-mono staging TAG)"

step "log rotation configured on containers"
opts=$(docker inspect -f '{{json .HostConfig.LogConfig}}' smoke-mono-staging-app-1)
[[ $opts == *max-size* ]] && ok "container log limits: $opts" || bad "no log limits on container"

echo
infra list
echo
echo "passed: $pass   failed: $fail"
(( fail == 0 ))
