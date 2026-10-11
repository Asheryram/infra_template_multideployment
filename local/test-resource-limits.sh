#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"

tmp=$(mktemp -d)
cleanup() {
  if [[ -d $tmp/resources/demo ]]; then
    rm -f "$tmp/resources/demo/common.api.env" "$tmp/resources/demo/preview.api.env" "$tmp/resources/demo/pr-12.api.env"
    rmdir "$tmp/resources/demo" "$tmp/resources"
  fi
  rmdir "$tmp"
}
trap cleanup EXIT
STATE_DIR=$tmp
RESOURCE_DEFAULT_MEM_LIMIT=512m
RESOURCE_DEFAULT_CPUS=1.0
RESOURCE_PREVIEW_MEM_LIMIT=256m
RESOURCE_PREVIEW_CPUS=0.5
RESOURCE_MAX_CONTAINER_MEM_LIMIT=1g
RESOURCE_MAX_CONTAINER_CPUS=2.0
RESOURCE_MAX_STACK_MEM_LIMIT=2g
RESOURCE_MAX_STACK_CPUS=3.0

resource_resolve demo develop api
[[ $RESOURCE_MEM == 512m && $RESOURCE_CPUS == 1.0 ]]
resource_resolve demo pr-12 api
[[ $RESOURCE_MEM == 256m && $RESOURCE_CPUS == 0.5 ]]

mkdir -p "$STATE_DIR/resources/demo"
printf 'MEM_LIMIT=768m\nCPUS=1.5\n' > "$STATE_DIR/resources/demo/common.api.env"
printf 'MEM_LIMIT=384m\n' > "$STATE_DIR/resources/demo/preview.api.env"
printf 'CPUS=0.75\n' > "$STATE_DIR/resources/demo/pr-12.api.env"
resource_resolve demo pr-12 api
[[ $RESOURCE_MEM == 384m && $RESOURCE_CPUS == 0.75 ]]
resource_resolve demo pr-13 api
[[ $RESOURCE_MEM == 384m && $RESOURCE_CPUS == 1.5 ]]
resource_resolve demo develop api
[[ $RESOURCE_MEM == 768m && $RESOURCE_CPUS == 1.5 ]]

resource_validate_value 1g 2.0
resource_validate_stack 2097152 3.0
if resource_mem_kib 512 >/dev/null 2>&1; then
  echo "expected memory limits to require an explicit unit" >&2
  exit 1
fi
if (resource_validate_value 2g 1.0) >/dev/null 2>&1; then
  echo "expected per-container memory ceiling to reject 2g" >&2
  exit 1
fi
if (resource_validate_stack 2097153 2.0) >/dev/null 2>&1; then
  echo "expected stack memory ceiling to reject a value over 2g" >&2
  exit 1
fi
if (resource_validate_value 256m 0.1234) >/dev/null 2>&1; then
  echo "expected CPU precision beyond three decimal places to be rejected" >&2
  exit 1
fi
if (resource_validate_stack 1024 3.001) >/dev/null 2>&1; then
  echo "expected stack CPU ceiling to reject a value over 3.0" >&2
  exit 1
fi

echo "resource limits: defaults, scope precedence, and container/stack ceilings verified"
