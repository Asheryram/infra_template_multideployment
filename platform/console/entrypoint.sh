#!/bin/sh
# Start as root only long enough to map the host's deploy user uid/gid,
# then drop to that uid so every file the console writes is owned exactly like the CLI's.
# The console no longer needs Docker socket access — it drives Docker exclusively through
# the infra CLI (bin/infra), which runs as the deploy user inside the container.
set -e
: "${RUN_UID:?}" "${RUN_GID:?}" "${DOCKER_SOCKET_GID:?}"

getent group "$RUN_GID" >/dev/null || groupadd -g "$RUN_GID" infra
getent passwd "$RUN_UID" >/dev/null || useradd -u "$RUN_UID" -g "$RUN_GID" -M -d /tmp/console-home -s /bin/bash infra

mkdir -p /tmp/console-home && chown "$RUN_UID:$RUN_GID" /tmp/console-home
export HOME=/tmp/console-home
exec setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --groups="$DOCKER_SOCKET_GID" python3 /app/console.py
