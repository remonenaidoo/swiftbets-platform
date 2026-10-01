#!/usr/bin/env bash
# Backs up every SwiftBets database of the compose stack (staging) into $BACKUP_DIR/<UTC timestamp>/:
# SQL Server databases as checksummed full backups, Postgres databases as custom-format dumps, Redis as an RDB
# snapshot, each with its row counts at backup time and a sha256 manifest. Keeps the newest $BACKUP_KEEP runs and,
# when $BACKUP_REMOTE is set (an rclone remote), copies the run off the host.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
compose=(docker compose --project-directory "$root/compose" -f "$root/compose/docker-compose.yml")
dest_root="${BACKUP_DIR:-$root/backups}"
keep="${BACKUP_KEEP:-14}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$dest_root/$stamp"
mkdir -p "$dest"

# shellcheck disable=SC2016 # expanded by bash inside the container, where the password lives
sql() { "${compose[@]}" exec -T sqlserver bash -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -h -1 -W -s "	" -Q "SET NOCOUNT ON; $1"' _ "$1"; }
psql_as() { "${compose[@]}" exec -T postgres psql -U postgres -At "$@"; }

mapfile -t sql_dbs < <(sql "SELECT name FROM sys.databases WHERE name LIKE 'Sb%' ORDER BY name" | tr -d '\r')
"${compose[@]}" exec -T sqlserver mkdir -p /var/opt/mssql/backup
for db in "${sql_dbs[@]}"; do
  [[ "$db" =~ ^Sb[A-Za-z]+$ ]] || { echo "unexpected database name $db" >&2; exit 1; }
  sql "SELECT s.name + '.' + t.name, SUM(p.rows) FROM [$db].sys.tables t JOIN [$db].sys.schemas s ON s.schema_id = t.schema_id JOIN [$db].sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1) GROUP BY s.name, t.name ORDER BY 1" | tr -d '\r' > "$dest/$db.counts"
  sql "BACKUP DATABASE [$db] TO DISK = N'/var/opt/mssql/backup/$db.bak' WITH INIT, CHECKSUM, COMPRESSION"
  "${compose[@]}" cp "sqlserver:/var/opt/mssql/backup/$db.bak" "$dest/$db.bak"
  "${compose[@]}" exec -T sqlserver rm -f "/var/opt/mssql/backup/$db.bak"
done

mapfile -t pg_dbs < <(psql_as -c "SELECT datname FROM pg_database WHERE datname LIKE 'sb\_%' ORDER BY 1")
for db in "${pg_dbs[@]}"; do
  [[ "$db" =~ ^sb_[a-z_]+$ ]] || { echo "unexpected database name $db" >&2; exit 1; }
  "${compose[@]}" exec -T postgres pg_dump -U postgres -Fc "$db" > "$dest/$db.dump"
done

if "${compose[@]}" ps --services --status running | grep -qx redis; then
  before="$("${compose[@]}" exec -T redis redis-cli LASTSAVE | tr -d '\r')"
  "${compose[@]}" exec -T redis redis-cli BGSAVE >/dev/null
  for _ in $(seq 1 60); do
    [[ "$("${compose[@]}" exec -T redis redis-cli LASTSAVE | tr -d '\r')" != "$before" ]] && break
    sleep 1
  done
  "${compose[@]}" cp redis:/data/dump.rdb "$dest/redis.rdb"
fi

(cd "$dest" && sha256sum -- * > SHA256SUMS)
echo "backed up ${#sql_dbs[@]} SQL Server and ${#pg_dbs[@]} Postgres databases to $dest"

if [[ -n "${BACKUP_REMOTE:-}" ]]; then
  rclone copy "$dest" "$BACKUP_REMOTE/$stamp"
fi

find "$dest_root" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | sort | head -n -"$keep" | xargs -r rm -rf --
