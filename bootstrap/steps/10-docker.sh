#!/usr/bin/env bash
# Docker Engine + Compose plugin.
#
# - Docker missing: install from Docker's repo with our daemon.json (nobody else uses it yet).
# - Docker present on a SHARED host: leave it completely alone — no daemon.json change,
#   no restart (a restart would bounce everyone's containers). Our containers set their
#   own log limits in the compose templates, so we don't need the daemon defaults.
# - Docker present on a DEDICATED host: apply daemon.json and restart (live-restore).
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

fresh=false
if ! command -v docker >/dev/null; then
  fresh=true
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get -yq install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker is installed but the Compose v2 plugin is missing."
  echo "Install it (apt-get install docker-compose-plugin) — not done automatically on an existing Docker setup."
  exit 1
fi

if [[ $fresh == true || ${HOST_MODE:-shared} == dedicated ]]; then
  install -d -m 0755 /etc/docker
  if ! cmp -s "$INFRA_ROOT/bootstrap/files/docker-daemon.json" /etc/docker/daemon.json; then
    install -m 0644 "$INFRA_ROOT/bootstrap/files/docker-daemon.json" /etc/docker/daemon.json
    systemctl restart docker
  fi
  systemctl enable --now docker
else
  echo "existing Docker on a shared host: daemon.json and the Docker service left untouched"
fi

docker compose version
echo "docker OK"
