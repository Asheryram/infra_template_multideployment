#!/usr/bin/env bash
# Set up Keycloak for the infra platform from a fresh install — realm, platform-admin group, console client,
# optional previews client and an optional first admin user. Idempotent: safe to re-run.
#
#   sudo bash platform/keycloak/bootstrap-realm.sh --admin-user asher --admin-email asher@example.com
#   sudo bash platform/keycloak/bootstrap-realm.sh --admin-user asher --admin-email asher@example.com --apply
#   sudo bash platform/keycloak/bootstrap-realm.sh --dry-run
#
#   --admin-user/--admin-email   create (or reuse) this user, mark the email verified and put them in the
#                                platform-admin group (KEYCLOAK_PLATFORM_ADMIN_GROUP, default infra-platform-admins)
#   --admin-password <pw>        initial password (default: generated and printed once; the user must change it)
#   --apply                      afterwards switch EVERYTHING to Keycloak login — console, environment gates and the
#                                ops tools (Traefik dashboard, logs) — by editing /etc/infra/infra.env after a
#                                timestamped backup, then running `infra platform up`
#   --dry-run                    print what would be done, change nothing
#
# Requires: the platform is up with PLATFORM_PROFILES containing `keycloak` (Keycloak running), run as root.
# Touches only the realm named by KEYCLOAK_REALM (default: infra) — never the master realm.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ADMIN_USER="" ADMIN_EMAIL="" ADMIN_PW="" APPLY=0 DRY=0
while (( $# )); do
  case $1 in
    --admin-user)     ADMIN_USER=${2:?}; shift 2 ;;
    --admin-email)    ADMIN_EMAIL=${2:?}; shift 2 ;;
    --admin-password) ADMIN_PW=${2:?}; shift 2 ;;
    --apply)          APPLY=1; shift ;;
    --dry-run)        DRY=1; shift ;;
    -h|--help)        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ -z $ADMIN_USER || -n $ADMIN_EMAIL ]] || { echo "--admin-user needs --admin-email" >&2; exit 2; }
[[ -z $ADMIN_USER || $ADMIN_USER =~ ^[a-zA-Z0-9._-]{2,40}$ ]] || { echo "bad --admin-user" >&2; exit 2; }
[[ -z $ADMIN_EMAIL || $ADMIN_EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "bad --admin-email" >&2; exit 2; }

kc_load_env
CONSOLE_CLIENT=${OAUTH2_PROXY_CLIENT_ID:-infra-console}
PREVIEWS_CLIENT=${OAUTH2_PREVIEWS_CLIENT_ID:-infra-previews}
: "${OAUTH2_PROXY_CLIENT_SECRET:?OAUTH2_PROXY_CLIENT_SECRET missing in platform.secrets.env}"

echo "realm:            $REALM"
echo "admin group:      $ADMIN_GROUP"
echo "console client:   $CONSOLE_CLIENT  → https://console.${DOMAIN}${PUBLIC_SUFFIX}/oauth2/callback"
if [[ -n ${OAUTH2_PREVIEWS_CLIENT_SECRET:-} ]]; then
  echo "previews client:  $PREVIEWS_CLIENT  → https://sso.${DOMAIN}${PUBLIC_SUFFIX}/oauth2/callback"
fi
[[ -z ${KEYCLOAK_USER_ADMIN_SECRET:-} ]] || echo "user-admin client: ${KEYCLOAK_USER_ADMIN_CLIENT:-infra-user-admin}  (service account: create/look up users)"
[[ -z $ADMIN_USER ]] || echo "first admin:      $ADMIN_USER <$ADMIN_EMAIL>"
if (( DRY )); then echo "(dry run — nothing changed)"; exit 0; fi

kc_login

# --- realm
if kcadm get "realms/$REALM" >/dev/null 2>&1; then
  echo "realm $REALM exists"
else
  kcadm create realms -s "realm=$REALM" -s enabled=true -s registrationAllowed=false -s loginWithEmailAllowed=true \
    -s duplicateEmailsAllowed=false -s bruteForceProtected=true -s sslRequired=external >/dev/null
  echo "created realm $REALM"
fi

# --- platform-admin group
group_id=$(kcadm get groups -r "$REALM" --fields id,name --format csv --noquotes | kc_csv | awk -F, -v n="$ADMIN_GROUP" '$2==n{print $1; exit}')
if [[ -z $group_id ]]; then
  group_id=$(kcadm create groups -r "$REALM" -s "name=$ADMIN_GROUP" -i | kc_csv)
  echo "created group $ADMIN_GROUP"
else
  echo "group $ADMIN_GROUP exists"
fi

# --- clients (each gets a groups-claim mapper and an audience mapper)
ensure_client "$CONSOLE_CLIENT" "$OAUTH2_PROXY_CLIENT_SECRET" "https://console.${DOMAIN}${PUBLIC_SUFFIX}/oauth2/callback"
if [[ -n ${OAUTH2_PREVIEWS_CLIENT_SECRET:-} ]]; then
  ensure_client "$PREVIEWS_CLIENT" "$OAUTH2_PREVIEWS_CLIENT_SECRET" "https://sso.${DOMAIN}${PUBLIC_SUFFIX}/oauth2/callback"
fi
# invitations: lets org admins create the invitee's account from the console (optional)
if [[ -n ${KEYCLOAK_USER_ADMIN_SECRET:-} ]]; then
  ensure_user_admin_client "${KEYCLOAK_USER_ADMIN_CLIENT:-infra-user-admin}" "$KEYCLOAK_USER_ADMIN_SECRET"
fi

# --- first admin user
if [[ -n $ADMIN_USER ]]; then
  uid=$(kcadm get users -r "$REALM" -q "username=$ADMIN_USER" -q exact=true --fields id --format csv --noquotes | kc_csv | head -1)
  if [[ -z $uid ]]; then
    uid=$(kcadm create users -r "$REALM" -s "username=$ADMIN_USER" -s "email=$ADMIN_EMAIL" -s enabled=true -s emailVerified=true \
            -s "firstName=${ADMIN_USER}" -s "lastName=Admin" -i | kc_csv)
    echo "created user $ADMIN_USER"
    if [[ -z $ADMIN_PW ]]; then ADMIN_PW=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20); GENERATED=1; fi
    kcadm set-password -r "$REALM" --username "$ADMIN_USER" --new-password "$ADMIN_PW" --temporary
  else
    echo "user $ADMIN_USER exists (password left unchanged)"
  fi
  kcadm update "users/$uid/groups/$group_id" -r "$REALM" -s "realm=$REALM" -s "userId=$uid" -s "groupId=$group_id" -n
  echo "$ADMIN_USER is in $ADMIN_GROUP"
  if [[ ${GENERATED:-0} == 1 ]]; then
    echo
    echo "  ┌─ first sign-in (shown once; Keycloak will make you change it) ─"
    echo "  │  user:      $ADMIN_USER"
    echo "  │  password:  $ADMIN_PW"
    echo "  └────────────────────────────────────────────────────────────────"
  fi
