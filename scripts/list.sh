#!/usr/bin/env bash
# List every deployment on this server.
#
#   infra list [app]
SCRIPT_NAME=list
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; fi
load_infra_env
filter=${1:-*}

fmt='%-22s %-16s %-9s %-7s %-24s %-18s %-17s %s\n'
# shellcheck disable=SC2059
printf "$fmt" APP ENV SERVICES UP BRANCH TAG DEPLOYED URL
for meta in "$DEPLOY_ROOT"/$filter/*/meta.env; do
  (
    set +u
    . "$meta"
    running=$(docker ps -q --filter "label=com.docker.compose.project=$(stack_name "$APP" "$ENV_NAME")" | wc -l)
    deployed=$(date -d "@$DEPLOYED_AT" '+%Y-%m-%d %H:%M')
    # shellcheck disable=SC2059
    printf "$fmt" "$APP" "$ENV_NAME" "$SERVICES" "$running" "${BRANCH:0:24}" "${TAG:0:18}" "$deployed" "$URL"
  )
done
echo
echo "previews: $(count_previews)/$MAX_PREVIEWS"
