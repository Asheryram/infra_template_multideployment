#!/usr/bin/env bash
# Live test of zero-downtime deploys on the real platform: a rolling update while traffic flows, a version that never becomes
# healthy, a version that is healthy but returns server errors (the canary must catch it), `rollback`, `rollback --to`, and
# replica scaling. A throwaway app ("rolltest", 2 replicas, prod) is built from the console image, so nothing is pulled; everything
# it creates is removed again, also on failure.
#
#   sudo bash /opt/infra/local/e2e/rollout.sh                 run, clean up at the end
#   sudo bash /opt/infra/local/e2e/rollout.sh --cleanup-only  remove leftovers of an interrupted run
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

set -a; . /etc/infra/infra.env; set +a
DEPLOY_USER=${DEPLOY_USER:-deploy}
DEPLOY_ROOT=${DEPLOY_ROOT:-/srv/deployments}
SECRETS_ROOT=${SECRETS_ROOT:-/etc/infra/secrets}
STATE_DIR=${STATE_DIR:-/var/lib/infra}
S=""; if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then S=":$TRAEFIK_HTTPS_PORT"; fi
APP=rolltest
URL="https://$APP.$DOMAIN$S/"                 # a service named `app` in prod is served at <app>.<domain>
W=/var/tmp/infra-rollout
LOOP_PID=""

pass=0 fail=0
D()     { sudo -u "$DEPLOY_USER" -H "$@"; }
title() { printf '\n\033[1m━━ %s\033[0m\n' "$1"; }
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 — got '$2', expected '$3'"; fi; }
meta()  { ( . "$DEPLOY_ROOT/$APP/prod/meta.env" 2>/dev/null; printf '%s' "${!1-}" ); }
running() { docker ps --filter "label=com.docker.compose.project=infra-$APP-prod" --filter status=running -q | wc -l; }
allctr()  { docker ps -a --filter "label=com.docker.compose.project=infra-$APP-prod" -q | wc -l; }
served()  { curl -sk --max-time 5 "$URL"; }

cleanup() {
  [[ -n $LOOP_PID ]] && kill "$LOOP_PID" 2>/dev/null
  [[ -d $DEPLOY_ROOT/$APP/prod ]] && D infra destroy --app "$APP" --env prod --i-really-mean-prod >/dev/null 2>&1
  D infra project remove "$APP" >/dev/null 2>&1
  rm -rf "${SECRETS_ROOT:?}/$APP" "${STATE_DIR:?}/overrides/$APP" "${STATE_DIR:?}/resources/$APP" "$W"
  for v in 1 2 3 4 5; do docker rmi "local/$APP:v$v" >/dev/null 2>&1; done
}
if [[ ${1:-} == --cleanup-only ]]; then cleanup; echo "cleaned up"; exit 0; fi
trap cleanup EXIT
cleanup

# ---- the app: four behaviours baked into the image by build args
title "build five versions of a tiny app"
rm -rf "$W"; mkdir -p "$W/repo/.infradeploy" "$W/img"; chmod -R a+rX "$W"
cat > "$W/img/app.py" <<'PY'
import http.server, os
MODE, VER = os.environ.get("MODE", "ok"), os.environ.get("VER", "1")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            code = 500 if MODE == "broken-health" else 200
        else:
            code = 500 if MODE == "errors" else 200
        body = f"v{VER}".encode()
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
PY
cat > "$W/img/Dockerfile" <<'EOF'
FROM infra-console:local
ARG MODE=ok
ARG VER=1
ENV MODE=$MODE VER=$VER
COPY app.py /app.py
HEALTHCHECK --interval=2s --timeout=2s --retries=2 --start-period=3s CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"
ENTRYPOINT []
CMD ["python3", "/app.py"]
EOF
for spec in "1 ok" "2 ok" "3 broken-health" "4 errors" "5 ok"; do
  set -- $spec
  docker build -q -t "local/$APP:v$1" --build-arg MODE="$2" --build-arg VER="$1" "$W/img" >/dev/null 2>&1 && ok "built v$1 ($2)" || bad "build v$1"
done
cat > "$W/repo/.infradeploy/infra.yml" <<EOF
name: $APP
services:
  app:
    image: local/$APP
    port: 8080
    health_path: /
environments:
  prod:
    replicas: 2
    canary_seconds: 20
EOF
chmod -R a+rX "$W"
D infra project add "$APP" --repo "e2e/$APP" >/dev/null 2>&1
deploy() { D infra deploy --manifest "$W/repo/.infradeploy" --env prod --tag "$1" --branch main >"$W/deploy-$1.log" 2>&1; }
tail_log() { sed 's/^/      | /' <(tail -${2:-12} "$W/deploy-$1.log" | cut -c1-200); }

