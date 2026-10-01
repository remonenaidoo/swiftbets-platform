# swiftbets-platform

[![ci](https://github.com/remonenaidoo/swiftbets-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/remonenaidoo/swiftbets-platform/actions/workflows/ci.yml)

SwiftBets is a soccer-first sports betting platform built as a production-grade vertical slice, with an operations copilot, Steward, that diagnoses incidents from the platform's own evidence and proposes remediations a human approves. This repository holds everything that is not a service: the local stack, the shared CI workflows, deployment (Kubernetes and Terraform, from Phase 5), dashboards and the design record.

## Repositories

| Repository | Role |
|---|---|
| [swiftbets-contracts](https://github.com/remonenaidoo/swiftbets-contracts) | Versioned event records, error envelope, wallet gRPC proto, generated TS types |
| [swiftbets-building-blocks](https://github.com/remonenaidoo/swiftbets-building-blocks) | Resilience, Kafka consumer host, outbox, persistence, observability, web |
| [swiftbets-offer](https://github.com/remonenaidoo/swiftbets-offer) | Historical fixture replay, offer store, read API |
| [swiftbets-placement](https://github.com/remonenaidoo/swiftbets-placement) | Placement saga, risk limits and bet history |
| [swiftbets-wallet](https://github.com/remonenaidoo/swiftbets-wallet) | Double-entry ledger (gRPC), balances, daily reconciliation |
| [swiftbets-identity](https://github.com/remonenaidoo/swiftbets-identity) | Accounts, registration, verification, reset, account status, RS256 tokens and JWKS |
| [swiftbets-settlement](https://github.com/remonenaidoo/swiftbets-settlement) | Evaluate → settle, Lua counters, reconciler, inbound DLQ |
| [swiftbets-payout](https://github.com/remonenaidoo/swiftbets-payout) | Delta payouts, named-step retry ladder, dead-letter |
| [swiftbets-steward](https://github.com/remonenaidoo/swiftbets-steward) | Detectors, tool-calling agent, runbook RAG, approvals |
| [swiftbets-gateway](https://github.com/remonenaidoo/swiftbets-gateway) | YARP BFF, cookie-to-bearer, rate limits |
| [swiftbets-realtime](https://github.com/remonenaidoo/swiftbets-realtime) | Kafka → SignalR, sequence-numbered deltas |
| [swiftbets-notifications](https://github.com/remonenaidoo/swiftbets-notifications) | Customer email from `NotificationRequestedV1`, marketing suppression |
| [swiftbets-web](https://github.com/remonenaidoo/swiftbets-web) | Server-rendered customer site (React Router 7, nonce CSP); account pages today |
| [swiftbets-design-tokens](https://github.com/remonenaidoo/swiftbets-design-tokens) | SwiftBets and SwiftPlay brand tokens for every front end |
| [swiftbets-dashboard](https://github.com/remonenaidoo/swiftbets-dashboard) | React ops UI |
| [swiftbets-mobile](https://github.com/remonenaidoo/swiftbets-mobile) | Expo customer app (APK) |
| [swiftbets-risk](https://github.com/remonenaidoo/swiftbets-risk) | Akka.NET liability actors (Phase 8) |

## Run it locally

Requirements: Docker with Compose v2 and about 8 GB free memory. Clone the repositories side by side, then:

```bash
cd swiftbets-platform
make packages   # fetch the pinned shared NuGet packages into each repo
make up         # builds every image, provisions topics and databases, waits until all health checks pass
```

| URL | What |
|---|---|
| http://127.0.0.1:7100 | Gateway (the only public API origin) |
| http://127.0.0.1:7110 | Dashboard |
| http://127.0.0.1:7180 | Redpanda Console |
| http://127.0.0.1:7130 | Grafana (admin / `GRAFANA_ADMIN_PASSWORD` from `compose/.env`) |
| http://127.0.0.1:7190 | Prometheus |
| http://127.0.0.1:7125 | Mailpit: every account email (verification, password reset) lands here |

`make reset` recreates every volume from scratch. `compose/.env` is generated from `.env.example` and never committed.

## What the stack does at start

1. Redpanda starts; the `topics` job turns off auto-creation and provisions every topic in [`compose/redpanda/topics.yaml`](compose/redpanda/topics.yaml) with the environment suffix.
2. SQL Server starts; `sqlserver-init` creates one login per service. Each service's migrator creates its database, runs its DbUp scripts and maps only its own login into the least-privilege `swiftbets_app` role.
3. Postgres creates `sb_steward` (with pgvector) and `sb_history`, each owned by its own login.
4. Services start only after their migrator has completed, and report ready only when their real dependencies answer.

## Shared CI

Every repository calls the reusable workflows in [`.github/workflows`](.github/workflows):

- `dotnet.yml`: restore, build, test (Testcontainers), vulnerable-package gate, CodeQL, pack and release, then multi-arch images scanned by Trivy and pushed to GHCR tagged by commit SHA and semver.
- `node.yml`: lint, typecheck, test, build, `npm audit`, CodeQL, and an optional image.

## Documents

- [docs/PLAN.md](docs/PLAN.md): the approved plan and phase gates
- [docs/DECISIONS.md](docs/DECISIONS.md): every decision and why
- [docs/SECURITY.md](docs/SECURITY.md): trust boundaries per service

## License

MIT
