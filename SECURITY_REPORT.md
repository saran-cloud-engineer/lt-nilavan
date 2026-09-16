# Security Report — lt-nilavan

Live target: https://nilavan-v1.cloudworkspace.fun/
All findings below are verified against the actual source code and/or the live
deployment — see `reports/` for raw supporting evidence (ZAP scan, server
state captures, PoC command outputs) and `Writeup/Writeups.txt` for full
methodology.

## Summary table

| # | Finding | OWASP 2021 | Severity | Status |
|---|---|---|---|---|
| 1 | Missing rate limiting on `/api/sendgrid` | A04 Insecure Design | High | Fixed (Nginx) |
| 2 | Unescaped user input in email HTML (injection) | A03 Injection | High | **Not fixed** |
| 3 | `.git` directory exposure | A05 Security Misconfiguration | Critical (if present) | Fixed |
| 4 | Secret leaked via `NEXT_PUBLIC_` + `console.log` in git history | A02 Cryptographic Failures | High | Historical — not in current tree |
| 5 | Missing clickjacking / security headers | A05 Security Misconfiguration | Medium | Fixed (Nginx) |
| 6 | Application running as non-root — validated by a real incident | A05 Security Misconfiguration | Critical (contextual) | Mitigated |
| 7 | Vulnerable/outdated dependencies | A06 Vulnerable and Outdated Components | Medium–High | Partially fixed |

---

## Finding 1: Missing rate limiting on contact-form endpoint
- **OWASP Category**: A04:2021 – Insecure Design
- **Affected File & Line**: `app/api/sendgrid/route.ts:4-51` — the entire `POST`
  handler contains no rate-limit or throttle logic, and no `middleware.ts`
  exists in the repo to add one at a higher layer.
- **Severity**: High
- **Description**: The endpoint accepts POST requests with no rate limit,
  CAPTCHA, or per-IP throttling, so any client can submit unlimited requests.
  Client-side, the only "protection" is the `isSubmitting` React state in
  `components/contact-section.tsx`, which is UI-only and trivially bypassed
  by calling the API directly.
- **Business Impact**: An attacker can flood the business owner's inbox with
  spam, exhaust SendGrid's sending quota, and risk the sending domain being
  flagged/blacklisted by mail providers.
- **Proof of Concept**:
  ```bash
  for i in $(seq 1 10); do curl -X POST https://nilavan-v1.cloudworkspace.fun/api/sendgrid -H "Content-Type: application/json" -d '{"name":"test","email":"x@x.com","phone":"0000000000","message":"spam"}' ; done
  ```
  **Note on evidence honesty**: the 10x loop above was only run *after* the
  Nginx rate-limit fix below was already applied, so we have confirmed
  "after" evidence (429s) but not a captured "before" run showing the flood
  succeeding unrestricted. The missing control itself is fully confirmed by
  static code review (no throttle logic anywhere in the route).
- **Recommended Fix (applied)**: Nginx `limit_req_zone` (5 req/min per IP,
  `burst=3 nodelay`, `limit_req_status 429`) — see `scripts/nginx-ratelimit.conf`
  and the `/api/sendgrid` location block in `scripts/nginx-lt-nilavan.conf`.
  **Confirmed working**, after also fixing the unrelated SendGrid Sender
  Identity issue (see "Resolved during this assessment" below) so requests
  genuinely succeed or fail on rate-limit grounds alone, not a bad config:
  ```
  request 1 -> HTTP 200   (real email sent successfully)
  request 2 -> HTTP 429
  request 3 -> HTTP 429
  request 4 -> HTTP 429
  request 5 -> HTTP 429
  request 6 -> HTTP 429
  request 7 -> HTTP 429
  request 8 -> HTTP 429
  request 9 -> HTTP 429
  request 10 -> HTTP 429
  ```
  Only 1 request got through before the limit here (rather than the
  `burst=3` configured) because the per-IP counter is a rolling window that
  hadn't fully reset since an immediately preceding test run from the same
  IP — consistent with `limit_req_zone` being a shared, persistent counter,
  not a bug.

---

