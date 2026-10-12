#!/usr/bin/env bash
# Create (or update) ONLY the Keycloak client used by the previews oauth2-proxy (PREVIEW_AUTH_MODE=keycloak).
# On a fresh install prefer platform/keycloak/bootstrap-realm.sh, which does this and more; this script is for
# adding previews SSO to a platform whose realm already exists.
#
#   sudo bash platform/keycloak/create-previews-client.sh [--dry-run]
#
# Needs OAUTH2_PREVIEWS_CLIENT_SECRET in /etc/infra/platform.secrets.env. The single redirect URI is the fixed
# callback host https://sso.<domain>[:port]/oauth2/callback (Keycloak cannot register wildcard hosts).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

DRY=0; [[ ${1:-} == --dry-run ]] && DRY=1
kc_load_env
CLIENT_ID=${OAUTH2_PREVIEWS_CLIENT_ID:-infra-previews}
: "${OAUTH2_PREVIEWS_CLIENT_SECRET:?set OAUTH2_PREVIEWS_CLIENT_SECRET in /etc/infra/platform.secrets.env first}"
REDIRECT="https://sso.${DOMAIN}${PUBLIC_SUFFIX}/oauth2/callback"
echo "realm:     $REALM"
echo "client:    $CLIENT_ID"
echo "redirect:  $REDIRECT"
if (( DRY )); then echo "(dry run — nothing changed)"; exit 0; fi

kc_login
ensure_client "$CLIENT_ID" "$OAUTH2_PREVIEWS_CLIENT_SECRET" "$REDIRECT"
echo "done. Next: set PREVIEW_AUTH_MODE=keycloak and add keycloak-previews to PLATFORM_PROFILES, then: sudo -u deploy infra platform up"
