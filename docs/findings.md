# Findings and remediations

Selected issues from the triage agent that demonstrate a find-then-fix loop. Each entry covers the scanner finding, what exists in the repository, the remediation, and screenshots from the triage PR comment and the matching code.

## How these findings reach the PR

Log-integrity runs first and must write `integrity.json` with `"passed": true`. That gate is what allows triage to publish:

![Log integrity agent PR comment](./images/findings/log-integrity-agent-githubactions.png)

*Integrity review: job conclusions matched the CI logs (`Integrity passed: true`).*

Triage then summarizes scanner artifacts into a grouped PR comment. The three findings below were selected from that output:

![Triage summary agent PR comment](./images/findings/triage-summary-agent-githubactions.png)

*Triage summary: Semgrep, Trivy, and secrets sections that feed the write-ups below.*

---

## 1. Directory listing enabled (Semgrep / Express)

**Scanner:** Semgrep (SAST)  
**Rule:** `javascript.express.security.audit.express-check-directory-listing.express-check-directory-listing`  
**Severity:** medium  
**Locations:** `app/server.ts` lines 269, 273, and 277

### Finding

Express is configured so several directories are browsable over HTTP (`/ftp`, `/.well-known`, `/encryptionkeys`, and related log paths). Anyone who can reach the app can list files in those trees. That aids reconnaissance and can expose material that should not be public (keys, logs, ftp contents).

![Triage finding — directory listing](./images/findings/01-directory-listing-triage.png)

*Triage PR comment — Semgrep directory listing finding.*

### What exists in the codebase

Static directory listing is wired with `serve-index` and related routes in `app/server.ts`:

```269:277:app/server.ts
  app.use('/ftp', serveIndexMiddleware, serveIndex('ftp', { icons: true })) // vuln-code-snippet vuln-line directoryListingChallenge
  app.use('/ftp(?!/quarantine)/:file', servePublicFiles()) // vuln-code-snippet vuln-line directoryListingChallenge
  app.use('/ftp/quarantine/:file', serveQuarantineFiles()) // vuln-code-snippet neutral-line directoryListingChallenge

  app.use('/.well-known', serveIndexMiddleware, serveIndex('.well-known', { icons: true, view: 'details' }))
  app.use('/.well-known', express.static('.well-known'))

  /* /encryptionkeys directory browsing */
  app.use('/encryptionkeys', serveIndexMiddleware, serveIndex('encryptionkeys', { icons: true, view: 'details' }))
```

Similar listing is also enabled under `/support/logs`. Comments in-file mark some of this as challenge-related, but from a secure-defaults perspective the scanner finding is valid: directory indexes are on.

![Code — server.ts listing routes](./images/findings/01-directory-listing-code.png)

*`app/server.ts` — `serveIndex` usage.*

### Remediation

Drop `serveIndex` so directories are not browsable. Keep explicit per-file routes where downloads are still needed, and harden any remaining `express.static` mounts:

```ts
// app/server.ts — replace the serveIndex mounts

// /ftp: file download only, no directory index
app.use('/ftp(?!/quarantine)/:file', servePublicFiles())
app.use('/ftp/quarantine/:file', serveQuarantineFiles())

// /.well-known: static files only, no listing, no dotfiles
app.use('/.well-known', express.static('.well-known', {
  index: false,
  dotfiles: 'deny'
}))

// /encryptionkeys: download by name only (no browse)
app.use('/encryptionkeys/:file', serveKeyFiles())

// /support/logs: keep auth/challenge middleware; remove listing
app.use('/support/logs', verify.accessControlChallenges())
app.use('/support/logs/:file', serveLogFiles())
```

Re-run Semgrep afterward and confirm the directory-listing rule is clear for these paths.

---

## 2. Critical vulnerable `jsonwebtoken` (Trivy / container)

**Scanner:** Container (Trivy)  
**Rule / CVE:** `CVE-2015-9235`  
**Severity:** critical  
**Locations:**  
- `juice-shop/node_modules/jsonwebtoken/package.json` (resolved install)  
- Nested copy under `express-jwt`  
**Declared in app:** `app/package.json` dependency `"jsonwebtoken": "0.4.0"` (also `"express-jwt": "0.1.3"`)

### Finding

Installed `jsonwebtoken` versions in the image/tree are far below the patched line. CVE-2015-9235 covers weak handling that allows tokens with algorithm `none` (and related forgery). An attacker who can present a crafted JWT may bypass signature checks and authenticate as an arbitrary user.

