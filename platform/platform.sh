#!/usr/bin/env bash
# Manage the shared platform services.
#
#   infra platform up        preflight, render Traefik config, start/update everything (idempotent)
#   infra platform check     preflight only: ports and names free / already ours?
#   infra platform render    only render config into $STATE_DIR/traefik
#   infra platform ps
#   infra platform logs [service]
#   infra platform pull      pull newer images (then run `up`)
#   infra platform down      stop the platform — every app loses routing and its database!
#
# TLS_MODE:
#   letsencrypt  Traefik owns 80/443, wildcard cert via DNS challenge
#   selfsigned   Traefik owns the ports, self-signed wildcard (local VM)
#   external     the host already runs nginx/apache/caddy on 80/443: Traefik listens on
#                TRAEFIK_BIND:TRAEFIK_HTTPS_PORT (e.g. 127.0.0.1:8443) as plain HTTP and the
#                existing proxy forwards *.DOMAIN to it (docs/shared-host.md)
SCRIPT_NAME=platform
# shellcheck source=../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

action=${1:-}
if [[ -z $action || $action == -h || $action == --help ]]; then usage; fi
shift
load_infra_env

P="$INFRA_ROOT/platform"
T="$STATE_DIR/traefik"
MANAGED="$STATE_DIR/platform-managed.yml"
export TRAEFIK_STATE_DIR="$T"
export COMPOSE_PROFILES="${PLATFORM_PROFILES:-}"
PUBLIC_HTTPS_PORT_SUFFIX=""
KEYCLOAK_HTTPS_PORT=443
if [[ $TLS_MODE != external && $TRAEFIK_HTTPS_PORT != 443 ]]; then
  PUBLIC_HTTPS_PORT_SUFFIX=":$TRAEFIK_HTTPS_PORT"
  KEYCLOAK_HTTPS_PORT=$TRAEFIK_HTTPS_PORT
fi
export PUBLIC_HTTPS_PORT_SUFFIX KEYCLOAK_HTTPS_PORT
if [[ ,$COMPOSE_PROFILES, == *,authentik,* && ( ,$COMPOSE_PROFILES, == *,keycloak,* || ,$COMPOSE_PROFILES, == *,keycloak-auth,* ) ]]; then
  die "PLATFORM_PROFILES cannot enable both authentik and keycloak because both use auth.${DOMAIN}"
fi
HAS_KEYCLOAK_PROFILE=false
HAS_KEYCLOAK_AUTH_PROFILE=false
CONSOLE_ROUTER_SERVICE=console
CONSOLE_LOGOUT_MIDDLEWARE=ops-auth@file,secure-headers@file
[[ ,$COMPOSE_PROFILES, == *,keycloak,* ]] && HAS_KEYCLOAK_PROFILE=true
[[ ,$COMPOSE_PROFILES, == *,keycloak-auth,* ]] && HAS_KEYCLOAK_AUTH_PROFILE=true
if $HAS_KEYCLOAK_AUTH_PROFILE && ! $HAS_KEYCLOAK_PROFILE; then
  die "PLATFORM_PROFILES=keycloak-auth requires keycloak as well"
fi
CONSOLE_AUTH_MODE=${CONSOLE_AUTH_MODE:-basic}
if [[ $CONSOLE_AUTH_MODE != basic && $CONSOLE_AUTH_MODE != authentik && $CONSOLE_AUTH_MODE != keycloak ]]; then
  die "CONSOLE_AUTH_MODE must be basic, authentik or keycloak"
