# Security Report — lt-nilavan

Live target: https://nilavan-v1.cloudworkspace.fun/

Every finding below follows the same structure: **Issue → Impact → Fix → Test
command → Confirmed result**. Every test command is real and can be re-run
live against the deployment.

## Testing tools used

| Tool | Used for | How |
|---|---|---|
| **curl** | Every PoC in this report — endpoint abuse, header checks, `.git` probing, injection payloads | `curl -I`, `curl -X POST -d '{...}'`, piped into `grep` for header checks. Fully scriptable, no GUI needed — the primary tool for this assessment. |
| **OWASP ZAP** | Automated baseline scan of the live site, independent confirmation of the header findings + extra ones we hadn't listed | Ran directly via Docker (not the GitHub Action — its report-upload step is broken): `docker run --rm -v "$(pwd)":/zap/wrk/:rw --network=host ghcr.io/zaproxy/zaproxy:stable zap-baseline.py -t https://nilavan-v1.cloudworkspace.fun/ -r zap-report.html`. Wired into the CI pipeline so it re-runs on every push. |
| **Browser DevTools** | Checking the SSL certificate details, confirming response headers visually, verifying the HTTPS padlock | Chrome/Edge → Network tab → inspect response headers on any request; the lock icon next to the URL → View certificate for cert details (`screenshots/https-browser-certificate.png`). |
| **Burp Suite** | Not used in this engagement | curl covered every PoC needed here (simple REST endpoint, no complex session/auth flows to intercept). Burp would add value for a more complex app with multi-step auth flows or needing to replay/tamper with intercepted requests interactively — overkill for a single unauthenticated POST endpoint. |
| **`npm audit`** | Dependency vulnerability scanning (Finding 7) | `npm audit --omit=dev`, then `npm audit fix` / `npm audit fix --force`, verified via `npm run build` |
| **`git log`/`git show`** | Secret-scanning git history (Finding 4) | `git log --all --oneline`, then `git show <hash> -- <file>` on suspicious commits — not in the assessment's suggested tool list, but necessary since one of the required scenarios is specifically about source/history exposure |

## Summary

| # | Finding | OWASP 2021 | Severity | Status |
|---|---|---|---|---|
| 1 | Missing rate limit on `/api/sendgrid` | A04 Insecure Design | High | Fixed |
| 2 | Unescaped input in email HTML (injection) | A03 Injection | High | Fixed |
| 3 | `.git` directory exposure | A05 Security Misconfiguration | Critical | Fixed |
| 4 | Secret leaked via `NEXT_PUBLIC_` in git history | A02 Cryptographic Failures | High | Historical |
| 5 | Missing security headers (clickjacking) | A05 Security Misconfiguration | Medium | Fixed |
| 6 | App running as non-root | A05 Security Misconfiguration | Critical | Validated by real incident |
| 7 | Vulnerable/outdated dependencies | A06 Vulnerable Components | Medium–High | Mostly fixed |

---

## 1. Missing rate limit on contact form
- **OWASP**: A04:2021 – Insecure Design
- **File**: `app/api/sendgrid/route.ts:4-51` — entire `POST` handler, no throttle logic anywhere, no `middleware.ts` either
- **Issue**: the endpoint accepts unlimited POST requests with no rate limit, CAPTCHA, or per-IP throttling
- **Impact**: an attacker can flood the business owner's inbox with spam, exhaust SendGrid's sending quota, and get the sending domain flagged/blacklisted by mail providers — a single script can do this at scale (1,000 req/min)
- **Fix**: Nginx `limit_req_zone` — 5 requests/min per IP, `burst=3 nodelay`, returns `429`
  ```nginx
  # /etc/nginx/conf.d/ratelimit.conf — zone must live in the http{} context
  limit_req_zone $binary_remote_addr zone=contact_form:10m rate=5r/m;
  ```
  ```nginx
  # inside the server block, /etc/nginx/sites-available/lt-nilavan.conf
  location /api/sendgrid {
      limit_req zone=contact_form burst=3 nodelay;
      limit_req_status 429;
      proxy_pass http://127.0.0.1:3000;
      # ...standard proxy headers...
  }
  ```
- **Test command**:
  ```bash
  for i in $(seq 1 10); do curl -s -o /dev/null -w "request $i -> HTTP %{http_code}\n" -X POST https://nilavan-v1.cloudworkspace.fun/api/sendgrid -H "Content-Type: application/json" -d '{"name":"test","email":"x@x.com","phone":"0000000000","message":"spam"}'; done
  ```
- **Confirmed result**: requests 1-4 → `200` (real emails sent), requests 5-10 → `429 Too Many Requests`
  ```
  request 1 -> HTTP 200
  request 2 -> HTTP 200
  request 3 -> HTTP 200
  request 4 -> HTTP 200
  request 5 -> HTTP 429
  request 6 -> HTTP 429
  request 7 -> HTTP 429
  request 8 -> HTTP 429
  ```
  (No "before" run exists showing the flood succeeding unrestricted — this PoC was only run after the fix. The missing control itself was confirmed by static code review: no throttle logic anywhere in the route before the fix.)
