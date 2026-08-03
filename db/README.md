# Database backup & restore

Backup/restore scripts for the `postgres` service started by
[`infra/docker-compose.yml`](../docker-compose.yml) (container name
`nimba-postgres`). Dumps use `pg_dump`'s custom format so they can be restored
selectively with `pg_restore`.

## Usage

From this directory (needs `infra/.env` — see [`../.env.example`](../.env.example)):

```bash
# Backup the running database into ./backups/nimba_dump_<timestamp>.backup
./export-database.sh

# Restore the most recent backup
./import-database.sh

# Restore a specific backup
./import-database.sh backups/nimba_dump_20260101_020000.backup
```

`export-database.sh` prunes backups older than `DB_BACKUP_RETENTION_DAYS` (default
14 days). Override it in `infra/.env` if you need a longer retention window.

## Managed Postgres instead of the local container

If `DATABASE_URL` in `infra/.env` points at a managed Postgres instance (Neon, RDS,
the bank's on-prem server, etc.) rather than the local `postgres` container, use
`pg_dump`/`pg_restore` directly against that connection string instead of these
scripts, which specifically target the `nimba-postgres` container by name:

```bash
pg_dump "$DATABASE_URL" --format=custom --no-owner --no-privileges -f backup.backup
pg_restore "$DATABASE_URL" --clean --if-exists --no-owner --no-privileges backup.backup
```

## Scheduling regular backups

Run `export-database.sh` on a schedule (cron, a systemd timer, or the platform's
scheduled-job feature). Example: every day at 2:00 AM —

```
0 2 * * * cd /path/to/nimba/infra/db && ./export-database.sh >> ./cron.log 2>&1
```
