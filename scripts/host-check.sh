#!/usr/bin/env bash
# Lightweight host watchdog (cron, every 10 min). Alerts via ALERT_WEBHOOK_URL,
# at most once per ALERT_REPEAT_MINUTES per problem.
#
#   infra host-check
SCRIPT_NAME=host-check
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; fi
load_infra_env
problems=0

check() { # key condition-ok message
  if [[ $2 == ok ]]; then alert_clear "$1"; else alert_throttled "$1" "$3"; problems=$((problems + 1)); fi
}

for mount in / /var/lib/docker; do
  [[ -d $mount ]] || continue
  pct=$(df --output=pcent "$mount" | tail -1 | tr -dc 0-9)
  key="disk${mount//\//_}"
  if (( pct < DISK_ALERT_PCT )); then check "$key" ok; else check "$key" bad "disk $mount at ${pct}% (threshold ${DISK_ALERT_PCT}%) — try 'infra cleanup'"; fi
done

avail=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d", a*100/t}' /proc/meminfo)
if (( avail > ${MEM_ALERT_AVAIL_PCT:-10} )); then check mem ok; else check mem bad "only ${avail}% memory available"; fi

for c in infra-traefik infra-postgres; do
  if [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]]; then check "$c" ok
  else check "$c" bad "platform container $c is NOT running — run 'infra platform up'"; fi
done

# Only our containers — other people's apps on this host are not ours to alert on.
unhealthy=$(docker ps --filter "label=$MANAGED_LABEL" --filter health=unhealthy --format '{{.Names}}' | paste -sd, -)
if [[ -z $unhealthy ]]; then check unhealthy ok; else check unhealthy bad "unhealthy containers: $unhealthy"; fi

restarting=$(docker ps --filter "label=$MANAGED_LABEL" --filter status=restarting --format '{{.Names}}' | paste -sd, -)
if [[ -z $restarting ]]; then check restarting ok; else check restarting bad "crash-looping containers: $restarting"; fi

if [[ -f /var/run/reboot-required ]]; then check reboot bad "reboot required after security updates"; else check reboot ok; fi

log "checks done, $problems problem(s)"
