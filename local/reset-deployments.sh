#!/bin/bash
# Wipe all app deployments, projects and app databases. Leaves platform services untouched.
set -e

INFRA_ROOT=/opt/infra
DEPLOY_ROOT=/srv/deployments
STATE_DIR=/var/lib/infra
SECRETS_ROOT=/etc/infra/secrets
PG_CONTAINER=infra-postgres
PREFIX=infra

echo "=== Destroying all app stacks ==="
for stack_dir in "$DEPLOY_ROOT"/*/*; do
  [[ -d $stack_dir ]] || continue
  app=$(basename "$(dirname "$stack_dir")")
  env=$(basename "$stack_dir")
  echo "  destroying $app/$env"
  bash "$INFRA_ROOT/scripts/destroy.sh" --app "$app" --env "$env" \
    $([ "$env" = "prod" ] && echo "--i-really-mean-prod") 2>/dev/null || true
done

echo "=== Removing any leftover infra-managed containers ==="
docker ps -aq --filter "label=infra.managed=true" \
  --filter "label!=com.docker.compose.project=infra-platform" | xargs -r docker rm -f

echo "=== Removing leftover infra-managed networks ==="
docker network ls --filter "label=infra.managed=true" -q | xargs -r docker network rm 2>/dev/null || true

echo "=== Dropping all app databases ==="
if docker inspect "$PG_CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  docker exec "$PG_CONTAINER" psql -U postgres -tAc \
    "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') AND NOT datistemplate" \
  | while read -r db; do
    echo "  dropping database $db"
    docker exec "$PG_CONTAINER" psql -U postgres -c "DROP DATABASE \"$db\" WITH (FORCE)" 2>/dev/null || true
    docker exec "$PG_CONTAINER" psql -U postgres -c "DROP ROLE IF EXISTS \"$db\"" 2>/dev/null || true
  done
fi

echo "=== Clearing deployment state ==="
rm -rf "$DEPLOY_ROOT"/*
rm -rf "$STATE_DIR/projects"
rm -rf "$STATE_DIR/docker"
rm -rf "$STATE_DIR/incoming"
rm -rf "$SECRETS_ROOT"/*
rm -f  "$STATE_DIR/owned-images"

echo "=== Done. Platform services still running: ==="
docker ps --filter "label=com.docker.compose.project=infra-platform" --format "  {{.Names}}  {{.Status}}"
