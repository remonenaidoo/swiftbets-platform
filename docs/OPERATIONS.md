# Operations

How SwiftBets is backed up, restored and watched. Measured numbers are updated by the E10 restore drills.

## Backups

| Environment | What | How | Schedule | Kept |
|---|---|---|---|---|
| staging (compose preview) | Every SQL Server `Sb*` database, every Postgres `sb_*` database, Redis | `scripts/backup.sh`: checksummed full backups, custom-format dumps, an RDB snapshot, row counts and a SHA-256 manifest | Nightly from the host's crontab (below) | 14 runs on the host; copied off the host when `BACKUP_REMOTE` (an rclone remote) is set |
| prod (defined, not running) | SQL Server databases on Azure SQL | The platform's automated backups with point-in-time restore | Continuous | 7 days (free offer); longer retention needs a paid tier |
| prod | In-cluster Postgres and Redis | `scripts/backup.sh` equivalent as Kubernetes CronJobs | Nightly | Added with the first prod cluster |

Staging crontab entry on the preview host:

```cron
17 2 * * * cd /srv/swiftbets/swiftbets-platform && BACKUP_REMOTE=offsite:swiftbets-backups scripts/backup.sh >> /var/log/swiftbets-backup.log 2>&1
```

Backups hold customer and money data: the off-host remote must be encrypted (an rclone `crypt` remote) and readable
only by the operator.

## Restore drill

`scripts/restore-drill.sh [run-dir]` restores the newest run (or the given one) into scratch `*_drill` databases. It fails unless:
- the manifest checksums match;
- every SQL Server restore passes `DBCC CHECKDB` and has the row counts recorded at backup time;
- a restored wallet ledger reconciles: every punter balance equals its entries, and the ledger sums to zero;
- every Postgres dump restores.

It then drops the scratch copies and prints how long each restore took.

CI runs the drill on every platform PR (`restore-drill` job): it seeds a balanced ledger, backs up, restores, and then
proves that a backup with a drifted balance fails the drill.

## Objectives

| | Staging | Prod (target) |
|---|---|---|
| RPO (data that may be lost) | 24 hours: nightly backups | 10 minutes for money databases: point-in-time restore |
| RTO (time to restore service) | 1 hour: the drill restores a database in seconds at current size; most of the hour is re-provisioning the host | 1 hour |

The prod figures are targets until a prod cluster exists and the E10 drill measures them.

## Restoring for real

1. Stop writers: scale the owning service to zero (or `docker compose stop <service>`), so nothing writes during the restore.
2. Restore the chosen run over the live database with the same commands the drill uses, minus the `_drill` suffix.
3. Run the service's migrator, so any migration newer than the backup is applied.
4. For the wallet, run `POST /reconciliation/runs` and confirm `isClean: true` before starting writers again.
5. Replay Kafka consumers from the backup time if events after it must be re-projected (bet history, Steward).
