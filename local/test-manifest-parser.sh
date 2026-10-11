#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"

for manifest in \
  "$ROOT/app-kit/.deploy/manifest.env" \
  "$ROOT"/app-kit/examples/*.manifest.env \
  "$ROOT"/local/examples/*/manifest.env \
  "$ROOT/local/e2e/apps/demo-api/.deploy/manifest.env" \
  "$ROOT/local/e2e/apps/demo-web/.deploy/manifest.env"; do
  load_manifest "$manifest"
done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'EOF'
APP_NAME=parser-test
TYPE=monolith
TYPO_PORT=8080
EOF

if output=$(load_manifest "$tmp" 2>&1); then
  echo "expected unsupported manifest key to fail" >&2
  exit 1
fi
grep -q "unsupported key 'TYPO_PORT'" <<<"$output" || {
  echo "unexpected parser error: $output" >&2
  exit 1
}

echo "manifest parser: all shipped manifests accepted; unknown keys rejected"
