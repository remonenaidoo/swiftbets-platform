#!/usr/bin/env bash
# Restores the newest backup run (or the one given) into scratch databases and proves it is usable: checksums match,
# SQL Server restores pass DBCC CHECKDB with the row counts taken at backup time, a restored wallet ledger reconciles,
# and every Postgres dump restores. Prints how long each restore took (the RTO evidence) and drops the scratch copies.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
compose=(docker compose --project-directory "$root/compose" -f "$root/compose/docker-compose.yml")
run="${1:-$(find "${BACKUP_DIR:-$root/backups}" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | sort | tail -n 1)}"
[[ -d "$run" ]] || { echo "no backup run found" >&2; exit 2; }
(cd "$run" && sha256sum --quiet -c SHA256SUMS)

# shellcheck disable=SC2016 # expanded by bash inside the container, where the password lives
sql() { "${compose[@]}" exec -T sqlserver bash -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -h -1 -W -s "	" -Q "SET NOCOUNT ON; $1"' _ "$1"; }
failures=0

for bak in "$run"/*.bak; do
  [[ -e "$bak" ]] || continue
  db="$(basename "$bak" .bak)"
  drill="${db}_drill"
  started=$SECONDS
  "${compose[@]}" exec -T sqlserver mkdir -p /var/opt/mssql/backup
  "${compose[@]}" cp "$bak" "sqlserver:/var/opt/mssql/backup/$db.bak"
  "${compose[@]}" exec -T -u root sqlserver chown mssql "/var/opt/mssql/backup/$db.bak"
  moves="$(sql "RESTORE FILELISTONLY FROM DISK = N'/var/opt/mssql/backup/$db.bak'" | tr -d '\r' | awk -F'\t' -v d="$drill" '{ ext = ($3 == "L") ? "ldf" : "mdf"; printf ", MOVE N'\''%s'\'' TO N'\''/var/opt/mssql/data/%s_%s.%s'\''", $1, d, NR, ext }')"
  sql "RESTORE DATABASE [$drill] FROM DISK = N'/var/opt/mssql/backup/$db.bak' WITH CHECKSUM, REPLACE$moves"
  sql "DBCC CHECKDB ([$drill]) WITH NO_INFOMSGS"
  restored="$(sql "SELECT s.name + '.' + t.name, SUM(p.rows) FROM [$drill].sys.tables t JOIN [$drill].sys.schemas s ON s.schema_id = t.schema_id JOIN [$drill].sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1) GROUP BY s.name, t.name ORDER BY 1" | tr -d '\r')"
  if [[ "$restored" != "$(cat "$run/$db.counts")" ]]; then
    echo "$db: restored row counts differ from the counts at backup time" >&2
    failures=$((failures + 1))
  fi

  if [[ "$(sql "SELECT COUNT(*) FROM [$drill].sys.tables t JOIN [$drill].sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = 'wallet' AND t.name = 'LedgerEntries'" | tr -d '\r')" != "0" ]]; then
    drift="$(sql "SELECT COUNT(*) FROM [$drill].wallet.Accounts a WHERE a.Kind = 1 AND (a.Available <> (SELECT COALESCE(SUM(Amount), 0) FROM [$drill].wallet.LedgerEntries e WHERE e.AccountId = a.AccountId AND e.Bucket = 1) OR a.Reserved <> (SELECT COALESCE(SUM(Amount), 0) FROM [$drill].wallet.LedgerEntries e WHERE e.AccountId = a.AccountId AND e.Bucket = 2))" | tr -d '\r')"
    total="$(sql "SELECT COALESCE(SUM(Amount), 0) FROM [$drill].wallet.LedgerEntries" | tr -d '\r')"
    if [[ "$drift" != "0" || "$total" != "0" ]]; then
      echo "$db: restored ledger does not reconcile ($drift drifted accounts, ledger total $total)" >&2
      failures=$((failures + 1))
    fi
  fi

  sql "DROP DATABASE [$drill]"
  "${compose[@]}" exec -T sqlserver rm -f "/var/opt/mssql/backup/$db.bak"
  echo "$db restored in $((SECONDS - started))s"
done

for dump in "$run"/*.dump; do
  [[ -e "$dump" ]] || continue
  db="$(basename "$dump" .dump)"
  drill="${db}_drill"
  started=$SECONDS
  "${compose[@]}" exec -T postgres dropdb -U postgres --if-exists "$drill"
  "${compose[@]}" exec -T postgres createdb -U postgres "$drill"
  "${compose[@]}" exec -T postgres pg_restore -U postgres --no-owner --exit-on-error -d "$drill" < "$dump"
  "${compose[@]}" exec -T postgres dropdb -U postgres "$drill"
  echo "$db restored and verified in $((SECONDS - started))s"
done

((failures == 0)) || exit 1
echo "restore drill passed for $run"
