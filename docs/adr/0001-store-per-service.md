# 0001. Store per service

- **Status:** Accepted, 1 Oct 2026 (D90)

## Context

The product plan adds about a dozen services. The money paths rely on SQL Server behaviour that the shared outbox, saga and wallet code are built on: `UPDLOCK`/`READPAST` claims, `sp_getapplock`, row locks under read committed snapshot. The read models and Steward already use Postgres for full-text search, JSONB and pgvector.

The Azure SQL free offer caps how many databases one subscription gets, and there is no cloud subscription yet, so the number of SQL Server databases is a real constraint whenever the cloud target arrives.

## Decision

- **SQL Server** for services that move money or hold regulated state: placement, wallet, settlement, payout, identity, compliance, payments, casino rounds and transactions.
- **Postgres** for read models and non-money stores: bet history, catalogue (offer and casino), config, reporting warehouse, notifications, Steward, risk journal.
- One database and one least-privilege login per service in both engines, as today.
- Building-blocks gains a Postgres outbox (`FOR UPDATE SKIP LOCKED` claims) so Postgres-backed services publish with the same guarantees.

## Consequences

- Money services keep one proven locking model; reviewers check one set of patterns on every money path.
- Two engines to operate and back up, which we already do.
- If a SQL Server database cap bites, the fallback is schemas in a shared database with separate logins and grants, with no code change.
