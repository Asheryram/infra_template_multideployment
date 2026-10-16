#!/usr/bin/env bash
# Live test of project links (a frontend serving its API under its own address) on the running platform.
# Uses the demo-api / demo-web test apps, creates its own environments and removes everything again.
#
#   sudo bash /opt/infra/local/e2e/upstreams.sh [--keep]
#
# What it proves: the link is made in the console (never in the repo) · it applies per environment class · the target can
# lose its public address · the frontend's access gate covers the route · exact path boundary · forged identity headers do
# not open the gate · deleting the link puts everything back · your other containers are untouched.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
KEEP=0; [[ ${1:-} == --keep ]] && KEEP=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . /etc/infra/infra.env; set +a
DEPLOY_USER=${DEPLOY_USER:-deploy}
S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
DEPLOY_ROOT=${DEPLOY_ROOT:-/srv/deployments}; SECRETS_ROOT=${SECRETS_ROOT:-/etc/infra/secrets}; STATE_DIR=${STATE_DIR:-/var/lib/infra}
export E2E_WORK=/var/tmp/infra-up-test
APPS="demo-api demo-web"
LOG=${LOG_DIR:-/var/log/infra}/deploy.log
pass=0 fail=0
D()     { sudo -u "$DEPLOY_USER" -H --preserve-env=E2E_WORK "$@"; }
sim()   { D bash "$HERE/gh-sim.sh" "$@"; }
title() { printf '\n\033[1m━━ %s\033[0m\n' "$1"; }
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 — got '$2', expected '$3'"; fi; }
host()  { local app=$1 svc=$2 env=$3 base=$1; [[ $env == prod ]] || base="$app-$env"; if [[ $svc == web || $svc == app ]]; then echo "$base.$DOMAIN"; else echo "$svc-$base.$DOMAIN"; fi; }
url()   { echo "https://$(host "$@")$S"; }
code()  { curl -sk -o /dev/null --max-time 15 -w '%{http_code}' "$@"; }
body()  { curl -sk --max-time 15 "$@"; }
G()     { D git -c user.name=t -c user.email=t@l -C "$E2E_WORK/$1" "${@:2}"; }
put()   { D bash -c 'cat > "$1"' _ "$E2E_WORK/$1"; }      # put <repo>/<file> < content  (everything in the work dir belongs to the deploy user)
adm()   { docker exec infra-console curl -s -m 900 -X "$1" -H 'X-Infra-Console: 1' -H 'Content-Type: application/json' \
            -H 'X-Forwarded-User: up-admin' -H 'X-Forwarded-Email: up-admin@example.invalid' -H 'X-Forwarded-Groups: /infra-platform-admins' ${3:+-d "$3"} "http://127.0.0.1:8000$2"; }
member() { docker exec infra-console curl -s -o /dev/null -w '%{http_code}' -X "$1" -H 'X-Infra-Console: 1' -H 'Content-Type: application/json' \
            -H 'X-Forwarded-User: up-nobody' -H 'X-Forwarded-Email: up-nobody@example.invalid' -H 'X-Forwarded-Groups: ' ${3:+-d "$3"} "http://127.0.0.1:8000$2"; }

