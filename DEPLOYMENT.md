# Deployment Guide — lt-nilavan

> **Status: living document.** Reflects everything actually done so far, in the
> order it happened, including the problems hit and how they were fixed. Keep
> updating this as more steps happen — don't let it drift from reality.

## 0. Prerequisites (done)
- [x] EC2 instance launched (Ubuntu LTS) with `scripts/ec2-user-data.sh` as User Data
- [x] Security Group: inbound 22, 2222, 80, 443 (22 kept open permanently — see trade-off note below)
- [x] Domain: `nilavan-v1.cloudworkspace.fun`, A record → `13.205.51.146`
- [x] Public IP: `13.205.51.146`

## 1. Verify first-boot (user-data) completed
```bash
ssh -i nilavan.pem ubuntu@13.205.51.146 "tail -50 /var/log/user-data.log"
ssh -i nilavan.pem deploy@13.205.51.146 "source ~/.nvm/nvm.sh && node -v && pm2 -v && nginx -v"
```
Confirms nginx, UFW, the non-root `deploy` user, Node 18, and PM2 are already in
place from `ec2-user-data.sh`.

📸 Screenshot: `sudo ufw status verbose` output → `screenshots/ufw-status.png`
(also captured automatically as text by the CI pipeline — see Section 8)

**Known issue hit here**: `pm2 -v` initially failed with `spawn ... EACCES`. Root
cause was corrupted PM2 daemon state from the very first invocation, not a real
permissions problem (file was already `755`, correctly owned). Fixed with:
```bash
pm2 kill 2>/dev/null
rm -rf ~/.pm2
pm2 list   # forces a clean daemon respawn
```

## 2. SSH hardening (custom port, key-only auth — 22 kept open by decision)
```bash
scp -i nilavan.pem scripts/01-server-hardening.sh ubuntu@13.205.51.146:~/
ssh -i nilavan.pem ubuntu@13.205.51.146
chmod +x ~/01-server-hardening.sh
sudo SSH_PORT=2222 ~/01-server-hardening.sh
```
**Checkpoint — verify in a NEW terminal before closing the original session:**
```bash
ssh -p 22 -i nilavan.pem ubuntu@13.205.51.146
ssh -p 2222 -i nilavan.pem ubuntu@13.205.51.146
```
Add inbound TCP `2222` to the EC2 Security Group (keep `22` too — deliberate
trade-off, see below).

Confirmed password auth is actually rejected:
```bash
ssh -p 2222 -o PreferredAuthentications=password -o PubkeyAuthentication=no ubuntu@13.205.51.146
# -> Permission denied (publickey), not a password prompt
```

**Known issue hit here**: right after the hardening script ran, `ssh -p 2222`
briefly returned "Connection refused". Self-resolved within ~15s (transient —
either the Security Group rule or sshd needed a moment to fully apply). If this
happens, wait and retry before assuming something's actually broken.

## 3. Deploy the app and run it under PM2
Create `/home/deploy/lt-nilavan/.env` first (see `PREREQUISITES.md` — two vars,
confirmed from `app/api/sendgrid/route.ts`):
```
SENDGRID_API_KEY=<your SendGrid API key>
SENDGRID_TO_EMAIL=<a verified sender in your SendGrid account>
```
Then (as `deploy`):
```bash
mv ~/lt-nilavan/.env ~/env-backup   # if .env already exists in an empty-ish target dir
git clone --branch live https://github.com/saran-cloud-engineer/lt-nilavan.git ~/lt-nilavan
mv ~/env-backup ~/lt-nilavan/.env
cd ~/lt-nilavan
npm ci
npm run build
pm2 start npm --name "lt-nilavan" -- start
pm2 save
```

**Known issue hit here — `npm ci` got OOM-killed** (`Killed`, then `next: not
found`). Root cause: `t2/t3.micro` only has 1GB RAM, not enough for this
project's dependency tree (Radix UI, framer-motion, recharts, etc.). Fixed by
adding 2GB swap (as `ubuntu`, needs root):
```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```
Then clean up the partial install and retry: `rm -rf node_modules && npm ci`.

📸 Screenshot: `pm2 list` output → `screenshots/pm2-list.png`
(also captured automatically as text by the CI pipeline — see Section 8)

## 4. Configure Nginx as a reverse proxy
```bash
sudo cp scripts/nginx-lt-nilavan.conf /etc/nginx/sites-available/lt-nilavan.conf
sudo ln -sf /etc/nginx/sites-available/lt-nilavan.conf /etc/nginx/sites-enabled/lt-nilavan.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```
(Note: the file is `lt-nilavan.conf` with the `.conf` extension — an earlier
version of this doc was missing that and referenced a non-existent path.)

