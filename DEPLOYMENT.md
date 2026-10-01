# Deployment Guide — lt-nilavan

Live: https://nilavan-v1.cloudworkspace.fun/

## 1. Server provisioning

### 1.1 Launch EC2 instance
Ubuntu LTS, `t2/t3.micro` (free tier). Security Group: inbound `22`, `80`, `443` open at launch.

### 1.2 User data (first-boot script)
Pasted into EC2 launch → Advanced details → User data. Runs once as root —
installs nginx/certbot/ufw/git, opens 22/80/443 in UFW, creates the
non-root `deploy` user, installs nvm+Node18+PM2 for `deploy`.
```bash
#!/usr/bin/env bash
set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

apt-get update -y && apt-get upgrade -y
apt-get install -y nginx certbot python3-certbot-nginx ufw git build-essential curl unzip

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
ufw --force enable

if ! id deploy &>/dev/null; then
  adduser --disabled-password --gecos "" deploy
  usermod -aG sudo deploy
fi
mkdir -p /home/deploy/.ssh
cp /home/ubuntu/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

su - deploy -c '
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"; source "$NVM_DIR/nvm.sh"
  nvm install 18; nvm alias default 18
  npm install -g pm2
'
```
SSH port/password login is deliberately **not** touched here — done manually in 1.6 so a lockout can be caught before closing the original session.

### 1.3 Elastic IP
Allocated + associated in EC2 console so the public IP stays fixed across restarts.

### 1.4 Domain
Free domain (`nilavan-v1.cloudworkspace.fun`), A record → Elastic IP. Needed before Certbot (no cert for a bare IP).

### 1.5 First login — verify user-data completed
```bash
ssh -i nilavan.pem ubuntu@13.205.51.146
tail -50 /var/log/user-data.log
```
Switch to the app user and confirm Node/PM2/Nginx are installed:
```bash
sudo su - deploy
source ~/.nvm/nvm.sh
node -v
pm2 -v
nginx -v
```
**Issue hit**: `pm2 -v` failed `EACCES` the first time — corrupted daemon state
from the very first invocation, not a real permissions bug.
**Fix**: `pm2 kill; rm -rf ~/.pm2; pm2 list` (forces a clean daemon respawn).

### 1.6 SSH hardening (custom port, key-only auth)
Back as `ubuntu`:
```bash
exit   # back to ubuntu if still in a deploy shell
scp -i nilavan.pem scripts/01-server-hardening.sh ubuntu@13.205.51.146:~/
ssh -i nilavan.pem ubuntu@13.205.51.146
chmod +x ~/01-server-hardening.sh
sudo SSH_PORT=2222 ~/01-server-hardening.sh
```
This adds port `2222` alongside `22` (kept open as a deliberate fallback),
sets `PasswordAuthentication no` and `PermitRootLogin no`.

**Verify from a NEW terminal before closing the original session:**
```bash
ssh -p 22 -i nilavan.pem ubuntu@13.205.51.146
ssh -p 2222 -i nilavan.pem ubuntu@13.205.51.146
ssh -p 2222 -o PreferredAuthentications=password -o PubkeyAuthentication=no ubuntu@13.205.51.146
# -> Permission denied (publickey), confirms password login is rejected
```

### 1.7 Open the custom port in the EC2 Security Group
UFW alone isn't enough — AWS blocks the port before it even reaches the
server. EC2 console → instance → Security → Security Group → Edit inbound
rules → Add rule → Custom TCP → port `2222` → source `0.0.0.0/0`.

### 1.8 Dedicated deploy keypair (for GitHub Actions)
Never reuse the admin `.pem` for CI — a leaked CI secret should not be able
to fully admin the box.
```bash
ssh-keygen -t ed25519 -f deploy_key -C "github-actions-deploy" -N ""
ssh -p 2222 -i nilavan.pem deploy@13.205.51.146 "cat >> ~/.ssh/authorized_keys" < deploy_key.pub
ssh -p 2222 -i deploy_key deploy@13.205.51.146 "echo ok"   # verify before trusting it
cat deploy_key   # contents go into the GitHub secret, see 7.2
```

