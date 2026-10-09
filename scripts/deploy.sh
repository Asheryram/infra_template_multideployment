#!/usr/bin/env bash
# Deploy or update one environment of one app.
#
#   infra deploy --manifest <repo>/.deploy --env <env> --tag <tag> [--branch <b>] [--commit <sha>] [--no-pull]
#   infra redeploy <app> <env> [--tag <tag>]     re-run using the stored manifest (after a variable change)
#   infra rollback <app> <env>                   redeploy the previous tag
#
# <env> is prod | staging | develop | pr-<number> | any short name (qa, demo...).
# Hosts:  prod → <app>.<DOMAIN>, others → <app>-<env>.<DOMAIN>
#         TYPE=split adds api-<app>[-<env>].<DOMAIN> for the API.
SCRIPT_NAME=deploy
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/db.sh
source "$INFRA_ROOT/scripts/lib/db.sh"

APP="" ENV_NAME="" TAG="" MANIFEST_DIR="" BRANCH="" COMMIT="" PULL=1 REDEPLOY=0 ROLLBACK=0
while (( $# )); do
  case $1 in
    --app)      APP=${2:?--app needs a value}; shift 2 ;;
    --env)      ENV_NAME=${2:?--env needs a value}; shift 2 ;;
    --tag)      TAG=${2:?--tag needs a value}; shift 2 ;;
    --manifest) MANIFEST_DIR=${2:?--manifest needs a value}; shift 2 ;;
    --branch)   BRANCH=${2-}; shift 2 ;;
    --commit)   COMMIT=${2-}; shift 2 ;;
    --no-pull)  PULL=0; shift ;;
    --redeploy) REDEPLOY=1; shift ;;
    --rollback) REDEPLOY=1; ROLLBACK=1; shift ;;
    -h|--help)  usage ;;
    *) die "unknown argument: $1 (see --help)" ;;
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
  # A blocked deploy (missing variables) is the newest intent: retry ITS tag, not the one still live.
  if [[ -f $(stack_dir "$APP" "$ENV_NAME")/status.env && $ROLLBACK -eq 0 ]]; then META="$(stack_dir "$APP" "$ENV_NAME")/status.env"; fi
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

[[ -n $TAG ]] || die "--tag is required"
[[ -n $MANIFEST_DIR ]] || die "--manifest is required (path to the app's .deploy directory)"
[[ -f $MANIFEST_DIR/manifest.env ]] || die "manifest not found: $MANIFEST_DIR/manifest.env"
MANIFEST_DIR=$(cd "$MANIFEST_DIR" && pwd)
BRANCH=${BRANCH//\'/_}

load_manifest "$MANIFEST_DIR/manifest.env"     # parsed, never executed (untrusted repo input)
: "${APP_NAME:?APP_NAME is missing from manifest.env}"
: "${TYPE:?TYPE is missing from manifest.env}"
validate_name app "$APP_NAME"
[[ -z $APP || $APP == "$APP_NAME" ]] || die "--app '$APP' does not match APP_NAME '$APP_NAME' in the manifest"
APP=$APP_NAME
case $APP in console|traefik|logs|status|hooks|grafana|www|api) die "APP_NAME '$APP' is reserved by the platform" ;; esac
comps=$(components_for "$TYPE")
read -r -a COMPONENTS <<<"$comps"

