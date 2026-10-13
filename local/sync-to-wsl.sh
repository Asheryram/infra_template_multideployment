#!/bin/bash
set -euo pipefail

SRC="/mnt/c/Users/YramAsherTetteh-Abot/OneDrive - AmaliTech gGmbH/Desktop/infra_template_multideployment"
cp "$SRC/scripts/lib/db.sh"              /opt/infra/scripts/lib/db.sh
cp "$SRC/scripts/lib/common.sh"          /opt/infra/scripts/lib/common.sh
cp "$SRC/scripts/deploy.sh"              /opt/infra/scripts/deploy.sh
cp "$SRC/scripts/cleanup.sh"             /opt/infra/scripts/cleanup.sh
cp "$SRC/platform/docker-compose.yml"    /opt/infra/platform/docker-compose.yml
cp "$SRC/platform/platform.sh"           /opt/infra/platform/platform.sh
cp "$SRC/platform/cert.sh"               /opt/infra/platform/cert.sh
cp "$SRC/platform/traefik/static.selfsigned.yml.tmpl" /opt/infra/platform/traefik/static.selfsigned.yml.tmpl
cp "$SRC/platform/traefik/static.letsencrypt.yml.tmpl" /opt/infra/platform/traefik/static.letsencrypt.yml.tmpl
cp "$SRC/platform/traefik/static.external.yml.tmpl" /opt/infra/platform/traefik/static.external.yml.tmpl
cp "$SRC/platform/traefik/dynamic/middlewares.yml.tmpl" /opt/infra/platform/traefik/dynamic/middlewares.yml.tmpl
cp "$SRC/platform/console/entrypoint.sh" /opt/infra/platform/console/entrypoint.sh
cp "$SRC/platform/console/console.py"    /opt/infra/platform/console/console.py
cp "$SRC/platform/console/access.py"     /opt/infra/platform/console/access.py
cp "$SRC/platform/console/policy.py"     /opt/infra/platform/console/policy.py
cp "$SRC/platform/console/Dockerfile"   /opt/infra/platform/console/Dockerfile
cp "$SRC/platform/console/index.html"    /opt/infra/platform/console/index.html
mkdir -p /opt/infra/app-kit/.infradeploy
cp "$SRC/scripts/parse-manifest.py"            /opt/infra/scripts/parse-manifest.py
cp "$SRC/app-kit/.infradeploy/infra.yml"       /opt/infra/app-kit/.infradeploy/infra.yml
cp "$SRC"/app-kit/examples/*.infra.yml         /opt/infra/app-kit/examples/
echo "deployment files synced to /opt/infra"
