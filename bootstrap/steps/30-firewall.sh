#!/usr/bin/env bash
# Firewall.
#
# SHARED host: never change defaults or enable/disable ufw — other apps rely on the current
#   rules. If ufw is already active we only ADD allow rules for Traefik's public ports.
# DEDICATED host: default deny, allow SSH (rate limited) + 80/443, fail2ban for SSH.
#
# Note: Docker writes its own iptables rules and BYPASSES ufw for published ports. That's
# why only Traefik publishes ports and everything else stays unpublished or on 127.0.0.1.
set -Eeuo pipefail

public_ports=()
if [[ ${TRAEFIK_BIND:-0.0.0.0} != 127.0.0.1 ]]; then
  public_ports=("${TRAEFIK_HTTP_PORT:-80}" "${TRAEFIK_HTTPS_PORT:-443}")
fi

if [[ ${HOST_MODE:-shared} != dedicated ]]; then
  if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    for p in "${public_ports[@]}"; do ufw allow "$p/tcp" comment 'infra traefik'; done
    echo "firewall OK (shared host: added allow rules for ${public_ports[*]:-nothing}; nothing else changed)"
  else
    echo "firewall OK (shared host: ufw not active — left as is)"
  fi
  exit 0
fi

ufw default deny incoming
ufw default allow outgoing
ufw limit "${SSH_PORT:-22}/tcp" comment 'ssh (rate limited)'
for p in "${public_ports[@]}"; do ufw allow "$p/tcp" comment 'infra traefik'; done
ufw --force enable

install -m 0644 "$INFRA_ROOT/bootstrap/files/fail2ban-jail.local" /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl restart fail2ban
ufw status verbose
echo "firewall OK (dedicated host)"
