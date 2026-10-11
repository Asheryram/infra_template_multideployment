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

for key in API_MEM_LIMIT API_CPUS PREVIEW_MEM_LIMIT; do
  printf 'APP_NAME=parser-test\nTYPE=backend\n%s=512m\n' "$key" > "$tmp"
  if output=$(load_manifest "$tmp" 2>&1); then
    echo "expected app-owned resource key $key to be rejected" >&2
    exit 1
  fi
  grep -q "unsupported key '$key'" <<<"$output" || {
    echo "unexpected resource-policy error: $output" >&2
    exit 1
  }
done

echo "manifest parser: shipped manifests accepted; unknown keys and app-owned resource limits rejected"
