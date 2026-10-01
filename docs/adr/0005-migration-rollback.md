# 0005. Migration rollback convention

- **Status:** Accepted, 1 Oct 2026 (D95). Extends D4.

## Context

DbUp is forward-only. The product brief requires a rollback script for every database change, or a stated reason why one is impossible.

## Decision

- Every new `Migrations/NNNN_name.sql` ships with `Rollbacks/NNNN_name.sql` in the same migrator project. Both are embedded; DbUp only selects `Migrations/`.
- A rollback reverses the change and deletes its own journal row, so re-running the migrator reapplies it.
- Every rollback has an up-down-up test against a real database.
- A change that cannot be rolled back (destructive data changes) says so in a header comment, with the reason and the restore path; it ships behind a backup taken by the migration job.
- Building-blocks adds `--to <version>` to run rollbacks in reverse order down to a target.
- Existing `0001`/`0002` initial schemas are declared not rollbackable: their rollback is dropping the database, and no product data exists yet.

## Consequences

- Every schema change costs a second script and a test, which keeps changes small.
- A rollback that loses data is visible in review because it must say so.
