#!/usr/bin/env bash
# Docker Engine + Compose plugin from Docker's official repo, with log rotation
# and sane daemon defaults (bootstrap/files/docker-daemon.json).
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null; then
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

install -d -m 0755 /etc/docker
if ! cmp -s "$INFRA_ROOT/bootstrap/files/docker-daemon.json" /etc/docker/daemon.json; then
  install -m 0644 "$INFRA_ROOT/bootstrap/files/docker-daemon.json" /etc/docker/daemon.json
  # live-restore keeps containers running across this restart
  systemctl restart docker
fi
systemctl enable --now docker
docker compose version
echo "docker OK"