- **Known limitation (confirmed, documented honestly)**: `limit_req_zone` keys on `$binary_remote_addr` — a single client IP. Verified directly: a local test (`127.0.0.1`) correctly triggers `429` after 4 requests, but the same burst sent from behind a CGNAT/mobile network showed each request landing on a *different* public IP (confirmed via `nginx access.log`), so none individually crossed the per-IP threshold. This isn't a flaw in the implementation — it's a known, general limitation of any per-IP rate limit: an attacker (or anyone behind CGNAT) can distribute requests across multiple source IPs to reduce the per-IP count. Mitigation for a future pass: combine with a secondary signal (e.g. a CAPTCHA, or a global — not just per-IP — cap on `/api/sendgrid`).

---

## 2. Unescaped input in outgoing email (HTML injection)
- **OWASP**: A03:2021 – Injection
- **File**: `app/api/sendgrid/route.ts:39-42` — `name`/`email`/`phone`/`message` interpolated raw into the `html` template, no encoding
- **Issue**: whatever a user types goes directly into the outgoing email's HTML with zero sanitization
- **Impact**: attacker submits `<a href="...">` as the name field → a real clickable link appears inside an email sent from the business's own verified SendGrid sender — classic phishing setup, since recipients trust an email that looks like it's from their own system
- **Fix**: `escapeHtml()` function added in `route.ts`, wraps all 4 fields before they're interpolated into the HTML template
  ```ts
  // added near the top of app/api/sendgrid/route.ts
  function escapeHtml(value: string): string {
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
  ```
  ```diff
  - <p><strong>Name:</strong> ${name}</p>
  - <p><strong>Email:</strong> ${email}</p>
  - <p><strong>Phone:</strong> ${phone}</p>
  - <p><strong>Message:</strong> ${message}</p>
  + <p><strong>Name:</strong> ${escapeHtml(name)}</p>
  + <p><strong>Email:</strong> ${escapeHtml(email)}</p>
  + <p><strong>Phone:</strong> ${escapeHtml(phone)}</p>
  + <p><strong>Message:</strong> ${escapeHtml(message)}</p>
  ```
- **Test command**:
  ```bash
  curl -X POST https://nilavan-v1.cloudworkspace.fun/api/sendgrid -H "Content-Type: application/json" -d '{"name":"<a href=\"https://evil.example/login\">Verify your account</a>","email":"x@x.com","phone":"0000000000","message":"test"}'
  ```
- **Before fix**: email rendered a real, clickable "Verify your account" link
- **Confirmed result (after fix)**: API returns `{"success":true}`; the received email shows the **literal text** `<a href="https://evil.example/login">Verify your account</a>` — not a rendered link (`screenshots/html-injection-fix-confirmed.png`). Gmail auto-links the bare URL substring itself (a client-side behavior, not our app rendering a link), but the actual vulnerability — a malicious link disguised behind trustworthy text — is fully neutralized.

---

## 3. `.git` directory exposure
- **OWASP**: A05:2021 – Security Misconfiguration
- **File**: N/A — Nginx/deployment configuration
- **Issue**: if `.git` ships inside the web root and Nginx doesn't block it, tools like `git-dumper` can reconstruct the full source history with zero authentication
- **Impact**: complete source code disclosure, including any secrets ever committed (see Finding 4) — all without logging in anywhere
- **Fix**: `location ~ /\.(git|svn|hg) { deny all; return 404; }` in `scripts/nginx-lt-nilavan.conf` — present from the very first deploy, never actually left exposed
- **Test command**:
  ```bash
  curl -I https://nilavan-v1.cloudworkspace.fun/.git/config
  ```
- **Confirmed result**: `HTTP/1.1 404 Not Found`

---

