#!/usr/bin/env bash
# Deploy or update one environment of one app.
#
#   infra deploy --manifest <repo>/.infradeploy --env <env> --tag <tag> [--branch <b>] [--commit <sha>] [--no-pull]
#   infra redeploy <app> <env> [--tag <tag>]
#   infra rollback <app> <env>
#
# <env> is prod | staging | develop | pr-<number> | any short name.
# Each service in infra.yml gets its own host:
#   service 'web' or 'app' -> <app>[-<env>].<DOMAIN>
#   any other name         -> <svcname>-<app>[-<env>].<DOMAIN>
SCRIPT_NAME=deploy
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$INFRA_ROOT/scripts/lib/db.sh"

APP="" ENV_NAME="" TAG="" MANIFEST_DIR="" BRANCH="" COMMIT="" PULL=1 REDEPLOY=0 ROLLBACK=0
while (( $# )); do
  case $1 in
    --app)      APP=${2:?}; shift 2 ;;
    --env)      ENV_NAME=${2:?}; shift 2 ;;
    --tag)      TAG=${2:?}; shift 2 ;;
    --manifest) MANIFEST_DIR=${2:?}; shift 2 ;;
    --branch)   BRANCH=${2-}; shift 2 ;;
    --commit)   COMMIT=${2-}; shift 2 ;;
    --no-pull)  PULL=0; shift ;;
    --redeploy) REDEPLOY=1; shift ;;
    --rollback) REDEPLOY=1; ROLLBACK=1; shift ;;
    -h|--help)  usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_infra_env
enable_file_log
[[ -n $ENV_NAME ]] || die "--env is required"
validate_name env "$ENV_NAME"

# ----------------------------------------------------------------------------- inputs

if (( REDEPLOY )); then
  [[ -n $APP ]] || die "redeploy/rollback need --app"
  validate_name app "$APP"
  META="$(stack_dir "$APP" "$ENV_NAME")/meta.env"
  if [[ -f $(stack_dir "$APP" "$ENV_NAME")/status.env && $ROLLBACK -eq 0 ]]; then
    META="$(stack_dir "$APP" "$ENV_NAME")/status.env"
  fi
  [[ -f $META ]] || die "no existing deployment $APP/$ENV_NAME"
  if (( ROLLBACK )); then
    TAG=$(meta_get "$META" PREV_TAG)
    [[ -n $TAG ]] || die "no previous tag recorded for $APP/$ENV_NAME"
    log "rolling back $APP/$ENV_NAME to $TAG"
  fi
  TAG=${TAG:-$(meta_get "$META" TAG)}
  BRANCH=${BRANCH:-$(meta_get "$META" BRANCH)}
  COMMIT=${COMMIT:-$(meta_get "$META" COMMIT)}
  MANIFEST_DIR="$(stack_dir "$APP" "$ENV_NAME")/deploy"
fi

[[ -n $TAG ]]          || die "--tag is required"
[[ -n $MANIFEST_DIR ]] || die "--manifest is required"
[[ -f $MANIFEST_DIR/infra.yml ]] || die "infra.yml not found: $MANIFEST_DIR/infra.yml"
MANIFEST_DIR=$(cd "$MANIFEST_DIR" && pwd)
BRANCH=${BRANCH//\'/_}

# Parse infra.yml via Python (untrusted repo input — never sourced directly)
PARSED=$(python3 "$INFRA_ROOT/scripts/parse-manifest.py" "$MANIFEST_DIR/infra.yml") \
  || die "infra.yml is invalid (see errors above)"
eval "$PARSED"

: "${APP_NAME:?APP_NAME missing from infra.yml}"
validate_name app "$APP_NAME"
[[ -z $APP || $APP == "$APP_NAME" ]] \
  || die "--app '$APP' does not match name '$APP_NAME' in infra.yml"
APP=$APP_NAME
case $APP in console|traefik|logs|status|hooks|grafana|www|api|auth|sso)
  die "name '$APP' is reserved by the platform" ;; esac

