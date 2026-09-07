#!/usr/bin/env bash
# EC2 "User data" — paste this into the launch wizard's
# "Advanced details" -> "User data" field (as plain text, not base64;
# the console base64-encodes it for you). Runs once, as root, on first boot.
#
# What this does:
#   - Updates packages
#   - Installs nginx, certbot, ufw, git, and basic build tools
#   - Enables UFW for 22/80/443
#   - Creates the non-root "deploy" user with sudo, copies the launch key's
#     authorized_keys so you can log in as deploy immediately
#   - Installs nvm, Node.js 18, and PM2 for the "deploy" user (not root —
#     the app must never run as root)
#
# Deliberately NOT done here (left for scripts/01-server-hardening.sh, run
# manually afterward): changing the SSH port and disabling password auth.
# That step needs you to verify the new login works BEFORE closing your
# original session — doing it blind in user-data risks a first-boot lockout
# with no easy console recovery. Everything else below is safe/reversible.

set -euo pipefail

exec > >(tee /var/log/user-data.log) 2>&1
echo "=== user-data starting: $(date) ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y nginx certbot python3-certbot-nginx ufw git build-essential curl unzip

echo "=== configuring UFW (22 temporary, 80, 443) ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH (temporary, until custom port is verified)'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

echo "=== creating non-root deploy user ==="
if ! id deploy &>/dev/null; then
  adduser --disabled-password --gecos "" deploy
  usermod -aG sudo deploy
fi

mkdir -p /home/deploy/.ssh
if [[ -f /home/ubuntu/.ssh/authorized_keys ]]; then
  cp /home/ubuntu/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
fi
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys || true
chown -R deploy:deploy /home/deploy/.ssh

echo "=== installing nvm + Node 18 + PM2 for the deploy user ==="
su - deploy -c '
  set -euo pipefail
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  source "$NVM_DIR/nvm.sh"
  nvm install 18
  nvm alias default 18
  npm install -g pm2
'

echo "=== user-data finished: $(date) ==="
echo "Next: SSH in as deploy using the same .pem, verify node/pm2:"
echo "  ssh -i <key.pem> deploy@<server-ip> \"source ~/.nvm/nvm.sh && node -v && pm2 -v\""
echo "Then run scripts/01-server-hardening.sh (SSH port change + key-only auth)."
