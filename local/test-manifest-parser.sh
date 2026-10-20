#!/usr/bin/env bash
# Validates every shipped infra.yml with the platform parser and checks that bad input is rejected.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSE="$ROOT/scripts/parse-manifest.py"

for f in "$ROOT/app-kit/.infradeploy/infra.yml" "$ROOT"/app-kit/examples/*.infra.yml \
         "$ROOT"/local/examples/*/infra.yml "$ROOT"/local/e2e/apps/*/.infradeploy/infra.yml; do
  python3 "$PARSE" "$f" >/dev/null || { echo "rejected shipped manifest: $f" >&2; exit 1; }
done

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
reject() { # description, yaml
  printf '%s\n' "$2" > "$tmp"
  if python3 "$PARSE" "$tmp" >/dev/null 2>&1; then echo "expected rejection: $1" >&2; exit 1; fi
}
reject "reserved app name"       $'name: console\nservices:\n  web:\n    image: x/y'
reject "missing image"           $'name: t\nservices:\n  web:\n    port: 80'
reject "no services"             $'name: t'
reject "bad env key"             $'name: t\nservices:\n  web:\n    image: x/y\n    required_env: ["BAD KEY"]'
reject "migrate unknown service" $'name: t\nservices:\n  web:\n    image: x/y\nmigrate:\n  service: nope\n  cmd: x'

accept() { # description, yaml, expected line in the parsed output
  printf '%s\n' "$2" > "$tmp"
  python3 "$PARSE" "$tmp" 2>&1 | grep -qF -- "$3" || { echo "expected '$3' for: $1" >&2; exit 1; }
}
accept "a colon inside a trailing comment on a list item" \
  $'name: t\nservices:\n  api:\n    image: x/y\n    required_env:\n      - A_KEY    # note: this is a comment\n      - B_KEY' "API_REQUIRED_ENV='A_KEY B_KEY'"
accept "a colon inside a trailing comment on a mapping line" \
  $'name: t\nservices:\n  api:\n    image: x/y   # which image: this one\n    port: 80  # the port: fixed' "API_PORT='80'"
accept "a hash inside quotes is not a comment" \
  $'name: t\nservices:\n  api:\n    image: x/y\n    required_env: ["A_KEY"]\n    health_path: "/h#x"' "API_HEALTH_PATH='/h#x'"

echo "infra.yml parser: shipped manifests accepted; invalid manifests rejected"
