#!/bin/sh
# Start as root only long enough to map the host's deploy user and the Docker socket's group,
# then drop to that uid so every file the console writes is owned exactly like the CLI's.
set -e
: "${RUN_UID:?}" "${RUN_GID:?}"

getent group "$RUN_GID" >/dev/null || groupadd -g "$RUN_GID" infra
getent passwd "$RUN_UID" >/dev/null || useradd -u "$RUN_UID" -g "$RUN_GID" -M -d /tmp/console-home -s /bin/bash infra
user=$(getent passwd "$RUN_UID" | cut -d: -f1)

sock_gid=$(stat -c %g /var/run/docker.sock)
getent group "$sock_gid" >/dev/null || groupadd -g "$sock_gid" dockersock
usermod -aG "$(getent group "$sock_gid" | cut -d: -f1)" "$user"

mkdir -p /tmp/console-home && chown "$RUN_UID:$RUN_GID" /tmp/console-home
export HOME=/tmp/console-home
exec setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --init-groups python3 /app/console.py