fi

# --- switch the platform over
ENVF=/etc/infra/infra.env
if (( APPLY )); then
  bk="$ENVF.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$ENVF" "$bk"; echo "backed up $ENVF -> $bk"
  set_kv() { if grep -q "^$1=" "$ENVF"; then sed -i "s|^$1=.*|$1=$2|" "$ENVF"; else echo "$1=$2" >> "$ENVF"; fi; }
  profiles=keycloak,keycloak-auth
  [[ -n ${OAUTH2_PREVIEWS_CLIENT_SECRET:-} ]] && profiles+=,keycloak-previews
  extra=$(sed -nE 's/^PLATFORM_PROFILES=(.*)$/\1/p' "$ENVF" | tr -d "'\"" | tr ',' '\n' | grep -vxE 'keycloak|keycloak-auth|keycloak-previews|' | paste -sd, - || true)
  set_kv PLATFORM_PROFILES "${extra:+$extra,}$profiles"
  set_kv CONSOLE_AUTH_MODE keycloak
  [[ -n ${OAUTH2_PREVIEWS_CLIENT_SECRET:-} ]] && { set_kv PREVIEW_AUTH_MODE keycloak; set_kv OPS_AUTH_MODE keycloak; }
  grep -E '^(PLATFORM_PROFILES|CONSOLE_AUTH_MODE|PREVIEW_AUTH_MODE|OPS_AUTH_MODE|KEYCLOAK_VPN_CIDRS)=' "$ENVF"
  sudo -u "${DEPLOY_USER:-deploy}" infra platform up
else
  echo
  echo "Keycloak is ready. To switch the console${OAUTH2_PREVIEWS_CLIENT_SECRET:+ and previews} to Keycloak login, re-run with --apply,"
  echo "or set PLATFORM_PROFILES=keycloak,keycloak-auth${OAUTH2_PREVIEWS_CLIENT_SECRET:+,keycloak-previews}, CONSOLE_AUTH_MODE=keycloak${OAUTH2_PREVIEWS_CLIENT_SECRET:+, PREVIEW_AUTH_MODE=keycloak}"
  echo "in /etc/infra/infra.env and run: sudo -u deploy infra platform up"
fi
