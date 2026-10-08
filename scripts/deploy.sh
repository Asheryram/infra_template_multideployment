#!/usr/bin/env bash
# Deploy or update one environment of one app.
#
#   infra deploy --manifest <repo>/.deploy --env <env> --tag <tag> [--branch <b>] [--commit <sha>] [--no-pull]
#   infra redeploy <app> <env> [--tag <tag>]     re-run using the stored manifest (config/secret change, relink)
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

source_env "$MANIFEST_DIR/manifest.env"
: "${APP_NAME:?APP_NAME is missing from manifest.env}"
: "${TYPE:?TYPE is missing from manifest.env}"
validate_name app "$APP_NAME"
[[ -z $APP || $APP == "$APP_NAME" ]] || die "--app '$APP' does not match APP_NAME '$APP_NAME' in the manifest"
APP=$APP_NAME
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

# Keep a snapshot of the manifest so redeploys/relinks don't need the app repo.
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

URL="https://${HOST[${COMPONENTS[0]}]}$URL_PORT_SUFFIX"
SELF_API_URL=""
case $TYPE in
  monolith)      SELF_API_URL="https://${HOST[app]}$URL_PORT_SUFFIX" ;;
  backend|split) SELF_API_URL="https://${HOST[api]}$URL_PORT_SUFFIX" ;;
esac

# ----------------------------------------------------------------------------- database

DATABASE_URL="" DB_NAME="" DB_PASSWORD=""
if [[ ${NEEDS_DB:-false} == true ]]; then
  DB_NAME=$(db_ident "${APP}_${ENV_NAME}")
  pwfile="$STACK_DIR/.db_password"
  if [[ ! -s $pwfile ]]; then ( umask 077; openssl rand -hex 24 > "$pwfile" ); fi
  DB_PASSWORD=$(<"$pwfile")
  template=""
  if [[ $PREVIEW == true && ${DB_PREVIEW_SOURCE:-template} == template ]]; then
    template=$(db_template_name "$APP")
  fi
  db_ensure "$DB_NAME" "$DB_NAME" "$DB_PASSWORD" "$template"
  DATABASE_URL="postgres://$DB_NAME:$DB_PASSWORD@$PG_CONTAINER:5432/$DB_NAME"
fi

# ----------------------------------------------------------------------------- backend resolution
# Frontend previews follow a backend preview built from the same branch name;
# otherwise they fall back to BACKEND_FALLBACK_ENV (default: develop).

UPSTREAM_API_URL="" UPSTREAM_SOURCE=""
resolve_backend() {
  local backend=${BACKEND_APP:-} target meta v
  v="API_URL_${CLASS_VAR}"
  if [[ -n ${!v:-} ]]; then UPSTREAM_API_URL=${!v}; UPSTREAM_SOURCE="manifest $v"; return 0; fi
  [[ -n $backend ]] || return 0

  if [[ $PREVIEW == true && -n $BRANCH ]]; then
    for meta in "$DEPLOY_ROOT/$backend"/pr-*/meta.env; do
      if [[ $(meta_get "$meta" BRANCH) == "$BRANCH" ]]; then
        UPSTREAM_API_URL=$(meta_get "$meta" API_URL)
        UPSTREAM_SOURCE="$backend/$(meta_get "$meta" ENV_NAME) (same branch)"
        return 0
      fi
    done
  fi

  target=$ENV_NAME
  if [[ $PREVIEW == true ]]; then target=${BACKEND_FALLBACK_ENV:-develop}; fi
  meta="$DEPLOY_ROOT/$backend/$target/meta.env"
  if [[ -f $meta ]]; then
    UPSTREAM_API_URL=$(meta_get "$meta" API_URL)
    UPSTREAM_SOURCE="$backend/$target"
  else
    warn "backend $backend/$target is not deployed — API_URL will be empty"
  fi
}

case $TYPE in
  split)    UPSTREAM_API_URL=$SELF_API_URL; UPSTREAM_SOURCE=self ;;
  frontend) resolve_backend ;;
esac
if [[ -n $UPSTREAM_SOURCE ]]; then log "API_URL → ${UPSTREAM_API_URL:-<none>} (from $UPSTREAM_SOURCE)"; fi

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
      if [[ -n $DATABASE_URL && $comp != web ]]; then
        echo "DATABASE_URL=$DATABASE_URL"
        echo "PGHOST=$PG_CONTAINER"
        echo "PGPORT=5432"
        echo "PGDATABASE=$DB_NAME"
        echo "PGUSER=$DB_NAME"
        echo "PGPASSWORD=$DB_PASSWORD"
      fi
      if [[ $comp != api && -n $UPSTREAM_API_URL ]]; then echo "API_URL=$UPSTREAM_API_URL"; fi
      if [[ $TYPE == split && $comp == api ]]; then echo "FRONTEND_URL=https://${HOST[web]}$URL_PORT_SUFFIX"; fi
      cat_existing \
        "$DEPLOY_DIR/env/common.env" "$DEPLOY_DIR/env/$CLASS.env" "$DEPLOY_DIR/env/$CLASS.$comp.env" \
        "$SECRETS_ROOT/$APP/common.env" "$SECRETS_ROOT/$APP/$CLASS.env" "$SECRETS_ROOT/$APP/$CLASS.$comp.env"
    } > "$out.tmp"
  )
  mv "$out.tmp" "$out"
done

# ----------------------------------------------------------------------------- compose inputs

tmp="$STACK_DIR/stack.env.tmp"
: > "$tmp"
write_kv "$tmp" STACK "$STACK"
write_kv "$tmp" APP "$APP"
write_kv "$tmp" ENV_NAME "$ENV_NAME"
write_kv "$tmp" TAG "$TAG"
write_kv "$tmp" DOMAIN "$DOMAIN"
write_kv "$tmp" ROUTER_TLS "$ROUTER_TLS"
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

registry_login
if (( PULL )); then
  mapfile -t stack_images < <("${COMPOSE[@]}" config --images)
  record_owned_images "${stack_images[@]}"
  "${COMPOSE[@]}" pull --quiet
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
write_kv "$tmp" UPSTREAM_API_URL "$UPSTREAM_API_URL"
write_kv "$tmp" UPSTREAM_SOURCE "$UPSTREAM_SOURCE"
write_kv "$tmp" BACKEND_APP "${BACKEND_APP:-}"
write_kv "$tmp" DB_NAME "$DB_NAME"
write_kv "$tmp" REPO "${GITHUB_REPOSITORY:-$(meta_get "$STACK_DIR/meta.env" REPO 2>/dev/null || true)}"
write_kv "$tmp" DEPLOYED_AT "$(date +%s)"
write_kv "$tmp" DEPLOYED_BY "${GITHUB_ACTOR:-${SUDO_USER:-${USER:-unknown}}}"
mv "$tmp" "$STACK_DIR/meta.env"

if [[ $PREVIEW == true && -n $BRANCH && -n $SELF_API_URL ]]; then
  relink_frontends "$APP" "$BRANCH" "$SELF_API_URL"
fi

log "OK  $STACK is live at $URL"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "url=$URL"
    echo "api_url=$SELF_API_URL"
    echo "upstream_api_url=$UPSTREAM_API_URL"
  } >> "$GITHUB_OUTPUT"
fi
echo "$URL"
