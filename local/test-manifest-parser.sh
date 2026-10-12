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

echo "infra.yml parser: shipped manifests accepted; invalid manifests rejected"
