# 0003. Customer web rendering

- **Status:** Accepted, 1 Oct 2026 (D94)

## Context

The customer site needs indexable, fast public pages (home, sports, fixture) and highly interactive authenticated ones (betslip, wallet, account). Today the public site is the mobile app's web export, which ships React Native Web and needs `'unsafe-inline'` styles.

## Decision

- `swiftbets-web` uses React Router 7 in framework mode with server rendering on Node, the router the dashboard already uses (D21).
- Loaders call the gateway server-side, forwarding the session cookie. The browser calls the gateway directly only for mutations and live data, through one typed client that handles 401 once (re-resolve the session, retry once, then a typed session-expired state).
- TanStack Query is seeded from loader data, so there is one cache, not two.
- The Node server mints a CSP nonce per request: `script-src 'nonce-…' 'strict-dynamic'`, no inline styles.
- Brands are built separately from `swiftbets-design-tokens` (Tailwind v4 theme plus CSS variables per brand); no runtime theme switching in production.
- Client state (betslip) lives in atom stores, persisted, read through a hydration-safe hook, merged per selection across tabs.
- Modern browsers only; the JS budget and Lighthouse scores are CI gates.

## Consequences

- One more Node process in the stack, behind the gateway like every other origin.
- The mobile web export is retired once the web serves every flow.
