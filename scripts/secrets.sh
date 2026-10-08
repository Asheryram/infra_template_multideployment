#!/usr/bin/env bash
# Manage per-app runtime secrets on the server (run with sudo).
#
#   sudo infra secrets edit <app> <name>     name: common | preview | develop | staging | prod
#                                            or <class>.<component>, e.g. prod.api
#   sudo infra secrets list [app]
#
# Files live in $SECRETS_ROOT/<app>/<name>.env (root:deploy 0660) and are merged
# into the container env on the next deploy. Apply now with: infra redeploy <app> <env>
SCRIPT_NAME=secrets
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

action=${1:-}
if [[ -z $action || $action == -h || $action == --help ]]; then usage; fi
shift
load_infra_env
[[ $EUID -eq 0 ]] || die "run with sudo"

case $action in
  edit)
    app=${1:?app}; name=${2:?name, e.g. prod or prod.api}
    validate_name app "$app"
    [[ $name =~ ^[a-z0-9-]+(\.(app|web|api))?$ ]] || die "invalid name '$name'"
    dir="$SECRETS_ROOT/$app"; file="$dir/$name.env"
    install -d -m 2770 -o root -g "$DEPLOY_USER" "$SECRETS_ROOT" "$dir"
    if [[ ! -f $file ]]; then
      install -m 660 -o root -g "$DEPLOY_USER" /dev/null "$file"
      printf '# Secrets for %s (%s). KEY=value, one per line, no quotes needed.\n' "$app" "$name" > "$file"
    fi
    "${EDITOR:-nano}" "$file"
    chown root:"$DEPLOY_USER" "$file"; chmod 660 "$file"
    log "saved $file — apply with: infra redeploy $app <env>"
    ;;
  list)
    find "$SECRETS_ROOT/${1:-}" -name '*.env' -printf '%p  (%TY-%Tm-%Td, %s bytes)\n' 2>/dev/null | sort
    ;;
  *) die "unknown action: $action" ;;
esac
