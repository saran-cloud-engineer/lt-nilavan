# Prerequisites / Open Items

## 1. Repo — done
- Own repo: https://github.com/saran-cloud-engineer/lt-nilavan (pushed: `live`)
- Local work branch: `fixed_code` (not yet pushed)

## 2. AWS EC2 — done
- Instance launched with `scripts/ec2-user-data.sh` as User Data
- Admin key: your `.pem` (keep for manual access only — do NOT put in GitHub secrets)
- Public IP: `13.205.51.146`
- SSH: port `22` and `2222` both open, key-only auth (see DEPLOYMENT.md Section 2)

## 3. Domain name — done
- Domain: `nilavan-v1.cloudworkspace.fun`, A record pointing at `13.205.51.146`
- SSL certificate issued via Certbot, valid until 2026-12-06

## 4. GitHub Actions deploy workflow — needs the dedicated deploy key (not done yet)
`.github/workflows/deploy.yml` is written but will fail until these secrets exist.
Do NOT reuse the AWS admin `.pem` for `SSH_PRIVATE_KEY` — generate a separate key:

```bash
# on your local machine
ssh-keygen -t ed25519 -f deploy_key -C "github-actions-deploy" -N ""

# copy the public half onto the server (as deploy, no sudo needed — own authorized_keys)
ssh -p 2222 -i nilavan.pem deploy@13.205.51.146 "cat >> ~/.ssh/authorized_keys" < deploy_key.pub

# verify it works before adding it to GitHub
ssh -p 2222 -i deploy_key deploy@13.205.51.146 "echo ok"
```

Then add these under Repo Settings → Secrets and variables → Actions:
- [ ] `SSH_HOST` = `13.205.51.146` (or the domain)
- [ ] `SSH_PORT` = `2222`
- [ ] `SSH_USER` = `deploy`
- [ ] `SSH_PRIVATE_KEY` = contents of `deploy_key` (the private half, not `deploy_key.pub`)
- [ ] `APP_DIR` = `/home/deploy/lt-nilavan`

## 5. Application secrets (server-side `.env`, never committed)
Confirmed from `app/api/sendgrid/route.ts` — no `.env.example` exists in the repo:
- [ ] `SENDGRID_API_KEY` — SendGrid account → Settings → API Keys
- [ ] `SENDGRID_TO_EMAIL` — used as BOTH `to` and `from`; must be a verified
      single sender (or verified domain) in SendGrid, or sends fail
