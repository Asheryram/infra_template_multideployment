#!/usr/bin/env bash
# Remove EVERYTHING this template installed — and nothing else. Lets you back out of a
# shared host cleanly (or reset a test machine). Other users' containers, images,
# volumes, firewall rules and packages are left exactly as they are.
#
#   sudo bash bootstrap/uninstall.sh            asks for confirmation
#   sudo bash bootstrap/uninstall.sh --yes
#
# Removes: all infra stacks + their DBs, the platform (incl. its volumes: Postgres data!),
# images we pulled, our ufw rules, cron/logrotate files, /usr/local/bin/infra,
# /etc/infra, /srv/deployments, /var/lib/infra, /var/log/infra, the deploy user.
# Keeps: /srv/backups (delete by hand once you're sure), installed apt packages, Docker.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

ENV_FILE=/etc/infra/infra.env
[[ -f /etc/infra/.managed-by-infra-template ]] || { echo "no infra installation found (/etc/infra marker missing)"; exit 1; }
set -a; . "$ENV_FILE"; set +a
DEPLOY_USER=${DEPLOY_USER:-deploy}
STATE_DIR=${STATE_DIR:-/var/lib/infra}
DEPLOY_ROOT=${DEPLOY_ROOT:-/srv/deployments}

if [[ ${1:-} != --yes ]]; then
  echo "This deletes every infra deployment, the platform and its Postgres data on $(hostname)."
  read -r -p "Type 'uninstall' to continue: " answer
  [[ $answer == uninstall ]] || { echo "aborted"; exit 1; }
fi

echo "== app stacks"
for meta in "$DEPLOY_ROOT"/*/*/meta.env; do
  [[ -f $meta ]] || continue
  app=$(. "$meta"; echo "$APP"); env=$(. "$meta"; echo "$ENV_NAME")
  sudo -u "$DEPLOY_USER" infra destroy --app "$app" --env "$env" --i-really-mean-prod || echo "  could not destroy $app/$env"
done
# Anything left that carries our label (e.g. a half-finished deploy)
docker ps -aq --filter label=infra.managed=true | xargs -r docker rm -f

echo "== platform"
if [[ -n ${INFRA_ROOT:-} && -f $INFRA_ROOT/platform/docker-compose.yml ]]; then
  files=(-f "$INFRA_ROOT/platform/docker-compose.yml")
  [[ -f $STATE_DIR/platform-managed.yml ]] && files+=(-f "$STATE_DIR/platform-managed.yml")
  TRAEFIK_STATE_DIR="$STATE_DIR/traefik" POSTGRES_PASSWORD=x COMPOSE_PROFILES="${PLATFORM_PROFILES:-}" \
    docker compose -p infra-platform "${files[@]}" down --volumes --remove-orphans || true
fi
for n in infra_proxy infra_data infra_socket infra_metrics; do
  if [[ $(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$n" 2>/dev/null) == infra-platform ]]; then
    docker network rm "$n" >/dev/null || true
  fi
done

echo "== images we pulled (only those not used by any container)"
if [[ -f $STATE_DIR/owned-images ]]; then
  in_use=$(docker ps -a --format '{{.Image}}' | sort -u)
  awk '{print $2}' "$STATE_DIR/owned-images" | sort -u | while read -r img; do
    grep -qxF "$img" <<<"$in_use" && continue
    docker rmi "$img" >/dev/null 2>&1 && echo "  removed $img" || true
  done
fi

echo "== firewall rules we added"
if command -v ufw >/dev/null; then
  while ufw status numbered | grep -q 'infra traefik'; do
    n=$(ufw status numbered | grep 'infra traefik' | head -1 | sed -E 's/^\[ *([0-9]+)\].*/\1/')
    ufw --force delete "$n" >/dev/null
  done
fi

echo "== the GitHub runner (if installed)"
if [[ -f /opt/actions-runner/.runner ]]; then
  (cd /opt/actions-runner && ./svc.sh stop && ./svc.sh uninstall) || true
  rm -rf /opt/actions-runner
  echo "  NOTE: also remove the runner in GitHub (Settings → Actions → Runners)"
fi

docker rmi infra-console:local >/dev/null 2>&1 || true

echo "== files, user"
rm -f /etc/cron.d/infra /etc/logrotate.d/infra /etc/tmpfiles.d/infra.conf /usr/local/bin/infra
rm -rf "$DEPLOY_ROOT" "$STATE_DIR" /var/log/infra /run/lock/infra /etc/infra
if id "$DEPLOY_USER" &>/dev/null; then userdel -r "$DEPLOY_USER" 2>/dev/null || userdel "$DEPLOY_USER"; fi

echo
echo "Uninstalled. Kept: ${BACKUP_DIR:-/srv/backups} (backups), apt packages, Docker itself."
