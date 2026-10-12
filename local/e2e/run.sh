#!/usr/bin/env bash
# End-to-end story test on the live platform. Two real apps (demo-api, demo-web — each its own git repo with a
# .infradeploy/infra.yml) go through the whole lifecycle: develop → prod, a database created on demand, an explicit
# API_URL variable, a preview behind the access gate, a feature that needs a new secret, a bad release rolled back,
# organizations with scoped grants and invitations, and signed webhooks from an untrusted repo. Every expected
# outcome is asserted, and EVERYTHING the test creates is removed again (also with --cleanup-only).
#
#   sudo bash /opt/infra/local/e2e/run.sh                 run everything, clean up at the end (and on failure)
#   sudo bash /opt/infra/local/e2e/run.sh --keep          leave the demo environments running afterwards
#   sudo bash /opt/infra/local/e2e/run.sh --cleanup-only  remove leftovers of an interrupted run
#
# Needs: bootstrap + `infra platform up` done. The console API is driven from INSIDE the console container with test
# identities (CONSOLE_AUTH_MODE=keycloak) or through basic auth (CONSOLE_AUTH_MODE=basic) — no Keycloak users needed.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

KEEP=0 CLEANUP_ONLY=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; --cleanup-only) CLEANUP_ONLY=1 ;; esac; done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . /etc/infra/infra.env; set +a
DEPLOY_USER=${DEPLOY_USER:-deploy}
S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
CONSOLE_AUTH_MODE=${CONSOLE_AUTH_MODE:-basic}
PREVIEW_AUTH_MODE=${PREVIEW_AUTH_MODE:-basic}
OPS_AUTH_MODE=${OPS_AUTH_MODE:-basic}
PREVIEW=${PREVIEW_AUTH_PLAIN:-preview:preview}
OPS=${DASHBOARD_AUTH_PLAIN:-admin:admin}
CONSOLE="https://console.$DOMAIN$S"
DEPLOY_ROOT=${DEPLOY_ROOT:-/srv/deployments}
SECRETS_ROOT=${SECRETS_ROOT:-/etc/infra/secrets}
STATE_DIR=${STATE_DIR:-/var/lib/infra}
export E2E_WORK=/var/tmp/infra-e2e
APPS="demo-api demo-web hook-demo"