fi
if [[ ,$COMPOSE_PROFILES, == *,authentik,* || $HAS_KEYCLOAK_PROFILE == true ]]; then
  AUTH_PROVIDER_VPN_CIDRS=${AUTHENTIK_VPN_CIDRS:-}
  if [[ $HAS_KEYCLOAK_PROFILE == true ]]; then
    AUTH_PROVIDER_VPN_CIDRS=${KEYCLOAK_VPN_CIDRS:-$AUTH_PROVIDER_VPN_CIDRS}
  fi
  [[ -n $AUTH_PROVIDER_VPN_CIDRS ]] \
    || die "set AUTHENTIK_VPN_CIDRS or KEYCLOAK_VPN_CIDRS to the trusted VPN subnet before enabling an identity provider"
  AUTH_PROVIDER_VPN_CIDRS_YAML=""
  IFS=',' read -r -a AUTH_PROVIDER_CIDR_LIST <<<"$AUTH_PROVIDER_VPN_CIDRS"
  for cidr in "${AUTH_PROVIDER_CIDR_LIST[@]}"; do
    [[ $cidr =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] \
      || die "invalid identity-provider VPN CIDR entry: $cidr"
    AUTH_PROVIDER_VPN_CIDRS_YAML+="          - \"$cidr\""$'\n'
  done
  AUTHENTIK_VPN_CIDRS_YAML=$AUTH_PROVIDER_VPN_CIDRS_YAML
  KEYCLOAK_VPN_CIDRS_YAML=$AUTH_PROVIDER_VPN_CIDRS_YAML
  if [[ $HAS_KEYCLOAK_PROFILE == true ]]; then
    [[ ${KEYCLOAK_POSTGRES_PASSWORD:-} =~ ^[a-fA-F0-9]{32,128}$ ]] \
      || die "set KEYCLOAK_POSTGRES_PASSWORD to a 32–128 character hex secret"
    [[ -n ${KEYCLOAK_ADMIN_PASSWORD:-} ]] || die "set KEYCLOAK_ADMIN_PASSWORD in /etc/infra/platform.secrets.env"
  fi
  if [[ $HAS_KEYCLOAK_AUTH_PROFILE == true ]]; then
    [[ -n ${OAUTH2_PROXY_CLIENT_SECRET:-} ]] || die "set OAUTH2_PROXY_CLIENT_SECRET in /etc/infra/platform.secrets.env"
    [[ ${OAUTH2_PROXY_COOKIE_SECRET:-} =~ ^[A-Za-z0-9+/]{32}$ ]] \
      || die "set OAUTH2_PROXY_COOKIE_SECRET to a 32-character base64 value"
  fi
  if [[ $CONSOLE_AUTH_MODE == authentik ]]; then
    [[ ,$COMPOSE_PROFILES, == *,authentik,* ]] \
      || die "CONSOLE_AUTH_MODE=authentik requires PLATFORM_PROFILES to include authentik"
    [[ -n ${AUTHENTIK_SECRET_KEY:-} ]] || die "set AUTHENTIK_SECRET_KEY in /etc/infra/platform.secrets.env"
    [[ ${AUTHENTIK_POSTGRES_PASSWORD:-} =~ ^[a-fA-F0-9]{32,128}$ ]] \
      || die "set AUTHENTIK_POSTGRES_PASSWORD to a 32–128 character hex secret"
    CONSOLE_AUTH_MIDDLEWARE=authentik-auth@file,secure-headers@file
  elif [[ $CONSOLE_AUTH_MODE == keycloak ]]; then
    [[ $HAS_KEYCLOAK_PROFILE == true && $HAS_KEYCLOAK_AUTH_PROFILE == true ]] \
      || die "CONSOLE_AUTH_MODE=keycloak requires PLATFORM_PROFILES to include keycloak,keycloak-auth"
    CONSOLE_AUTH_MIDDLEWARE=secure-headers@file
    CONSOLE_ROUTER_SERVICE=oauth2-proxy@docker
    CONSOLE_LOGOUT_MIDDLEWARE=secure-headers@file
  else
    CONSOLE_AUTH_MIDDLEWARE=ops-auth@file,secure-headers@file
  fi
else
  [[ $CONSOLE_AUTH_MODE == basic ]] \
    || die "CONSOLE_AUTH_MODE=$CONSOLE_AUTH_MODE requires its corresponding PLATFORM_PROFILES"
  AUTHENTIK_VPN_CIDRS_YAML='          - "127.0.0.1/32"'
  KEYCLOAK_VPN_CIDRS_YAML='          - "127.0.0.1/32"'
  CONSOLE_AUTH_MIDDLEWARE=ops-auth@file,secure-headers@file
fi
export CONSOLE_AUTH_MODE CONSOLE_AUTH_MIDDLEWARE CONSOLE_ROUTER_SERVICE CONSOLE_LOGOUT_MIDDLEWARE AUTHENTIK_VPN_CIDRS_YAML KEYCLOAK_VPN_CIDRS_YAML
# The console container runs as the deploy user so its files match the CLI's ownership.
DEPLOY_UID=$(id -u "$DEPLOY_USER"); DEPLOY_GID=$(id -g "$DEPLOY_USER")
DOCKER_SOCKET_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 0)
export DEPLOY_UID DEPLOY_GID DOCKER_SOCKET_GID INFRA_ROOT SECRETS_ROOT DEPLOY_ROOT BACKUP_DIR STATE_DIR LOG_DIR LOCK_DIR
mkdir -p "$LOCK_DIR" "$STATE_DIR/overrides"

