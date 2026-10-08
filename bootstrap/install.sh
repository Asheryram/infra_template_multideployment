#!/usr/bin/env bash
# Prepare an Ubuntu 22.04 / 24.04 server. Idempotent — safe to re-run after
# changing the inventory or pulling a newer version of this repo.
#
# HOST_MODE (inventory) decides how much we may touch:
#   shared     (default) server already runs other apps: we only add our own user, dirs,
#              containers, cron file and (if ufw is active) allow rules. Nothing host-wide.
#   dedicated  server is ours alone: also SSH hardening, firewall defaults, Docker daemon,
#              journald, sysctl, swap, unattended upgrades.
# Step 00 (preflight) runs first and stops before any change if it finds a collision.
#
#   sudo bash bootstrap/install.sh inventory/prod.env            all steps
#   sudo bash bootstrap/install.sh inventory/prod.env 30 40      only steps 30 and 40
#
# Optional self-hosted GitHub runner (step 60) — pass a fresh registration token:
#   sudo GH_RUNNER_URL=https://github.com/your-org GH_RUNNER_TOKEN=XXXX \
#        bash bootstrap/install.sh inventory/prod.env 60
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
INVENTORY_FILE=$(readlink -f "${1:?usage: install.sh <inventory-file> [step...]}")
shift
[[ -f $INVENTORY_FILE ]] || { echo "inventory not found: $INVENTORY_FILE" >&2; exit 1; }

INFRA_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export INFRA_ROOT INVENTORY_FILE

# Keep runner variables from the environment even if the inventory doesn't set them.
_runner_url=${GH_RUNNER_URL:-}; _runner_token=${GH_RUNNER_TOKEN:-}
set -a
# shellcheck disable=SC1090
. "$INVENTORY_FILE"
set +a
export GH_RUNNER_URL=${GH_RUNNER_URL:-$_runner_url} GH_RUNNER_TOKEN=${GH_RUNNER_TOKEN:-$_runner_token}
export DEPLOY_USER=${DEPLOY_USER:-deploy} ADMIN_USER=${ADMIN_USER:-ubuntu} HOST_MODE=${HOST_MODE:-shared}

for step in "$INFRA_ROOT"/bootstrap/steps/[0-9]*.sh; do
  num=$(basename "$step" | cut -c1-2)
  if (( $# )) && [[ " $* " != *" $num "* ]]; then continue; fi
  echo
  echo "==> $(basename "$step")"
  bash "$step"
done

echo
echo "Bootstrap complete. Next:"
echo "  1. review /etc/infra/platform.secrets.env (and /etc/infra/traefik.env for Let's Encrypt)"
echo "  2. sudo -u $DEPLOY_USER infra platform up"