## Finding 2: Unescaped user input in outgoing email (HTML/link injection)
- **OWASP Category**: A03:2021 – Injection
- **Affected File & Line**: `app/api/sendgrid/route.ts:39-42` — `name`,
  `email`, `phone`, `message` are interpolated directly into the `html`
  template literal with no encoding:
  ```ts
  <p><strong>Name:</strong> ${name}</p>
  <p><strong>Email:</strong> ${email}</p>
  <p><strong>Phone:</strong> ${phone}</p>
  <p><strong>Message:</strong> ${message}</p>
  ```
- **Severity**: High
- **Description**: Because these fields are inserted raw into HTML sent from
  the business's own verified SendGrid sender (`from: toEmail`, line 26), an
  attacker can inject an `<a href="...">` link that renders as part of a
  legitimate-looking email from the business's own system. There is also no
  format/length validation on any field.
- **Business Impact**: Sets up phishing against the business's own staff or
  customers using a channel (their own outgoing email) that recipients
  inherently trust; damages sender-domain reputation if reported as phishing.
- **Proof of Concept**:
  ```bash
  curl -X POST https://nilavan-v1.cloudworkspace.fun/api/sendgrid \
    -H "Content-Type: application/json" \
    -d '{"name":"<a href=\"https://evil.example/login\">Verify your account</a>","email":"x@x.com","phone":"0000000000","message":"test"}'
  ```
  **Confirmed live** (real result): the API returned `{"success":true}`, and
  the received email at the verified sender inbox rendered the injected
  `Name` field as an actual clickable "Verify your account" link — not
  escaped text — appearing inside an email that looks like it came from the
  business's own system.
- **Status (before fix)**: This is a code-only fix — Nginx has no visibility
  into the Node process's own SendGrid API call, so unlike Findings 1 and 5,
  there is no infrastructure-level mitigation available.
- **Recommended Fix**:
  ```ts
  function escapeHtml(value: string): string {
    return value
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
  // then use escapeHtml(name), escapeHtml(email), etc. in the html template
  ```
  Combined with basic server-side validation (email format, length caps —
  `zod` is already a project dependency, unused for this).

---

## Finding 3: Source code / `.git` directory exposure
- **OWASP Category**: A05:2021 – Security Misconfiguration
- **Affected File & Line**: N/A — Nginx/deployment configuration
- **Severity**: Critical (if present and unblocked)
- **Description**: If `.git` ships inside the web root and Nginx doesn't
  block it, tools like `git-dumper` can reconstruct full source history with
  zero authentication.
- **Business Impact**: Full source disclosure — compounded by Finding 4
  below, since this specific repo's history contains a real leaked secret.
- **Proof of Concept** (confirmed live):
  ```bash
  curl -I https://nilavan-v1.cloudworkspace.fun/.git/config
  ```
  Result: `HTTP/1.1 404 Not Found`
- **Status**: Fixed at deploy time (never left exposed in practice — blocked
  from the first Nginx config).
- **Recommended Fix (applied)**: `location ~ /\.(git|svn|hg) { deny all;
  return 404; }` in `scripts/nginx-lt-nilavan.conf`.

---

## Finding 4: Secret exposed via `NEXT_PUBLIC_` + `console.log`, in git history
- **OWASP Category**: A02:2021 – Cryptographic Failures
- **Affected File & Line**: Not present in the current tree — found via
  `git log --all --oneline`, commits `87785f4a`/`8ef6e1ad`/`affbccef` on the
  pre-App-Router `src/components/contact.tsx`:
  ```ts
  const token = process.env.NEXT_PUBLIC_BEARER_TOKEN;
  console.log("Token:", token);
  ```
- **Severity**: High (Critical if the referenced token/service is still live)
- **Description**: `NEXT_PUBLIC_`-prefixed env vars are bundled into the
  client-side JS bundle by Next.js at build time — readable by any visitor —
  and this token was additionally logged to the browser console in plaintext.
  Directly relevant to "read the full source code from the browser, no
  credentials": even with `.git` blocked today, this proves the repo's
  history has held real secrets before.
- **Business Impact**: If `https://nilavan-email.vercel.app/send-email` (the
  endpoint this token authenticated to) is still active, the token is
  trivially recoverable from history and reusable.
- **Proof of Concept**:
  ```bash
  git log --all --oneline | grep -iE "token|env|key"
  git show 87785f4a -- src/components/contact.tsx
  ```