dc() {
  local files=(-f "$P/docker-compose.yml")
  if [[ -f $MANAGED ]]; then files+=(-f "$MANAGED"); fi
  docker compose -p infra-platform "${files[@]}" "$@"
}

# ----------------------------------------------------------------------------- preflight
# Refuse to start if anything we'd create already exists and belongs to someone else.

PLATFORM_CONTAINERS=(infra-socket-proxy infra-traefik infra-postgres infra-uptime-kuma infra-dozzle infra-console
                     infra-authentik-server infra-authentik-worker infra-authentik-redis infra-keycloak infra-oauth2-proxy
                     infra-prometheus infra-node-exporter infra-cadvisor infra-grafana infra-registry)
PLATFORM_NETWORKS=(infra_proxy infra_data infra_socket infra_metrics)

preflight() {
  local name proj p problems=0
  for name in "${PLATFORM_CONTAINERS[@]}"; do
    proj=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null) || continue
    if [[ $proj != infra-platform ]]; then
      warn "container name '$name' is already used by something else (project: ${proj:-none})"; problems=$((problems + 1))
    fi
  done
  for name in "${PLATFORM_NETWORKS[@]}"; do
    proj=$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$name" 2>/dev/null) || continue
    if [[ $proj != infra-platform ]]; then
      warn "network '$name' already exists and is not ours (project: ${proj:-none})"; problems=$((problems + 1))
    fi
  done
  if [[ $(docker inspect -f '{{.State.Running}}' infra-traefik 2>/dev/null) != true ]]; then
    for p in "$TRAEFIK_HTTP_PORT" "$TRAEFIK_HTTPS_PORT"; do
      if ss -Hltn "sport = :$p" | grep -q .; then
        warn "port $p is already in use by another service:"
        ss -Hltnp "sport = :$p" 2>/dev/null | sed 's/^/        /' >&2 || true
        problems=$((problems + 1))
      fi
    done
  fi
  if (( problems )); then
    die "$problems conflict(s) with existing services — nothing was changed. If 80/443 are taken, use
       TLS_MODE=external with TRAEFIK_BIND=127.0.0.1 TRAEFIK_HTTPS_PORT=8443 (see docs/shared-host.md)."
  fi
  log "preflight OK: no conflicts with existing containers, networks or ports"
}

# ----------------------------------------------------------------------------- render

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