read -r -a SERVICES <<< "$SERVICES"
(( ${#SERVICES[@]} > 0 )) || die "infra.yml has no services"

STACK=$(stack_name "$APP" "$ENV_NAME")
STACK_DIR=$(stack_dir "$APP" "$ENV_NAME")
STACK_NETWORK=$(stack_network "$APP" "$ENV_NAME")
CLASS=$(env_class "$ENV_NAME")
CLASS_VAR=${CLASS^^}; CLASS_VAR=${CLASS_VAR//-/_}
PREVIEW=false
if is_preview "$ENV_NAME"; then PREVIEW=true; fi

acquire_lock "$STACK"

if [[ ! -f $STACK_DIR/meta.env ]]; then
  foreign=$(foreign_in_project "$STACK")
  [[ -z $foreign ]] || die "compose project '$STACK' already has containers we did not create ($foreign)"
fi

if [[ $PREVIEW == true && ! -f $STACK_DIR/meta.env ]]; then
  n=$(count_previews)
  (( n < MAX_PREVIEWS )) || die "preview limit reached ($n/$MAX_PREVIEWS)"
  if [[ -n ${MAX_PREVIEWS_PER_APP:-} ]]; then
    app_n=$(find "$DEPLOY_ROOT/$APP" -mindepth 1 -maxdepth 1 -type d -name 'pr-*' 2>/dev/null | wc -l)
    (( app_n < MAX_PREVIEWS_PER_APP )) \
      || die "per-app preview limit reached ($app_n/$MAX_PREVIEWS_PER_APP)"
  fi
fi

PREV_TAG=""
if [[ -f $STACK_DIR/meta.env ]]; then
  old_tag=$(meta_get "$STACK_DIR/meta.env" TAG)
  if [[ $old_tag == "$TAG" ]]; then PREV_TAG=$(meta_get "$STACK_DIR/meta.env" PREV_TAG)
  else PREV_TAG=$old_tag; fi
fi

log "deploying $STACK  services=${SERVICES[*]}  tag=$TAG  branch=${BRANCH:-n/a}"

mkdir -p "$STACK_DIR/runtime"
if (( ! REDEPLOY )); then
  rm -rf "$STACK_DIR/deploy.new"
  cp -R "$MANIFEST_DIR" "$STACK_DIR/deploy.new"
  rm -rf "$STACK_DIR/deploy"
  mv "$STACK_DIR/deploy.new" "$STACK_DIR/deploy"
fi
DEPLOY_DIR="$STACK_DIR/deploy"

# ----------------------------------------------------------------------------- per service

# Project links (console → Access → Project links) that involve this project, as set by an administrator
LINKS=$(python3 "$INFRA_ROOT/scripts/project-links.py" "$STATE_DIR/console-access.sqlite3" "$APP" 2>/dev/null || true)

declare -A SVC_HOST SVC_IMAGE SVC_PORT SVC_MEM SVC_CPUS SVC_MW SVC_SSO SVC_PUBLIC
stack_mem_kib=0
stack_cpus=0

for svc in "${SERVICES[@]}"; do
  S=${svc^^}; S=${S//-/_}

  # host
  host_var="${S}_HOST_${CLASS_VAR}"
  if [[ -n ${!host_var:-} ]]; then
    host=${!host_var}
  else
    base=$APP
    [[ $ENV_NAME == prod ]] || base="$APP-$ENV_NAME"
    if [[ $svc == web || $svc == app ]]; then
      host="$base.$DOMAIN"
    else
      host="$svc-$base.$DOMAIN"
    fi
  fi
  SVC_HOST[$svc]=$host

  # image: <image>:<tag> (replace {tag} placeholder if present)
  img_var="${S}_IMAGE"
  raw_image=${!img_var:-}
  [[ -n $raw_image ]] || die "service '$svc': image is required"
  SVC_IMAGE[$svc]=${raw_image//\{tag\}/$TAG}
  # append tag if no tag/digest already present
  if [[ ${SVC_IMAGE[$svc]} != *:* && ${SVC_IMAGE[$svc]} != *@* ]]; then
    SVC_IMAGE[$svc]="${SVC_IMAGE[$svc]}:$TAG"
  fi

  # port
  port_var="${S}_PORT"
  SVC_PORT[$svc]=${!port_var:-80}

  # resources
  resource_resolve "$APP" "$ENV_NAME" "$svc"
  SVC_MEM[$svc]=$RESOURCE_MEM
  SVC_CPUS[$svc]=$RESOURCE_CPUS
  resource_validate_value "${SVC_MEM[$svc]}" "${SVC_CPUS[$svc]}"
  svc_mem_kib=$(resource_mem_kib "${SVC_MEM[$svc]}")
  stack_mem_kib=$((stack_mem_kib + svc_mem_kib))
  stack_cpus=$(awk -v t="$stack_cpus" -v a="${SVC_CPUS[$svc]}" 'BEGIN{printf "%.3f",t+a}')

  # middlewares
  mw="secure-headers@file,compress@file"
  # Access gate: previews default to ON, every other class to OFF. `environments.<class>.auth` and
  # `environments.<class>.<service>.auth` in infra.yml override it (so develop/staging/prod can opt in too).
  auth=false
  if [[ $PREVIEW == true ]]; then mw+=",preview-noindex@file"; auth=true; fi
  auth_var="ENV_${CLASS_VAR}_AUTH"
  if [[ -n ${!auth_var:-} ]]; then auth=${!auth_var}; fi
  svc_auth_var="ENV_${CLASS_VAR}_${S}_AUTH"
  if [[ -n ${!svc_auth_var:-} ]]; then auth=${!svc_auth_var}; fi
  if [[ $PREVIEW_AUTH_ENABLED == true && $auth == true ]]; then
    if [[ ${PREVIEW_AUTH_MODE:-basic} == keycloak ]]; then
      mw+=",${STACK}-${svc}-sso@docker"; SVC_SSO[$svc]=1      # Keycloak login + role check (console /auth/preview)
    else
      mw+=",preview-auth@file"                                 # shared basic-auth password
    fi
  fi
  extra_var="${S}_EXTRA_MIDDLEWARES"
  if [[ -n ${!extra_var:-} ]]; then mw+=",${!extra_var}"; fi
  SVC_MW[$svc]=$mw
  # public: false → no reachable address of its own (served only through other services' `upstreams`)
  if grep -qx "HIDE|$svc" <<<"$LINKS"; then SVC_PUBLIC[$svc]=false; SVC_MW[$svc]="deny-all@file"; unset "SVC_SSO[$svc]"; fi
done
resource_validate_stack "$stack_mem_kib" "$stack_cpus"

# hostname ownership check
for svc in "${SERVICES[@]}"; do
  h=${SVC_HOST[$svc]}
  if [[ $h == *".$DOMAIN" ]]; then
    sub=${h%".$DOMAIN"}
    valid=false
    [[ $sub == "$APP" || $sub == "$APP-"* ]] && valid=true
    [[ $sub == "$svc-$APP" || $sub == "$svc-$APP-"* ]] && valid=true
    $valid || die "host $h is outside $APP's namespace"
  fi
  for f in "$DEPLOY_ROOT"/*/*/stack.env; do
    [[ $f == "$STACK_DIR/stack.env" ]] && continue
    grep -qF "_HOST='$h'" "$f" \
      && die "host $h already served by $(dirname "${f#"$DEPLOY_ROOT/"}")"
  done
done

URL="https://${SVC_HOST[${SERVICES[0]}]}$URL_PORT_SUFFIX"

# ----------------------------------------------------------------------------- project links
# An administrator can link a service of this project to a service of another project (console → Access → Project
# links): requests to <path> on THIS service's host are forwarded to that service over the platform network. The browser
# only ever talks to one host, so the access gate on this host covers the whole call (whoever may open the frontend can use
# its API — no access to the API project is needed) and the target can drop its own public address. Links live in the
# console's database, not in infra.yml, so a pull request cannot create one.
declare -A UP_LABELS UP_INJECT
UP_META=""
up_i=0
while IFS='|' read -r usvc upath uproj utsvc uenv ustrip uinject; do
  [[ -n $usvc ]] || continue
  [[ " ${SERVICES[*]} " == *" $usvc "* ]] || { warn "link for service '$usvc' ignored: this project has no such service"; continue; }
  # The target is the SAME environment name unless `env:` says otherwise, and never a different environment class:
  # a preview must not reach another project's develop/prod, nor develop reach prod. (It attaches by name, so the
  # other project may be deployed before or after this one.)
  tenv=${uenv:-$ENV_NAME}
  [[ $(env_class "$tenv") == "$CLASS" ]] \
    || die "service '$usvc' routes to $uproj/$tenv, but this is a $CLASS environment: upstreams stay inside the same environment class"
  if [[ -f $DEPLOY_ROOT/$uproj/$tenv/meta.env ]] \
     && ! grep -qw -- "$utsvc" <<<"$(meta_get "$DEPLOY_ROOT/$uproj/$tenv/meta.env" SERVICES)"; then
    die "upstream $uproj/$tenv has no service '$utsvc'"
  fi
  tstack=$(stack_name "$uproj" "$tenv")
  up_i=$((up_i + 1)); rname="${STACK}-${usvc}-up${up_i}"
  mw=${SVC_MW[$usvc]}
  # exact path boundary: /api matches /api and /api/..., never /apix
  base=${upath%/}
  if [[ -z $base ]]; then pathrule="PathPrefix(\`/\`)"; else pathrule="(Path(\`${base}\`) || PathPrefix(\`${base}/\`))"; fi
  labels="      - traefik.http.routers.${rname}.rule=Host(\`${SVC_HOST[$usvc]}\`) && ${pathrule}
      - traefik.http.routers.${rname}.priority=$((1000 + ${#upath}))
      - traefik.http.routers.${rname}.entrypoints=websecure
      - traefik.http.routers.${rname}.tls=${ROUTER_TLS:-true}
      - traefik.http.routers.${rname}.service=${tstack}-${utsvc}@docker"
  if [[ $ustrip == true ]]; then
    labels+=$'\n'"      - traefik.http.middlewares.${rname}-strip.stripprefix.prefixes=${upath}"
    mw+=",${rname}-strip@docker"
  fi
  labels+=$'\n'"      - traefik.http.routers.${rname}.middlewares=${mw}"
  UP_LABELS[$usvc]+="$labels"$'\n'
  [[ -z $uinject ]] || UP_INJECT[$usvc]+="${uinject}=https://${SVC_HOST[$usvc]}${URL_PORT_SUFFIX}"$'\n'
  UP_META+="${usvc}:${upath}=${uproj}/${tenv}/${utsvc} "
  log "upstream: https://${SVC_HOST[$usvc]}${upath} → ${uproj}/${tenv} ${utsvc}"
done < <(grep -v '^HIDE|' <<<"$LINKS" || true)


# ----------------------------------------------------------------------------- databases
# Databases declared in infra.yml are NOT created here. They are created on demand
# (console button / `infra db create`). A database that has been created gets its role and
# password re-synced and its URL injected into the declaring service; the rest are reported.

USES_PG=false
ALL_DBS=()
PENDING_DBS=()
declare -A DB_NAMES  # svc -> space-separated "inject_as=url" pairs

declared=$(declared_dbs "$DEPLOY_DIR" "$APP" "$ENV_NAME") || die "failed to read databases from infra.yml"
while IFS='|' read -r id svc inject_as db_name fixed_pw; do
  [[ -n $id ]] || continue
  if ! db_is_created "$STACK_DIR" "$db_name"; then
    PENDING_DBS+=("$id")
    continue
  fi
  if pg_running; then
    db_ensure "$db_name" "$db_name" "$(<"$STACK_DIR/.db_password_$db_name")" "" "$CLASS"
    USES_PG=true
  fi
  DB_NAMES[$svc]+="${inject_as}=$(db_url_for "$STACK_DIR" "$db_name") "
  ALL_DBS+=("$db_name")
done <<< "$declared"
if (( ${#PENDING_DBS[@]} )); then
  log "databases declared but not created yet: ${PENDING_DBS[*]} (create them in the console → Database)"
fi

# ----------------------------------------------------------------------------- runtime env files

for svc in "${SERVICES[@]}"; do
  S=${svc^^}; S=${S//-/_}
  out="$STACK_DIR/runtime/$svc.env"
  (
    umask 077
    {
      echo "# Generated by 'infra deploy' — do not edit."
      echo "APP_NAME=$APP"
      echo "APP_ENV=$ENV_NAME"
      echo "ENV_CLASS=$CLASS"
      echo "IS_PREVIEW=$PREVIEW"
      echo "PORT=${SVC_PORT[$svc]}"
      echo "PUBLIC_URL=https://${SVC_HOST[$svc]}$URL_PORT_SUFFIX"
      echo "INFRA_DOMAIN=$DOMAIN"
      echo "IMAGE_TAG=$TAG"
      echo "GIT_BRANCH=$BRANCH"
      echo "GIT_COMMIT=$COMMIT"

      # inject DB URLs declared in infra.yml
      if [[ -n ${DB_NAMES[$svc]:-} ]]; then
        echo "# --- injected databases"
        for pair in ${DB_NAMES[$svc]}; do
          echo "$pair"
        done
      fi

      # inject per-env-class static vars from infra.yml environments block
      cls_prefix="ENV_${CLASS_VAR}_${S}_"
      for var in $(compgen -v "$cls_prefix" || true); do
        key=${var#"$cls_prefix"}
        [[ $key == AUTH ]] && continue   # platform setting, not an app variable
        echo "$key=${!var}"
      done

      cat_existing \
        "$DEPLOY_DIR/env/common.env"        \
        "$DEPLOY_DIR/env/$CLASS.env"        \
        "$DEPLOY_DIR/env/$CLASS.$svc.env"   \
        "$SECRETS_ROOT/$APP/common.env"     \
        "$SECRETS_ROOT/$APP/$CLASS.env"     \
        "$SECRETS_ROOT/$APP/$CLASS.$svc.env"
      if [[ $ENV_NAME != "$CLASS" ]]; then
        cat_existing \
          "$SECRETS_ROOT/$APP/$ENV_NAME.env" \
          "$SECRETS_ROOT/$APP/$ENV_NAME.$svc.env"
      fi
      # last, so it wins over anything set by hand: variables pointing at this service's own address (see `upstreams`)
      if [[ -n ${UP_INJECT[$svc]:-} ]]; then echo "# --- upstream routes"; printf '%s' "${UP_INJECT[$svc]}"; fi
    } > "$out.tmp"
  )
  mv "$out.tmp" "$out"
done

# ----------------------------------------------------------------------------- required variables

missing_all=()
for svc in "${SERVICES[@]}"; do
  S=${svc^^}; S=${S//-/_}
  req_var="${S}_REQUIRED_ENV"
  for key in ${!req_var:-}; do
    if ! grep -qE "^${key}=.+" "$STACK_DIR/runtime/$svc.env"; then
      missing_all+=("$svc:$key")
    fi
  done
done
if (( ${#missing_all[@]} )); then
  tmp="$STACK_DIR/status.env.tmp"; : > "$tmp"
  write_kv "$tmp" STATUS blocked
  write_kv "$tmp" MISSING "${missing_all[*]}"
  write_kv "$tmp" APP "$APP"
  write_kv "$tmp" ENV_NAME "$ENV_NAME"
  write_kv "$tmp" TAG "$TAG"
  write_kv "$tmp" BRANCH "$BRANCH"
  write_kv "$tmp" COMMIT "$COMMIT"
  write_kv "$tmp" BLOCKED_AT "$(date +%s)"
  mv "$tmp" "$STACK_DIR/status.env"
  alert "deploy BLOCKED for $STACK: missing ${missing_all[*]}"
  scopes="'$ENV_NAME'"
  [[ $ENV_NAME != "$CLASS" ]] && scopes+=" or '$CLASS' (all previews)"
  for m in "${missing_all[@]}"; do
    for p in "${PENDING_DBS[@]}"; do
      [[ $m == "$p" ]] && warn "$m is a database that has not been created — create it in the console → Database, then redeploy"
    done
  done
  die "missing required variables: ${missing_all[*]}
       Add them in the console → Variables → $APP, scope $scopes"
fi
rm -f "$STACK_DIR/status.env"

# ----------------------------------------------------------------------------- generate compose

# Generate one compose file per service from the generic template
mkdir -p "$STACK_DIR/generated"
: > "$STACK_DIR/compose-files"

for svc in "${SERVICES[@]}"; do
  S=${svc^^}; S=${S//-/_}
  out="$STACK_DIR/generated/$svc.yml"
  sso_labels=""
  if [[ -n ${SVC_SSO[$svc]:-} ]]; then
    sso_labels="      - traefik.http.middlewares.${STACK}-${svc}-sso.forwardauth.address=http://console:8000/auth/preview?app=${APP}&env=${ENV_NAME}
      - traefik.http.middlewares.${STACK}-${svc}-sso.forwardauth.trustForwardHeader=true"
  fi
  cat > "$out" << COMPOSEYML
services:
  ${svc}:
    image: ${SVC_IMAGE[$svc]}
    restart: unless-stopped
    init: true
    env_file: [runtime/${svc}.env]
    extra_hosts: ["host.docker.internal:host-gateway"]
    networks: [default]
    mem_limit: ${SVC_MEM[$svc]}
    cpus: ${SVC_CPUS[$svc]}
    pids_limit: 512
    security_opt: ["no-new-privileges:true"]
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    labels:
      - infra.managed=true
      - infra.app=${APP}
      - infra.env=${ENV_NAME}
      - traefik.enable=true
      - traefik.docker.network=${STACK_NETWORK}
      - traefik.http.routers.${STACK}-${svc}.rule=Host(\`${SVC_HOST[$svc]}\`)
      - traefik.http.routers.${STACK}-${svc}.entrypoints=websecure
      - traefik.http.routers.${STACK}-${svc}.tls=${ROUTER_TLS:-true}
      - traefik.http.routers.${STACK}-${svc}.middlewares=${SVC_MW[$svc]}
      - traefik.http.routers.${STACK}-${svc}.service=${STACK}-${svc}
      - traefik.http.services.${STACK}-${svc}.loadbalancer.server.port=${SVC_PORT[$svc]}
${sso_labels}
${UP_LABELS[$svc]:-}
networks:
  default:
    name: ${STACK_NETWORK}
    external: true
COMPOSEYML
  echo "stack:generated/$svc.yml" >> "$STACK_DIR/compose-files"
done

# ----------------------------------------------------------------------------- stack.env

tmp="$STACK_DIR/stack.env.tmp"; : > "$tmp"
write_kv "$tmp" STACK "$STACK"
write_kv "$tmp" APP "$APP"
write_kv "$tmp" ENV_NAME "$ENV_NAME"
write_kv "$tmp" TAG "$TAG"
write_kv "$tmp" DOMAIN "$DOMAIN"
write_kv "$tmp" ROUTER_TLS "$ROUTER_TLS"
write_kv "$tmp" STACK_NETWORK "$STACK_NETWORK"
mv "$tmp" "$STACK_DIR/stack.env"

load_stack "$APP" "$ENV_NAME"
"${COMPOSE[@]}" config --quiet || die "invalid compose configuration"

# stamp managed label
{
  echo "services:"
  "${COMPOSE[@]}" config --services | while read -r s; do
    printf '  %s:\n    labels:\n      infra.managed: "true"\n' "$s"
  done
} > "$STACK_DIR/managed.yml"
echo "stack:managed.yml" >> "$STACK_DIR/compose-files"
load_stack "$APP" "$ENV_NAME"

# ----------------------------------------------------------------------------- network + pull

if [[ $USES_PG == true ]] || grep -qs "@$PG_CONTAINER[:/]" "$STACK_DIR"/runtime/*.env; then
  USES_PG=true
fi
ensure_stack_network "$STACK_NETWORK" "$APP" "$ENV_NAME" "$USES_PG"

registry_login
load_stack "$APP" "$ENV_NAME"
if (( PULL )); then
  mapfile -t stack_images < <("${COMPOSE[@]}" config --images)
  record_owned_images "${stack_images[@]}"
  if ! "${COMPOSE[@]}" pull --quiet 2>/dev/null; then
    warn "pull failed — continuing with images already on this host"
  fi
fi

# ----------------------------------------------------------------------------- migrations

if [[ -n ${MIGRATE_CMD:-} ]]; then
  msvc=${MIGRATE_SERVICE:-${SERVICES[-1]}}
  murl=$(awk -F= -v pg="$PG_CONTAINER" '
    $1~/^[A-Za-z_][A-Za-z0-9_]*$/ && $2~/^postgres(ql)?:\/\// && index($0,"@"pg) {
      sub(/^[^=]*=/,""); print; exit
    }' "$STACK_DIR/runtime/$msvc.env")
  if [[ -z $murl ]]; then
    log "migrations skipped: no postgres URL in '$msvc' yet"
    MIGRATE_CMD=""
  fi
fi
if [[ -n ${MIGRATE_CMD:-} ]]; then
  svc=${MIGRATE_SERVICE:-${SERVICES[-1]}}
  if [[ $ENV_NAME != prod && -n ${BACKUP_DIR:-} ]]; then
    snap_dir="$BACKUP_DIR/pre-migrate"; mkdir -p "$snap_dir"; chmod 700 "$snap_dir"
    snap="$snap_dir/$STACK-$TAG.dump"
    db_name=$(db_ident "${APP}_${ENV_NAME}")
    if docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc "$db_name" > "$snap" 2>/dev/null; then
      log "pre-migration snapshot: $snap"
      find "$snap_dir" -name "$STACK-*.dump" -mtime +3 -delete 2>/dev/null || true
    else
      warn "pre-migration snapshot failed — continuing"
      rm -f "$snap"
    fi
  fi
  log "running migrations: $MIGRATE_CMD"
  if ! "${COMPOSE[@]}" run --rm --no-deps -T --label traefik.enable=false \
       "$svc" sh -c "$MIGRATE_CMD"; then
    alert "migrations FAILED for $STACK ($TAG)"
    die "migrations failed"
  fi
fi

# ----------------------------------------------------------------------------- roll out

if ! "${COMPOSE[@]}" up -d --remove-orphans --wait \
     --wait-timeout "${DEPLOY_WAIT_TIMEOUT:-180}"; then
  "${COMPOSE[@]}" ps -a || true
  "${COMPOSE[@]}" logs --no-color --tail 100 || true
  alert "deploy FAILED for $STACK ($TAG)"
  die "containers did not become healthy within ${DEPLOY_WAIT_TIMEOUT:-180}s"
fi

# Waits until Traefik routes the host (anything but a 404 counts). Readiness itself is gated by the
# image's own HEALTHCHECK through `up --wait`; the platform never injects one (images may lack wget/curl).
wait_routed() {
  local host=$1 path=${2:-/} scheme=https i out
  [[ $ROUTER_TLS == true ]] || scheme=http
  for i in $(seq 1 30); do
    if out=$(docker exec infra-traefik wget -q -O /dev/null --no-check-certificate \
               --header "Host: $host" "$scheme://127.0.0.1:443$path" 2>&1); then return 0; fi
    [[ $out == *" 404"* ]] || return 0
    sleep 1
  done
  warn "Traefik still 404 for $host after 30s"
}
for svc in "${SERVICES[@]}"; do
  S=${svc^^}; S=${S//-/_}; hp_var="${S}_HEALTH_PATH"
  [[ ${SVC_PUBLIC[$svc]:-true} == false ]] || wait_routed "${SVC_HOST[$svc]}" "${!hp_var:-/}"
done

# ----------------------------------------------------------------------------- record

tmp="$STACK_DIR/meta.env.tmp"; : > "$tmp"
write_kv "$tmp" APP "$APP"
write_kv "$tmp" ENV_NAME "$ENV_NAME"
write_kv "$tmp" CLASS "$CLASS"
write_kv "$tmp" TAG "$TAG"
write_kv "$tmp" PREV_TAG "$PREV_TAG"
write_kv "$tmp" BRANCH "$BRANCH"
write_kv "$tmp" COMMIT "$COMMIT"
write_kv "$tmp" URL "$URL"
urls=""; for svc in "${SERVICES[@]}"; do [[ ${SVC_PUBLIC[$svc]:-true} == false ]] || urls+="$svc=https://${SVC_HOST[$svc]}$URL_PORT_SUFFIX "; done
write_kv "$tmp" URLS "${urls% }"
write_kv "$tmp" UPSTREAMS "${UP_META% }"
write_kv "$tmp" SERVICES "${SERVICES[*]}"
write_kv "$tmp" STACK_NETWORK "$STACK_NETWORK"
write_kv "$tmp" USES_PG "$USES_PG"
write_kv "$tmp" DB_LIST "${ALL_DBS[*]:-}"
write_kv "$tmp" DB_PENDING "${PENDING_DBS[*]:-}"
write_kv "$tmp" REPO "${GITHUB_REPOSITORY:-$(meta_get "$STACK_DIR/meta.env" REPO 2>/dev/null || true)}"
write_kv "$tmp" DEPLOYED_AT "$(date +%s)"
write_kv "$tmp" DEPLOYED_BY "${GITHUB_ACTOR:-${SUDO_USER:-${USER:-unknown}}}"
mv "$tmp" "$STACK_DIR/meta.env"

log "OK  $STACK is live at $URL"
[[ -z ${GITHUB_OUTPUT:-} ]] || echo "url=$URL" >> "$GITHUB_OUTPUT"
echo "$URL"