- **Recommended Fix**: Never call third-party APIs with a bearer token from
  client-side code (the current `app/api/sendgrid/route.ts` already does
  this correctly — server-only `SENDGRID_API_KEY`, no `NEXT_PUBLIC_` prefix).
  Rotate the old token if that service is still live; run a full secret scan
  (Gitleaks/TruffleHog) before ever making this repo's history public.

---

## Finding 5: Missing clickjacking / security headers
- **OWASP Category**: A05:2021 – Security Misconfiguration
- **Affected File & Line**: No `next.config.js`/`.mjs` existed in the repo at
  all, and no `middleware.ts` — confirmed via repo listing.
- **Severity**: Medium
- **Description**: With no `X-Frame-Options`/CSP `frame-ancestors`, the site
  could be embedded in an attacker's `<iframe>`.
- **Proof of Concept (before fix — confirmed live)**:
  ```bash
  curl -sI https://nilavan-v1.cloudworkspace.fun/ | grep -Ei "x-frame-options|content-security-policy|strict-transport-security|x-content-type-options"
  ```
  Result: `NONE FOUND - vulnerable to clickjacking`

  **Independently confirmed by OWASP ZAP** (`reports/zap-report/`):
  `Content Security Policy (CSP) Header Not Set` (Medium), `Missing
  Anti-clickjacking Header` (Medium), `Strict-Transport-Security Header Not
  Set` (Low), `X-Content-Type-Options Header Missing` (Low), plus
  `Server`/`X-Powered-By` version-disclosure headers (Low).
- **Recommended Fix (applied)**: `add_header` directives in
  `scripts/nginx-lt-nilavan.conf`: `X-Frame-Options: DENY`,
  `Content-Security-Policy: frame-ancestors 'none'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy`,
  `Strict-Transport-Security`.
- **Status**: Fixed and confirmed live. Re-running the same PoC command after
  the fix:
  ```bash
  curl -sI https://nilavan-v1.cloudworkspace.fun/ | grep -Ei "x-frame-options|content-security-policy|strict-transport-security|x-content-type-options"
  ```
  Result (previously `NONE FOUND`):
  ```
  X-Frame-Options: DENY
  Content-Security-Policy: frame-ancestors 'none'
  X-Content-Type-Options: nosniff
  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
  ```

---

## Finding 6: Non-root execution — validated by a real incident during this assessment
- **OWASP Category**: A05:2021 – Security Misconfiguration (privilege-escalation
  blast radius)
- **Affected File & Line**: N/A — deployment/process configuration
  (`scripts/ec2-user-data.sh`, `scripts/01-server-hardening.sh`)
- **Severity**: Critical (contextual — multiplies the impact of any other bug)
- **Description**: The app runs under PM2 as a dedicated non-root `deploy`
  user, never root, confirmed via `pm2 list` (`reports/server-evidence/pm2-list.txt`):
  process owner `deploy`, not root.
- **This was not theoretical.** During this assessment, the publicly exposed
  instance was compromised by an opportunistic internet-scanning attacker
  (first infection artifact dated the same day the server went live) and
  used to run cryptocurrency-mining malware (XMRig-family, three separate
  infection generations found), a self-reinstalling cron-based persistence
  mechanism, and a planted backdoor SSH key. **Critically, `sudo crontab -l
  -u root` was empty — the malicious persistence only existed in the
  `deploy` user's own crontab, and all malicious processes ran as `deploy`,
  never root.** The non-root design directly contained the blast radius of
  this real compromise to one low-privilege account rather than the whole
  system.
- **Business Impact (of the counterfactual)**: had this process run as root,
  the same initial compromise (whatever its actual entry point) would have
  granted the attacker root immediately — full read/write to every file,
  ability to install kernel-level persistence, tamper with Nginx/SSH config,
  and pivot to any other service on the box, instead of being contained to
  `deploy`'s limited permissions.
- **Recommended Fix (already in place)**: dedicated non-root user for the
  app process (done); additionally consider systemd sandboxing
  (`ProtectSystem=strict`, `NoNewPrivileges=yes`) or containerization for
  further isolation on any future deployment.
- **Incident response taken**: malicious crontab removed, planted SSH key
  removed from `authorized_keys`, malicious processes killed, outbound
  traffic to the attacker's C2/mining-pool IPs blocked via UFW, malware
  files deleted, and the `SENDGRID_API_KEY` treated as compromised pending
  rotation (it sat in a plaintext `.env` readable at the same privilege
  level the attacker already had).

