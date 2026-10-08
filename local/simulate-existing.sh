#!/usr/bin/env bash
# Make the fake VPS look like the real, already-in-use server BEFORE bootstrap:
# someone else's Docker setup, firewall, apps, database with data, cached images and
# volumes — plus a compose project whose name looks like one of ours.
# Then records a baseline that verify-isolation.sh compares against.
#
#   sudo bash /opt/infra/local/simulate-existing.sh
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

echo "== Docker installed by 'someone else' (their own daemon.json)"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
if [[ ! -f /etc/docker/daemon.json ]]; then
  echo '{ "log-driver": "json-file", "log-opts": { "max-size": "50m" } }' > /etc/docker/daemon.json
  systemctl restart docker
fi

# In WSL every distro shares one network stack, so enabling ufw here would firewall your
# other distros too. Skip it there unless explicitly asked (SIMULATE_UFW=true).
if grep -qi microsoft /proc/version && [[ ${SIMULATE_UFW:-false} != true ]]; then
  echo "== (WSL) skipping firewall simulation — ufw would affect your other WSL distros"
else
  echo "== their firewall: ssh + their app on 8088"
  ufw allow 22/tcp >/dev/null
  ufw allow 8088/tcp comment 'legacy app' >/dev/null
  ufw --force enable >/dev/null
fi

echo "== their app: nginx + postgres with real data (compose project 'legacy')"
mkdir -p /opt/legacy
cat > /opt/legacy/docker-compose.yml <<'EOF'
name: legacy
services:
  web:
    image: nginx:alpine
    ports: ["8088:80"]
    restart: unless-stopped
  db:
    image: postgres:16-alpine
    environment: { POSTGRES_PASSWORD: legacy }
    volumes: [legacy-db:/var/lib/postgresql/data]
    restart: unless-stopped
volumes:
  legacy-db: {}
EOF
docker compose -f /opt/legacy/docker-compose.yml up -d
for _ in $(seq 1 30); do docker exec legacy-db-1 pg_isready -U postgres -q && break; sleep 2; done
docker exec legacy-db-1 psql -U postgres -qc \
  "CREATE TABLE IF NOT EXISTS customers(id int); TRUNCATE customers; INSERT INTO customers VALUES (1),(2),(3);"

echo "== a project named like one of our stacks would be WITHOUT a prefix ('shop-prod')"
docker rm -f shop-prod-app-1 >/dev/null 2>&1 || true
docker run -d --name shop-prod-app-1 --restart unless-stopped \
  --label com.docker.compose.project=shop-prod --label com.docker.compose.service=app \
  traefik/whoami:v1.10 >/dev/null

echo "== cached images and a volume nobody is using right now (global prune would delete them)"
docker pull -q redis:7-alpine >/dev/null
docker pull -q busybox:latest >/dev/null
docker volume create someone-elses-volume >/dev/null

bash "$(dirname "$0")/verify-isolation.sh" --record
echo
echo "Simulated existing workload is in place. Now bootstrap with HOST_MODE=shared."
