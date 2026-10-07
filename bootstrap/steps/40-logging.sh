#!/usr/bin/env bash
# Log retention everywhere:
#   containers → Docker json-file, 3 × 10 MB per container (daemon.json + templates)
#   systemd    → journald capped at 500 MB / 1 month
#   infra CLI  → /var/log/infra/*.log rotated daily, 14 days, max 50 MB each
set -Eeuo pipefail

install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 "$INFRA_ROOT/bootstrap/files/journald.conf" /etc/systemd/journald.conf.d/90-infra.conf
systemctl restart systemd-journald

install -d -m 2775 -o root -g "$DEPLOY_USER" /var/log/infra
sed "s/@DEPLOY_USER@/$DEPLOY_USER/g" "$INFRA_ROOT/bootstrap/files/logrotate-infra" > /etc/logrotate.d/infra
chmod 644 /etc/logrotate.d/infra
logrotate --debug /etc/logrotate.d/infra >/dev/null 2>&1 || { echo "logrotate config invalid"; exit 1; }
echo "logging OK"