### 1.9 Scoped sudo for `deploy`
`deploy` has no password, so plain `sudo` fails. Scoped passwordless sudo
added for exactly the commands CI needs — not full root:
```bash
echo 'deploy ALL=(root) NOPASSWD: /usr/sbin/ufw status verbose, /usr/bin/certbot certificates' | sudo tee /etc/sudoers.d/deploy-readonly
sudo chmod 440 /etc/sudoers.d/deploy-readonly
sudo visudo -c   # must print "no syntax errors"
```

---

## 2. Application deployment

### 2.1 Push source to your own repo (local machine)
```bash
git clone https://github.com/Leadtap/lt-nilavan.git
cd lt-nilavan
git remote add myrepo https://github.com/saran-cloud-engineer/lt-nilavan.git
git push myrepo live:live
```

### 2.2 SSH into the server as `deploy`
```bash
ssh -p 2222 -i nilavan.pem deploy@13.205.51.146
```

### 2.3 Clone the app onto the server
```bash
cd ~
git clone https://github.com/saran-cloud-engineer/lt-nilavan.git ~/lt-nilavan
cd ~/lt-nilavan
```
`git clone` creates `~/lt-nilavan` itself — a separate `mkdir` isn't needed.
**Gotcha hit**: if `.env` is created *before* cloning, `git clone` fails
because the target directory isn't empty. Always clone first, create `.env`
after (see 2.4) — or if `.env` already exists, move it aside, clone, move it back:
```bash
mv ~/lt-nilavan/.env ~/env-backup
git clone https://github.com/saran-cloud-engineer/lt-nilavan.git ~/lt-nilavan
mv ~/env-backup ~/lt-nilavan/.env
```

### 2.4 Create `.env`
```bash
nano ~/lt-nilavan/.env
```
```
SENDGRID_API_KEY=<key>
SENDGRID_TO_EMAIL=<verified sender>
```
(See section 5 for where these values come from.)

### 2.5 Install dependencies and build
```bash
cd ~/lt-nilavan
npm ci
npm run build
```
**Issue hit**: `npm ci` got OOM-killed (`Killed`, then `next: not found`) —
the `t2/t3.micro`'s 1GB RAM isn't enough for this dependency tree.
**Fix** — add 2GB swap (as `ubuntu`, needs root):
```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```
Then retry: `rm -rf node_modules && npm ci && npm run build`.

### 2.6 Start under PM2
```bash
pm2 start npm --name "lt-nilavan" -- start
pm2 startup      # run the sudo command it prints, enables boot persistence
pm2 save         # saves the current process list
```
📸 `pm2 list` → `screenshots/pm2-list.png`

### 2.7 Reboot test (proves auto-restart actually works)
```bash
sudo reboot
# wait ~30-45s, then from your local machine:
ssh -p 2222 -i nilavan.pem deploy@13.205.51.146 "pm2 list"
curl -I https://nilavan-v1.cloudworkspace.fun/
```
Confirmed: app comes back online automatically (fresh PID, 0 restarts) with no manual intervention.

---

## 3. Nginx reverse proxy

### 3.1 Install the site config
```bash
sudo cp scripts/nginx-lt-nilavan.conf /etc/nginx/sites-available/lt-nilavan.conf
sudo ln -sf /etc/nginx/sites-available/lt-nilavan.conf /etc/nginx/sites-enabled/lt-nilavan.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```
Proxies to `127.0.0.1:3000` (the app never listens publicly) and blocks
`.git`/`.env` (returns 404) by default.
📸 config contents → `screenshots/nginx-config.png`

### 3.2 Verify
```bash
curl -I http://nilavan-v1.cloudworkspace.fun/
curl -I https://nilavan-v1.cloudworkspace.fun/.git/config   # -> 404
```
(Also opened the domain in a browser to confirm it loads.)

---

## 4. SSL (Certbot)

