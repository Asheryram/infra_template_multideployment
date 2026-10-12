#!/usr/bin/env bash
# Install the infra CLI, config, directories and cron jobs.
set -Eeuo pipefail

G=$DEPLOY_USER

# Config: /etc/infra is root-owned, readable by the deploy group only.
install -d -m 750 -o root -g "$G" /etc/infra
# secrets: group-writable so the console (runs as the deploy user) can manage variables
install -d -m 2770 -o root -g "$G" /etc/infra/secrets
find /etc/infra/secrets -mindepth 1 -type d -exec chmod 2770 {} + -o -type f -exec chmod 660 {} +
echo "Created by infra bootstrap ($INFRA_ROOT). Preflight uses this to recognise our own files." \
  > /etc/infra/.managed-by-infra-template
install -m 640 -o root -g "$G" "$INVENTORY_FILE" /etc/infra/infra.env
printf "\nINFRA_ROOT='%s'\n" "$INFRA_ROOT" >> /etc/infra/infra.env

if [[ ! -f /etc/infra/platform.secrets.env ]]; then
  sed -e "s/@GENERATED@/$(openssl rand -hex 24)/g" \
      -e "s/@AUTHENTIK_DB_PASSWORD@/$(openssl rand -hex 32)/g" \
      -e "s/@AUTHENTIK_SECRET_KEY@/$(openssl rand -hex 50)/g" \
      -e "s/@KEYCLOAK_DB_PASSWORD@/$(openssl rand -hex 32)/g" \
      -e "s/@KEYCLOAK_ADMIN_PASSWORD@/$(openssl rand -hex 32)/g" \
      -e "s/@OAUTH2_PROXY_CLIENT_SECRET@/$(openssl rand -hex 32)/g" \
      -e "s|@OAUTH2_PROXY_COOKIE_SECRET@|$(openssl rand -base64 24 | tr -d '\n')|g" \
      -e "s/@OAUTH2_PREVIEWS_CLIENT_SECRET@/$(openssl rand -hex 32)/g" \
      -e "s|@OAUTH2_PREVIEWS_COOKIE_SECRET@|$(openssl rand -base64 24 | tr -d '\n')|g" \
      "$INFRA_ROOT/inventory/platform.secrets.env.example" \
    > /etc/infra/platform.secrets.env
  echo "created /etc/infra/platform.secrets.env with a generated POSTGRES_PASSWORD"
fi
if ! grep -q '^AUTHENTIK_POSTGRES_PASSWORD=' /etc/infra/platform.secrets.env; then
  printf 'AUTHENTIK_POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)" >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^AUTHENTIK_SECRET_KEY=' /etc/infra/platform.secrets.env; then
  printf 'AUTHENTIK_SECRET_KEY=%s\n' "$(openssl rand -hex 50)" >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^AUTHENTIK_BOOTSTRAP_EMAIL=' /etc/infra/platform.secrets.env; then
  printf 'AUTHENTIK_BOOTSTRAP_EMAIL=\n' >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^AUTHENTIK_BOOTSTRAP_PASSWORD=' /etc/infra/platform.secrets.env; then
  printf 'AUTHENTIK_BOOTSTRAP_PASSWORD=\n' >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^KEYCLOAK_POSTGRES_PASSWORD=' /etc/infra/platform.secrets.env; then
  printf 'KEYCLOAK_POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)" >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^KEYCLOAK_ADMIN_PASSWORD=' /etc/infra/platform.secrets.env; then
  printf 'KEYCLOAK_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 32)" >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^OAUTH2_PROXY_CLIENT_SECRET=' /etc/infra/platform.secrets.env; then
  printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\n' "$(openssl rand -hex 32)" >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^OAUTH2_PROXY_COOKIE_SECRET=' /etc/infra/platform.secrets.env; then
  printf 'OAUTH2_PROXY_COOKIE_SECRET=%s\n' "$(openssl rand -base64 24 | tr -d '\n')" >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^OAUTH2_PREVIEWS_CLIENT_SECRET=' /etc/infra/platform.secrets.env; then
  printf 'OAUTH2_PREVIEWS_CLIENT_SECRET=%s\n' "$(openssl rand -hex 32)" >> /etc/infra/platform.secrets.env
fi
if ! grep -q '^OAUTH2_PREVIEWS_COOKIE_SECRET=' /etc/infra/platform.secrets.env; then
  printf 'OAUTH2_PREVIEWS_COOKIE_SECRET=%s\n' "$(openssl rand -base64 24 | tr -d '\n')" >> /etc/infra/platform.secrets.env
fi
chown root:"$G" /etc/infra/platform.secrets.env
chmod 640 /etc/infra/platform.secrets.env

if [[ ${TLS_MODE:-selfsigned} == letsencrypt && ! -f /etc/infra/traefik.env ]]; then
  install -m 640 -o root -g "$G" "$INFRA_ROOT/inventory/traefik.env.example" /etc/infra/traefik.env
  echo "created /etc/infra/traefik.env — ADD YOUR DNS PROVIDER TOKEN before 'infra platform up'"
fi

# State and data directories, owned by the deploy user.
for d in "${DEPLOY_ROOT:-/srv/deployments}" "${STATE_DIR:-/var/lib/infra}"; do
  install -d -m 750 -o "$G" -g "$G" "$d"
done
install -d -m 700 -o "$G" -g "$G" "${BACKUP_DIR:-/srv/backups}"

# Deploy locks live in /run (tmpfs — wiped at every boot). Recreate the directory with the right
# owner at boot; otherwise Docker may create it as root when it bind-mounts it into the console.
echo "d ${LOCK_DIR:-/run/lock/infra} 2775 root $G -" > /etc/tmpfiles.d/infra.conf
systemd-tmpfiles --create /etc/tmpfiles.d/infra.conf
chown root:"$G" "${LOCK_DIR:-/run/lock/infra}"; chmod 2775 "${LOCK_DIR:-/run/lock/infra}"

# CLI wrapper (works even if the repo is on a mount without exec bits).
cat > /usr/local/bin/infra <<EOF
#!/bin/sh
exec bash "$INFRA_ROOT/bin/infra" "\$@"
EOF
chmod 755 /usr/local/bin/infra

sed "s/@DEPLOY_USER@/$G/g" "$INFRA_ROOT/bootstrap/files/cron" > /etc/cron.d/infra
chmod 644 /etc/cron.d/infra

# GitOps watcher — starts automatically after platform up, restarts on failure.
sed -e "s|@DEPLOY_USER@|$G|g" -e "s|@INFRA_ROOT@|$INFRA_ROOT|g" \
  "$INFRA_ROOT/bootstrap/files/infra-gitops.service" > /etc/systemd/system/infra-gitops.service
systemctl daemon-reload
systemctl enable infra-gitops.service
echo "infra-gitops.service enabled — starts automatically after 'infra platform up'"

echo "infra OK — CLI at /usr/local/bin/infra, config in /etc/infra"
