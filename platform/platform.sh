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

dc() {
  local files=(-f "$P/docker-compose.yml")
  if [[ -f $MANAGED ]]; then files+=(-f "$MANAGED"); fi
  docker compose -p infra-platform "${files[@]}" "$@"
}

# ----------------------------------------------------------------------------- preflight
# Refuse to start if anything we'd create already exists and belongs to someone else.

PLATFORM_CONTAINERS=(infra-socket-proxy infra-traefik infra-postgres infra-uptime-kuma infra-dozzle
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

  VARS='${DOMAIN} ${ACME_EMAIL} ${DNS_PROVIDER} ${ACME_CA_SERVER} ${HSTS_SECONDS} ${DASHBOARD_AUTH_USERS} ${PREVIEW_AUTH_USERS}'
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
    new=$(sha256sum "$T/traefik.yml" | cut -d' ' -f1)
    old=$(cat "$T/.static.sha" 2>/dev/null || true)
    dc up -d --remove-orphans --wait
    if [[ -n $old && $new != "$old" ]]; then
      log "Traefik static config changed — restarting traefik"
      dc restart traefik
    fi
    echo "$new" > "$T/.static.sha"
    scheme=https
    if [[ $TLS_MODE == external ]]; then
      log "Traefik listens on http://$TRAEFIK_BIND:$TRAEFIK_HTTPS_PORT — point your existing proxy's *.$DOMAIN at it"
    fi
    log "platform is up:"
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