ensure_keycloak_cert() {
  local cert_dir="$T/certs/keycloak"
  local crt="$cert_dir/tls.crt" key="$cert_dir/tls.key"
  install -d -m 750 "$cert_dir"
  if [[ -f $crt && -f $key ]] \
     && openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null \
     && openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -qF "*.$DOMAIN"; then
    return 0
  fi
  log "generating an internal Keycloak TLS certificate for *.${DOMAIN}"
  openssl req -x509 -newkey rsa:2048 -nodes -days 397 \
    -keyout "$key" -out "$crt" -subj "/CN=*.$DOMAIN" \
    -addext "subjectAltName=DNS:*.$DOMAIN,DNS:$DOMAIN" 2>/dev/null
  chmod 640 "$key"
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
  local dashboard=tls
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
    external)
      export HSTS_SECONDS=0          # the outer proxy owns TLS and its headers
      dashboard=plain
      ;;
    *) die "TLS_MODE must be selfsigned, letsencrypt or external (got '$TLS_MODE')" ;;
  esac

  if [[ $HAS_KEYCLOAK_PROFILE == true ]]; then ensure_keycloak_cert; fi

  VARS='${DOMAIN} ${ACME_EMAIL} ${DNS_PROVIDER} ${ACME_CA_SERVER} ${HSTS_SECONDS} ${DASHBOARD_AUTH_USERS} ${PREVIEW_AUTH_USERS} ${AUTHENTIK_VPN_CIDRS_YAML} ${KEYCLOAK_VPN_CIDRS_YAML}'
  render_file "$P/traefik/static.$TLS_MODE.yml.tmpl" "$T/traefik.yml"
  local f
  for f in "$P"/traefik/dynamic/*.yml.tmpl; do
    render_file "$f" "$T/dynamic/$(basename "${f%.tmpl}")"
  done
  render_file "$P/traefik/dashboard.$dashboard.yml.tmpl" "$T/dynamic/dashboard.yml"
  if [[ $TLS_MODE == selfsigned ]]; then
    render_file "$P/traefik/tls.selfsigned.yml.tmpl" "$T/dynamic/tls.yml"
  else
    rm -f "$T/dynamic/tls.yml"
  fi
  log "rendered Traefik config into $T (TLS_MODE=$TLS_MODE)"
}

# Label every platform container infra.managed=true (works for any profile combination).
write_managed_override() {
  rm -f "$MANAGED"
  local svcs
  svcs=$(dc config --services)
  {
    echo "# Generated by 'infra platform up'."
    echo "services:"
    while read -r svc; do printf '  %s:\n    labels:\n      infra.managed: "true"\n' "$svc"; done <<<"$svcs"
  } > "$MANAGED"
}

# ----------------------------------------------------------------------------- actions

case $action in
  check)  preflight ;;
  render) render ;;
  up)
    preflight
    render
    write_managed_override
    if [[ ,$COMPOSE_PROFILES, == *,authentik,* ]]; then
      dc up -d --wait postgres
      docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" infra-postgres \
        psql -v ON_ERROR_STOP=1 -v authentik_password="$AUTHENTIK_POSTGRES_PASSWORD" \
        -U postgres -d postgres <<'SQL'
SELECT format('CREATE ROLE authentik LOGIN PASSWORD %L', :'authentik_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authentik') \gexec
ALTER ROLE authentik LOGIN PASSWORD :'authentik_password';
SELECT format('CREATE DATABASE authentik OWNER authentik')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='authentik') \gexec
ALTER DATABASE authentik OWNER TO authentik;
SQL
    fi
    if [[ $HAS_KEYCLOAK_PROFILE == true ]]; then
      dc up -d --wait postgres
      docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" infra-postgres \
        psql -v ON_ERROR_STOP=1 -v keycloak_password="$KEYCLOAK_POSTGRES_PASSWORD" \
        -U postgres -d postgres <<'SQL'
SELECT format('CREATE ROLE keycloak LOGIN PASSWORD %L', :'keycloak_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='keycloak') \gexec
ALTER ROLE keycloak LOGIN PASSWORD :'keycloak_password';
SELECT format('CREATE DATABASE keycloak OWNER keycloak')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='keycloak') \gexec
ALTER DATABASE keycloak OWNER TO keycloak;
SQL
    fi
    new=$(sha256sum "$T/traefik.yml" | cut -d' ' -f1)
    old=$(cat "$T/.static.sha" 2>/dev/null || true)
    dc up -d --build --remove-orphans --wait
    if [[ -n $old && $new != "$old" ]]; then
      log "Traefik static config changed — restarting traefik"
      dc restart traefik
    fi
    echo "$new" > "$T/.static.sha"
    # Recreated platform containers lose runtime network attachments — restore them.
    bash "$INFRA_ROOT/scripts/networks.sh" reconnect
    # Start the GitOps watcher now that the platform (webhook endpoint) is up.
    if systemctl is-enabled infra-gitops.service >/dev/null 2>&1; then
      systemctl restart infra-gitops.service
      log "GitOps watcher started (infra-gitops.service) — polls GitHub every 30s for all registered projects"
    fi
    scheme=https
    if [[ $TLS_MODE == external ]]; then
      log "Traefik listens on http://$TRAEFIK_BIND:$TRAEFIK_HTTPS_PORT — point your existing proxy's *.$DOMAIN at it"
    fi
    log "platform is up:"
    log "  $scheme://console.$DOMAIN$URL_PORT_SUFFIX   (DevOps console, ops-auth)"
    log "  $scheme://hooks.$DOMAIN$URL_PORT_SUFFIX/webhook   (signed deploy webhooks for registered projects)"
    log "  $scheme://traefik.$DOMAIN$URL_PORT_SUFFIX   (dashboard, ops-auth)"
    log "  $scheme://logs.$DOMAIN$URL_PORT_SUFFIX      (dozzle, ops-auth — shows only infra-managed containers)"
    log "  $scheme://status.$DOMAIN$URL_PORT_SUFFIX    (uptime-kuma)"
    if [[ ,$COMPOSE_PROFILES, == *,metrics,* ]]; then log "  $scheme://grafana.$DOMAIN$URL_PORT_SUFFIX"; fi
    ;;
  ps)   dc ps -a ;;
  logs) dc logs -f --tail 200 "$@" ;;
  pull) dc pull ;;
  down) dc down ;;
  *) die "unknown action: $action" ;;
esac