![Triage finding — CVE-2015-9235](./images/findings/02-jsonwebtoken-cve-triage.png)

*Triage PR comment — Trivy CVE-2015-9235.*

### What exists in the codebase

Direct pins in `app/package.json`:

```json
"express-jwt": "0.1.3",
"jsonwebtoken": "0.4.0"
```

`express-jwt` 0.1.3 also pulls an older nested `jsonwebtoken`. Trivy reports both inside the built image’s `node_modules`. Call sites such as `app/lib/insecurity.ts` invoke `jwt.verify` without an `algorithms` allowlist:

```ts
jwt.verify(token, publicKey, (err: Error | null, decoded: any) => {
  if (err === null && decoded?.data !== undefined) {
    authenticatedUsers.put(token, decoded)
    res.cookie('token', token)
  }
})
```

![Code — package.json JWT pins](./images/findings/02-jsonwebtoken-package-json.png)

*`app/package.json` — `jsonwebtoken` / `express-jwt` versions.*

### Remediation

Bump the declared dependencies and force nested copies to a patched `jsonwebtoken` via npm `overrides`:

```json
{
  "dependencies": {
    "express-jwt": "^8.5.1",
    "jsonwebtoken": "^9.0.2"
  },
  "overrides": {
    "jsonwebtoken": "^9.0.2",
    "express-jwt": {
      "jsonwebtoken": "^9.0.2"
    }
  }
}
```

Require an explicit algorithm allowlist on verify (this app signs with `RS256`):

```ts
// app/lib/insecurity.ts (and other jwt.verify call sites)
jwt.verify(token, publicKey, { algorithms: ['RS256'] }, (err, decoded) => {
  if (err === null && decoded?.data !== undefined) {
    authenticatedUsers.put(token, decoded)
    res.cookie('token', token)
  }
})
```

Rebuild the app image, re-run Trivy, and confirm CVE-2015-9235 clears (or drops as expected for remaining transitive noise).

---

## 3. Hardcoded JWT in unit tests (Gitleaks / secrets)

**Scanner:** Secrets (Gitleaks)  
**Rule:** `jwt`  
**Severity:** high  
**Location:** `app/frontend/src/app/app.guard.spec.ts` (same rule also hit other test files under `app/`)

### Finding

Gitleaks flagged a JWT-shaped string committed in a frontend unit test. Tokens in git history are visible to anyone with repository access. Even when the value is only used in tests, the pattern trains bad habits and can leak a real token if someone pastes a live credential later.

![Triage finding — hardcoded JWT](./images/findings/03-hardcoded-jwt-triage.png)

*Triage PR comment — Gitleaks JWT finding.*

### What exists in the codebase

In `app.guard.spec.ts`, a full JWT is written into `localStorage` to exercise `tokenDecode()`:

```46:49:app/frontend/src/app/app.guard.spec.ts
        localStorage.setItem('token', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c')
        expect(guard.tokenDecode()).toEqual({
            sub: '1234567890',
            name: 'John Doe',
```

This string is a well-known public jwt.io-style demo payload, not an AWS or Anthropic secret. The finding is still valid as a **secrets-in-repo** control: JWT literals should not live in source.

Similar Gitleaks `jwt` hits appear in other specs and Cypress tests under `app/`.

![Code — app.guard.spec.ts token](./images/findings/03-hardcoded-jwt-code.png)

*`app.guard.spec.ts` — committed JWT string.*

### Remediation

`tokenDecode()` only base64-decodes the payload (`jwt-decode`); it does not verify a signature. Build the token in the test from the claims object so no compact JWT literal sits in the file:

```ts
// app/frontend/src/app/app.guard.spec.ts

function fakeJwt (payload: object): string {
  const b64url = (value: object) =>
    btoa(JSON.stringify(value))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '')

  return `${b64url({ alg: 'HS256', typ: 'JWT' })}.${b64url(payload)}.test-sig`
}

it('returns payload from decoding a valid JWT', () => {
  const guard = TestBed.inject(LoginGuard)
  const claims = { sub: '1234567890', name: 'John Doe', iat: 1516239022 }

  localStorage.setItem('token', fakeJwt(claims))
  expect(guard.tokenDecode()).toEqual(claims)
})
```

Apply the same helper to the other Gitleaks JWT hits under `app/`, then re-run Gitleaks so the `jwt` rule is clean for those paths.
