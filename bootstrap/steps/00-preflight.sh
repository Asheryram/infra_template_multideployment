#!/usr/bin/env bash
# Look before we touch anything. Reports what already lives on this host and stops
# if bootstrap would collide with it.
#
# HOST_MODE=shared     (default) the server already runs other people's apps. Bootstrap only
#                      ADDS things in its own namespace and never changes host-wide settings.
# HOST_MODE=dedicated  the server is ours alone. Bootstrap also hardens SSH, firewall defaults,
#                      Docker daemon, journald, sysctl and swap. Refused if foreign containers exist.
set -Eeuo pipefail

mode=${HOST_MODE:-shared}
marker=/etc/infra/.managed-by-infra-template
problems=0
fail() { echo "  ✗ $*"; problems=$((problems + 1)); }
note() { echo "  • $*"; }

echo "host mode: $mode"
[[ $mode == shared || $mode == dedicated ]] || { echo "HOST_MODE must be shared or dedicated"; exit 1; }

# --- what is already here --------------------------------------------------------
if command -v docker >/dev/null; then
  foreign=$(docker ps -a --format '{{.Names}}\t{{.Label "infra.managed"}}' | awk -F'\t' '$2 != "true" {print $1}')
  count=$(grep -c . <<<"$foreign" || true)
  note "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) is installed; $count container(s) not managed by us"
  if [[ -n $foreign ]]; then sed 's/^/      /' <<<"$foreign" | head -20; fi
  if [[ $mode == dedicated && $count -gt 0 && ${ALLOW_DEDICATED_WITH_FOREIGN:-false} != true ]]; then
    fail "HOST_MODE=dedicated would restart Docker and change host-wide settings under $count existing container(s). Use HOST_MODE=shared."
  fi
else
  note "Docker not installed — it will be installed"
fi

for p in "${TRAEFIK_HTTP_PORT:-80}" "${TRAEFIK_HTTPS_PORT:-443}"; do
  if ss -Hltn "sport = :$p" | grep -q . && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx infra-traefik; then
    note "port $p is in use by an existing service — 'infra platform up' will refuse; consider TLS_MODE=external (docs/shared-host.md)"
  fi
done

if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  note "ufw is active — shared mode only ADDS allow rules for Traefik's ports"
fi

# --- names we want to own --------------------------------------------------------
if [[ -d /etc/infra && ! -f $marker ]]; then fail "/etc/infra exists but was not created by this template"; fi
for d in "${DEPLOY_ROOT:-/srv/deployments}" "${STATE_DIR:-/var/lib/infra}" "${BACKUP_DIR:-/srv/backups}"; do
  if [[ -e $d && ! -f $marker ]] && [[ -n $(ls -A "$d" 2>/dev/null) ]]; then fail "$d already exists and is not empty"; fi
done
if [[ -e /usr/local/bin/infra ]] && ! grep -q 'bin/infra' /usr/local/bin/infra 2>/dev/null; then
  fail "/usr/local/bin/infra exists and is not ours"
fi
if [[ -e /etc/cron.d/infra ]] && ! grep -q 'Managed by infra bootstrap' /etc/cron.d/infra; then
  fail "/etc/cron.d/infra exists and is not ours"
fi
if id "${DEPLOY_USER:-deploy}" &>/dev/null && [[ ! -f $marker ]] && [[ ${REUSE_DEPLOY_USER:-false} != true ]]; then
  fail "user '${DEPLOY_USER:-deploy}' already exists (someone else's?). Set DEPLOY_USER to an unused name, or REUSE_DEPLOY_USER=true"
fi

if (( problems )); then
  echo "preflight found $problems problem(s) — nothing has been changed."
  exit 1
fi
echo "preflight OK"