pass=0 fail=0
D()      { sudo -u "$DEPLOY_USER" -H --preserve-env=E2E_WORK "$@"; }
sim()    { D bash "$HERE/gh-sim.sh" "$@"; }
title()  { printf '\n\033[1m━━ %s\033[0m\n' "$1"; }
ok()     { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check()  { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 — got '$2', expected '$3'"; fi; }
skip()   { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
code()   { curl -sk -o /dev/null --max-time 10 -w '%{http_code}' "$@"; }

# URL convention: service web|app → <app>[-env].<domain>; any other service → <service>-<app>[-env].<domain>
svc_url() { local app=$1 svc=$2 env=$3 base=$1; [[ $env == prod ]] || base="$app-$env"
            if [[ $svc == web || $svc == app ]]; then echo "https://$base.$DOMAIN$S"; else echo "https://$svc-$base.$DOMAIN$S"; fi; }
api()     { curl -sk --max-time 10 "$(svc_url demo-api api "$1")/" | jq -r "$2" 2>/dev/null; }
web_env() { curl -sk --max-time 10 -u "$PREVIEW" "$(svc_url demo-web web "$1")/env.js" | sed -nE "s/.*\"$2\": \"(.*)\",?/\1/p"; }

# ---- console API as a test identity (inside the console container: nothing is published, no Keycloak user needed)
ID_USER=e2e-admin ID_GROUPS=/infra-platform-admins
as_admin() { ID_USER=e2e-admin; ID_GROUPS=/infra-platform-admins; }
as_user()  { ID_USER=$1; ID_GROUPS=""; }
creq() { # METHOD PATH [JSON] [curl-args...]
  local m=$1 p=$2 b=${3:-}; shift 3 2>/dev/null || shift $#
  if [[ $CONSOLE_AUTH_MODE == keycloak ]]; then
    docker exec infra-console curl -s -m 900 "$@" -X "$m" -H 'X-Infra-Console: 1' -H 'Content-Type: application/json' \
      -H "X-Forwarded-User: $ID_USER" -H "X-Forwarded-Email: $ID_USER@example.invalid" -H "X-Forwarded-Preferred-Username: $ID_USER" \
      -H "X-Forwarded-Groups: $ID_GROUPS" ${b:+-d "$b"} "http://127.0.0.1:8000$p"
  else
    curl -sk -m 900 "$@" -u "$OPS" -X "$m" -H 'X-Infra-Console: 1' -H 'Content-Type: application/json' ${b:+-d "$b"} "$CONSOLE$p"
  fi
}
cj() { creq "$@"; }                                        # body
cc() { creq "$1" "$2" "${3:-}" -o /dev/null -w '%{http_code}'; }   # status code only
cstate() { as_admin; cj GET /api/state | jq -r --arg a "$1" --arg e "$2" ".deployments[] | select(.APP==\$a and .ENV_NAME==\$e) | $3"; }
seen() { cj GET /api/state | jq -r '[.deployments[] | .APP + "/" + .ENV_NAME + ":" + .ROLE] | sort | join(",")'; }   # as the current identity

# ---- everything the test creates is removed here (also used by --cleanup-only and on every exit)
cleanup() {
  : "${E2E_WORK:?}"
  for app in $APPS; do
    for d in "$DEPLOY_ROOT/$app"/*/; do
      [[ -d $d ]] && D infra destroy --app "$app" --env "$(basename "$d")" --i-really-mean-prod >/dev/null 2>&1
    done
    D infra project remove "$app" >/dev/null 2>&1
    rm -rf "${SECRETS_ROOT:?}/$app" "${STATE_DIR:?}/overrides/$app" "${STATE_DIR:?}/resources/$app"
  done
  rm -rf "$E2E_WORK" /var/tmp/e2e-hook-demo /var/tmp/e2e-hook-demo-evil /var/tmp/e2e-hook-demo-inject
  # test organizations, people and invitations in the console's access database (our own state)
  docker exec -i -u "$(id -u "$DEPLOY_USER")" infra-console python3 - >/dev/null 2>&1 <<'PY'
import os, sqlite3
db = sqlite3.connect(os.path.join(os.environ.get("STATE_DIR", "/var/lib/infra"), "console-access.sqlite3"))
db.execute("PRAGMA foreign_keys = ON")
db.execute("DELETE FROM organizations WHERE slug LIKE 'e2e-%'")
db.execute("DELETE FROM invitations WHERE email LIKE '%@example.invalid'")
db.execute("DELETE FROM identities WHERE email LIKE '%@example.invalid'")
db.commit()
PY
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^local/(demo-(api|web)|smoke-mono)' | xargs -r docker rmi >/dev/null 2>&1
  return 0
}
finish() { (( KEEP )) || { title "cleanup"; cleanup; echo "  removed every demo environment, project, variable, test organization and image"; }
           echo; echo "passed: $pass   failed: $fail"; (( fail == 0 )); }

if (( CLEANUP_ONLY )); then cleanup; echo "cleaned up"; exit 0; fi
trap 'finish; exit $?' EXIT
NOT_OURS_BEFORE=$(docker ps -a --format '{{.Names}}' | grep -v "^${STACK_PREFIX:-infra}-" | sort)

# ════════════════════════════════════════════════════════════════════════════════════════
title "0. Fresh start — two repos, like two GitHub repos"
cleanup
sim init
D infra project add demo-api --repo e2e/demo-api >/dev/null 2>&1; D infra project add demo-web --repo e2e/demo-web >/dev/null 2>&1
check "both projects registered" "$(D infra project list 2>/dev/null | grep -cE '^demo-(api|web) ')" 2

title "1. Teams push to develop"
sim push demo-api develop
sim push demo-web develop
check "api develop answers as env=develop"              "$(api develop .env)"              develop
check "api URL follows the convention (api-<app>-<env>)" "$(code "$(svc_url demo-api api develop)/health")" 200
check "the declared database is NOT created by deploy"   "$(api develop .db.error)"          "no DATABASE_URL"
check "web develop is up"                                "$(code -u "$PREVIEW" "$(svc_url demo-web web develop)/")" 200
check "nothing auto-wires the web to the api"            "$(web_env develop API_URL)"       ""

title "2. Create the database on demand (console button)"
as_admin
check "console lists the declared database as not created" "$(cj GET '/api/database?app=demo-api&env=develop' | jq -r '.databases[0].created')" false
check "create + redeploy via the console"                  "$(cj POST /api/dbop '{"app":"demo-api","env":"develop","op":"create"}' | jq -r .ok)" true
check "api now has its own database"                       "$(api develop .db.database)"    demo_api_develop_api_database_url
check "migrations ran (visits table works)"               "$(api develop .db.ok)"          true
check "a platform admin can reveal the full URL"           "$(cj GET '/api/database/reveal?app=demo-api&env=develop&db=api:DATABASE_URL' | jq -r .url | cut -c1-11)" postgres://
if [[ $CONSOLE_AUTH_MODE == keycloak ]]; then
  as_user nobody; check "anyone else may not"             "$(cc GET '/api/database/reveal?app=demo-api&env=develop&db=api:DATABASE_URL')" 403; as_admin
fi

title "3. API_URL is an ordinary variable — set it explicitly"
cj POST /api/secret "{\"app\":\"demo-web\",\"scope\":\"develop\",\"key\":\"API_URL\",\"value\":\"$(svc_url demo-api api develop)\"}" >/dev/null
check "redeploy applies it"                              "$(cj POST /api/action '{"app":"demo-web","env":"develop","action":"redeploy"}' | jq -r .ok)" true
check "the browser-visible config now has API_URL"       "$(web_env develop API_URL)"       "$(svc_url demo-api api develop)"

title "4. Release to prod (push main)"
sim push demo-api main
sim push demo-web main
check "api prod runs as env=prod"                        "$(api prod .env)"                 prod
check "prod is public (no gate unless infra.yml opts in)" "$(code "$(svc_url demo-web web prod)/")" 200
check "prod has no database until someone creates it"    "$(api prod .db.error)"            "no DATABASE_URL"

title "5. Preview environments sit behind the access gate"
sim branch demo-web feature/checkout
sim commit demo-web feature/checkout "new checkout page" -- sed -i 's/web v1/web v2 (checkout)/' site/index.html
sim pr-open demo-web 11 feature/checkout
PRV=$(svc_url demo-web web pr-11)
if [[ $PREVIEW_AUTH_MODE == keycloak ]]; then
  read -r st loc < <(curl -sk -o /dev/null --max-time 10 -w '%{http_code} %{redirect_url}' "$PRV/")
  check "signed-out visitors are sent to Keycloak"        "$st ${loc%%\?*}"                  "302 https://sso.$DOMAIN$S/oauth2/start"
  check "the router carries the SSO middleware"           "$(docker inspect -f '{{index .Config.Labels "traefik.http.routers.infra-demo-web-pr-11-web.middlewares"}}' infra-demo-web-pr-11-web-1 | grep -c 'infra-demo-web-pr-11-web-sso@docker')" 1
  check "the gate knows the app AND the environment"      "$(docker inspect -f '{{index .Config.Labels "traefik.http.middlewares.infra-demo-web-pr-11-web-sso.forwardauth.address"}}' infra-demo-web-pr-11-web-1)" "http://console:8000/auth/preview?app=demo-web&env=pr-11"
  check "gate endpoint answers 302 without a session"     "$(docker exec infra-console curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' -H "X-Forwarded-Host: demo-web-pr-11.$DOMAIN$S" -H 'X-Forwarded-Uri: /' 'http://127.0.0.1:8000/auth/preview?app=demo-web&env=pr-11')" 302
else
  check "preview needs the shared password"               "$(code "$PRV/")"                  401
  check "...and opens with it"                            "$(code -u "$PREVIEW" "$PRV/")"    200
fi
check "the preview serves the PR's code (through the gate's credentials)" "$(docker exec infra-demo-web-pr-11-web-1 wget -qO- http://127.0.0.1/ 2>/dev/null | grep -c 'web v2 (checkout)')" 1
if [[ $OPS_AUTH_MODE == keycloak ]]; then
  check "ops tools (traefik dashboard) go through Keycloak" "$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' "https://traefik.$DOMAIN$S/dashboard/")" 302
  check "no basic-auth challenge anywhere on the ops hosts" "$(curl -sk -D - -o /dev/null --max-time 10 "https://logs.$DOMAIN$S/" | grep -ci 'www-authenticate')" 0
else
  check "ops tools ask for the shared password"           "$(code "https://traefik.$DOMAIN$S/dashboard/")" 401
fi

title "6. A feature needs a NEW secret → blocked until someone sets it"
sim branch demo-api feature/checkout
sim commit demo-api feature/checkout "v2 needs NEW_FEATURE_KEY" -- bash -c \
  "sed -i 's/^VERSION = \"v1\"/VERSION = \"v2\"/' app.py && sed -i 's/^    health_path: \/health\$/&\n    required_env: [NEW_FEATURE_KEY]/' .infradeploy/infra.yml"
if sim pr-open demo-api 7 feature/checkout 2>/dev/null; then bad "first deploy should have been blocked"; else ok "deploy blocked (missing NEW_FEATURE_KEY)"; fi
check "console shows pr-7 as blocked"                    "$(cstate demo-api pr-7 .STATE)"   blocked
check "console names the missing key"                    "$(cstate demo-api pr-7 '.MISSING|join(",")')" "api:NEW_FEATURE_KEY"
check "console warns develop will miss it"               "$(cstate demo-api develop '.UPCOMING_MISSING|join(",")')" "api:NEW_FEATURE_KEY"
check "console warns prod will miss it"                  "$(cstate demo-api prod '.UPCOMING_MISSING|join(",")')"    "api:NEW_FEATURE_KEY"
as_admin
check "variable saved via the console"                   "$(cj POST /api/secret '{"app":"demo-api","scope":"pr-7","key":"NEW_FEATURE_KEY","value":"sk_test_pr7"}' | jq -r .ok)" true
check "retry deploy succeeds"                            "$(cj POST /api/action '{"app":"demo-api","env":"pr-7","action":"redeploy"}' | jq -r .ok)" true
check "pr-7 runs v2 and sees the secret"                 "$(api pr-7 .version)/$(api pr-7 .feature.new_feature_key_set)" v2/true
check "develop was untouched"                            "$(api develop .version)"          v1

title "7. A bad commit lands → roll back from the console"
sim commit demo-api feature/checkout "oops" -- sed -i 's/hello from demo-api/BROKEN/' app.py
sim pr-sync demo-api 7
check "bad version is live"                              "$(api pr-7 .message)"             BROKEN
check "rollback via the console"                         "$(cj POST /api/action '{"app":"demo-api","env":"pr-7","action":"rollback"}' | jq -r .ok)" true
check "previous version is back"                         "$(api pr-7 .message)"             "hello from demo-api"

title "8. Organizations, scoped grants and invitations (through the real console)"
if [[ $CONSOLE_AUTH_MODE != keycloak ]]; then skip "needs CONSOLE_AUTH_MODE=keycloak (identities come from Keycloak)"; else
  as_admin
  check "create the client organization"                 "$(cj POST /api/access '{"op":"organization-create","slug":"e2e-org","name":"E2E Client"}' | jq -r .ok)" true
  check "assign both projects to it"                     "$(cj POST /api/access '{"op":"project-link","organization":"e2e-org","app":"demo-api"}' | jq -r .ok)/$(cj POST /api/access '{"op":"project-link","organization":"e2e-org","app":"demo-web"}' | jq -r .ok)" true/true
  for u in e2e-alice e2e-carol e2e-orgadmin; do as_user $u; cj GET /api/state >/dev/null; done     # first sight registers the identity
  as_admin
  uid() { cj GET /api/access | jq -r --arg e "$1@example.invalid" '.access.identities[] | select(.email==$e) | .uid'; }
  check "platform admin appoints an organization admin"  "$(cj POST /api/access "{\"op\":\"member\",\"organization\":\"e2e-org\",\"uid\":\"$(uid e2e-orgadmin)\",\"role\":\"org_admin\"}" | jq -r .ok)" true
  as_user e2e-orgadmin
  check "…who can NOT add people by email directly"      "$(cc POST /api/access '{"op":"member","organization":"e2e-org","email":"e2e-alice@example.invalid","role":"member"}')" 400
  check "…but invites alice with a develop-only role"    "$(cj POST /api/access '{"op":"invite","organization":"e2e-org","email":"e2e-alice@example.invalid","create_account":false,"grants":[{"app":"demo-api","role":"operator","scope":"env:develop"}]}' | jq -r .ok)" true
  check "…and carol with all previews of demo-web"       "$(cj POST /api/access '{"op":"invite","organization":"e2e-org","email":"e2e-carol@example.invalid","create_account":false,"grants":[{"app":"demo-web","role":"viewer","scope":"class:preview"}]}' | jq -r .ok)" true
  as_user e2e-alice
  check "before accepting, alice sees nothing"           "$(seen)" ""
  inv=$(cj GET /api/state | jq -r '.access.my_invitations[0].id')
  check "she can see the invitation to accept"           "$(cj GET /api/state | jq -r '.access.my_invitations | length')" 1
  check "accepting applies membership and grants"        "$(cj POST /api/invitations "{\"op\":\"accept\",\"id\":\"$inv\"}" | jq -r .ok)" true
  check "alice now sees ONLY demo-api develop, as operator" "$(seen)" "demo-api/develop:operator"
  check "alice may redeploy develop"                     "$(cj POST /api/action '{"app":"demo-api","env":"develop","action":"redeploy"}' | jq -r .ok)" true
  check "alice may NOT touch prod"                       "$(cc POST /api/action '{"app":"demo-api","env":"prod","action":"redeploy"}')" 403
  check "alice may NOT read prod's variables"            "$(cc GET '/api/vars?app=demo-api&env=prod')" 403
  check "operators cannot edit variables"                "$(cc POST /api/secret '{"app":"demo-api","scope":"develop","key":"X","value":"1"}')" 403
  as_user e2e-carol
  carolinv=$(cj GET /api/state | jq -r '.access.my_invitations[0].id')
  cj POST /api/invitations "{\"op\":\"accept\",\"id\":\"$carolinv\"}" >/dev/null
  check "carol (class:preview viewer) sees only the web preview" "$(seen)" "demo-web/pr-11:viewer"
  check "carol cannot read the api's logs"               "$(cc GET '/api/logs?app=demo-api&env=develop')" 403
  as_user e2e-orgadmin
  check "org admin sees no environments by that role alone" "$(seen)" ""
  as_admin
  check "platform admin sees everything"                 "$(cj GET /api/state | jq -r '.deployments | length')" "$(D infra list 2>/dev/null | grep -cE '^demo-(api|web) ')"
fi

title "9. Untrusted repos: registered projects, signed webhooks, stack policy"
HOOK="https://hooks.$DOMAIN$S/webhook"; HD=/var/tmp/e2e-hook-demo
rm -rf "$HD" "$HD-evil" "$HD-inject"; mkdir -p "$HD"
cp -r "$HERE/../examples/monolith/." "$HD/"; sed -i 's/^name: smoke-mono/name: hook-demo/' "$HD/infra.yml"
HSECRET=$(D infra project add hook-demo --repo acme/hook-demo --envs preview,develop 2>/dev/null | awk '/INFRA_WEBHOOK_SECRET/ {print $2}')
check "project registered (secret issued)"               "${#HSECRET}" 64
hsend() { INFRA_WEBHOOK_URL=$HOOK INFRA_WEBHOOK_SECRET=${HS:-$HSECRET} bash "$HERE/../../scripts/webhook-send.sh" --insecure \
            --app "${HAPP:-hook-demo}" --repo "${HREPO:-acme/hook-demo}" --manifest-dir "${HDIR:-$HD}" --tag t1 --branch feature/h "$@" 2>/dev/null; }
# HTTP status of a rejected request; retried ONLY when no status came back at all (a transient connection blip), never on a wrong status
hhttp() { local out i; for i in 1 2 3; do out=$(hsend "$@" | grep -o 'HTTP [0-9]*'); [[ -n $out ]] && break; sleep 2; done; echo "$out"; }
check "signed deploy → preview live"                     "$(hsend --action deploy --env pr-41 | jq -r .status)" succeeded
check "  …and serving behind the gate"                   "$(code "$(svc_url hook-demo app pr-41)/")" "$([[ $PREVIEW_AUTH_MODE == keycloak ]] && echo 302 || echo 401)"
check "tampered signature → 401"                         "$(hhttp --action deploy --env pr-42 --tamper)" "HTTP 401"
check "10-minute-old request → 401"                      "$(hhttp --action deploy --env pr-42 --timestamp $(( $(date +%s) - 600 )))" "HTTP 401"
check "unregistered project → 401"                       "$(HAPP=nobody hhttp --action deploy --env pr-42)" "HTTP 401"
check "another repo using the secret → 403"              "$(HREPO=evil/fork hhttp --action deploy --env pr-42)" "HTTP 403"
check "environment not allowed (prod) → 403"             "$(hhttp --action deploy --env prod)" "HTTP 403"
body='{"action":"destroy","repo":"acme/hook-demo","env":"pr-49"}'; ts=$(date +%s)
sig=$(printf '%s.%s' "$ts" "$body" | openssl dgst -sha256 -hmac "$HSECRET" -r | cut -d' ' -f1)
rq() { curl -sk -o /dev/null -w '%{http_code}' -X POST "$HOOK" -H "X-Infra-Project: hook-demo" -H "X-Infra-Timestamp: $ts" \
         -H "X-Infra-Signature: sha256=$sig" -H 'Content-Type: application/json' --data-binary "$body"; }
check "replayed request → refused"                       "$(rq)/$(rq)" 202/401
check "hooks host can't reach the console"               "$(code "https://hooks.$DOMAIN$S/api/state")/$(code "https://hooks.$DOMAIN$S/")" 404/404
cp -r "$HD" "$HD-inject"; printf "    health_path: '/x'; touch /tmp/E2E_PWNED\n" >> "$HD-inject/infra.yml"
rm -f /tmp/E2E_PWNED
inj=$(HDIR=$HD-inject hsend --action deploy --env pr-43)      # refused at the door (HTTP 403) or failed in the job: never deployed
check "manifest with shell code → refused"               "$([[ $inj == *"HTTP 403"* || $(jq -r .status <<<"$inj" 2>/dev/null) == failed ]] && echo refused)" refused
check "  …and nothing was executed"                       "$(ls /tmp/E2E_PWNED 2>/dev/null | wc -l)" 0
cp -r "$HD" "$HD-evil"; cat > "$HD-evil/compose.extra.yml" <<'Y'
services:
  miner:
    image: traefik/whoami:v1.10
    privileged: true
    network_mode: host
    volumes: ["/:/host"]
Y
out=$(HDIR=$HD-evil hsend --action deploy --env pr-44 | jq -r .status)
check "a smuggled compose.extra.yml is ignored (deploy still works)" "$out" succeeded
check "  …no extra container, nothing privileged"        "$(docker ps -a --filter label=com.docker.compose.project=infra-hook-demo-pr-44 --format '{{.Names}}' | wc -l)/$(docker ps -aq --filter label=com.docker.compose.project=infra-hook-demo-pr-44 | xargs -r docker inspect -f '{{.HostConfig.Privileged}}' | grep -c true)" 1/0
printf '    host:\n      preview: demo-web-develop.%s\n' "$DOMAIN" >> "$HD/infra.yml"
hostres=$(hsend --action deploy --env pr-45)
check "hostname of another app → refused"                "$([[ $hostres == *"HTTP 403"* || $(jq -r .status <<<"$hostres" 2>/dev/null) == failed ]] && echo refused)" refused
check "signed destroy → preview gone"                    "$(hsend --action destroy --env pr-41 | jq -r .status)/$(code "$(svc_url hook-demo app pr-41)/")" succeeded/404

title "10. Your other containers were never touched"
check "containers that are not ours are exactly the same" "$(docker ps -a --format '{{.Names}}' | grep -v "^${STACK_PREFIX:-infra}-" | sort | md5sum)" "$(echo "$NOT_OURS_BEFORE" | md5sum)"
if [[ -d /var/lib/isolation-baseline ]]; then
  iso=$(bash "$HERE/../verify-isolation.sh" 2>&1)
  check "isolation check against the recorded baseline" "$(grep -oE 'failed:? [0-9]+' <<<"$iso" | tail -1 | tr -d ':')" "failed 0"
fi
