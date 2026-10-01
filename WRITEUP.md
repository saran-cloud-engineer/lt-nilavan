WRITE-UP — METHODOLOGY, DECISIONS, TRADE-OFFS
lt-nilavan Security + DevOps Assessment
======================================================================

APPROACH TO FINDING VULNERABILITIES (tools, methodology)

Static review first, dynamic testing second. Before touching the live
server, the source was read directly: app/api/sendgrid/route.ts (the only
API route in the app), components/contact-section.tsx (the form calling
it), app/layout.tsx, and a repo-wide check for next.config.js/middleware.ts
(neither exists) and dangerouslySetInnerHTML (one instance, in an unused
shadcn chart.tsx component fed by developer config, not user input — ruled
out). This static pass is what surfaced the two most code-specific
findings: the unescaped ${name}/${email}/${phone}/${message} interpolation
directly into the outgoing email's HTML, and the complete absence of any
rate-limiting or validation logic in that same route.

Git history was checked, not just the current tree. Because one of the
assessment's own threat scenarios is "read the full source code from the
browser, no credentials," it mattered whether history itself held anything
sensitive — not just the working copy. `git log --all --oneline` surfaced
commits titled "token"/"toen" on a pre-App-Router src/components/contact.tsx,
which `git show` confirmed contained process.env.NEXT_PUBLIC_BEARER_TOKEN
(bundled into the client JS by Next.js at build time) plus a console.log of
that same token. That code is gone from the current tree, but the secret is
still fully recoverable from history — directly relevant if .git is ever
exposed.

Dependency scanning: `npm audit --omit=dev` against the lockfile, surfacing
15 advisories (notably PostCSS XSS/path-traversal CVEs and sharp libvips
CVEs) — mostly build-toolchain exposure rather than live-request exposure,
but real and worth fixing.

Dynamic testing against the live deployment, once it existed:
- curl for endpoint abuse (rate limit), header injection into the email
  body, direct .git/.env path probing, and response-header inspection for
  clickjacking protection.
- OWASP ZAP baseline scan, run directly via Docker
  (ghcr.io/zaproxy/zaproxy:stable zap-baseline.py) rather than the
  zaproxy/action-baseline GitHub Action — that action's own internal
  artifact-upload step is currently broken against GitHub's Actions
  backend, so the scan is run manually and the report uploaded with the
  standard actions/upload-artifact action instead. ZAP independently
  confirmed the missing-clickjacking-header finding and additionally
  flagged missing CSP, HSTS, X-Content-Type-Options, and server-version
  disclosure (Server/X-Powered-By headers) — folded into the fix list.
- Browser DevTools for the one thing no CLI tool can check: whether the
  padlock/HTTPS actually renders correctly for a real user.

All of this was wired into a single automated pipeline
(.github/workflows/deploy.yml) rather than being one-off manual steps: on
every push it builds, deploys over SSH, runs the ZAP scan, captures
UFW/PM2/Nginx/Certbot state from the live server, and re-runs the
non-destructive PoCs (.git block, clickjacking headers). The two PoCs that
send real emails (spam-flood, HTML-injection) are deliberately NOT run on
every push — they're gated behind a manual workflow_dispatch trigger so
routine commits don't burn SendGrid's daily quota or spam the verified
inbox. That's a methodology choice as much as an implementation detail:
automate what's safe to automate, keep a human in the loop for what has a
real-world side effect.

======================================================================

DECISIONS MADE DURING SERVER SETUP AND WHY

- Non-root "deploy" user, never root, created at first boot via EC2
  user-data, with the app run under PM2 as that user. Containment: any
  app-level compromise stays scoped to a low-privilege account instead of
  granting the attacker root outright.

- UFW default-deny, only SSH (22 + 2222), 80, 443 open. The Next.js process
  itself only ever listens on 127.0.0.1:3000 — never exposed directly, only
  reachable through the Nginx reverse proxy.

- Port 22 kept open alongside a custom port 2222, rather than fully
  replacing 22 as the assessment's wording literally suggests. Deliberate
  trade-off for operational fallback access. The part that actually matters
  for security — key-only auth, no password login, no root login — is
  enforced identically on both ports, so what this trade-off actually
  reintroduces is exposure to automated port-22 login attempts, which still
  fail outright (no password auth accepted), not exposure to successful
  unauthorized access.