STACK=$(stack_name "$APP" "$ENV_NAME")
STACK_DIR=$(stack_dir "$APP" "$ENV_NAME")
CLASS=$(env_class "$ENV_NAME")
CLASS_VAR=${CLASS^^}; CLASS_VAR=${CLASS_VAR//-/_}
PREVIEW=false
if is_preview "$ENV_NAME"; then PREVIEW=true; fi

acquire_lock "$STACK"

if [[ ! -f $STACK_DIR/meta.env ]]; then
  foreign=$(foreign_in_project "$STACK")
  [[ -z $foreign ]] || die "compose project '$STACK' already has containers we did not create ($foreign) — refusing to touch them. Change STACK_PREFIX or APP_NAME."
fi

if [[ $PREVIEW == true && ! -f $STACK_DIR/meta.env ]]; then
  n=$(count_previews)
  (( n < MAX_PREVIEWS )) || die "preview limit reached ($n/$MAX_PREVIEWS). Close old PRs or run 'infra cleanup'."
fi

PREV_TAG=""
if [[ -f $STACK_DIR/meta.env ]]; then
  old_tag=$(meta_get "$STACK_DIR/meta.env" TAG)
  if [[ $old_tag == "$TAG" ]]; then PREV_TAG=$(meta_get "$STACK_DIR/meta.env" PREV_TAG); else PREV_TAG=$old_tag; fi
fi

log "deploying $STACK  type=$TYPE  tag=$TAG  branch=${BRANCH:-n/a}"

# Keep a snapshot of the manifest so redeploys don't need the app repo.
mkdir -p "$STACK_DIR/runtime"
if (( ! REDEPLOY )); then
  rm -rf "$STACK_DIR/deploy.new"
  cp -R "$MANIFEST_DIR" "$STACK_DIR/deploy.new"
  rm -rf "$STACK_DIR/deploy"
  mv "$STACK_DIR/deploy.new" "$STACK_DIR/deploy"
fi
DEPLOY_DIR="$STACK_DIR/deploy"

# ----------------------------------------------------------------------------- per component

base=$APP
if [[ $ENV_NAME != prod ]]; then base="$APP-$ENV_NAME"; fi

declare -A HOST IMAGE PORT MEM CPUS MW
for comp in "${COMPONENTS[@]}"; do
  C=${comp^^}

  host="$base.$DOMAIN"
  if [[ $TYPE == split && $comp == api ]]; then host="api-$base.$DOMAIN"; fi
  v="${C}_HOST_${CLASS_VAR}"; HOST[$comp]=${!v:-$host}        # e.g. WEB_HOST_PROD=www.example.com

  v="${C}_IMAGE"; image=${!v:-}
  if [[ -z $image ]]; then
    [[ -n ${IMAGE_REPO:-} ]] || die "set IMAGE_REPO (or ${C}_IMAGE) in manifest.env"
    image="$IMAGE_REPO/$comp:$TAG"
  fi
  IMAGE[$comp]=${image//\{tag\}/$TAG}

  v="${C}_PORT";      PORT[$comp]=${!v:-$(default_port "$comp")}
  v="${C}_MEM_LIMIT"; MEM[$comp]=${!v:-512m}
  v="${C}_CPUS";      CPUS[$comp]=${!v:-1.0}
  if [[ $PREVIEW == true && -n ${PREVIEW_MEM_LIMIT:-} ]]; then MEM[$comp]=$PREVIEW_MEM_LIMIT; fi

  mw="secure-headers@file,compress@file"
  if [[ $PREVIEW == true ]]; then
    mw+=",preview-noindex@file"
    # APIs skip basic-auth by default: browsers won't send it on cross-origin fetches.
    auth=${PREVIEW_AUTH:-true}
    if [[ $comp == api ]]; then auth=${API_PREVIEW_AUTH:-false}; fi
    if [[ $PREVIEW_AUTH_ENABLED == true && $auth == true ]]; then mw+=",preview-auth@file"; fi
  fi
  if [[ -n ${EXTRA_MIDDLEWARES:-} ]]; then mw+=",$EXTRA_MIDDLEWARES"; fi
  MW[$comp]=$mw
done

# Hostname ownership (multi-tenant): an app may only use hosts in its own namespace on the platform
# domain, and never a host another environment already serves — no traffic hijacking.
for comp in "${COMPONENTS[@]}"; do
  h=${HOST[$comp]}
  if [[ $h == *".$DOMAIN" ]]; then
    sub=${h%".$DOMAIN"}
    [[ $sub == "$APP" || $sub == "$APP-"* || $sub == "api-$APP" || $sub == "api-$APP-"* ]] \
      || die "host $h is outside $APP's namespace (allowed on $DOMAIN: $APP[-…] and api-$APP[-…])"
  fi
  for f in "$DEPLOY_ROOT"/*/*/stack.env; do
    [[ $f == "$STACK_DIR/stack.env" ]] && continue
    if grep -qF "_HOST='$h'" "$f"; then
      die "host $h is already served by $(dirname "${f#"$DEPLOY_ROOT/"}") — refusing to take it over"
    fi
  done
done

URL="https://${HOST[${COMPONENTS[0]}]}$URL_PORT_SUFFIX"
SELF_API_URL=""
case $TYPE in
  monolith)      SELF_API_URL="https://${HOST[app]}$URL_PORT_SUFFIX" ;;
  backend|split) SELF_API_URL="https://${HOST[api]}$URL_PORT_SUFFIX" ;;
esac

# ----------------------------------------------------------------------------- database (provisioned, never wired)
# Render model: NEEDS_DB=true provisions an empty, isolated database for this environment on its
# FIRST deploy — and that's all. Nothing is injected into the app: DevOps decides what the app
# connects to by setting DATABASE_URL (or any name) as a variable — this DB, another env's, an
# external one, or none. A wiped DB is NOT recreated by later deploys; only `infra db create`
# (console: Database → Create) brings it back, empty, with the same URL.

DB_NAME=$(db_ident "${APP}_${ENV_NAME}")
pwfile="$STACK_DIR/.db_password"
if [[ ${NEEDS_DB:-false} == true && ! -f $STACK_DIR/meta.env && ! -f $STACK_DIR/.db_wiped ]]; then
  if [[ ! -s $pwfile ]]; then ( umask 077; openssl rand -hex 24 > "$pwfile" ); fi
  template=""
  if [[ $PREVIEW == true && ${DB_PREVIEW_SOURCE:-template} == template ]]; then template=$(db_template_name "$APP"); fi
  db_ensure "$DB_NAME" "$DB_NAME" "$(<"$pwfile")" "$template"
  log "database $DB_NAME provisioned (not connected — set DATABASE_URL in the console to use it)"
fi
OWN_DB=false
if [[ -s $pwfile ]] && pg_running && db_exists "$DB_NAME"; then OWN_DB=true; fi


# ----------------------------------------------------------------------------- runtime env files
# Order (later wins): injected by infra < repo .deploy/env/* < server secrets.

for comp in "${COMPONENTS[@]}"; do
  out="$STACK_DIR/runtime/$comp.env"
  (
    umask 077
    {
      echo "# Generated by 'infra deploy' — do not edit. Change the sources listed below instead."
      echo "APP_NAME=$APP"
      echo "APP_ENV=$ENV_NAME"
      echo "ENV_CLASS=$CLASS"
      echo "IS_PREVIEW=$PREVIEW"
      echo "PORT=${PORT[$comp]}"
      echo "PUBLIC_URL=https://${HOST[$comp]}$URL_PORT_SUFFIX"
      echo "INFRA_DOMAIN=$DOMAIN"
      echo "IMAGE_TAG=$TAG"
      echo "GIT_BRANCH=$BRANCH"
      echo "GIT_COMMIT=$COMMIT"
      # Nothing else is injected: no DATABASE_URL, no API URLs. Connections are variables DevOps sets.
      cat_existing \
        "$DEPLOY_DIR/env/common.env" "$DEPLOY_DIR/env/$CLASS.env" "$DEPLOY_DIR/env/$CLASS.$comp.env" \
        "$SECRETS_ROOT/$APP/common.env" "$SECRETS_ROOT/$APP/$CLASS.env" "$SECRETS_ROOT/$APP/$CLASS.$comp.env"
      # Most specific: variables for exactly this environment (e.g. pr-12.env), set from the console.
      if [[ $ENV_NAME != "$CLASS" ]]; then
        cat_existing "$SECRETS_ROOT/$APP/$ENV_NAME.env" "$SECRETS_ROOT/$APP/$ENV_NAME.$comp.env"
      fi
    } > "$out.tmp"
  )
  mv "$out.tmp" "$out"
done

# ----------------------------------------------------------------------------- required variables
# Manifest: <COMPONENT>_REQUIRED_ENV="STRIPE_KEY NEW_FEATURE_URL". Missing or empty → the deploy is
# blocked before anything changes, and the console shows exactly what to add where.

missing_all=()
for comp in "${COMPONENTS[@]}"; do
  v="${comp^^}_REQUIRED_ENV"
  for key in ${!v:-}; do
    if ! grep -qE "^${key}=.+" "$STACK_DIR/runtime/$comp.env"; then missing_all+=("$comp:$key"); fi
  done
done
if (( ${#missing_all[@]} )); then
  tmp="$STACK_DIR/status.env.tmp"; : > "$tmp"
  write_kv "$tmp" STATUS blocked
  write_kv "$tmp" MISSING "${missing_all[*]}"
  write_kv "$tmp" APP "$APP"
  write_kv "$tmp" ENV_NAME "$ENV_NAME"
  write_kv "$tmp" TYPE "$TYPE"
  write_kv "$tmp" TAG "$TAG"
  write_kv "$tmp" BRANCH "$BRANCH"
  write_kv "$tmp" COMMIT "$COMMIT"
  write_kv "$tmp" BLOCKED_AT "$(date +%s)"
  mv "$tmp" "$STACK_DIR/status.env"
  alert "deploy BLOCKED for $STACK: missing ${missing_all[*]}"
  scopes="'$ENV_NAME'"
  if [[ $ENV_NAME != "$CLASS" ]]; then scopes+=" (this PR only) or '$CLASS' (all previews)"; fi
  die "missing required variables: ${missing_all[*]}
       Add them in the console (https://console.$DOMAIN$URL_PORT_SUFFIX → Variables → $APP, scope $scopes)
       or: sudo infra secrets edit $APP $CLASS   — then retry: infra redeploy $APP $ENV_NAME"
fi
rm -f "$STACK_DIR/status.env"

# ----------------------------------------------------------------------------- compose inputs

tmp="$STACK_DIR/stack.env.tmp"
: > "$tmp"
write_kv "$tmp" STACK "$STACK"
write_kv "$tmp" APP "$APP"
write_kv "$tmp" ENV_NAME "$ENV_NAME"
write_kv "$tmp" TAG "$TAG"
write_kv "$tmp" DOMAIN "$DOMAIN"
write_kv "$tmp" ROUTER_TLS "$ROUTER_TLS"
STACK_NETWORK=$(stack_network "$APP" "$ENV_NAME")
write_kv "$tmp" STACK_NETWORK "$STACK_NETWORK"
# Postgres joins this environment's network only if it actually uses the platform DB.
USES_PG=false
# Postgres joins this environment's network only if it has its own DB or a variable points at Postgres.
if [[ $OWN_DB == true ]] || grep -qs "@$PG_CONTAINER[:/]" "$STACK_DIR"/runtime/*.env; then USES_PG=true; fi
for comp in "${COMPONENTS[@]}"; do
  C=${comp^^}
  write_kv "$tmp" "${C}_IMAGE" "${IMAGE[$comp]}"
  write_kv "$tmp" "${C}_HOST" "${HOST[$comp]}"
  write_kv "$tmp" "${C}_PORT" "${PORT[$comp]}"
  write_kv "$tmp" "${C}_MEM_LIMIT" "${MEM[$comp]}"
  write_kv "$tmp" "${C}_CPUS" "${CPUS[$comp]}"
  write_kv "$tmp" "${C}_MIDDLEWARES" "${MW[$comp]}"
done
mv "$tmp" "$STACK_DIR/stack.env"

{
  for comp in "${COMPONENTS[@]}"; do echo "tpl:components/$comp.yml"; done
  if [[ -f $DEPLOY_DIR/compose.extra.yml ]]; then echo "stack:deploy/compose.extra.yml"; fi
} > "$STACK_DIR/compose-files"

load_stack "$APP" "$ENV_NAME"
"${COMPOSE[@]}" config --quiet || die "invalid compose configuration for $STACK"

# Stamp every service — including sidecars from compose.extra.yml — as ours.
{
  echo "# Generated by 'infra deploy': marks every container in this stack as managed by infra."
  echo "services:"
  "${COMPOSE[@]}" config --services | while read -r svc; do
    printf '  %s:\n    labels:\n      infra.managed: "true"\n' "$svc"
  done
} > "$STACK_DIR/managed.yml"
echo "stack:managed.yml" >> "$STACK_DIR/compose-files"
load_stack "$APP" "$ENV_NAME"

# ----------------------------------------------------------------------------- roll out

# ----------------------------------------------------------------------------- policy
# The repo controls its .deploy/ folder (incl. compose.extra.yml). On a multi-tenant host that
# must never become a way into the host or into another project, so the fully merged stack is
# checked BEFORE anything starts. Violations block the deploy.

compose_without_extra() { # BASE = the COMPOSE command with only the platform templates
  local i; BASE=()
  for (( i = 0; i < ${#COMPOSE[@]}; i++ )); do
    if [[ ${COMPOSE[i]} == -f && ( ${COMPOSE[i+1]:-} == "$STACK_DIR/deploy/compose.extra.yml" \
          || ${COMPOSE[i+1]:-} == "$STACK_DIR/managed.yml" ) ]]; then i=$((i + 1)); continue; fi
    BASE+=("${COMPOSE[i]}")
  done
}

policy_violations() {
  local full raw base
  full=$("${COMPOSE[@]}" config --format json)
  raw=$("${COMPOSE[@]}" config --no-normalize --no-interpolate --no-consistency --format json)
  compose_without_extra
  base=$("${BASE[@]}" config --format json)
  jq -rn --argjson c "$full" --argjson r "$raw" --argjson b "$base" --arg runtime "$STACK_DIR/runtime/" '
    def tlabels: (. // {}) | with_entries(select(.key | startswith("traefik.")));
    def service_checks($s; $v):
      (if $v.privileged then "privileged" else empty end),
      (if (($v.cap_add // []) | length) > 0 then "cap_add" else empty end),
      (if (($v.devices // []) | length) > 0 then "devices" else empty end),
      ("network_mode", "pid", "ipc", "uts", "userns_mode", "cgroup_parent", "container_name"
         | select($v[.] != null)),
      (if (($v.ports // []) | length) > 0 then "ports (publish through Traefik instead)" else empty end),
      (if $v.build != null then "build (images are built in CI)" else empty end),
      (if (($v.volumes_from // []) | length) > 0 then "volumes_from" else empty end),
      (($v.volumes // [])[] | select(.type != "volume" and .type != "tmpfs") | "\(.type) mount \(.source // "")"),
      (($v.security_opt // [])[] | select(. != "no-new-privileges:true" and . != "no-new-privileges") | "security_opt \(.)"),
      (($v.networks // {}) | keys[] | select(. != "default") | "extra network \(.)"),
      (if (($v.sysctls // {}) | length) > 0 then "sysctls" else empty end),
      (if ($v.mem_limit // $v.deploy.resources.limits.memory) == null then "no mem_limit" else empty end),
      ((($r.services[$s].env_file) // [])[] | .path | select(startswith($runtime) | not) | "env_file \(.)"),
      (if ($v.labels | tlabels) != ($b.services[$s].labels | tlabels)
         then "traefik labels differ from the platform template (custom routing is not allowed)" else empty end);
    ($c.services | to_entries[] | .key as $s | service_checks($s; .value) | "\($s): \(.)"),
    (($c.volumes // {}) | to_entries[] | select(.value.external == true or ((.value.driver_opts // {}) | length) > 0)
       | "volume \(.key): external volumes and driver_opts are not allowed"),
    (($c.networks // {}) | keys[] | select(. != "default") | "top-level network \(.)"),
    (($c.configs // {}) | keys[] | "top-level configs: \(.)"),
    (($c.secrets // {}) | keys[] | "top-level secrets: \(.)")'
}

discard_if_new() { # a refused FIRST deploy leaves nothing behind (DB, network, state)
  if [[ ! -f $STACK_DIR/meta.env ]]; then
    db_drop "$DB_NAME" "$DB_NAME"            # only exists if this very deploy provisioned it
    rm -rf "$STACK_DIR"; rmdir "$DEPLOY_ROOT/$APP" 2>/dev/null || true
  fi
}
if ! violations=$(policy_violations); then
  discard_if_new
  die "could not evaluate the stack policy (is compose.extra.yml valid?)"
fi
if [[ -n $violations ]]; then
  discard_if_new
  alert "deploy REFUSED for $STACK: stack violates the platform policy"
  die "the stack violates the platform policy (nothing was started):
$(sed 's/^/         - /' <<<"$violations")
       Sidecars in compose.extra.yml may only use images, env (runtime/*.env), named volumes,
       tmpfs and mem_limit. Ports, host mounts, privileges and custom routing are not allowed."
fi

# Before migrations: `compose run` already needs the network (and Postgres on it).
ensure_stack_network "$STACK_NETWORK" "$APP" "$ENV_NAME" "$USES_PG"

registry_login
load_stack "$APP" "$ENV_NAME"     # rebuild COMPOSE so pulls use the project's DOCKER_CONFIG
if (( PULL )); then
  mapfile -t stack_images < <("${COMPOSE[@]}" config --images)
  record_owned_images "${stack_images[@]}"
  # Tags are immutable (sha-…), so an image already on the host is the right one even if the
  # registry is unreachable. A truly missing image still fails at `up`.
  if ! "${COMPOSE[@]}" pull --quiet 2>/dev/null; then
    warn "pull failed — continuing with images already on this host"
  fi
fi

# Migrations need a database the service is actually told about — and must not alter someone
# else's: they run only against THIS environment's own DB, unless DevOps sets the variable
# MIGRATE_ON_SHARED_DB=true for the service.
db_of_url() { sed -nE 's#^[a-z]+://[^@]*@([^:/]+)(:[0-9]+)?/([^?]+).*#\1 \3#p' <<<"$1"; }   # → "host db"
if [[ -n ${MIGRATE_CMD:-} ]]; then
  msvc=${MIGRATE_SERVICE:-${COMPONENTS[-1]}}
  murl=$(sed -nE 's/^DATABASE_URL=(.+)$/\1/p' "$STACK_DIR/runtime/$msvc.env" | tail -1)
  read -r mhost mdb <<<"$(db_of_url "$murl")"
  if [[ -z $murl ]]; then
    log "migrations skipped: '$msvc' has no DATABASE_URL yet (set it in the console → Manage → Database)"
    MIGRATE_CMD=""
  elif [[ ! ( $mhost == "$PG_CONTAINER" && $mdb == "$DB_NAME" ) ]] \
       && ! grep -qE '^MIGRATE_ON_SHARED_DB=true$' "$STACK_DIR/runtime/$msvc.env"; then
    warn "migrations skipped: DATABASE_URL points to '$mdb' on '$mhost', not this environment's own DB (set MIGRATE_ON_SHARED_DB=true to allow)"
    MIGRATE_CMD=""
  fi
fi
if [[ -n ${MIGRATE_CMD:-} ]]; then
  svc=${MIGRATE_SERVICE:-${COMPONENTS[-1]}}
  log "running migrations in '$svc': $MIGRATE_CMD"
  if ! "${COMPOSE[@]}" run --rm --no-deps -T --label traefik.enable=false "$svc" sh -c "$MIGRATE_CMD"; then
    alert "migrations FAILED for $STACK ($TAG) — old version still running"
    die "migrations failed"
  fi
fi

if ! "${COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout "${DEPLOY_WAIT_TIMEOUT:-180}"; then
  "${COMPOSE[@]}" ps -a || true
  "${COMPOSE[@]}" logs --no-color --tail 100 || true
  alert "deploy FAILED for $STACK ($TAG)"
  die "containers did not become healthy within ${DEPLOY_WAIT_TIMEOUT:-180}s"
fi

# Healthy containers aren't reachable until Traefik has picked them up (event + reload, ~1-3 s).
# Ask Traefik itself — from inside its container, so this works from the CLI, CI runner and console
# alike — until the host stops returning Traefik's "no route" 404. 401 (preview auth) counts as routed.
wait_routed() {
  local host=$1 scheme=https i out
  if [[ $ROUTER_TLS != true ]]; then scheme=http; fi
  for i in $(seq 1 30); do
    if out=$(docker exec infra-traefik wget -q -O /dev/null --no-check-certificate \
               --header "Host: $host" "$scheme://127.0.0.1:443/" 2>&1); then return 0; fi
    [[ $out == *" 404"* ]] || return 0
    sleep 1
  done
  warn "Traefik still answers 404 for $host after 30s — the app may 404 on '/', or routing is broken"
}
for comp in "${COMPONENTS[@]}"; do wait_routed "${HOST[$comp]}"; done

# ----------------------------------------------------------------------------- record

tmp="$STACK_DIR/meta.env.tmp"
: > "$tmp"
write_kv "$tmp" APP "$APP"
write_kv "$tmp" TYPE "$TYPE"
write_kv "$tmp" ENV_NAME "$ENV_NAME"
write_kv "$tmp" CLASS "$CLASS"
write_kv "$tmp" TAG "$TAG"
write_kv "$tmp" PREV_TAG "$PREV_TAG"
write_kv "$tmp" BRANCH "$BRANCH"
write_kv "$tmp" COMMIT "$COMMIT"
write_kv "$tmp" URL "$URL"
write_kv "$tmp" API_URL "$SELF_API_URL"
# What the service is actually connected to (for the console) — read from its env, not assumed.
DB_CONNECTED=none
for comp in "${COMPONENTS[@]}"; do
  u=$(sed -nE 's/^DATABASE_URL=(.+)$/\1/p' "$STACK_DIR/runtime/$comp.env" | tail -1)
  [[ -n $u ]] || continue
  read -r h d <<<"$(db_of_url "$u")"
  if [[ $h == "$PG_CONTAINER" && $d == "$DB_NAME" ]]; then DB_CONNECTED=own
  elif [[ $h == "$PG_CONTAINER" ]]; then DB_CONNECTED="platform:$d"
  else DB_CONNECTED="external:$h"; fi
done
write_kv "$tmp" DB_NAME "$([[ $OWN_DB == true ]] && echo "$DB_NAME")"
write_kv "$tmp" DB_CONNECTED "$DB_CONNECTED"
write_kv "$tmp" STACK_NETWORK "$STACK_NETWORK"
write_kv "$tmp" USES_PG "$USES_PG"
write_kv "$tmp" REPO "${GITHUB_REPOSITORY:-$(meta_get "$STACK_DIR/meta.env" REPO 2>/dev/null || true)}"
write_kv "$tmp" DEPLOYED_AT "$(date +%s)"
write_kv "$tmp" DEPLOYED_BY "${GITHUB_ACTOR:-${SUDO_USER:-${USER:-unknown}}}"
mv "$tmp" "$STACK_DIR/meta.env"

log "OK  $STACK is live at $URL"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "url=$URL"
    echo "api_url=$SELF_API_URL"
  } >> "$GITHUB_OUTPUT"
fi
echo "$URL"
