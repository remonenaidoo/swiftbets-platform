# 0002. Opaque browser sessions at the gateway

- **Status:** Accepted, 1 Oct 2026 (D93). Refines D13.

## Context

Today the gateway writes the access and refresh JWTs themselves into httpOnly cookies. JavaScript cannot read them, but the server cannot list a customer's devices or end one session before its tokens expire. Responsible gambling needs exactly that: self-exclusion and suspension must end every session at once, and customers must be able to see and revoke devices.

A common failure in this design space is handing the browser a bearer token anyway so a WebSocket can authenticate, which hands any XSS a usable credential.

## Decision

- The cookie (`HttpOnly`, `Secure`, `SameSite=Strict`, path `/api`) carries a random 256-bit session id and nothing else.
- The session record lives in Redis: user, device label, created and last-seen times, the current access and refresh tokens. The id rotates on every refresh.
- The gateway attaches the access token downstream as a bearer header, refreshing server-side when it is near expiry.
- `GET /api/session/devices` lists sessions; `DELETE /api/session/devices/{id}` revokes one. Identity publishes `SessionRevokedV1` on suspension, closure or self-exclusion; the gateway deletes every session for that user.
- The realtime hub keeps cookie authentication through the gateway. No route ever returns a token to JavaScript.
- Mobile keeps bearer tokens in secure storage, with refresh rotation and server-side revocation through identity.

## Consequences

- Revocation is immediate for browsers and at most one access-token lifetime (10 minutes) for mobile.
- Redis holds session state, so it needs persistence (AOF) and backup like the other stateful stores.
- Every request costs one Redis read at the gateway, well inside the latency budget.
