#!/usr/bin/env bash
# Manage the shared platform services.
#
#   infra platform up        render Traefik config, start/update everything (idempotent)
#   infra platform render    only render config into $STATE_DIR/traefik
#   infra platform ps
#   infra platform logs [service]
#   infra platform pull      pull newer images (then run `up`)
#   infra platform down      stop the platform — every app loses routing and its database!
SCRIPT_NAME=platform
# shellcheck source=../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

action=${1:-}
if [[ -z $action || $action == -h || $action == --help ]]; then usage; fi
shift
load_infra_env

P="$INFRA_ROOT/platform"
T="$STATE_DIR/traefik"
export TRAEFIK_STATE_DIR="$T"
export COMPOSE_PROFILES="${PLATFORM_PROFILES:-}"

dc() { docker compose -p infra-platform -f "$P/docker-compose.yml" "$@"; }

# Accept either a ready htpasswd line (…_USERS) or user:password (…_PLAIN) and hash it.
resolve_auth() {
  local users_var=$1 plain_var=$2 user pass
  if [[ -n ${!users_var:-} ]]; then return 0; fi
  [[ -n ${!plain_var:-} ]] || die "set $users_var (htpasswd line) or $plain_var (user:password) in $INFRA_ENV_FILE"
  user=${!plain_var%%:*}; pass=${!plain_var#*:}
  printf -v "$users_var" '%s' "$(htpasswd -nbB "$user" "$pass" | head -n1)"
  export "${users_var?}"
}

ensure_selfsigned_cert() {
  local crt="$T/certs/wildcard.crt" key="$T/certs/wildcard.key"
  if [[ -f $crt && -f $key ]] \
     && openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null \
     && openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -qF "*.$DOMAIN"; then
    return 0
  fi
  log "generating self-signed wildcard certificate for *.$DOMAIN (drop mkcert files here to replace: $T/certs)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 397 \
    -keyout "$key" -out "$crt" -subj "/CN=*.$DOMAIN" \
    -addext "subjectAltName=DNS:*.$DOMAIN,DNS:$DOMAIN" 2>/dev/null
  chmod 600 "$key"
}

render_file() { # template → destination (atomic, so Traefik's watcher never sees half a file)
  envsubst "$VARS" < "$1" > "$2.tmp"
  mv "$2.tmp" "$2"
}

render() {
  mkdir -p "$T/dynamic" "$T/certs"
  resolve_auth DASHBOARD_AUTH_USERS DASHBOARD_AUTH_PLAIN
  resolve_auth PREVIEW_AUTH_USERS PREVIEW_AUTH_PLAIN
  export ACME_CA_SERVER="${ACME_CA_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
  case $TLS_MODE in
    letsencrypt)
      : "${ACME_EMAIL:?ACME_EMAIL is required for TLS_MODE=letsencrypt}"
      : "${DNS_PROVIDER:?DNS_PROVIDER is required for TLS_MODE=letsencrypt}"
      [[ -f /etc/infra/traefik.env ]] || warn "/etc/infra/traefik.env missing — DNS challenge will fail without provider credentials"
      export HSTS_SECONDS=31536000
      ;;
    selfsigned)
      export HSTS_SECONDS=0          # never HSTS a self-signed host: browsers would block click-through
      ensure_selfsigned_cert
      ;;
    *) die "TLS_MODE must be selfsigned or letsencrypt (got '$TLS_MODE')" ;;
  esac

  VARS='${DOMAIN} ${ACME_EMAIL} ${DNS_PROVIDER} ${ACME_CA_SERVER} ${HSTS_SECONDS} ${DASHBOARD_AUTH_USERS} ${PREVIEW_AUTH_USERS}'
  render_file "$P/traefik/static.$TLS_MODE.yml.tmpl" "$T/traefik.yml"
  local f
  for f in "$P"/traefik/dynamic/*.yml.tmpl; do
    render_file "$f" "$T/dynamic/$(basename "${f%.tmpl}")"
  done
  if [[ $TLS_MODE == selfsigned ]]; then
    render_file "$P/traefik/tls.selfsigned.yml.tmpl" "$T/dynamic/tls.yml"
  else
    rm -f "$T/dynamic/tls.yml"
  fi
  log "rendered Traefik config into $T (TLS_MODE=$TLS_MODE)"
}

case $action in
  render) render ;;
  up)
    render
    new=$(sha256sum "$T/traefik.yml" | cut -d' ' -f1)
    old=$(cat "$T/.static.sha" 2>/dev/null || true)
    dc up -d --remove-orphans --wait
    if [[ -n $old && $new != "$old" ]]; then
      log "Traefik static config changed — restarting traefik"
      dc restart traefik
    fi
    echo "$new" > "$T/.static.sha"
    log "platform is up:"
    log "  https://traefik.$DOMAIN   (dashboard, ops-auth)"
    log "  https://logs.$DOMAIN      (dozzle, ops-auth)"
    log "  https://status.$DOMAIN    (uptime-kuma)"
    if [[ ,$COMPOSE_PROFILES, == *,metrics,* ]]; then log "  https://grafana.$DOMAIN"; fi
    ;;
  ps)   dc ps -a ;;
  logs) dc logs -f --tail 200 "$@" ;;
  pull) dc pull ;;
  down) dc down ;;
  *) die "unknown action: $action" ;;
esac
