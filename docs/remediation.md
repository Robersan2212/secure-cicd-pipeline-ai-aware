# Remediations applied

Code changes made on branch `remediate/selected-triage-findings` for the three findings documented in [findings.md](findings.md).

---

## 1. Directory listing disabled (Semgrep)

**Finding:** `express-check-directory-listing` on `app/server.ts`  
**Status:** Applied

### Changes

- Removed all `serveIndex` / `serveIndexMiddleware` mounts for `/ftp`, `/.well-known`, `/encryptionkeys`, and `/support/logs`.
- Kept explicit per-file download routes (`servePublicFiles`, `serveQuarantineFiles`, `serveKeyFiles`, `serveLogFiles`).
- Hardened `/.well-known` with `express.static(..., { index: false, dotfiles: 'deny' })`.
- Removed the unused `serve-index` import from `app/server.ts`.

### Files

- `app/server.ts`

### Tests

- `app/test/api/ftp-folder.test.ts` — `GET /ftp` must **not** return a directory listing HTML title.
- `app/test/api/file-serving.test.ts` — `GET /encryptionkeys` and `GET /.well-known` must **not** return directory listings; known files under those trees still succeed.

---

## 2. Patched `jsonwebtoken` / JWT verify allowlist (Trivy CVE-2015-9235)

**Finding:** `CVE-2015-9235` (critical) via outdated `jsonwebtoken` / nested `express-jwt`  
**Status:** Applied

### Changes

- Bumped `jsonwebtoken` to `^9.0.2` and `express-jwt` to `^8.5.1` in `app/package.json`.
- Added npm `overrides` so nested copies resolve to `jsonwebtoken` `^9.0.2`.
- Updated auth middleware to the express-jwt v8 API with `algorithms: ['RS256']`.
- Added `{ algorithms: ['RS256'] }` to `jwt.verify` in `app/lib/insecurity.ts` and `app/routes/verify.ts`.
- Set `allowInsecureKeySizes: true` on sign/verify so Juice Shop’s existing demo RSA key (under 2048 bits) still works with `jsonwebtoken` v9.
- Replaced `jws.verify` in `security.verify()` with `jwt.verify(..., { algorithms: ['RS256'] })` so cookie/session checks match the same allowlist.
- Removed `@types/express-jwt` (types ship with express-jwt v8); bumped `@types/jsonwebtoken` to `^9.0.7`.

### Files

- `app/package.json`
- `app/lib/insecurity.ts`
- `app/routes/verify.ts`

### Tests

- `app/test/server/insecurity.unit.test.ts` — `jwt.verify(..., { algorithms: ['RS256'] })` **rejects** `alg: none` tokens and still **accepts** RS256-signed tokens from `authorize()`.
- `app/test/api/basket.test.ts` — `GET /rest/basket/1` with a forged `alg: none` Bearer token is **rejected** (401/403), replacing the old “accept forged JWTs” challenge expectation.
- `app/test/server/verify.unit.test.ts` — Juice Shop JWT CTF challenge cases now expect forged `alg: none` / HMAC-with-PEM tokens are **not** accepted (`solved: false`), which matches `jsonwebtoken` v9 behavior.
- `app/test/server/currentUser.unit.test.ts` — builds the cookie with `authorize()` instead of a hardcoded JWT literal.

### Follow-up

Run `npm install` under `app/` (and rebuild the container image) so `node_modules` and Trivy pick up the patched tree before validating the CVE is cleared.

---

## 3. Hardcoded JWT removed from unit test (Gitleaks)

**Finding:** `jwt` rule on `app/frontend/src/app/app.guard.spec.ts`  
**Status:** Applied for the documented location

### Changes

- Added a local `fakeJwt()` helper that builds a JWT-shaped string from claims at test runtime (no compact JWT literal in source).
- Updated the “valid JWT” test to use `fakeJwt(claims)` instead of the committed jwt.io demo token.

### Files

- `app/frontend/src/app/app.guard.spec.ts`

### Tests

- `app/frontend/src/app/app.guard.spec.ts` — “returns payload from decoding a valid JWT” now proves decode still works with a runtime-built token (and keeps a compact JWT out of the file for Gitleaks).

### Follow-up

Other Gitleaks `jwt` hits under `app/` (additional specs / Cypress) were called out in findings.md but are outside this three-item remediation set. Address them in a later pass if the secrets job should be fully clean of the `jwt` rule.

---

## Summary

| # | Scanner finding | Remediation | Proof tests |
|---|-----------------|-------------|-------------|
| 1 | Directory listing (Semgrep) | Removed `serveIndex`; hardened static mount | `ftp-folder.test.ts`, `file-serving.test.ts` |
| 2 | CVE-2015-9235 (Trivy) | Dependency bumps + overrides + `algorithms` on verify | `insecurity.unit.test.ts`, `basket.test.ts` |
| 3 | Hardcoded JWT (Gitleaks) | Runtime `fakeJwt()` in `app.guard.spec.ts` | `app.guard.spec.ts` (updated case) |

---

## How to run the proof tests

All commands below are run from the `app/` directory after dependencies are installed.

```bash
cd app
npm install
```

### Remediation 1 — directory listing (API tests)

Full API suite (includes `ftp-folder` and `file-serving`):

```bash
npm run test:api
```

Target only the listing-related files:

```bash
node --import ./test/api/helpers/test-env.mjs --import tsx --test --test-force-exit \
  test/api/ftp-folder.test.ts \
  test/api/file-serving.test.ts
```

### Remediation 2 — JWT algorithms / `alg: none` (server + API)

Server unit tests (includes the `jwt.verify algorithms allowlist` cases):

```bash
npm run test:server
```

Target the JWT unit tests only:

```bash
node --import ./test/server/helpers/test-env.mjs --import tsx --test --test-force-exit \
  test/server/insecurity.unit.test.ts
```

Basket API case that rejects forged `alg: none` tokens (part of the API suite):

```bash
node --import ./test/api/helpers/test-env.mjs --import tsx --test --test-force-exit \
  test/api/basket.test.ts
```

### Remediation 3 — hardcoded JWT removed (frontend)

Frontend unit tests (includes `app.guard.spec.ts`):

```bash
npm run test:frontend
```

From `app/frontend`, you can also run Angular’s test runner (same suite):

```bash
cd frontend
npm run test
```

### Full app test suite

```bash
cd app
npm test
```

That runs frontend, then server, then API tests in order.

Source of truth for finding context and screenshots: [findings.md](findings.md).
