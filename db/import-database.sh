#!/bin/bash
# Restore the most recent backup produced by export-database.sh into the
# `nimba-postgres` container. Pass a specific file as $1 to restore that one
# instead of the latest, e.g. ./import-database.sh backups/nimba_dump_20260101_020000.backup
set -euo pipefail
cd "$(dirname "$0")"

# Load environment variables from infra/.env
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | grep -v '^$' | xargs)
fi

: "${POSTGRES_DB:?POSTGRES_DB not set (copy infra/.env.example to infra/.env)}"
: "${POSTGRES_USER:?POSTGRES_USER not set}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set}"

CONTAINER="nimba-postgres"
BACKUP_DIR="./backups"

DUMP_FILE="${1:-$(ls -t "$BACKUP_DIR"/nimba_dump_*.backup 2>/dev/null | head -n 1)}"

if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
  echo "No backup file found (looked in $BACKUP_DIR). Pass a path explicitly or run export-database.sh first." >&2
  exit 1
fi

echo "$(date '+%F %T') Restoring $DUMP_FILE into container: $CONTAINER (database: $POSTGRES_DB)"

docker cp "$DUMP_FILE" "$CONTAINER:/tmp/restore.backup"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER" \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --clean --if-exists --no-owner --no-privileges \
    "/tmp/restore.backup"
docker exec "$CONTAINER" rm -f "/tmp/restore.backup"

echo "$(date '+%F %T') Restore complete"
