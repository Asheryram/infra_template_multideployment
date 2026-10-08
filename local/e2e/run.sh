#!/usr/bin/env bash
# End-to-end story test: two real apps (demo-api, demo-web) go through the whole lifecycle —
# branches, PRs, a feature that needs a new secret, DevOps rewiring, a bad release, merges,
# prod releases — and every expected outcome is asserted. Run as root on the test host:
#
#   sudo bash /opt/infra/local/e2e/run.sh            run everything, clean up at the end
#   sudo bash /opt/infra/local/e2e/run.sh --pause    stop after each chapter so you can look in the browser
#   sudo bash /opt/infra/local/e2e/run.sh --keep     leave the demo environments running afterwards
#
# Needs: bootstrap + `infra platform up` done. Uses the console's HTTP API exactly like the UI.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

PAUSE=0 KEEP=0
CLEANUP_ONLY=0
for a in "$@"; do case $a in --pause) PAUSE=1 ;; --keep) KEEP=1 ;; --cleanup-only) CLEANUP_ONLY=1 ;; esac; done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . /etc/infra/infra.env; set +a
DEPLOY_USER=${DEPLOY_USER:-deploy}
S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
PREVIEW=${PREVIEW_AUTH_PLAIN:-preview:preview}
OPS=${DASHBOARD_AUTH_PLAIN:-admin:admin}
CONSOLE="https://console.$DOMAIN$S"
export E2E_WORK=/var/tmp/infra-e2e

