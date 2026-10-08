#!/usr/bin/env bash
# deploy user (runs every deployment, owns no sudo) and SSH hardening.
# Never locks you out: hardening is skipped if ADMIN_USER has no authorized key.
set -Eeuo pipefail

add_key() { # user key
  local home; home=$(getent passwd "$1" | cut -d: -f6)
  install -d -m 700 -o "$1" -g "$1" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  grep -qxF "$2" "$home/.ssh/authorized_keys" || echo "$2" >> "$home/.ssh/authorized_keys"
  chown "$1:$1" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
}

id "$DEPLOY_USER" &>/dev/null || useradd --create-home --shell /bin/bash "$DEPLOY_USER"
usermod -aG docker "$DEPLOY_USER"   # note: docker group == root-equivalent; keep this account tight

if [[ -n ${DEPLOY_SSH_PUBKEY:-} ]]; then add_key "$DEPLOY_USER" "$DEPLOY_SSH_PUBKEY"; fi

# sshd is host-wide: on a shared server other people log in too (passwords, other users).
if [[ ${HOST_MODE:-shared} != dedicated ]]; then
  echo "users OK (shared host: sshd configuration left untouched)"
  exit 0
fi

if [[ -n ${ADMIN_SSH_PUBKEY:-} ]]; then add_key "$ADMIN_USER" "$ADMIN_SSH_PUBKEY"; fi

admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)
if [[ -z $admin_home || ! -s $admin_home/.ssh/authorized_keys ]]; then
  echo "WARN: $ADMIN_USER has no authorized_keys — skipping SSH hardening to avoid a lockout"
  exit 0
fi

allow="$ADMIN_USER"
if [[ -n ${DEPLOY_SSH_PUBKEY:-} ]]; then allow+=" $DEPLOY_USER"; fi

# 00- prefix: sshd uses the FIRST value it sees, so this beats cloud-init's 50-*.conf
sed -e "s/@ALLOW_USERS@/$allow/" "$INFRA_ROOT/bootstrap/files/sshd-hardening.conf" \
  > /etc/ssh/sshd_config.d/00-infra.conf
chmod 644 /etc/ssh/sshd_config.d/00-infra.conf
sshd -t
systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "users/ssh OK (AllowUsers: $allow)"
