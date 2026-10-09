#!/bin/bash
SRC="/mnt/c/Users/YramAsherTetteh-Abot/OneDrive - AmaliTech gGmbH/Desktop/infra_template_multideployment"
cp "$SRC/scripts/lib/db.sh"              /opt/infra/scripts/lib/db.sh
cp "$SRC/scripts/lib/common.sh"          /opt/infra/scripts/lib/common.sh
cp "$SRC/scripts/deploy.sh"              /opt/infra/scripts/deploy.sh
cp "$SRC/scripts/cleanup.sh"             /opt/infra/scripts/cleanup.sh
cp "$SRC/platform/docker-compose.yml"    /opt/infra/platform/docker-compose.yml
cp "$SRC/platform/console/entrypoint.sh" /opt/infra/platform/console/entrypoint.sh
cp "$SRC/platform/console/console.py"    /opt/infra/platform/console/console.py
cp "$SRC/app-kit/.deploy/manifest.env"   /opt/infra/app-kit/.deploy/manifest.env
cp "$SRC/app-kit/examples/backend.manifest.env" /opt/infra/app-kit/examples/backend.manifest.env
cp "$SRC/app-kit/examples/split.manifest.env"   /opt/infra/app-kit/examples/split.manifest.env
echo "all copied"