This also blocks public access to `.git` and `.env` per the assessment requirement.

📸 Screenshot: contents of `/etc/nginx/sites-available/lt-nilavan.conf` → `screenshots/nginx-config.png`
(also captured automatically as text by the CI pipeline — see Section 8)

## 5. Obtain SSL certificate (Let's Encrypt / Certbot) and enforce HTTPS
```bash
sudo certbot --nginx -d nilavan-v1.cloudworkspace.fun --redirect -m <your-email> --agree-tos -n
```
`--redirect` makes certbot add the HTTP→HTTPS redirect automatically. (`certbot`
and the nginx plugin are already installed via `ec2-user-data.sh`.) Certbot
rewrites `sites-available/lt-nilavan.conf` in place, adding the `listen 443 ssl`
block and cert paths directly into the same server block we control.

📸 Screenshots:
- `sudo certbot certificates` output → `screenshots/ssl-certificate.png`
  (also captured automatically as text by the CI pipeline — see Section 8)
- Browser padlock / HTTPS working → `screenshots/https-browser.png`
  (**manual only** — no CI tool can capture browser chrome/address bar)

## 6. Verify auto-renewal
```bash
sudo certbot renew --dry-run
```

## 7. Confirm `.git` is blocked
```bash
curl -I https://nilavan-v1.cloudworkspace.fun/.git/config
# Confirmed: 404
```

## 8. CI/CD pipeline (`.github/workflows/deploy.yml`)
One consolidated GitHub Actions workflow, triggered on every push (any branch)
plus manual `workflow_dispatch`. Four jobs:

- **`deploy`** — `npm ci` + `npm run build` (fails fast before touching the
  server), then SSHes in via `appleboy/ssh-action`, pulls the pushed branch,
  rebuilds, `pm2 restart lt-nilavan`.
- **`zap-scan`** — runs OWASP ZAP's baseline scan directly via Docker (not the
  `zaproxy/action-baseline` action — its own internal artifact-upload step is
  broken against the current Actions backend: `"Create Artifact Container
  failed: the artifact name zap_scan is not valid"`. Worked around by running
  the same scan command ourselves and uploading the report with
  `actions/upload-artifact@v4` instead). Report saved as the `zap-report` artifact.
