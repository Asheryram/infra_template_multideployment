#!/usr/bin/env bash
# Shared helpers for the Keycloak setup scripts. Source it; do not run it.
# Everything goes through kcadm inside the infra-keycloak container and only touches the realm named by
# KEYCLOAK_REALM (default: infra). It never edits the master realm or any other realm.

kc_load_env() {
  set -a
  # shellcheck disable=SC1091
  . /etc/infra/infra.env
  # shellcheck disable=SC1091
  . /etc/infra/platform.secrets.env
  set +a
  REALM=${KEYCLOAK_REALM:-infra}
  ADMIN_GROUP=${KEYCLOAK_PLATFORM_ADMIN_GROUP:-infra-platform-admins}
  : "${DOMAIN:?DOMAIN missing in /etc/infra/infra.env}" "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD missing}"
  PUBLIC_SUFFIX=""
  if [[ ${TLS_MODE:-selfsigned} != external && ${TRAEFIK_HTTPS_PORT:-443} != 443 ]]; then PUBLIC_SUFFIX=":$TRAEFIK_HTTPS_PORT"; fi
  KC=(docker exec -e KCPW="$KEYCLOAK_ADMIN_PASSWORD" -e KCUSER="${KEYCLOAK_ADMIN_USERNAME:-admin}" infra-keycloak)
}

kcadm() { "${KC[@]}" /opt/keycloak/bin/kcadm.sh "$@"; }

kc_login() {
  docker inspect -f '{{.State.Running}}' infra-keycloak 2>/dev/null | grep -q true \
    || { echo "infra-keycloak is not running — run: sudo -u deploy infra platform up" >&2; return 1; }
  local i
  for i in $(seq 1 30); do   # Keycloak needs a while to boot on a fresh database
    if "${KC[@]}" bash -c '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master \
         --user "$KCUSER" --password "$KCPW"' >/dev/null 2>&1; then return 0; fi
    sleep 5
  done
  echo "could not log in to Keycloak as admin (is it still starting? is KEYCLOAK_ADMIN_PASSWORD the one it was first started with?)" >&2
  return 1
}

kc_csv() { tr -d '\r'; }

# ensure_client <client_id> <secret> <redirect_uri>   → sets CLIENT_UUID. Creates or updates ONE client and
# gives it the same two mappers the console needs: a `groups` claim and the client's own audience.
# The realm has no `groups` client scope, so none is requested — client-level mappers always apply.
ensure_client() {
  local cid=$1 secret=$2 redirect=$3 existing have
  existing=$(kcadm get clients -r "$REALM" -q "clientId=$cid" --fields id --format csv --noquotes | kc_csv | head -1)
  local args=(-r "$REALM" -s "clientId=$cid" -s protocol=openid-connect -s publicClient=false
              -s standardFlowEnabled=true -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false
              -s "secret=$secret" -s "redirectUris=[\"$redirect\"]" -s 'webOrigins=["+"]')
  if [[ -n $existing ]]; then
    kcadm update "clients/$existing" "${args[@]}"; CLIENT_UUID=$existing; echo "updated client $cid"
  else
    CLIENT_UUID=$(kcadm create clients "${args[@]}" -i | kc_csv); echo "created client $cid"
  fi
  have=$(kcadm get "clients/$CLIENT_UUID/protocol-mappers/models" -r "$REALM" --fields name --format csv --noquotes | kc_csv)
  _add_mapper() { # name type config-json
    if grep -qx "$1" <<<"$have"; then return 0; fi
    kcadm create "clients/$CLIENT_UUID/protocol-mappers/models" -r "$REALM" -s "name=$1" -s protocol=openid-connect \
      -s "protocolMapper=$2" -s "config=$3" >/dev/null && echo "  added mapper $1"
  }
  _add_mapper "$cid-groups" oidc-group-membership-mapper \
    '{"claim.name":"groups","full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}'
  _add_mapper "$cid-audience" oidc-audience-mapper \
    "{\"included.client.audience\":\"$cid\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\"}"
}

# ensure_user_admin_client <client_id> <secret>
# A confidential, service-account-only client (no login flows). Its service account gets just the realm-management
# roles needed to create and look up users in THIS realm. Keycloak cannot narrow these further (no per-group
# delegation), so the console is deliberately create-only: it never edits or resets an account it did not just create
# and never touches the platform-admin group. Disable the feature entirely with INVITE_CREATE_ACCOUNTS=false.
ensure_user_admin_client() {
  local cid=$1 secret=$2 existing id
  existing=$(kcadm get clients -r "$REALM" -q "clientId=$cid" --fields id --format csv --noquotes | kc_csv | head -1)
  local args=(-r "$REALM" -s "clientId=$cid" -s protocol=openid-connect -s publicClient=false -s standardFlowEnabled=false
              -s directAccessGrantsEnabled=false -s implicitFlowEnabled=false -s serviceAccountsEnabled=true -s "secret=$secret")
  if [[ -n $existing ]]; then kcadm update "clients/$existing" "${args[@]}"; id=$existing; echo "updated client $cid"
  else id=$(kcadm create clients "${args[@]}" -i | kc_csv); echo "created client $cid"; fi
  kcadm add-roles -r "$REALM" --uusername "service-account-$cid" --cclientid realm-management \
    --rolename manage-users --rolename view-users --rolename query-users
  echo "  service account may create/look up users in realm $REALM"
}