- Most of the server setup is automated via EC2 user-data
  (scripts/ec2-user-data.sh) rather than done by hand: package installs,
  base UFW rules, the deploy user, and Node 18/PM2 (installed for deploy
  specifically, never root). The one step deliberately left manual is the
  SSH-port/password-auth change (scripts/01-server-hardening.sh) — that's
  the one step that can lock you out of the box entirely if something's
  misconfigured, so it's worth verifying interactively (confirm the new
  login works, from a second terminal, before closing the original
  session) rather than trusting an unattended script with no console
  fallback handy.

- Certbot's --nginx plugin over a hand-rolled cert + cron renewal — fewer
  moving parts, and renewal is handled by a systemd timer Certbot installs
  automatically (certbot renew --dry-run confirmed working).

- A dedicated ed25519 keypair for GitHub Actions, generated separately from
  the AWS admin .pem and added only to deploy's authorized_keys. If the CI
  secret ever leaked, the blast radius is one low-privilege account on one
  box — not full AWS admin access via the original key.

- Narrowly-scoped passwordless sudo for deploy, limited to exactly two
  read-only commands (ufw status verbose, certbot certificates) via a
  dedicated /etc/sudoers.d/deploy-readonly file — added only so the CI
  pipeline's evidence-capture step could run non-interactively. Deliberately
  not full sudo, and not achieved by putting the admin key into CI instead
  (which would have a far larger blast radius for a much smaller benefit).

- 2GB swap added after the fact, once npm ci was observed getting
  OOM-killed on the t2/t3.micro's 1GB RAM during the dependency install.
  Not something anticipated up front — a real constraint discovered by
  hitting it, fixed by adding swap rather than upgrading instance size,
  since this is a free-tier assessment deployment, not a production
  capacity-planning exercise.

- No parallel/concurrent GitHub Actions jobs deploying to the server — the
  same low-RAM t2/t3.micro constraint that motivated the swap file also
  ruled out letting multiple workflow runs touch the server at once: two
  simultaneous npm ci/npm run build processes on 1 vCPU/1GB RAM thrashed
  the box into swap and blew past the SSH command timeout. Fixed with a
  concurrency group (cancel-in-progress: true) in deploy.yml so a new run
  cancels an in-flight one instead of racing it — a direct consequence of
  the server's resource ceiling, not a general CI best practice applied
  for its own sake.

- pm2 startup needed sudo, which deploy doesn't have by password —
  enabling PM2 to auto-restart the app on server reboot requires running
  the command pm2 startup prints with sudo (it installs a systemd
  service). Since deploy has no password (adduser --disabled-password),
  running that as deploy directly hit the same "sudo: Authentication
  failed" wall as every other sudo attempt from that account. Resolved by
  extending deploy's scoped sudo access to cover this step too, rather
  than doing PM2's reboot-persistence setup as ubuntu/root instead.

======================================================================

TRADE-OFFS IN FIX IMPLEMENTATIONS

- Rate limiting and clickjacking/security headers were fixed at the Nginx
  layer, not in application code. This keeps the size of the actual code
  change surface small (zero, for these two), works even independent of
  the Node process's health, and doesn't require an app rebuild/redeploy to
  take effect — just an Nginx reload. The trade-off: Nginx's
  limit_req_zone is in-memory and per-instance, so it wouldn't share
  rate-limit state across multiple app instances behind a load balancer.
  Acceptable for this single-VPS deployment; would need a shared store
  (e.g. Redis) if this ever scaled horizontally.

- The HTML-injection-into-email fix has no Nginx-level option at all —
  Nginx has no visibility into the Node process's own SendGrid API call, so
  this one genuinely requires an application-code change (escaping user
  input before interpolating it into the email template in
  app/api/sendgrid/route.ts). This is intentionally the one fix still
  pending, held back pending an explicit decision to start modifying
  application code rather than infrastructure config.

- Port 22 kept open — covered above, repeated here because it's as much a
  fix-implementation trade-off as a setup decision: it's a deliberate,
  documented deviation from the assessment's literal wording, not an
  oversight.

- Automated PoC evidence vs. manual screenshots — UFW status, PM2 list,
  Nginx config, and the SSL certificate are all captured automatically as
  text by the CI pipeline on every run (reports/server-evidence/*.txt),
  which is more reproducible and current than a one-off manual screenshot
  would be. The one exception is the browser padlock/HTTPS screenshot,
  which cannot be automated at all — no CI tool has access to actual
  browser chrome (the address bar), so that one piece of evidence stays
  manual by necessity.