---

## Finding 7: Vulnerable/outdated dependencies
- **OWASP Category**: A06:2021 – Vulnerable and Outdated Components
- **Affected File & Line**: `package-lock.json` (transitive dependencies);
  `package.json` (`next: ^15.1.0`)
- **Severity**: Medium (High for the PostCSS advisories; **High** for the
  Next.js RCE advisory specifically — see below)
- **Description**: `npm audit --omit=dev` originally reported 15 advisories
  (1 low, 2 moderate, 10 high, 2 critical): `postcss <=8.5.22` (XSS +
  path-traversal/arbitrary-file-read), `sharp <0.35.0` (libvips CVEs),
  `postcss-selector-parser` (ReDoS), `yaml` (stack overflow via nested
  collections), `picomatch` (ReDoS). Running the fix additionally surfaced
  that **the pinned Next.js version itself (15.1.0) carries an unauthenticated
  Remote Code Execution advisory** (`GHSA-p293-qw3h-jr36`,
  `GHSA-2xp9-vwfh-vxw4` — Windows-hosted RCE and RCE via the Image
  Optimization API with AVIF files), only surfaced once the dependency tree
  was re-resolved — a good example of why a plain visual read of
  `package.json` isn't enough to catch this class of issue.
- **Business Impact**: The PostCSS/sharp/yaml issues are mostly
  build-toolchain exposure. The Next.js RCE advisory is direct live-request
  exposure — a real, high-severity finding, not just hygiene.
- **Proof of Concept**: `npm audit --omit=dev`
- **Recommended Fix — applied and verified**:
  ```bash
  npm audit fix          # 15 -> 3 advisories, rebuilt clean
  npm audit fix --force  # 3 -> 2 advisories (upgraded next 15.1.0 -> 15.5.25,
                          # fixing the RCE advisory), rebuilt clean
  ```
  `npm run build` confirmed successful after each step. The remaining 2
  advisories require Next.js **16** (a major version jump) and were
  deliberately **not** forced — that needs real migration testing, not a
  blind `--force`, and is out of scope for this pass. Documented as an
  accepted residual risk rather than silently left unaddressed.

---

## Threat-scenario mapping (per assessment requirements)
| Scenario | Root cause | Fix status |
|---|---|---|
| Flood the inbox with spam via the contact form | Finding 1 | Fixed (Nginx rate limit, confirmed via 429s) |
| Inject a malicious link appearing to come from the business | Finding 2 | **Not fixed** — code change required |
| Read the full source code from the browser, no credentials | Finding 3 + Finding 4 | Fixed (`.git` blocked); history exposure noted, not rewritable at this point |
| Embed the site in an iframe (clickjacking) | Finding 5 | Fixed and confirmed live (Nginx headers) |
| Server compromise made worse by running as root | Finding 6 | Mitigated — validated by a real incident during this assessment |

## Open items (tracked honestly, not glossed over)
- [ ] Finding 2 (HTML injection) code fix not yet applied
- [ ] Remaining 2 dependency advisories require a Next.js 16 major upgrade —
      deliberately deferred pending real migration testing (see Finding 7)

## Resolved during this assessment (not vulnerabilities — operational issues)
- **SendGrid `500` errors during rate-limit testing** — root cause found via
  `pm2 logs`: SendGrid `403 Forbidden`, "The from address does not match a
  verified Sender Identity." `SENDGRID_TO_EMAIL` (used as both `to` and
  `from`) had never been verified as a Sender Identity in the SendGrid
  account. Fixed by verifying the address under SendGrid → Settings →
  Sender Authentication. Confirmed working:
  ```bash
  curl -X POST https://nilavan-v1.cloudworkspace.fun/api/sendgrid -H "Content-Type: application/json" -d '{"name":"test","email":"x@x.com","phone":"0000000000","message":"debug test"}'
  ```
  Result: `{"success":true}` (previously `{"error":"Error sending email"}`).
- **`SENDGRID_API_KEY` rotated** — the original key was treated as
  compromised for two reasons: it sat in plaintext `.env` on the box during
  the cryptomining incident (Finding 6), and it was separately pasted into
  this session's chat transcript. Revoked in the SendGrid dashboard and
  replaced with a newly generated key before retesting.
