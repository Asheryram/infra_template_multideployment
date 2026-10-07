#!/usr/bin/env bash
# Nightly backup (cron). Dumps every non-preview database plus /etc/infra,
# prunes old local copies, and pushes off-server with restic if configured.
#
#   infra backup              BACKUP_PREVIEWS=true to include pr-* databases
#
# Off-server copies: set RESTIC_REPOSITORY + RESTIC_PASSWORD (and e.g.
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY) in /etc/infra/platform.secrets.env.
# A backup that only lives on the same disk is not a backup.
SCRIPT_NAME=backup
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/db.sh
source "$INFRA_ROOT/scripts/lib/db.sh"

if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; fi
load_infra_env
enable_file_log
trap 'alert "backup FAILED (line $LINENO)"' ERR

pg_wait
day="$BACKUP_DIR/$(date +%F)"
mkdir -p "$day"
chmod 700 "$BACKUP_DIR" "$day"

log "dumping roles"
docker exec "$PG_CONTAINER" pg_dumpall -U postgres --globals-only > "$day/globals.sql"

count=0
while IFS= read -r db; do
  [[ -n $db ]] || continue
  if [[ $db == *_pr_* && ${BACKUP_PREVIEWS:-false} != true ]]; then continue; fi
  log "dumping $db"
  docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc "$db" > "$day/$db.dump.tmp"
  if [[ ! -s $day/$db.dump.tmp ]]; then alert "backup FAILED: empty dump for $db"; die "empty dump for $db"; fi
  mv "$day/$db.dump.tmp" "$day/$db.dump"
  count=$((count + 1))
done < <(sql_scalar "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY 1")

log "archiving /etc/infra (contains secrets — backup dir is 0700)"
tar -czf "$day/etc-infra.tgz" -C /etc infra 2>/dev/null || warn "could not read all of /etc/infra"

log "pruning local backups older than $BACKUP_RETENTION_DAYS days"
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -rf {} +

if [[ -n ${RESTIC_REPOSITORY:-} ]]; then
  export RESTIC_REPOSITORY RESTIC_PASSWORD
  if ! restic cat config >/dev/null 2>&1; then log "initialising restic repository"; restic init; fi
  restic backup --quiet --tag "$SERVER_NAME" "$day"
  restic forget --quiet --tag "$SERVER_NAME" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  log "pushed to $RESTIC_REPOSITORY"
else
  warn "RESTIC_REPOSITORY not set — backups exist only on this server"
fi

log "OK  $count database(s) backed up to $day ($(du -sh "$day" | cut -f1))"
