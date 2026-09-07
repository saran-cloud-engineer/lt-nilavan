# Deployment Guide — lt-nilavan

> **Status: runbook.** Follow top to bottom. As you run each command against the
> real EC2 instance, paste in the actual output where useful (the assessment wants
> "every command you ran"), and take the marked screenshots into `screenshots/`.

## 0. Prerequisites (done)
- [x] EC2 instance launched (Ubuntu LTS) with `scripts/ec2-user-data.sh` as User Data
- [x] Security Group: inbound 22, 80, 443 (22 kept open permanently — see trade-off note below)
- [ ] Domain name pointed at the instance's IP (needed before the Certbot step)

## 1. Verify first-boot (user-data) completed
```bash
ssh -i <key.pem> ubuntu@<public-ip> "tail -50 /var/log/user-data.log"
ssh -i <key.pem> deploy@<public-ip> "source ~/.nvm/nvm.sh && node -v && pm2 -v && nginx -v"
```
Confirms nginx, UFW, the non-root `deploy` user, Node 18, and PM2 are already in
place from `ec2-user-data.sh`.

📸 Screenshot: `sudo ufw status verbose` output → `screenshots/ufw-status.png`

## 2. SSH hardening (custom port, key-only auth — 22 kept open by decision)
```bash
scp -i <key.pem> scripts/01-server-hardening.sh ubuntu@<public-ip>:~/
ssh -i <key.pem> ubuntu@<public-ip>
sudo SSH_PORT=2222 ./01-server-hardening.sh
```
**Checkpoint — verify in a NEW terminal before closing the original session:**
```bash
ssh -p 22 -i <key.pem> deploy@<public-ip>
ssh -p 2222 -i <key.pem> deploy@<public-ip>
```
Add inbound TCP `2222` to the EC2 Security Group (keep `22` too — deliberate
trade-off, see below).

## 3. Deploy the app and run it under PM2
Create `/home/deploy/lt-nilavan/.env` first (see `PREREQUISITES.md` — two vars,
confirmed from `app/api/sendgrid/route.ts`):
```
SENDGRID_API_KEY=<your SendGrid API key>
SENDGRID_TO_EMAIL=<a verified sender in your SendGrid account>
```
Then:
```bash
REPO_URL=https://github.com/saran-cloud-engineer/lt-nilavan.git \
APP_DIR=/home/deploy/lt-nilavan \
BRANCH=live \
./scripts/02-app-setup.sh
```
Update `BRANCH` to `security-fixes` once the fixes are committed and pushed there.

📸 Screenshot: `pm2 list` output → `screenshots/pm2-list.png`

## 4. Configure Nginx as a reverse proxy
```bash
sudo cp scripts/nginx-lt-nilavan.conf /etc/nginx/sites-available/lt-nilavan
sudo sed -i 's/REPLACE_WITH_DOMAIN/<your-domain>/' /etc/nginx/sites-available/lt-nilavan
sudo ln -s /etc/nginx/sites-available/lt-nilavan /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```
This also blocks public access to `.git` and `.env` per the assessment requirement.

📸 Screenshot: contents of `/etc/nginx/sites-available/lt-nilavan` → `screenshots/nginx-config.png`

## 5. Obtain SSL certificate (Let's Encrypt / Certbot) and enforce HTTPS
```bash
sudo certbot --nginx -d <your-domain> --redirect -m <your-email> --agree-tos -n
```
`--redirect` makes certbot add the HTTP→HTTPS redirect automatically. (`certbot`
and the nginx plugin are already installed via `ec2-user-data.sh`.)

📸 Screenshots:
- `sudo certbot certificates` output → `screenshots/ssl-certificate.png`
- Browser padlock / HTTPS working → `screenshots/https-browser.png`

## 6. Verify auto-renewal
```bash
sudo certbot renew --dry-run
```

## 7. Confirm `.git` is blocked
```bash
curl -I https://<your-domain>/.git/config
# Expect: 404 (not 200)
```

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
