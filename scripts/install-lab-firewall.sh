#!/usr/bin/env bash
# Install persistent home-lab firewall rules (survives reboot + re-applies after firewalld).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_NAME="rhbk-lab-firewall.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
OPEN_SCRIPT="${ROOT}/scripts/open-lab-firewall.sh"

if [[ ! -x "${OPEN_SCRIPT}" ]]; then
  chmod +x "${OPEN_SCRIPT}"
fi

echo "=== Applying permanent firewalld rules ==="
bash "${OPEN_SCRIPT}"

echo "=== Installing systemd unit (${UNIT_NAME}) ==="
sudo tee "${UNIT_PATH}" >/dev/null <<EOF
[Unit]
Description=rhbk-mc home lab LAN ports (Postgres 5432, HAProxy 8443, SPA 8444)
After=firewalld.service network-online.target
Wants=firewalld.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=LAN_CIDR=192.168.0.0/24
ExecStart=/bin/bash ${OPEN_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${UNIT_NAME}"
sudo systemctl start "${UNIT_NAME}" || true

echo ""
echo "Installed. Rules re-applied on every boot after firewalld."
echo "Check: sudo systemctl status ${UNIT_NAME}"
echo "      firewall-cmd --permanent --list-rich-rules | grep 5432"
