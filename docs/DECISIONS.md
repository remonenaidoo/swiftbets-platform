# Decisions

Each entry: the decision, the reason, and what it rules out. New decisions are appended; superseded ones are marked, never deleted.

## Design authority

**D30. The brief's betting-domain patterns are the design authority for placement, settlement and payout.** These are:
- transactional outbox with a claiming relay;
- durable saga intents with an orphan sweeper;
- token-guarded atomic Lua progress counters;
- two-stage evaluate → Kafka → settle;
- delta-based payouts with a named-step retry ladder;
- the reconciler.

The PaymentApi / MarketApp money patterns govern the wallet and ledger layer:
- locked row reads with an idempotency key checked under the lock;
- a `WasApplied` result so compensation reverses only real debits;
- atomic claims by conditional `UPDATE` plus a row-count check;
- non-cancellable money writes.

Where the two disagree, the brief wins and the disagreement is recorded under "Conflicts" below.

## Conflicts

| Date | Area | Brief says | Reference pattern says | Resolution |
|---|---|---|---|---|
| - | - | none recorded yet | - | - |

## Platform

**D1. .NET 10 LTS, C# latest, nullable enabled, warnings as errors.** .NET 8 leaves support on 10 Nov 2026, and .NET 10 is supported to Nov 2028. Every dependency used here targets `net10.0`.

**D2. Use cases are plain handler interfaces (`I<Verb><Noun>Handler`), with no MediatR.** MediatR is commercially licensed from v13, and direct calls keep the call graph navigable.

**D3. Data access is Dapper. There is one embedded `.sql` resource per query, and no stored procedures.** Logic stays in tested C#. The SQL stays reviewable text and is loaded by resource name through `ISqlResources`. Every statement is parameterised. This rules out the procedure drift seen in the reference systems: `CREATE OR ALTER` copies, filename-prefix ordering, and committed SQL that did not match live.

**D4. Migrations run in DbUp, one migrator per service.**
- Scripts are named `NNNN_description.sql` and tracked in a journal table (`dbo.SchemaVersions`, or `public.schemaversions` on Postgres).
- The migrator runs as a one-shot container in compose and as a Helm `pre-install,pre-upgrade` Job.
- Services never migrate on startup, because two replicas would race.

**D5. Stores.**
- **SQL Server** holds the transactional bet store. It gives row locks with `UPDLOCK`/`READPAST` queue semantics for the outbox and saga claims, and `sp_getapplock` for per-wallet serialisation. There are separate databases (`SbPlacement`, `SbWallet`, `SbSettlement`, `SbPayout`), each with its own login.
- **PostgreSQL** holds the bet-history read model and Steward. It has pgvector, `tsvector` full-text search, and JSONB for reports.
- **Redis** holds the offer store, settlement counters, rate limits and the SignalR backplane. It runs with `maxmemory-policy noeviction`, because an evicted counter is a correctness bug, not a cache miss.

**D6. Money and odds.**
- Amounts are `long` minor units in one currency per deployment (ZAR by default).
- Odds are `decimal(10,3)`.
- One rounding function (round down to the minor unit) is used everywhere a payout is computed.

**D7. Ledger.** The ledger is double-entry and append-only; every movement posts two entries that sum to zero. The account balance is a projection updated in the same transaction and guarded by `CHECK (Available >= 0)`. A reconciler asserts that sum(entries) = balance.

**D8. Events.**
- **Envelope:** JSON with `id`, `type`, `version`, `occurredAt`, `correlationId`, `causationId` and `payload`.
- **Versioning:** the major version is in both the type name and the topic (`.v1`).
- **Schemas:** JSON Schemas are generated from the records, checked in, and snapshot-tested, so a breaking diff fails CI.

**D9. Kafka.**
- Confluent.Kafka 2.15 against Redpanda v26.1.
- Producers use `acks=all` and are idempotent.
- Consumers commit manually, only after success.
- Topics are provisioned from `compose/redpanda/topics.yaml`, and auto-creation is disabled.
- Topic names are `swiftbets.<domain>.<event>.v<N>.<env>`.

**D10. Consumer failure policy.**
- **Poison messages** (validation or deserialisation failure) go to `<topic>.dlq` with the original topic, partition, offset and error headers. The offset is then committed so the partition keeps flowing.
- **Transient failures** pause the partition and retry with backoff, without committing.
- The inbox insert (`consumer`, `eventId`, unique) shares the transaction with the state change.

**D11. Resilience.** Polly v8 through `Microsoft.Extensions.Resilience`, with named pipelines:
- `idempotent-http`
- `keyed-http`
- `keyed-grpc`
- `sql-transient` (1205 and connection errors, plus the Azure SQL transients 40613, 40197, 40501, 49918-49920)
- `kafka-produce`