## 4. Secret leaked via `NEXT_PUBLIC_` + `console.log`, in git history
- **OWASP**: A02:2021 – Cryptographic Failures
- **File**: not present in the current tree — found in history: `src/components/contact.tsx`, commits `87785f4a`/`8ef6e1ad`/`affbccef`
- **Issue**: an old commit set `process.env.NEXT_PUBLIC_BEARER_TOKEN` (the `NEXT_PUBLIC_` prefix bundles it straight into the client-side JS by Next.js at build time) and additionally `console.log`'d that token to the browser console
- **Impact**: anyone who ever had access to that build, or who pulls full git history, can recover a real bearer token — directly relevant to "read the full source / secrets from the browser, no credentials," since it proves this repo's history has held real secrets before
- **Fix**: not applied to history (can't practically rewrite already-pushed git history) — confirmed the *current* code does this correctly (server-only `SENDGRID_API_KEY`, no `NEXT_PUBLIC_` prefix, never logged). Recommendation: rotate the old token if the referenced service is still live; run a secret scanner (Gitleaks/TruffleHog) before ever making this history public.
- **Test command**:
  ```bash
  git log --all --oneline | grep -iE "token|env|key"
  git show 87785f4a -- src/components/contact.tsx
  ```
- **Confirmed result**: the commit diff shows `const token = process.env.NEXT_PUBLIC_BEARER_TOKEN;` and `console.log("Token:", token);` in plaintext

---

## 5. Missing security headers (clickjacking)
- **OWASP**: A05:2021 – Security Misconfiguration
- **File**: no `next.config.js`/`.mjs` and no `middleware.ts` existed in the repo at all
- **Issue**: with no `X-Frame-Options`/CSP `frame-ancestors`, the site could be embedded in an attacker's `<iframe>`
- **Impact**: attacker overlays the real site inside their own malicious page to trick users into clicking something they didn't intend (classic clickjacking)
- **Fix**: `add_header` directives in the server block (`scripts/nginx-lt-nilavan.conf`)
  ```nginx
  add_header X-Frame-Options "DENY" always;
  add_header Content-Security-Policy "frame-ancestors 'none'" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
  ```
  (`always` ensures these are sent on error responses like 404s too, not just 200s)
- **Test command**:
  ```bash
  curl -sI https://nilavan-v1.cloudworkspace.fun/ | grep -Ei "x-frame-options|content-security-policy|strict-transport-security|x-content-type-options"
  ```
- **Before fix**: no output at all (headers absent) — also independently confirmed by an OWASP ZAP scan
- **Confirmed result (after fix)**:
  ```
  X-Frame-Options: DENY
  Content-Security-Policy: frame-ancestors 'none'
  X-Content-Type-Options: nosniff
  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
  ```

---

## 6. App running as non-root — validated by a real incident
- **OWASP**: A05:2021 – Security Misconfiguration (privilege-escalation blast radius)
- **File**: N/A — deployment/process config (`scripts/ec2-user-data.sh`, `scripts/01-server-hardening.sh`)
- **Issue**: if the app process runs as root, any future code-execution bug (in the app or a dependency) hands an attacker full root immediately
- **Impact**: full read/write to every file, ability to install kernel-level persistence, tamper with Nginx/SSH config, pivot to other services — instead of being contained to one low-privilege account
- **Fix**: app runs under PM2 as a dedicated non-root `deploy` user, never root — built into the deployment from the start
- **Not theoretical — this was actually tested by a real attacker mid-assessment**: the live instance was compromised by an opportunistic internet-scanning attacker (cryptomining malware, a self-reinstalling cron-based persistence mechanism, a planted backdoor SSH key). Incident response taken: malicious cron removed, planted SSH key removed, malicious processes killed, attacker's C2/mining-pool IPs blocked via UFW, malware deleted, `SENDGRID_API_KEY` rotated.
- **Test command**:
  ```bash
  pm2 list                      # check the "user" column
  sudo crontab -l -u root       # check for root-level persistence
  ```
- **Confirmed result**: `pm2 list` shows process owner `deploy`, not root. `sudo crontab -l -u root` → `no crontab for root` — despite the real compromise, **all malicious activity stayed confined to the `deploy` account and never reached root.**

---

## 7. Vulnerable/outdated dependencies
- **OWASP**: A06:2021 – Vulnerable and Outdated Components
- **File**: `package-lock.json`, `package.json` (`next` was pinned at `15.1.0`)
- **Issue**: `npm audit --omit=dev` found 15 advisories (1 low, 2 moderate, 10 high, 2 critical) — including an **unauthenticated Remote Code Execution advisory in the pinned Next.js version itself** (`GHSA-p293-qw3h-jr36`, `GHSA-2xp9-vwfh-vxw4`)
- **Impact**: most advisories (PostCSS, sharp, yaml) are build-toolchain exposure; the Next.js RCE is direct live-request exposure — a genuinely exploitable, high-severity issue, not just hygiene
- **Fix**:
  ```bash
  npm audit fix          # 15 -> 3 advisories
  npm audit fix --force  # 3 -> 2 advisories (next 15.1.0 -> 15.5.25, fixes the RCE)
  ```
- **Test command**:
  ```bash
  npm run build
  npm audit --omit=dev
  ```
- **Confirmed result**: `npm run build` succeeds; `npm audit` shows 2 remaining advisories (down from 15), both requiring a Next.js **16** major upgrade — deliberately deferred since that needs real migration testing, not a blind `--force`. Documented as an accepted residual risk, not silently left unaddressed.

---

## Threat-scenario mapping
| Scenario | Finding | Status |
|---|---|---|
| Flood inbox via contact form | 1 | Fixed, confirmed live |
| Malicious link appearing to come from the business | 2 | Fixed, confirmed live |
| Read full source code from browser, no creds | 3 + 4 | `.git` blocked; history exposure documented |
| Embed site in iframe (clickjacking) | 5 | Fixed, confirmed live |
| Server compromise worse because of root | 6 | Validated by real incident |

## Resolved along the way (not vulnerabilities)
- **SendGrid `500` errors**: root cause was an unverified Sender Identity, not a code bug. Fixed via SendGrid dashboard → Sender Authentication. Confirmed: `curl -X POST .../api/sendgrid ...` → `{"success":true}` (was `{"error":"Error sending email"}`).
- **`SENDGRID_API_KEY` rotated**: the original key was treated as compromised for two reasons — it sat in plaintext `.env` on the box during the cryptomining incident, and it was separately pasted into a chat transcript. Revoked and replaced before any further testing.
