#!/usr/bin/env bash
# CI fixture for the restore drill. seed: a balanced ledger; drift: change one balance outside the ledger.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
compose=(docker compose --project-directory "$here/../../compose" -f "$here/../../compose/docker-compose.yml")
# shellcheck disable=SC2016 # expanded by bash inside the container, where the password lives
sqlcmd='/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b'

case "${1:?seed or drift}" in
  seed)
    "${compose[@]}" cp "$here/drill-seed.sql" sqlserver:/tmp/drill-seed.sql
    "${compose[@]}" exec -T sqlserver bash -c "$sqlcmd -i /tmp/drill-seed.sql"
    ;;
  drift)
    "${compose[@]}" exec -T sqlserver bash -c "$sqlcmd -Q 'UPDATE SbWallet.wallet.Accounts SET Available = Available + 5 WHERE AccountId = 1'"
    ;;
  *) echo "seed or drift" >&2; exit 2 ;;
esac