# ---- steady traffic through Traefik for the whole test; every response is recorded
traffic_start() { : > "$W/traffic.log"; ( while true; do printf '%s %s\n' "$(date +%s.%N)" "$(curl -sk -o /dev/stdout -w ' %{http_code}' --max-time 3 "$URL" 2>/dev/null)" >> "$W/traffic.log"; sleep 0.1; done ) & LOOP_PID=$!; }
traffic_mark() { wc -l < "$W/traffic.log"; }
traffic_bad()  { tail -n +"$(( $1 + 1 ))" "$W/traffic.log" | awk '$NF != 200' | wc -l; }    # failed requests since a mark
# WHEN the failed requests happened (UTC) next to the deploy's own milestones, to see what the platform was doing at that moment
when_bad() { # mark deploy-log
  local t
  for t in $(tail -n +"$(( $1 + 1 ))" "$W/traffic.log" | awk '$NF != 200 {print int($1)}'); do printf '      failed request at %s
' "$(date -u -d "@$t" +%T)"; done
  [[ -n ${2:-} ]] && grep -E 'rolling out|canary|retiring|OK ' "$W/$2" 2>/dev/null | sed -E 's/^([0-9T:-]+Z) \[deploy\] /      deploy     /' | sed -E 's/T([0-9:]+)Z/ /' | cut -c1-110
}
traffic_versions() { tail -n +"$(( $1 + 1 ))" "$W/traffic.log" | awk '{print $2}' | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}'; }

title "1. first deploy (v1, two replicas)"
deploy v1; check "v1 deployed" "$?" 0
check "two copies running" "$(running)" 2
check "served" "$(served)" v1

title "2. rolling update v1 → v2 while traffic flows"
traffic_start; sleep 2
m=$(traffic_mark)
deploy v2; rc=$?
tail_log v2 8
check "v2 deployed" "$rc" 0
sleep 2
check "now serving v2" "$(served)" v2
check "two copies running (the old ones are gone)" "$(running)" 2
check "no stopped leftovers" "$(allctr)" 2
echo "      traffic during the update: $(traffic_versions "$m")"
check "ZERO failed requests during the update" "$(traffic_bad "$m")" 0
when_bad "$m" deploy-v2.log
check "recorded version" "$(meta TAG)" v2

title "3. a version that never becomes healthy (v3) is refused and the old one keeps serving"
m=$(traffic_mark)
deploy v3; rc=$?
tail_log v3 6
check "deploy of v3 fails" "$([[ $rc -ne 0 ]] && echo failed || echo succeeded)" failed
check "log says it was rolled back" "$(grep -c 'rolled back' "$W/deploy-v3.log" | sed 's/^[1-9].*/yes/')" yes
sleep 1
check "still serving v2" "$(served)" v2
check "two copies, no leftovers of v3" "$(allctr)" 2
echo "      traffic: $(traffic_versions "$m")"
check "ZERO failed requests while v3 was refused" "$(traffic_bad "$m")" 0
check "recorded version unchanged" "$(meta TAG)" v2

title "4. a healthy version that returns server errors (v4): the canary rolls it back"
m=$(traffic_mark)
deploy v4; rc=$?
tail_log v4 6
check "deploy of v4 fails" "$([[ $rc -ne 0 ]] && echo failed || echo succeeded)" failed
check "log names the server errors" "$(grep -c 'server error' "$W/deploy-v4.log" | sed 's/^[1-9].*/yes/')" yes
sleep 1
check "still serving v2" "$(served)" v2
check "two copies, no leftovers of v4" "$(allctr)" 2
bad_n=$(traffic_bad "$m")
echo "      traffic: $(traffic_versions "$m")  (failed: $bad_n)"
check "customers saw only a handful of errors before the rollback (≤ 15)" "$([[ $bad_n -le 15 ]] && echo yes || echo "no: $bad_n")" yes
check "recorded version unchanged" "$(meta TAG)" v2

title "5. v5 is fine and goes live; history is kept"
m=$(traffic_mark)
deploy v5; check "v5 deployed" "$?" 0
sleep 2
check "serving v5" "$(served)" v5
check "ZERO failed requests during the update" "$(traffic_bad "$m")" 0
when_bad "$m" deploy-v5.log
check "history lists the earlier versions (newest first)" "$(meta TAG_HISTORY)" "v2 v1"
check "previous version" "$(meta PREV_TAG)" v2

title "6. rollback"
m=$(traffic_mark)
D infra rollback "$APP" prod >"$W/rb1.log" 2>&1; check "rollback ok" "$?" 0
sleep 2
check "back on v2" "$(served)" v2
check "ZERO failed requests during the rollback" "$(traffic_bad "$m")" 0
m=$(traffic_mark)
D infra rollback "$APP" prod --to v1 >"$W/rb2.log" 2>&1; check "rollback --to v1 ok" "$?" 0
sleep 2
check "back on v1" "$(served)" v1
check "ZERO failed requests during rollback --to" "$(traffic_bad "$m")" 0
D infra rollback "$APP" prod --to v99 >"$W/rb3.log" 2>&1; rc=$?
check "rollback --to an unknown version is refused" "$([[ $rc -ne 0 ]] && echo refused || echo accepted)" refused
check "still on v1" "$(served)" v1

kill "$LOOP_PID" 2>/dev/null; LOOP_PID=""
title "result"
printf '  %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