cleanup() {
  for app in $APPS; do
    for d in "$DEPLOY_ROOT/$app"/*/; do [[ -d $d ]] && D infra destroy --app "$app" --env "$(basename "$d")" --i-really-mean-prod >/dev/null 2>&1; done
    D infra project remove "$app" >/dev/null 2>&1
    rm -rf "${SECRETS_ROOT:?}/$app" "${STATE_DIR:?}/overrides/$app" "${STATE_DIR:?}/resources/$app"
  done
  rm -rf "$E2E_WORK"
  docker exec -i -u "$(id -u "$DEPLOY_USER")" infra-console python3 - >/dev/null 2>&1 <<'PY'
import os, sqlite3
db = sqlite3.connect(os.path.join(os.environ.get("STATE_DIR", "/var/lib/infra"), "console-access.sqlite3"))
db.execute("DELETE FROM project_links WHERE consumer LIKE 'demo-%' OR provider LIKE 'demo-%'")
db.execute("DELETE FROM identities WHERE email LIKE '%@example.invalid'")
db.commit()
PY
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^local/demo-(api|web)' | xargs -r docker rmi >/dev/null 2>&1
  return 0
}
finish() { (( KEEP )) || { title "cleanup"; cleanup; echo "  removed the test environments, projects, links and images"; }
           echo; echo "passed: $pass   failed: $fail"; (( fail == 0 )); }
trap 'finish; exit $?' EXIT
NOT_OURS_BEFORE=$(docker ps -a --format '{{.Names}}' | grep -v "^${STACK_PREFIX:-infra}-" | sort)

title "0. Two separate projects, nothing special in either repo"
cleanup; sim init
D infra project add demo-api --repo e2e/demo-api >/dev/null 2>&1; D infra project add demo-web --repo e2e/demo-web >/dev/null 2>&1
for r in demo-api demo-web; do G $r checkout -q develop; done
put demo-api/.infradeploy/infra.yml <<'EOF'
name: demo-api
services:
  api:
    image: local/demo-api
    port: 8080
    health_path: /health
EOF
put demo-web/.infradeploy/infra.yml <<'EOF'
name: demo-web
services:
  web:
    image: local/demo-web
    port: 80
EOF
for r in demo-api demo-web; do G $r add -A; G $r commit -qm "plain manifests"; done
sim push demo-api develop >/dev/null 2>&1; sim push demo-web develop >/dev/null 2>&1
WEB=$(url demo-web web develop); API=$(url demo-api api develop)
check "before any link the API answers on its own address"   "$(code "$API/health")" 200
check "…and the frontend has no /api route"                  "$(body "$WEB/api/" | jq -r .env 2>/dev/null)" ""

title "1. A pull request cannot create a link"
put demo-web/.infradeploy/infra.yml <<'EOF'
name: demo-web
services:
  web:
    image: local/demo-web
    port: 80
    upstreams:
      - path: /api
        to: demo-api/api
EOF
G demo-web commit -qam "malicious: declare a route to another project"
out=$(sim push demo-web develop 2>&1); rc=$?
check "a manifest declaring upstreams is REFUSED"            "$rc" 1
check "…and the message points to the console"               "$(tail -30 "$LOG" | grep -c "'upstreams' is not part of infra.yml")" 1
G demo-web reset -q --hard HEAD~1

title "2. The link is made in the console"
LNK='{"op":"link-create","consumer":"demo-web","service":"web","path":"/api","provider":"demo-api","provider_service":"api","strip":true,"inject_as":"API_URL","hide_provider":true}'
check "a member cannot create it"                            "$(member POST /api/access "$LNK")" 403
check "a platform admin creates it"                          "$(adm POST /api/access "$LNK" | jq -r .ok)" true
LID=$(adm GET /api/access | jq -r '.access.project_links[] | select(.consumer=="demo-web") | .id')
check "the same path twice is refused"                       "$(adm POST /api/access "$LNK" | jq -r .error | grep -c 'already has a link')" 1
check "Apply now redeploys both projects"                    "$(adm POST /api/access "{\"op\":\"link-apply\",\"id\":\"$LID\"}" | jq -r '.redeployed | map(select(endswith(":ok"))) | length')" 2

title "3. The route works, and the API has no address of its own"
check "frontend serves its own page"                         "$(code "$WEB/")" 200
check "/api/ reaches the API (strip prefix)"                 "$(body "$WEB/api/" | jq -r .env)" develop
check "/api/health reaches the API's /health"                "$(code "$WEB/api/health")" 200
check "the API's own address now answers 403"                "$(code "$API/health")" 403
check "API_URL points at the frontend's own address"         "$(body "$WEB/env.js" | sed -nE 's/.*"API_URL": "(.*)",?/\1/p')" "$WEB"
check "the API is not listed as a public URL"                "$(adm GET /api/state | jq -r '[.deployments[] | select(.APP=="demo-api" and .ENV_NAME=="develop") | .URLS] | join(",")')" ""

title "4. Path boundary: exact, not a string prefix"
check "/apix is NOT sent to the API"                         "$(body "$WEB/apix" | jq -r .env 2>/dev/null)" ""
check "/apiary is NOT sent to the API"                       "$(body "$WEB/apiary/x" | jq -r .env 2>/dev/null)" ""
check "encoded slash cannot smuggle a prefix"                "$(body --path-as-is "$WEB/api%2f..%2f" | jq -r .env 2>/dev/null)" ""
check "dot-dot cannot make the API answer for another path"  "$(body --path-as-is "$WEB/api/../index.html" | grep -c '"env"')" 0
check "case matters: /API is the frontend's, not the API's"  "$(body "$WEB/API/" | jq -r .env 2>/dev/null)" ""

title "5. Previews follow the same rule, and stay in their own class"
sim branch demo-api feature/x >/dev/null 2>&1; sim pr-open demo-api 21 feature/x >/dev/null 2>&1
sim branch demo-web feature/x >/dev/null 2>&1; sim pr-open demo-web 21 feature/x >/dev/null 2>&1
PW=$(url demo-web web pr-21)
check "preview frontend is gated (anonymous → sign-in)"      "$(code "$PW/")" 302
check "the ROUTE is gated too (anonymous /api/ → sign-in)"   "$(code "$PW/api/")" 302
check "forged identity headers do not open it"               "$(code -H 'X-Forwarded-User: root' -H 'X-Auth-Request-User: root' -H 'X-Auth-Request-Email: root@x.y' -H 'X-Forwarded-Groups: /infra-platform-admins' "$PW/api/")" 302
check "the preview API has no address of its own"            "$(code "$(url demo-api api pr-21)/health")" 403
R=infra-demo-web-pr-21-web-up1
check "the preview route targets the PREVIEW api, not develop's" "$(docker inspect -f '{{json .Config.Labels}}' infra-demo-web-pr-21-web-1 | jq -r --arg r "$R" '.["traefik.http.routers."+$r+".service"]')" "infra-demo-api-pr-21-api@docker"
check "the router carries the gate AND the exact-path rule"  "$(docker inspect -f '{{json .Config.Labels}}' infra-demo-web-pr-21-web-1 | jq -r --arg r "$R" '[.["traefik.http.routers."+$r+".middlewares"], .["traefik.http.routers."+$r+".rule"]] | join(" | ")' | grep -cE 'sso@docker.*Path\(`/api`\) \|\| PathPrefix\(`/api/`\)')" 1

title "6. What Traefik was given (its own API is not exposed by design: label view)"
docker inspect -f '{{json .Config.Labels}}' infra-demo-web-pr-21-web-1 | jq -r 'to_entries[] | select(.key|test("up1")) | "    \(.key | sub("traefik.http.";"")) = \(.value)"'
check "the API container keeps its service but its own router denies everyone" "$(docker inspect -f '{{json .Config.Labels}}' infra-demo-api-pr-21-api-1 | jq -r '(.["traefik.http.services.infra-demo-api-pr-21-api.loadbalancer.server.port"]) + "/" + (.["traefik.http.routers.infra-demo-api-pr-21-api.middlewares"])')" "8080/deny-all@file"

title "7. Cost of the route (median of 40 calls)"
med() { local t=(); for i in $(seq 1 40); do t+=("$(curl -sk -o /dev/null --max-time 15 -w '%{time_total}' "$@")"); done; printf '%s\n' "${t[@]}" | sort -n | sed -n 20p; }
via_route=$(med "$WEB/api/health"); own=$(med "$WEB/")
printf '  frontend own page: %ss · through the route /api/health: %ss (medians)\n' "$own" "$via_route"
check "the route adds well under 100 ms over the frontend's own page" "$(awk -v a="$via_route" -v b="$own" 'BEGIN{print (a-b < 0.100) ? "yes" : "no"}')" yes

title "8. Deleting the link puts everything back"
check "delete the link"                                      "$(adm POST /api/access "{\"op\":\"link-delete\",\"id\":\"$LID\"}" | jq -r .ok)" true
check "(apply is refused for a link that no longer exists)"  "$(adm POST /api/access "{\"op\":\"link-apply\",\"id\":\"$LID\"}" | jq -r .error | grep -c 'no such link')" 1
sim push demo-api develop >/dev/null 2>&1; sim push demo-web develop >/dev/null 2>&1
check "the API has its own address again"                    "$(code "$API/health")" 200
check "the frontend no longer serves /api"                   "$(body "$WEB/api/" | jq -r .env 2>/dev/null)" ""

title "9. Your other containers were never touched"
check "containers that are not ours are exactly the same"    "$(diff <(docker ps -a --format '{{.Names}}' | grep -v "^${STACK_PREFIX:-infra}-" | sort) <(echo "$NOT_OURS_BEFORE") >/dev/null && echo same)" same