A non-idempotent call is retried only when it carries an idempotency key.

**D12. Auth.**
- RS256 JWTs are issued by placement's identity module.
- Every other service validates them against `/.well-known/jwks.json`.
- Access tokens last 10 minutes. Refresh tokens last 7 days and are rotated single-use.
- Roles are `Punter`, `Operator` and `Admin`.

**D13. Browser sessions go through the gateway BFF.**
- The session cookie is httpOnly, Secure and `SameSite=Strict`.
- Every mutation must also carry the `X-SwiftBets-Csrf: 1` header.
- The gateway converts the cookie to a bearer token for downstream services and strips inbound identity headers.

**D14. Validation.** FluentValidation runs at the API boundary. Domain invariants are enforced in constructors and factory methods, which return `Result`.

**D15. Observability.**
- **Logs:** Serilog, compact JSON to stdout.
- **Traces:** OpenTelemetry over OTLP to Tempo.
- **Metrics:** prometheus-net `/metrics`, because the OTel Prometheus exporter is still prerelease.
- **Correlation:** a correlation id is carried in `X-Correlation-Id` and in the Kafka `correlation-id` header.
- **Health:** `/health/live` (process) and `/health/ready` (dependencies).

**D16. Tests.**
- **.NET:** xUnit v3, Shouldly (FluentAssertions 8 is commercially licensed), NSubstitute, Testcontainers, Respawn, and NetArchTest for layer rules.
- **Load:** k6.
- **Frontend:** Vitest with Testing Library, and Playwright.
- **Policy:** one positive and one negative test per behaviour. The money paths additionally carry the four named failure scenarios: duplicate message, out-of-order result, reprocessing after crash, and wallet outage.

**D17. Dataset.** A curated historical EPL season: fixtures, opening and closing odds, and results, normalised to JSON inside the offer repo.

**D18. Time.** `TimeProvider` is injected everywhere. The replay feed runs on a compressed clock and loops seasons with id offsets.

**D19. Steward model.**
- It uses the native tool-use Messages API: Sonnet 5.5 for diagnosis and Haiku 4.5 for triage.
- The system prompt and tool definitions are prompt-cached and byte-stable.
- Spend has a hard cap of USD 10 a month.
- CI runs in replay mode only.

**D20. Embeddings.** Ollama `nomic-embed-text` in compose. CI uses a deterministic hashing embedder behind the same `IEmbeddingGenerator` port.

**D21. Frontend.** React 19, Vite, React Router 7, TanStack Query 5, Jotai, Tailwind v4 and clsx.

**D22. Mobile.** Expo (current SDK) with expo-router. The APK is a Gradle release build in Actions, published as a GitHub Release asset.

**D23. Kubernetes.**
- Charts are portable Helm: a library chart, one chart per service, an infra chart and an umbrella chart.
- Ingress is standard `networking.k8s.io/v1`. There are no distribution-specific CRDs.
- Every install is verified on kind in CI and on k3s.

**D24. Infrastructure as code.**
- Terraform with the OCI, `azurerm`, Kubernetes and Helm providers.
- Remote state lives in an OCI Object Storage S3-compatible backend.
- Apply is a manual workflow.

**D25. CI.**
- Every repo calls the reusable workflows in `swiftbets-platform`.
- Gates: Trivy on images, `dotnet list package --vulnerable`, `npm audit`, and CodeQL.
- Images are multi-arch (amd64 + arm64), pushed to GHCR, and tagged by commit SHA and semver. Never `:latest`.

**D26. Landing page.** An Astro static site with no secrets.

**D27. Risk.** Akka.NET 1.5 with one liability actor per fixture and a sharding-ready message extractor. It is advisory only; placement's risk module remains the hard gate.

## Approved changes (30 Sep 2026)

**D28. Bet scope (change 1).**
- In: singles and accumulators, void legs counted at odds 1.00, the price-change policy (accept equal or better, reject worse with the current price in the error), offer version checks, and result versions with priority and resettlement.
- Backlog: system bets (k-from-n) and bankers.
- The domain keeps a `BetType` discriminator and a leg list, so system bets can be added without breaking the contract.

**D29. Wallet transport (change 2).**
- `Wallet.Api` exposes gRPC `swiftbets.wallet.v1.Wallet` (proto in `swiftbets-contracts`), consumed by placement and payout. Every mutating RPC takes an idempotency key.
- The only HTTP surface is the operator top-up, plus health and metrics.
- Everything else in the platform is HTTP plus Kafka.

