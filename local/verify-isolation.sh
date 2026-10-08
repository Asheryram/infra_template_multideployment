#!/usr/bin/env bash
# Proves our platform didn't touch anything it didn't create.
#
#   sudo bash verify-isolation.sh --record    snapshot the existing workload (simulate-existing.sh does this)
#   sudo bash verify-isolation.sh             compare now vs snapshot
#
# Checks: foreign containers never restarted/recreated, their volumes/images still exist,
# their DB data intact, their app still answers, Docker daemon.json + sshd config unchanged,
# every firewall rule they had still present.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

B=/var/lib/isolation-baseline
ufw_status() { if command -v ufw >/dev/null; then ufw status; else echo "Status: not installed"; fi; }
foreign_containers() {
  docker ps -a --format '{{.Names}}\t{{.Label "infra.managed"}}' | awk -F'\t' '$2 != "true" {print $1}' | sort
}
container_state() { # name → id + start time (changes if restarted or recreated)
  docker inspect -f '{{.Name}} {{.Id}} {{.State.StartedAt}} {{.State.Status}}' "$1"
}
config_hashes() {
  sha256sum /etc/docker/daemon.json /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || true
  sysctl -n vm.swappiness net.core.somaxconn
  readlink -f /etc/localtime
}

if [[ ${1:-} == --record ]]; then
  rm -rf "$B"; mkdir -p "$B"
  for c in $(foreign_containers); do container_state "$c"; done > "$B/containers"
  docker volume ls -q | grep -v '^infra' | sort > "$B/volumes" || true
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort > "$B/images"
  config_hashes > "$B/config"
  ufw_status | sed -n '/^--/,$p' | tail -n +2 | sed 's/ \+/ /g; s/ *$//' > "$B/ufw"
  ufw_status | head -1 > "$B/ufw-status"
  if docker inspect legacy-db-1 >/dev/null 2>&1; then   # only when simulate-existing.sh was used
    docker exec legacy-db-1 psql -U postgres -tAc 'SELECT count(*) FROM customers' > "$B/rows"
  fi
  # Every published port of an existing container must still answer afterwards.
  { docker ps --format '{{.Ports}}' | grep -oE '0\.0\.0\.0:[0-9]+' | cut -d: -f2 | sort -u || true; } > "$B/ports"
  echo "baseline recorded in $B: $(wc -l < "$B/containers") containers, $(wc -l < "$B/volumes") volumes, $(wc -l < "$B/images") images"
  exit 0
fi

[[ -d $B ]] || { echo "no baseline — run simulate-existing.sh first"; exit 1; }
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }

echo "== existing containers untouched (same ID, never restarted)"
while read -r name id started status; do
  name=${name#/}
  now=$(container_state "$name" 2>/dev/null || echo "missing")
  if [[ $now == "/$name $id $started $status" ]]; then ok "$name"; else bad "$name changed: was [$id $started $status] now [$now]"; fi
done < "$B/containers"

echo "== existing volumes and images still there"
while read -r v; do docker volume inspect "$v" >/dev/null 2>&1 && ok "volume $v" || bad "volume $v deleted"; done < "$B/volumes"
while read -r i; do docker image inspect "$i" >/dev/null 2>&1 && ok "image $i" || bad "image $i deleted"; done < "$B/images"

echo "== existing data and services"
if [[ -f $B/rows ]]; then
  rows=$(docker exec legacy-db-1 psql -U postgres -tAc 'SELECT count(*) FROM customers' 2>/dev/null || echo "?")
  [[ $rows == "$(cat "$B/rows")" ]] && ok "legacy DB still has $rows rows" || bad "legacy DB rows: $rows (expected $(cat "$B/rows"))"
fi
while read -r port; do
  [[ -n $port ]] || continue
  if timeout 3 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then ok "existing service on :$port still accepts connections"
  else bad "existing service on :$port no longer reachable"; fi
done < "$B/ports"

echo "== host-wide config unchanged"
if diff -q <(config_hashes) "$B/config" >/dev/null; then ok "daemon.json, sshd, sysctl, timezone"
else bad "host config changed:"; diff <(config_hashes) "$B/config" | sed 's/^/        /'; fi
now_ufw=$(ufw_status | sed -n '/^--/,$p' | tail -n +2 | sed 's/ \+/ /g; s/ *$//')
missing=0
while read -r rule; do [[ -z $rule ]] && continue; grep -qxF "$rule" <<<"$now_ufw" || { bad "firewall rule removed: $rule"; missing=1; }; done < "$B/ufw"
(( missing )) || ok "all existing firewall rules still present"
[[ $(ufw_status | head -1) == "$(cat "$B/ufw-status")" ]] && ok "ufw state unchanged ($(cat "$B/ufw-status"))" || bad "ufw state changed: $(ufw_status | head -1)"

echo
echo "isolation: passed $pass, failed $fail"
(( fail == 0 ))
