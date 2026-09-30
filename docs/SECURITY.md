# Security

This file describes each service's trust boundary: what it trusts, what it validates, and what an attacker at that boundary can and cannot do. It is kept current as each phase lands. Controls marked *(Phase N)* are designed but not yet implemented.

## Platform-wide controls

- **Identity.**
  - Placement's identity module issues RS256 JWTs. Every other service validates them against the published JWKS, checking issuer, audience, lifetime and the `RS256` algorithm, with 30 s of clock skew.
  - Only identity holds the private key, so a compromised downstream service cannot mint tokens.
- **Authorisation.** Enforced server-side on every mutation through role policies: `Punter`, `Operator`, `Admin`, `Service`. UI checks are presentation only.
- **Input.**
  - FluentValidation runs at every HTTP boundary.
  - Every Kafka consumer validates the envelope type, version and payload before handling. Invalid messages go to the dead-letter queue instead of reaching a handler.
  - All SQL is parameterised Dapper over embedded `.sql` files, with no dynamic SQL. The one identifier that must be dynamic, the app login name in the migrator grant, goes through `QUOTENAME`, and a hostile name is covered by a test.
- **Errors.** One envelope everywhere, carrying a code and a correlation id. Unexpected exceptions return `internal_error` and never include exception text, which a test enforces.
- **Headers.**
  - APIs send `nosniff`, `X-Frame-Options: DENY`, `default-src 'none'; frame-ancestors 'none'`, `no-referrer`, `Cache-Control: no-store` by default, and HSTS outside Development.
  - The dashboard sends a per-request nonce CSP with `strict-dynamic`.
- **Secrets.**
  - Secrets come only from the environment or Kubernetes Secrets; nothing is in code or images, and `.env` is git-ignored.
  - Local compose passwords are development-only placeholders in `.env.example`.
- **Least privilege.**
  - Each SQL Server service has its own login, mapped only into its own database as a member of `swiftbets_app`, which is granted DML on the service's own schemas. It is not `db_owner`, and it cannot open another service's database (verified).
  - Postgres databases are each owned by their own login.
  - Migrators run with elevated rights once, then exit.
- **Containers.**
  - .NET images use the chiseled runtime: non-root, and no shell or package manager.
  - The dashboard runs on unprivileged nginx.
  - Compose runs services with a read-only root filesystem, `no-new-privileges`, and memory and CPU limits.
- **Fault injection.**
  - Off unless configured.
  - A host refuses to start in `Production` if it is enabled.
  - Fault endpoints are for the Operator role only *(Phase 3)*.
- **Supply chain.**
  - CI blocks on known-vulnerable NuGet packages, `npm audit` (high and above), Trivy image findings (critical or high with a fix available), and CodeQL.
  - Images are tagged by commit SHA, never `:latest`.

## Per service

### gateway (public edge)
- **Trusts:** nothing inbound.
- **Validates:** cookie session or bearer token; the CSRF header on cookie-authenticated mutations; per-route rate limits in Redis *(Phase 1)*.
- **Attacker at this boundary can:** send any HTTP. **Cannot:** forge identity headers (inbound `X-User-*` and similar are stripped), read the session cookie from script (httpOnly), ride the cookie cross-site (`SameSite=Strict` plus the required header), or reach a service port directly (only the gateway publishes a port).

### placement
- **Trusts:** tokens signed by its own key; the offer version and price read from Redis at placement time.
- **Validates:**
  - coupon shape and stake limits;
  - the price-change policy against the current offer version;
  - the per-fixture liability cap;
  - a mandatory `Idempotency-Key`.
- **Attacker with a valid Punter token can:** place coupons within their own limits. **Cannot:**
  - place against a suspended market or a stale price;
  - double-spend by replaying a request, because the idempotency key and a unique index turn a replay into the original response *(Phase 1)*.

### wallet (internal, gRPC)
- **Trusts:** `Service`-role tokens from placement and payout; `Operator` for top-up.
- **Validates:**
  - an idempotency key on every mutating RPC, unique-indexed;
  - `Available >= 0` as a database constraint;
  - currency match;
  - blacklist on credits.
- **Attacker with network access but no service token:** rejected. **A compromised caller:** can move money only within its own RPCs, and every posting is double-entry and reconciled *(Phase 1)*.

### settlement
- **Trusts:** results from the offer topic.
- **Validates:** envelope and payload; the result version and priority gate, so a stale or lower-priority result is a no-op.
- **Attacker able to publish a malformed result:** it is dead-lettered and the partition keeps flowing. **A duplicate or out-of-order result:** no effect on the outcome *(Phase 2)*.

### payout
- **Trusts:** `coupon-settled` events.
- **Validates:** the delta against what has already been paid, with a versioned idempotency key.
- **Replaying a settled event:** credits nothing twice. **A blacklisted wallet:** never paid; the payout is parked with a reason *(Phase 2)*.

### steward
- **Trusts:** its own tool results.
- **Validates:**
  - every evidence reference in a model-written report must resolve to a real tool result;
  - remediation runs only after an Operator approves, with the approval id as its idempotency key, and is audited.
- **Prompt injection through event payloads:** can influence the text of a report. **Cannot:** act on its own, because only allow-listed actions exist and each one needs approval *(Phase 3)*.

### realtime
- **Trusts:** Kafka.
- **Validates:** the token on connect; group membership (a punter can join only their own `coupon:{id}` groups) *(Phase 4)*.

### dashboard / mobile
- **Dashboard:** holds no secrets; the session lives in an httpOnly cookie at the gateway.
- **Mobile:** stores tokens only in SecureStore; certificate pinning is planned for the release build *(Phase 6)*.
