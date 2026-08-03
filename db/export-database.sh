#!/bin/bash
# Dump (backup) the Postgres database running in the `nimba-postgres` container
# started by infra/docker-compose.yml. Custom pg_dump format so it can be restored
# selectively with pg_restore (see import-database.sh).
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
RETENTION_DAYS="${DB_BACKUP_RETENTION_DAYS:-14}"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DUMP_FILE="$BACKUP_DIR/nimba_dump_${TIMESTAMP}.backup"

echo "$(date '+%F %T') Exporting Postgres DB from container: $CONTAINER"

docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER" \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --format=custom --no-owner --no-privileges \
    -f "/tmp/$(basename "$DUMP_FILE")"

docker cp "$CONTAINER:/tmp/$(basename "$DUMP_FILE")" "$DUMP_FILE"
docker exec "$CONTAINER" rm -f "/tmp/$(basename "$DUMP_FILE")"

echo "$(date '+%F %T') Exported to $DUMP_FILE"

find "$BACKUP_DIR" -type f -name "nimba_dump_*.backup" -mtime "+${RETENTION_DAYS}" -delete
echo "$(date '+%F %T') Pruned backups older than ${RETENTION_DAYS} days"