- **`server-evidence`** — SSHes in and captures `ufw status`, `pm2 list`,
  the Nginx config, and `certbot certificates` as text files, uploaded as the
  `server-evidence` artifact. This is the automated stand-in for four of the
  five required screenshots (text, not images — see Section 5's note on the
  one screenshot that can't be automated).
- **`live-poc-tests`** — runs the non-destructive PoCs (`.git` block check,
  clickjacking-header check) on every push. The two PoCs that **send real
  emails** (spam-flood, HTML-injection) are gated behind `if: github.event_name
  == 'workflow_dispatch'` so routine pushes don't burn SendGrid quota or spam
  the inbox — trigger them manually via the Actions tab's "Run workflow"
  button when you want that evidence.

**Required repo secrets** (Settings → Secrets and variables → Actions):
`SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_PRIVATE_KEY`, `APP_DIR` — see
`PREREQUISITES.md` for how these were generated (a **dedicated** deploy keypair,
never the AWS admin `.pem`).

**Required one-time server-side prerequisite** for the `server-evidence` job:
`deploy` has no password, so `sudo ufw status`/`sudo certbot certificates` over
SSH need narrowly-scoped passwordless sudo (see `PREREQUISITES.md` §4b).

**Known issues hit and fixed in this pipeline:**
- `appleboy/scp-action` copies runner → server, not server → runner (wrong
  direction for fetching evidence) — failed with `tar: empty archive`. Replaced
  with plain `ssh host "command" > local-file.txt` redirects.
- The evidence-capture SSH commands ran in a non-interactive shell that doesn't
  source `~/.bashrc`, so `pm2` wasn't on `PATH` (`pm2: command not found`).
  Fixed by explicitly sourcing nvm first: `export NVM_DIR="$HOME/.nvm"; source
  "$NVM_DIR/nvm.sh"; pm2 list`.
- Nginx config path in the evidence job was wrong (`lt-nilavan` instead of
  `lt-nilavan.conf`), same issue as Section 4 above.
- **Manual `workflow_dispatch` didn't show a "Run workflow" button** — GitHub
  only shows that button for workflows that exist on the repo's **default
  branch**. The workflow lived only on `fixed_code`/`fix_code_0`; fixed by also
  committing `.github/workflows/deploy.yml` onto `live` (the default branch),
  without touching `live`'s actual app code.
- **Overlapping deploys thrashed the small instance** — a push and a manual
  dispatch running `npm ci`/`npm run build` at the same time on a 1-vCPU/1GB
  box blew past the 10-minute SSH command timeout. Fixed with a `concurrency`
  group (`cancel-in-progress: true`) so only one run touches the server at a time.

## 9. Nginx-level vulnerability fixes applied
Two of the required fixes were done at the Nginx layer, deliberately without
touching application code (per current project decision — see `WRITEUP.md`):

**Rate limiting** (`scripts/nginx-ratelimit.conf` → `/etc/nginx/conf.d/ratelimit.conf`,
referenced from `scripts/nginx-lt-nilavan.conf`'s `/api/sendgrid` location):
```bash
sudo cp scripts/nginx-ratelimit.conf /etc/nginx/conf.d/ratelimit.conf
sudo cp scripts/nginx-lt-nilavan.conf /etc/nginx/sites-available/lt-nilavan.conf
sudo nginx -t   # MUST be run with sudo — without it, fails to read the
                # Let's Encrypt private key and errors misleadingly
sudo systemctl reload nginx
```
5 requests/minute per IP, `burst=3 nodelay`, `limit_req_status 429`.

**Confirmed working** (live test, 10 rapid requests):
```
request 1 -> HTTP 500   (see SendGrid 500 issue below — separate, pre-existing)
request 2 -> HTTP 500
request 3 -> HTTP 500
request 4 -> HTTP 500
request 5 -> HTTP 429
request 6 -> HTTP 429
...
request 10 -> HTTP 429
```

**Clickjacking + other security headers** (`add_header` in the same site
config): `X-Frame-Options: DENY`, `Content-Security-Policy: frame-ancestors
'none'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`,
`Strict-Transport-Security`.

**Still open / not yet fixed:**
- **HTML-injection into the email body** — cannot be fixed at Nginx level at
  all (Nginx has no visibility into the Node process's SendGrid API call).
  Requires an app-code change to `app/api/sendgrid/route.ts` (escape user
  input before interpolating into the HTML template). Not yet applied.
- **SendGrid `500` errors** — the rate-limit test above shows the app itself
  erroring on every request, before rate-limiting even matters. Under
  investigation via `pm2 logs lt-nilavan --lines 50 --nostream` — likely an
  invalid/expired `SENDGRID_API_KEY`, an unverified `SENDGRID_TO_EMAIL` sender,
  or exhausted daily quota from repeated PoC testing.

## Design decisions & trade-offs (for WRITEUP.md)
- **Port 22 kept open alongside the custom port 2222** — deviates from the
  assessment's literal "change the default SSH port" wording. Chosen deliberately
  for operational fallback access. The actual security-relevant control (key-only
  auth, no password login, no root login) is enforced identically on **both**
  ports, so the risk this trade-off reintroduces is limited to automated
  port-22 login *attempts* (which still fail — no password auth), not successful
  unauthorized access.
- **Non-root `deploy` user + PM2** instead of running as root: containment — any
  app-level compromise stays scoped to a low-privilege account.
- **UFW default-deny** with only the required ports open; the Next.js process
  itself only listens on `127.0.0.1:3000`, never exposed directly.
- **Certbot's `--nginx` plugin** over a manual cert + cron renewal: fewer moving
  parts, renewal handled by a systemd timer certbot installs automatically.
- **Most setup automated via EC2 user-data** (`ec2-user-data.sh`) rather than
  fully manual: packages, UFW base rules, the `deploy` user, and Node/PM2 install
  all happen at first boot. The SSH-port/password-auth change is the one
  deliberately left manual, since it's the one step that can lock you out if
  something's wrong — worth verifying interactively rather than trusting blind.
- **Nginx-level fixes over code-level, where possible** — rate limiting and
  security headers were implemented purely in Nginx config, not app code,
  keeping the "what changed" surface small and reviewable. The HTML-injection
  fix has no such option — it genuinely requires a code change.
- **In-memory/Nginx rate limiting over a distributed store (Redis, etc.)** —
  accepted as fine for a single-instance VPS deployment; would need revisiting
  if this ever ran across multiple app instances behind a load balancer.
