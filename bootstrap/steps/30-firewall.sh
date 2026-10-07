#!/usr/bin/env bash
# ufw: only SSH, HTTP, HTTPS in. fail2ban for SSH brute force.
#
# IMPORTANT: Docker writes its own iptables rules and BYPASSES ufw for published
# ports. That's why only Traefik publishes ports (80/443) and everything else is
# either unpublished or bound to 127.0.0.1. Never add `ports:` to app services.
set -Eeuo pipefail

ufw default deny incoming
ufw default allow outgoing
ufw limit "${SSH_PORT:-22}/tcp" comment 'ssh (rate limited)'
ufw allow 80/tcp comment 'http'
ufw allow 443/tcp comment 'https'
ufw --force enable

install -m 0644 "$INFRA_ROOT/bootstrap/files/fail2ban-jail.local" /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl restart fail2ban
ufw status verbose
echo "firewall OK"
