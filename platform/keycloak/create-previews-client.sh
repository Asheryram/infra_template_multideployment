#!/usr/bin/env bash
# Create (or update) the Keycloak OIDC client used by the previews oauth2-proxy (PREVIEW_AUTH_MODE=keycloak).
#
#   sudo bash platform/keycloak/create-previews-client.sh [--dry-run]
#
# Reads /etc/infra/infra.env and /etc/infra/platform.secrets.env. Needs, in the secrets file:
#   KEYCLOAK_ADMIN_PASSWORD, OAUTH2_PREVIEWS_CLIENT_SECRET   (openssl rand -hex 32)
# It only touches ONE client (default id: infra-previews) in the realm — it never edits other clients, users or
# realm settings. The redirect URI is the single fixed callback host https://sso.<domain>[:port]/oauth2/callback,
# because Keycloak cannot register wildcard hosts; the session cookie is shared across *.<domain> by oauth2-proxy.
set -euo pipefail

DRY=0; [[ ${1:-} == --dry-run ]] && DRY=1
set -a
# shellcheck disable=SC1091
. /etc/infra/infra.env
# shellcheck disable=SC1091
. /etc/infra/platform.secrets.env
set +a

REALM=${KEYCLOAK_REALM:-infra}
CLIENT_ID=${OAUTH2_PREVIEWS_CLIENT_ID:-infra-previews}
: "${DOMAIN:?DOMAIN missing in infra.env}" "${KEYCLOAK_ADMIN_PASSWORD:?missing}" "${OAUTH2_PREVIEWS_CLIENT_SECRET:?set OAUTH2_PREVIEWS_CLIENT_SECRET first}"
SUFFIX=""
if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then SUFFIX=":$TRAEFIK_HTTPS_PORT"; fi
REDIRECT="https://sso.${DOMAIN}${SUFFIX}/oauth2/callback"
KC=(docker exec -e KCPW="$KEYCLOAK_ADMIN_PASSWORD" infra-keycloak)
kcadm() { "${KC[@]}" /opt/keycloak/bin/kcadm.sh "$@"; }

echo "realm:     $REALM"
echo "client:    $CLIENT_ID"
echo "redirect:  $REDIRECT"
if (( DRY )); then echo "(dry run — nothing changed)"; exit 0; fi

"${KC[@]}" bash -c '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master \
  --user "${KEYCLOAK_ADMIN_USERNAME:-admin}" --password "$KCPW"' >/dev/null

existing=$(kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r' | head -1)
args=(-r "$REALM" -s "clientId=$CLIENT_ID" -s protocol=openid-connect -s publicClient=false
      -s standardFlowEnabled=true -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false
      -s "secret=$OAUTH2_PREVIEWS_CLIENT_SECRET" -s "redirectUris=[\"$REDIRECT\"]" -s 'webOrigins=["+"]')
if [[ -n $existing ]]; then
  echo "updating existing client $existing"
  kcadm update "clients/$existing" "${args[@]}"
  id=$existing
else
  echo "creating client"
  id=$(kcadm create clients "${args[@]}" -i | tr -d '\r')
fi

# The proxy reads group membership from the `groups` claim (platform admins are recognised by group).
# Attach the realm's `groups` client scope if it exists; otherwise add the same mapper the infra-console client uses.
scope=$(kcadm get client-scopes -r "$REALM" -q name=groups --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -1 || true)
if [[ -n $scope ]]; then
  kcadm update "clients/$id/default-client-scopes/$scope" -r "$REALM" >/dev/null 2>&1 \
    && echo "attached the 'groups' client scope" || echo "NOTE: could not attach the 'groups' scope — add it in Keycloak → Clients → $CLIENT_ID → Client scopes"
else
  echo "NOTE: no 'groups' client scope found — copy whatever infra-console uses for its groups claim to $CLIENT_ID"
fi
echo "done. Next: set PREVIEW_AUTH_MODE=keycloak and add keycloak-previews to PLATFORM_PROFILES, then: sudo -u deploy infra platform up"
