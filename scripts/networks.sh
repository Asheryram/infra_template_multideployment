#!/usr/bin/env bash
# Per-environment network maintenance.
#
#   infra networks list         every environment network, and who is attached
#   infra networks reconnect    re-attach Traefik/Postgres to every environment network
#                               (run automatically by `infra platform up` — recreating the
#                               platform containers drops runtime network connections)
#   infra networks migrate      move every existing environment onto its own private network
#                               (one-time, after upgrading from the shared infra_proxy/infra_data layout)
SCRIPT_NAME=networks
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

action=${1:-}
if [[ -z $action || $action == -h || $action == --help ]]; then usage; fi
load_infra_env

case $action in
  list)
    printf '%-42s %s\n' NETWORK ATTACHED
    for meta in "$DEPLOY_ROOT"/*/*/meta.env; do
      net=$(meta_get "$meta" STACK_NETWORK)
      [[ -n $net ]] || { printf '%-42s %s\n' "$(meta_get "$meta" APP)/$(meta_get "$meta" ENV_NAME)" "(legacy shared networks — run: infra networks migrate)"; continue; }
      printf '%-42s %s\n' "$net" "$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net" 2>/dev/null || echo missing)"
    done
    ;;

  reconnect)
    n=0
    for meta in "$DEPLOY_ROOT"/*/*/meta.env; do
      net=$(meta_get "$meta" STACK_NETWORK)
      [[ -n $net ]] && docker network inspect "$net" >/dev/null 2>&1 || continue
      net_connect "$net" "$TRAEFIK_CONTAINER"
      if [[ $(meta_get "$meta" USES_PG) == true ]]; then net_connect "$net" "$PG_CONTAINER"; fi
      n=$((n + 1))
    done
    log "reconnected platform to $n environment network(s)"
    ;;

  migrate)
    enable_file_log
    for meta in "$DEPLOY_ROOT"/*/*/meta.env; do
      [[ -z $(meta_get "$meta" STACK_NETWORK) ]] || continue
      app=$(meta_get "$meta" APP); env=$(meta_get "$meta" ENV_NAME)
      log "moving $app/$env onto its own network"
      run_clean "$INFRA_ROOT/scripts/deploy.sh" --app "$app" --env "$env" --redeploy --no-pull || warn "failed: $app/$env"
    done
    log "done — 'infra networks list' to check"
    ;;

  *) die "unknown action: $action" ;;
esac