pass=0 fail=0 chapter=""
D()      { sudo -u "$DEPLOY_USER" -H --preserve-env=E2E_WORK "$@"; }
sim()    { D bash "$HERE/gh-sim.sh" "$@"; }
title()  { chapter=$1; printf '\n\033[1m━━ %s\033[0m\n' "$1"; }
ok()     { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check()  { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 — got '$2', expected '$3'"; fi; }
url()    { if [[ $2 == prod ]]; then echo "https://$1.$DOMAIN$S"; else echo "https://$1-$2.$DOMAIN$S"; fi; }
api()    { curl -sk --max-time 10 "$(url demo-api "$1")/" | jq -r "$2" 2>/dev/null; }
web_api_url() { curl -sk --max-time 10 -u "$PREVIEW" "$(url demo-web "$1")/env.js" | sed -nE 's/.*"API_URL": "(.*)",/\1/p'; }
code()   { curl -sk -o /dev/null --max-time 10 -w '%{http_code}' "$@"; }
console(){ curl -sk --max-time 600 -u "$OPS" -H 'Content-Type: application/json' -H 'X-Infra-Console: 1' -d "$2" "$CONSOLE$1"; }
cstate() { curl -sk -u "$OPS" "$CONSOLE/api/state" | jq -r --arg a "$1" --arg e "$2" ".deployments[] | select(.APP==\$a and .ENV_NAME==\$e) | $3"; }
pause()  {
  (( PAUSE )) || return 0
  printf '\n  \033[33mLook around:\033[0m console %s\n' "$CONSOLE"
  for u in "$@"; do printf '               %s\n' "$u"; done
  read -r -p "  Enter to continue… " _ </dev/tty
}

cleanup() {
  # overrides first, so no "DB is lent" guard blocks the teardown
  rm -rf "${STATE_DIR:-/var/lib/infra}"/overrides/demo-api "${STATE_DIR:-/var/lib/infra}"/overrides/demo-web
  for e in pr-11 develop staging prod; do D infra destroy --app demo-web --env "$e" --i-really-mean-prod >/dev/null 2>&1; done
  for e in pr-7 develop staging prod; do D infra destroy --app demo-api --env "$e" --i-really-mean-prod >/dev/null 2>&1; done
  rm -rf "${SECRETS_ROOT:-/etc/infra/secrets}"/demo-api "${SECRETS_ROOT:-/etc/infra/secrets}"/demo-web \
         "${STATE_DIR:-/var/lib/infra}"/overrides/demo-api "${STATE_DIR:-/var/lib/infra}"/overrides/demo-web "$E2E_WORK"
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^local/demo-(api|web)/' | xargs -r docker rmi >/dev/null 2>&1
}

# ════════════════════════════════════════════════════════════════════════════════════════
if (( CLEANUP_ONLY )); then cleanup; echo "cleaned up"; exit 0; fi

title "0. Fresh start — two repos, like two GitHub repos"
cleanup
sim init

title "1. Teams push to develop"
sim push demo-api develop
sim push demo-web develop
check "api develop answers as env=develop"            "$(api develop .env)"         develop
check "api develop has its OWN database"               "$(api develop .db.database)" demo_api_develop
check "web develop → API_URL = api develop"            "$(web_api_url develop)"      "$(url demo-api develop)"
pause "$(url demo-web develop)"

title "2. Release to prod (push main)"
sim push demo-api main
sim push demo-web main
check "api prod has its own database"                  "$(api prod .db.database)"    demo_api_prod
check "web prod → API_URL = api prod"                  "$(web_api_url prod)"         "$(url demo-api prod)"
check "prod is public (no preview password)"           "$(code "$(url demo-web prod)/")" 200
pause "$(url demo-web prod)"

title "3. Frontend-only PR #11 (feature/checkout) — no backend PR yet"
sim branch demo-web feature/checkout
sim commit demo-web feature/checkout "new checkout page" -- sed -i 's/web v1/web v2 (checkout)/' site/index.html
sim pr-open demo-web 11 feature/checkout
check "preview needs the preview password"             "$(code "$(url demo-web pr-11)/")" 401
check "preview opens with the password"                "$(code -u "$PREVIEW" "$(url demo-web pr-11)/")" 200
check "preview serves the PR's code"                   "$(curl -sk -u "$PREVIEW" "$(url demo-web pr-11)/" | grep -c 'web v2 (checkout)')" 1
check "no backend PR → falls back to api develop"      "$(web_api_url pr-11)"        "$(url demo-api develop)"
pause "$(url demo-web pr-11)  (login $PREVIEW)"

title "4. Backend PR #7 on the SAME branch name → frontend relinks by itself"
sim branch demo-api feature/checkout
sim commit demo-api feature/checkout "checkout endpoint" -- sed -i 's/hello from demo-api/checkout-ready api/' app.py
sim pr-open demo-api 7 feature/checkout
check "api pr-7 runs the PR's code"                    "$(api pr-7 .message)"        "checkout-ready api"
check "api pr-7 has its OWN isolated database"         "$(api pr-7 .db.database)"    demo_api_pr_7
check "web pr-11 now → api pr-7 (auto relink)"         "$(web_api_url pr-11)"        "$(url demo-api pr-7)"
check "develop untouched"                              "$(api develop .message)"     "hello from demo-api"
pause "$(url demo-web pr-11)" "$(url demo-api pr-7)"

title "5. The feature needs a NEW secret → blocked until DevOps adds it"
sim commit demo-api feature/checkout "v2 needs NEW_FEATURE_KEY" -- bash -c \
  "sed -i 's/^VERSION = \"v1\"/VERSION = \"v2\"/' app.py && echo 'API_REQUIRED_ENV=\"NEW_FEATURE_KEY\"' >> .deploy/manifest.env"
if sim pr-sync demo-api 7 2>/dev/null; then bad "deploy should have been blocked"; else ok "deploy blocked (missing NEW_FEATURE_KEY)"; fi
check "console shows pr-7 as blocked"                  "$(cstate demo-api pr-7 .STATE)"   blocked
check "console names the missing key"                  "$(cstate demo-api pr-7 '.MISSING|join(",")')" "api:NEW_FEATURE_KEY"
check "old version keeps serving meanwhile"            "$(api pr-7 .version)"        v1
check "console warns develop will miss it"             "$(cstate demo-api develop '.UPCOMING_MISSING|join(",")')" "api:NEW_FEATURE_KEY"
check "console warns prod will miss it"                "$(cstate demo-api prod '.UPCOMING_MISSING|join(",")')"    "api:NEW_FEATURE_KEY"
pause
echo "  DevOps → console → Variables → demo-api, scope pr-7: NEW_FEATURE_KEY → Retry deploy"
check "variable saved via console"                     "$(console /api/secret '{"app":"demo-api","scope":"pr-7","key":"NEW_FEATURE_KEY","value":"sk_test_pr7"}' | jq -r .ok)" true
check "retry deploy via console succeeds"              "$(console /api/action '{"app":"demo-api","env":"pr-7","action":"redeploy"}' | jq -r .ok)" true
check "pr-7 now runs v2"                               "$(api pr-7 .version)"        v2
check "pr-7 sees the new secret"                       "$(api pr-7 .feature.new_feature_key_set)" true
pause "$(url demo-web pr-11)"

title "6. A bad commit lands on the PR → roll back from the console"
sim commit demo-api feature/checkout "oops" -- sed -i 's/checkout-ready api/BROKEN/' app.py
sim pr-sync demo-api 7
check "bad version is live"                            "$(api pr-7 .message)"        BROKEN
check "rollback via console"                           "$(console /api/action '{"app":"demo-api","env":"pr-7","action":"rollback"}' | jq -r .ok)" true
check "previous version is back"                       "$(api pr-7 .message)"        "checkout-ready api"
sim commit demo-api feature/checkout "revert oops" -- sed -i 's/BROKEN/checkout-ready api/' app.py
sim pr-sync demo-api 7

title "7. DevOps rewiring (survives CI pushes)"
console /api/link '{"app":"demo-web","scope":"pr-11","mode":"api","target":"demo-api/prod"}' >/dev/null
check "web pr-11 pinned → api prod"                    "$(web_api_url pr-11)"        "$(url demo-api prod)"
sim pr-sync demo-web 11
check "pin survives a CI redeploy"                     "$(web_api_url pr-11)"        "$(url demo-api prod)"
console /api/link '{"app":"demo-web","scope":"pr-11","mode":"auto"}' >/dev/null
check "back to automatic → api pr-7"                   "$(web_api_url pr-11)"        "$(url demo-api pr-7)"
console /api/db '{"app":"demo-api","scope":"pr-7","mode":"share","target":"demo-api/develop"}' >/dev/null
check "api pr-7 now uses develop's database"           "$(api pr-7 .db.database)"    demo_api_develop
if D infra destroy --app demo-api --env develop >/dev/null 2>&1; then bad "destroying a lent DB must be refused"; else ok "destroy of develop refused while its DB is lent"; fi
check "prod DB needs --allow-prod"                     "$(console /api/db '{"app":"demo-api","scope":"pr-7","mode":"share","target":"demo-api/prod"}' | jq -r .ok)" false
console /api/db '{"app":"demo-api","scope":"pr-7","mode":"own"}' >/dev/null
check "back to its own database"                       "$(api pr-7 .db.database)"    demo_api_pr_7
pause "$(url demo-web pr-11)"

title "8. Merge backend PR #7 → develop"
if sim pr-close demo-api 7 --merge 2>/dev/null; then bad "develop should be blocked (no NEW_FEATURE_KEY there yet)"; else ok "develop deploy blocked: needs NEW_FEATURE_KEY"; fi
check "pr-7 preview is gone"                           "$(code "$(url demo-api pr-7)/")" 404
check "pr-7's PR-only variable was deleted"            "$(ls "${SECRETS_ROOT:-/etc/infra/secrets}/demo-api/pr-7.env" 2>/dev/null | wc -l)" 0
check "web pr-11 falls back to api develop"            "$(web_api_url pr-11)"        "$(url demo-api develop)"
check "develop still serves the old version"           "$(api develop .version)"     v1
echo "  DevOps → console → Variables → demo-api, scope 'all environments': NEW_FEATURE_KEY → Retry develop"
console /api/secret '{"app":"demo-api","scope":"common","key":"NEW_FEATURE_KEY","value":"sk_shared"}' >/dev/null
check "retry develop via console"                      "$(console /api/action '{"app":"demo-api","env":"develop","action":"redeploy"}' | jq -r .ok)" true
check "develop runs v2 with the feature"               "$(api develop .version)/$(api develop .feature.new_feature_key_set)" v2/true
check "prod no longer flagged as 'will miss'"          "$(cstate demo-api prod '.UPCOMING_MISSING|length')" 0

title "9. Release: develop → main → prod"
sim merge demo-api develop main
check "prod runs v2 with the feature"                  "$(api prod .version)/$(api prod .feature.new_feature_key_set)" v2/true
check "prod kept its own data"                         "$(api prod .db.database)"    demo_api_prod
pause "$(url demo-web prod)"

title "10. Frontend PR #11 closed without merging"
sim pr-close demo-web 11
check "web pr-11 is gone"                              "$(code -u "$PREVIEW" "$(url demo-web pr-11)/")" 404
check "web develop unaffected"                         "$(code "$(url demo-web develop)/")" 200

title "11. Your other containers were never touched"
if [[ -d /var/lib/isolation-baseline ]]; then
  if bash "$HERE/../verify-isolation.sh" | tail -1 | grep -q 'failed 0'; then ok "verify-isolation: all PASS"; else bad "verify-isolation reported failures (run it for details)"; fi
else
  echo "  (no isolation baseline recorded — skipped)"
fi

# ════════════════════════════════════════════════════════════════════════════════════════
if (( KEEP )); then
  title "Kept running — clean up later with: sudo bash $0 --cleanup-only"
else
  title "Cleanup"; cleanup; echo "  demo environments, variables, images and repos removed"
fi
printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$pass" "$fail"
(( fail == 0 ))
