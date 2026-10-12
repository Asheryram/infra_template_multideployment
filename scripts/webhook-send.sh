#!/usr/bin/env bash
# Send a signed deploy/destroy request to the platform and wait for the result — the same thing
# the app-kit workflow does from GitHub Actions. Useful for testing and for non-GitHub CI.
#
#   INFRA_WEBHOOK_URL=https://hooks.example.com/webhook INFRA_WEBHOOK_SECRET=… \
#   webhook-send.sh --app shop-api --repo acme/shop-api --action deploy --env pr-12 \
#                   --tag sha-0123456789ab --branch feature/x --commit 0123abcd --manifest-dir .infradeploy
#
#   --action destroy --env pr-12          tear a preview down
#   --no-wait                             print the job id and exit
#   --insecure                            accept self-signed certificates (local tests)
#   --timestamp N / --tamper              testing only: forge an old request / break the signature
#
# Exit: 0 succeeded · 1 deploy failed · 2 request rejected (printed: HTTP code + reason)
set -euo pipefail

URL=${INFRA_WEBHOOK_URL:-} SECRET=${INFRA_WEBHOOK_SECRET:-}
APP="" REPO="" ACTION=deploy ENV="" TAG="" BRANCH="" COMMIT="" DIR=".infradeploy"
WAIT=1 CURL_OPTS=(-sS --max-time 30) TS="" TAMPER=0 TIMEOUT=${WEBHOOK_WAIT_TIMEOUT:-900}
while (( $# )); do
  case $1 in
    --url) URL=$2; shift 2 ;;
    --app) APP=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --action) ACTION=$2; shift 2 ;;
    --env) ENV=$2; shift 2 ;;
    --tag) TAG=$2; shift 2 ;;
    --branch) BRANCH=$2; shift 2 ;;
    --commit) COMMIT=$2; shift 2 ;;
    --manifest-dir) DIR=$2; shift 2 ;;
    --no-wait) WAIT=0; shift ;;
    --insecure) CURL_OPTS+=(-k); shift ;;
    --timestamp) TS=$2; shift 2 ;;
    --tamper) TAMPER=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -n $URL && -n $SECRET && -n $APP && -n $ENV ]] || { echo "need INFRA_WEBHOOK_URL, INFRA_WEBHOOK_SECRET, --app, --env" >&2; exit 2; }
URL=${URL%/}; [[ $URL == */webhook ]] || URL="$URL/webhook"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sign() { # timestamp payload-file → hex
  { printf '%s.' "$1"; cat "$2"; } | openssl dgst -sha256 -hmac "$SECRET" -r | cut -d' ' -f1
}

if [[ $ACTION == deploy ]]; then
  [[ -f $DIR/infra.yml ]] || { echo "no $DIR/infra.yml" >&2; exit 2; }
  tar -C "$DIR" -czf - . | base64 | tr -d '\n' > "$tmp/bundle"
else
  : > "$tmp/bundle"
fi
jq -cn --arg action "$ACTION" --arg repo "$REPO" --arg env "$ENV" --arg tag "$TAG" \
  --arg branch "$BRANCH" --arg commit "$COMMIT" --rawfile bundle "$tmp/bundle" \
  '{action: $action, repo: $repo, env: $env, tag: $tag, branch: $branch, commit: $commit}
   + (if $bundle == "" then {} else {bundle: $bundle} end)' > "$tmp/body"

ts=${TS:-$(date +%s)}
sig=$(sign "$ts" "$tmp/body")
if (( TAMPER )); then sig="0${sig:1}"; fi
code=$(curl "${CURL_OPTS[@]}" -o "$tmp/resp" -w '%{http_code}' -X POST "$URL" \
  -H 'Content-Type: application/json' -H "X-Infra-Project: $APP" \
  -H "X-Infra-Timestamp: $ts" -H "X-Infra-Signature: sha256=$sig" --data-binary @"$tmp/body")
if [[ $code != 202 ]]; then echo "rejected: HTTP $code $(cat "$tmp/resp")"; exit 2; fi

job=$(jq -r .job "$tmp/resp")
if (( ! WAIT )); then echo "$job"; exit 0; fi
echo "job $job accepted — waiting…" >&2
deadline=$(( $(date +%s) + TIMEOUT ))
while (( $(date +%s) < deadline )); do
  sleep 3
  ts=$(date +%s); printf '%s' "$job" > "$tmp/jobid"
  curl "${CURL_OPTS[@]}" -o "$tmp/status" "$URL/jobs/$job" -H "X-Infra-Project: $APP" \
    -H "X-Infra-Timestamp: $ts" -H "X-Infra-Signature: sha256=$(sign "$ts" "$tmp/jobid")" || continue
  status=$(jq -r '.status // empty' "$tmp/status")
  case $status in
    succeeded) jq . "$tmp/status"; exit 0 ;;
    failed)    jq . "$tmp/status"; exit 1 ;;
  esac
done
echo "timed out after ${TIMEOUT}s waiting for job $job" >&2; exit 1
