#!/usr/bin/env bash
# 01-server-hardening.sh
#
# Run as root (or sudo) after confirming user-data finished (see
# /var/log/user-data.log) and you can already log in as "deploy".
#
# This adds a custom SSH port ALONGSIDE port 22 (kept open deliberately —
# see WRITEUP.md trade-off note) and enforces key-only auth on both.
#
# Usage:
#   sudo SSH_PORT=2222 ./01-server-hardening.sh
#
# IMPORTANT: Before disabling password auth, confirm you can already log in
# with your SSH key on BOTH ports from a second terminal. Do not close your
# original session until you've verified this.

set -euo pipefail

SSH_PORT="${SSH_PORT:-2222}"

if [[ $EUID -ne 0 ]]; then
  echo "Run this as root (sudo)." >&2
  exit 1
fi

echo "==> Confirming UFW allows 22, ${SSH_PORT}, 80, 443 (22 kept open by request)"
apt-get update -y
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH (kept open alongside custom port)'
ufw allow "${SSH_PORT}/tcp" comment 'SSH (custom port)'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
ufw status verbose

echo "==> Hardening sshd_config (listen on 22 AND ${SSH_PORT}, key-only auth, no root login)"
SSHD_CONFIG=/etc/ssh/sshd_config
cp "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.$(date +%s)"

# Remove any existing Port lines, then add both explicitly (sshd supports
# multiple Port directives — it listens on all of them).
sed -i -E '/^[#[:space:]]*Port[[:space:]]/d' "${SSHD_CONFIG}"
{
  echo "Port 22"
  echo "Port ${SSH_PORT}"
} >> "${SSHD_CONFIG}"

set_directive() {
  local key="$1" value="$2"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]" "${SSHD_CONFIG}"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" "${SSHD_CONFIG}"
  else
    echo "${key} ${value}" >> "${SSHD_CONFIG}"
  fi
}

set_directive PermitRootLogin "no"
set_directive PasswordAuthentication "no"
set_directive PubkeyAuthentication "yes"
set_directive ChallengeResponseAuthentication "no"
set_directive UsePAM "yes"

sshd -t   # validate config before restarting — fails loudly if syntax is broken
echo "    sshd config OK. Restarting sshd..."
systemctl restart sshd

cat <<EOF

==> Done. NEXT STEPS (do these before closing this session):
1. In a NEW terminal, confirm you can connect on BOTH ports:
     ssh -p 22 -i <your-key.pem> deploy@<server-ip>
     ssh -p ${SSH_PORT} -i <your-key.pem> deploy@<server-ip>
2. Confirm the EC2 Security Group allows inbound TCP 22 AND ${SSH_PORT}.
3. Only after both succeed should you close this original session.

Note: port 22 is being kept open per your own decision, not the assessment's
strict reading of "change the default SSH port" — password auth is still fully
disabled on both ports (the actual security-relevant part), but note this
trade-off explicitly in WRITEUP.md/SECURITY_REPORT.md so it reads as a
deliberate choice, not an oversight.
EOF
