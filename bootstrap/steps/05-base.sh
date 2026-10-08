#!/usr/bin/env bash
# Packages we need. Dedicated hosts additionally get upgrades, timezone, unattended
# security updates, swap and kernel tuning — shared hosts never do (those belong to
# whoever already runs the server).
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

need=(ca-certificates curl gnupg jq gettext-base openssl apache2-utils iproute2 logrotate cron rsync restic git)
if [[ ${HOST_MODE:-shared} == dedicated ]]; then
  need+=(unattended-upgrades apt-listchanges ufw fail2ban python3-systemd htop ncdu)
fi

missing=()
for p in "${need[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
if (( ${#missing[@]} )); then
  apt-get update -q
  # --no-upgrade: never bump packages that are already installed (other apps may depend on them)
  # --no-install-recommends: recommended extras can hook into existing services
  #   (e.g. restic → javascript-common → enables a config in an existing Apache)
  apt-get -yq install --no-upgrade --no-install-recommends "${missing[@]}"
fi

if [[ ${HOST_MODE:-shared} != dedicated ]]; then
  echo "base OK (shared host: installed only missing packages: ${missing[*]:-none})"
  exit 0
fi

apt-get -yq upgrade
timedatectl set-timezone "${TIMEZONE:-UTC}"

# Security updates only (Ubuntu's default origins); Docker's repo is not auto-upgraded.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52infra-unattended <<EOF
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT:-false}";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
systemctl enable --now unattended-upgrades

# Swap: a safety net so one memory spike doesn't trigger the OOM killer on prod.
if [[ ${SWAP_SIZE:-0} != 0 ]] && ! swapon --show | grep -q '^/swapfile'; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

cat > /etc/sysctl.d/90-infra.conf <<'EOF'
vm.swappiness = 10
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
sysctl --system >/dev/null
echo "base OK (dedicated host)"