### 4.1 Obtain certificate
```bash
sudo certbot --nginx -d nilavan-v1.cloudworkspace.fun --redirect -m <email> --agree-tos -n
```
`--redirect` adds the HTTP→HTTPS redirect automatically. Certbot rewrites
`sites-available/lt-nilavan.conf` in place to add the cert paths.
📸 `screenshots/ssl-certificate.png` + a manual browser padlock screenshot (can't be automated)

### 4.2 Verify
```bash
sudo certbot certificates
sudo certbot renew --dry-run
```

---

## 5. Mail functionality (SendGrid)

### 5.1 API key
SendGrid free-tier account → Settings → API Keys → create one with **Mail Send** permission only.

### 5.2 Sender authentication
`SENDGRID_TO_EMAIL` is used as both `to` and `from` — it must be verified
first, or every send fails `403 Forbidden`.
SendGrid → Settings → Sender Authentication → Verify a Single Sender → fill
in From Email / Reply To / Name / Address → click the confirmation link
SendGrid emails you.

### 5.3 Update `.env` and restart
```bash
nano ~/lt-nilavan/.env
# SENDGRID_API_KEY=<real key>
# SENDGRID_TO_EMAIL=<verified address>
pm2 restart lt-nilavan
```
Confirm:
```bash
curl -X POST https://nilavan-v1.cloudworkspace.fun/api/sendgrid -H "Content-Type: application/json" -d '{"name":"test","email":"x@x.com","phone":"0000000000","message":"debug test"}'
# -> {"success":true}
```

---

## 6. Nginx hardening (rate limit + security headers)

### 6.1 Rate-limit zone
Must be declared in the `http{}` context, not inside a `server{}` block — a separate file:
```bash
sudo cp scripts/nginx-ratelimit.conf /etc/nginx/conf.d/ratelimit.conf
```
5 requests/minute per IP, referenced from the `/api/sendgrid` location block
in the main site config.

### 6.2 Security headers + updated site config
```bash
sudo cp scripts/nginx-lt-nilavan.conf /etc/nginx/sites-available/lt-nilavan.conf
sudo nginx -t   # MUST use sudo — without it, fails to read the Let's Encrypt
                # private key and prints a misleading error
sudo systemctl reload nginx
```
Adds `X-Frame-Options`, CSP, `X-Content-Type-Options`, HSTS via `add_header`.

### 6.3 Verify
```bash
for i in $(seq 1 10); do curl -s -o /dev/null -w "request $i -> HTTP %{http_code}\n" -X POST https://nilavan-v1.cloudworkspace.fun/api/sendgrid -H "Content-Type: application/json" -d '{"name":"test","email":"x@x.com","phone":"0000000000","message":"spam"}'; done

curl -sI https://nilavan-v1.cloudworkspace.fun/ | grep -Ei "x-frame-options|content-security-policy|strict-transport-security|x-content-type-options"
```

---

## 7. CI/CD pipeline

### 7.1 Workflow
One file, `.github/workflows/deploy.yml`, runs on every push (any branch) +
manual `workflow_dispatch`. 4 jobs:
- **deploy** — build, SSH in, pull, rebuild, `pm2 restart`
- **zap-scan** — OWASP ZAP via Docker
- **server-evidence** — SSH captures ufw/pm2/nginx/certbot state as text
- **live-poc-tests** — safe checks every push; the 2 email-sending PoCs only on manual dispatch

### 7.2 Secrets
Repo Settings → Secrets and variables → Actions:
- `SSH_HOST` = `13.205.51.146`
- `SSH_PORT` = `2222`
- `SSH_USER` = `deploy`
- `SSH_PRIVATE_KEY` = contents of `deploy_key` from 1.8
- `APP_DIR` = `/home/deploy/lt-nilavan`

### 7.3 Triggering
```bash
git add .
git commit -m "message"
git push myrepo branch-name:branch-name   # runs automatically
```
Manual (for the 2 email-sending tests): Actions tab → **Run workflow**
(only shows up if the workflow file exists on the repo's **default branch**).

### 7.4 Issues hit and fixed
- Copying evidence server→runner used the wrong-direction tool (`scp-action`
  only goes runner→server) → switched to plain `ssh "cmd" > file`
- ZAP action's own report-upload step was broken → ran ZAP directly via Docker instead
- `pm2: command not found` over SSH (no `.bashrc` loaded in a one-off command) → source nvm inline first
- Two deploys running at once crashed the small server → added `concurrency: cancel-in-progress`
- Manual dispatch button didn't appear → workflow file must exist on the repo's default branch

---

## 8. Final verification checklist
Every item below is a real, runnable command — use these live if asked to prove any part of the setup.

### 8.1 Firewall (UFW)
```bash
sudo ufw status verbose
```
Expect: `Status: active`, default deny incoming, with `22`, `2222`, `80`, `443` listed as `ALLOW IN`. 📸 `screenshots/ufw-status.png`

### 8.2 SSH — both ports reachable, password auth rejected
```bash
ssh -p 22 -i nilavan.pem ubuntu@13.205.51.146 "echo ok"
ssh -p 2222 -i nilavan.pem ubuntu@13.205.51.146 "echo ok"
ssh -p 2222 -o PreferredAuthentications=password -o PubkeyAuthentication=no ubuntu@13.205.51.146
```
Expect: first two print `ok`; third → `Permission denied (publickey)`, never a password prompt.

### 8.3 EC2 Security Group — confirm the custom port is actually open at the AWS level
EC2 console → instance → Security tab → Security Group → Inbound rules.
Expect: rows for `22`, `2222`, `80`, `443`, source `0.0.0.0/0`. (UFW alone isn't enough — this is the layer in front of it.)

### 8.4 PM2 / app process
```bash
pm2 list
```
Expect: `lt-nilavan`, status `online`, user `deploy` (never `root`). 📸 `screenshots/pm2-list.png`

### 8.5 Nginx config + reload
```bash
sudo nginx -t
cat /etc/nginx/sites-available/lt-nilavan.conf
```
Expect: `syntax is ok` / `test is successful`. 📸 `screenshots/nginx-config.png`

### 8.6 Domain / DNS resolves to the right server
```bash
dig +short nilavan-v1.cloudworkspace.fun
# or: nslookup nilavan-v1.cloudworkspace.fun
```
Expect: `13.205.51.146`

### 8.7 HTTP → HTTPS redirect
```bash
curl -I http://nilavan-v1.cloudworkspace.fun/
```
Expect: `301 Moved Permanently` → `Location: https://nilavan-v1.cloudworkspace.fun/`

### 8.8 HTTPS site + SSL certificate
```bash
curl -I https://nilavan-v1.cloudworkspace.fun/
sudo certbot certificates
sudo certbot renew --dry-run
```
Expect: `200 OK`; certificate `VALID`, listing the right domain and expiry date. 📸 `screenshots/ssl-certificate.png` + manual browser padlock screenshot (no CI tool can capture browser chrome)

### 8.9 `.git` / `.env` blocked
```bash
curl -I https://nilavan-v1.cloudworkspace.fun/.git/config
curl -I https://nilavan-v1.cloudworkspace.fun/.env
```
Expect: both → `404 Not Found`

### 8.10 Scoped sudo for `deploy` actually works
```bash
sudo ufw status verbose        # as deploy, no password prompt
sudo certbot certificates      # as deploy, no password prompt
```
Expect: both run without asking for a password (scoped sudoers rule), while anything else (e.g. `sudo reboot`) still correctly asks for one / fails for `deploy`.

### 8.11 Reboot persistence (PM2 auto-restart)
```bash
sudo reboot
# wait ~30-45s
ssh -p 2222 -i nilavan.pem deploy@13.205.51.146 "pm2 list"
curl -I https://nilavan-v1.cloudworkspace.fun/
```
Expect: app `online` with a fresh PID and `0` restarts, site returns `200` — with no manual `pm2 start` needed.

### 8.12 GitHub Actions pipeline
Actions tab → latest run → all 4 jobs green (`deploy`, `zap-scan`, `server-evidence`, `live-poc-tests`). "Run workflow" button available for manual triggers.