**D31. Cloud betstore (change 4).**
- The cloud cluster is the Oracle Always Free ARM (Ampere A1) VM running k3s. SQL Server has no arm64 image.
- In the cloud, the betstore is Azure SQL Database (free tier), reached over TLS (`Encrypt=True`) from the OCI cluster and provisioned by the `azurerm` Terraform module.
- Locally, in compose and in CI, the SQL Server container (amd64) is used.
- Connection strings are plain configuration, so environments differ only by env vars and secrets, never by code.
- All SwiftBets images are multi-arch. Postgres, Redis, Redpanda, Tempo, Prometheus, Grafana and every service run on the ARM node.
- The umbrella chart's `values-cloud.yaml` has no SQL Server StatefulSet; `values-local.yaml` keeps it.

**D32. Repositories.** There are 13, each independently buildable, all under `github.com/remonenaidoo`:
- `swiftbets-platform`, `swiftbets-contracts`, `swiftbets-building-blocks`
- `swiftbets-offer`, `swiftbets-placement`, `swiftbets-settlement`, `swiftbets-payout`
- `swiftbets-steward`
- `swiftbets-gateway`, `swiftbets-realtime`
- `swiftbets-dashboard`, `swiftbets-mobile`
- `swiftbets-risk`

**D33. Authorship.** Everything is authored as Remone Naidoo <naidoo.remone@gmail.com>. There is no tool or AI attribution in commits, headers, metadata or docs. Commits follow Conventional Commits.

## Phase 0

**D34. Shared packages are distributed as GitHub Release assets, not through a package registry.**
- `swiftbets-contracts` and `swiftbets-building-blocks` publish `.nupkg` files, and the contracts npm tarball, as assets on a semver-tagged GitHub Release.
- Consumers pin an exact version. CI downloads the pinned assets into a local folder feed (`.packages/`) before restore. Locally, `scripts/pack-local.sh` fills the same folder.
- Reason: GitHub Packages NuGet requires an authenticated token even for public packages, and cross-repo read access for user-owned packages can only be granted in the web UI. Release assets on public repos need no credentials, are immutable per tag, and keep every repo buildable on its own.

**D35. Central package management.** Each repo pins its versions in `Directory.Packages.props`. `Directory.Build.props` sets the target framework, nullable, analyzers, warnings as errors, deterministic builds and SourceLink.

**D36. Container images.**
- Multi-stage builds: the SDK image builds, and the runtime is `mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra`, which is non-root and has no shell.
- Health checks run over HTTP from compose, not from inside the image.
- Every image carries OCI labels, including `org.opencontainers.image.source`.

**D37. Infrastructure image versions.**

| Component | Image |
|---|---|
| Redpanda | v26.1.18 |
| Redpanda Console | v3.12.0 |
| SQL Server | 2025-CU9-ubuntu-24.04 |
| Postgres + pgvector | pgvector 0.8.6, pg17 |
| Redis | 8.6-alpine |
| Prometheus | v3.15.0 |
| Grafana | 13.0.10 |
| Tempo | 3.1.0 |

**D38. Runtime image flavour.** Services use `aspnet`/`runtime:10.0-noble-chiseled-extra`, not plain chiseled. Microsoft.Data.SqlClient refuses to run in invariant-globalization mode, and plain chiseled images have no ICU; `-extra` adds ICU and tzdata and is still non-root and shell-free. The failure only shows inside the container, never under `dotnet test`, so compose is part of the Phase 0 gate.

**D39. Hosts are web hosts.** Workers (settlement, payout, risk) are `WebApplication` hosts too, so every process has the same `/health/*` and `/metrics` surface and the same `--healthcheck` probe.

**D40. Local ports.** SwiftBets binds only to 127.0.0.1, in the 7100-7199 range: gateway 7100, dashboard 7110, Grafana 7130, SQL Server 7133, Postgres 7134, Redis 7135, Redpanda Console 7180, Prometheus 7190, Kafka 7192. Services have no published ports; the gateway is the only API origin.

**D41. Messaging and outbox packages depend on hosting abstractions only.** An earlier draft took a framework reference on ASP.NET Core, which forced the non-web migrators onto the ASP.NET runtime. Only the Observability and Web packages reference ASP.NET Core.

**D42. CI token scopes.** `dotnet.yml` (build, test, scan, images) needs at most `packages: write` and `security-events: write`. Releasing lives in a separate `dotnet-release.yml` whose one job holds `contents: write`, and only the two package repos call it, on `v*` tags. Reusable workflows are referenced `@main` because they live in the same owner's repository and change together with the platform. Pinning them to a commit SHA is the hardening step once the workflows stabilise (Phase 5).

**D43. Image vulnerability exceptions.** Trivy blocks CRITICAL/HIGH findings that have a fix. When the fix exists upstream but the vendor base image has not been rebuilt yet (chiseled images cannot be patched with apt), the finding goes into `security/.trivyignore` with a written reason why it does not apply and an `exp:` date. When the date passes, the gate fails again. First entry: CVE-2026-84782 (openssl DTLS; SwiftBets uses no DTLS), expiring 2026-10-31.
