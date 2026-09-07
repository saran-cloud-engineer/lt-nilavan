#!/usr/bin/env bash
# 02-app-setup.sh
#
# Run as the non-root "deploy" user (never root) after 01-server-hardening.sh
# has been verified. nvm/Node/PM2 should already be installed by
# ec2-user-data.sh at first boot — this script checks and installs them only
# if missing (e.g. you're running this on a box that skipped user-data).
#
# Usage:
#   REPO_URL=https://github.com/saran-cloud-engineer/lt-nilavan.git \
#   BRANCH=live \
#   APP_DIR=/home/deploy/lt-nilavan \
#   ./02-app-setup.sh

set -euo pipefail

REPO_URL="${REPO_URL:?Set REPO_URL, e.g. https://github.com/saran-cloud-engineer/lt-nilavan.git}"
APP_DIR="${APP_DIR:-$HOME/lt-nilavan}"
BRANCH="${BRANCH:-live}"
NODE_VERSION="${NODE_VERSION:-18}"

if [[ $EUID -eq 0 ]]; then
  echo "Do not run this as root — the app must run as a non-root user." >&2
  exit 1
fi

export NVM_DIR="$HOME/.nvm"
if [[ ! -d "$NVM_DIR" ]]; then
  echo "==> nvm not found, installing (expected to already exist from user-data)"
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
# shellcheck disable=SC1091
source "$NVM_DIR/nvm.sh"

if ! command -v node &>/dev/null || [[ "$(node -v)" != v${NODE_VERSION}.* ]]; then
  echo "==> Installing Node ${NODE_VERSION}"
  nvm install "${NODE_VERSION}"
  nvm alias default "${NODE_VERSION}"
fi
node -v
npm -v

if ! command -v pm2 &>/dev/null; then
  echo "==> Installing PM2"
  npm install -g pm2
fi

echo "==> Cloning ${REPO_URL} (branch: ${BRANCH}) into ${APP_DIR}"
if [[ -d "${APP_DIR}/.git" ]]; then
  git -C "${APP_DIR}" fetch origin
  git -C "${APP_DIR}" checkout "${BRANCH}"
  git -C "${APP_DIR}" pull origin "${BRANCH}"
else
  git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
fi

cd "${APP_DIR}"
if [[ ! -f .env ]]; then
  echo "!! ${APP_DIR}/.env is missing. Create it now with:"
  echo "   SENDGRID_API_KEY=<your key>"
  echo "   SENDGRID_TO_EMAIL=<a verified sender in SendGrid>"
  echo "   (both confirmed required by app/api/sendgrid/route.ts)"
  exit 1
fi

echo "==> Installing dependencies and building"
npm ci
npm run build

echo "==> Starting under PM2"
pm2 start npm --name "lt-nilavan" -- start
pm2 save

echo "==> Enabling PM2 on reboot"
STARTUP_CMD=$(pm2 startup systemd -u "$(whoami)" --hp "$HOME" | tail -n1)
echo "    Run the following ONCE, as a sudo-capable user, to finish enabling PM2 on boot:"
echo "    ${STARTUP_CMD}"

pm2 list
