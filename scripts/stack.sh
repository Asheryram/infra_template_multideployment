#!/usr/bin/env bash
# Inspect or poke a running deployment.
#
#   infra logs    <app> <env> [service]           follow logs (last 200 lines)
#   infra ps      <app> <env>
#   infra restart <app> <env> [service]
#   infra exec    <app> <env> <service> [cmd...]  default cmd: sh
#   infra config  <app> <env>                     print the fully resolved compose file
#   infra env     <app> <env> [component]         show generated runtime env (secrets masked)
SCRIPT_NAME=stack
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

action=${1:-}
if [[ -z $action || $action == -h || $action == --help ]]; then usage; fi
app=${2:?usage: infra $action <app> <env>}
env=${3:?usage: infra $action <app> <env>}
shift 3

load_infra_env
load_stack "$app" "$env"

case $action in
  logs)    "${COMPOSE[@]}" logs -f --tail 200 "$@" ;;
  tail)    "${COMPOSE[@]}" logs --no-color --timestamps --tail "${1:-200}" ;;
  ps)      "${COMPOSE[@]}" ps -a ;;
  restart) "${COMPOSE[@]}" restart "$@" ;;
  config)  "${COMPOSE[@]}" config ;;
  exec)
    svc=${1:?service name required}; shift
    if (( $# )); then "${COMPOSE[@]}" exec "$svc" "$@"; else "${COMPOSE[@]}" exec "$svc" sh; fi
    ;;
  env)
    for f in "$STACK_DIR"/runtime/${1:-*}.env; do
      echo "== $f"
      sed -E 's/^([A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|KEY|DATABASE_URL)[A-Za-z0-9_]*)=.*/\1=****/' "$f"
    done
    ;;
  *) die "unknown action: $action" ;;
esac
