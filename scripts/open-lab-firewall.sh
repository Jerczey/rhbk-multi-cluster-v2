#!/usr/bin/env bash
# Open inbound LAN ports on the Linux primary host (Site A) for the PoC.
# Run on Fedora with firewalld active. Safe to re-run (idempotent rich rules).
set -euo pipefail

if ! command -v firewall-cmd >/dev/null 2>&1; then
  echo "firewall-cmd not found — install firewalld or open ports manually." >&2
  exit 1
fi

LAN_CIDR="${LAN_CIDR:-192.168.0.0/24}"
PORTS=(5432 8443 8444 8765)

run_fw() {
  if [[ "${EUID}" -eq 0 ]]; then
    firewall-cmd "$@"
  else
    sudo firewall-cmd "$@"
  fi
}

echo "=== Opening PoC ports for ${LAN_CIDR} on $(firewall-cmd --get-default-zone) ==="

for port in "${PORTS[@]}"; do
  rule="rule family=\"ipv4\" source address=\"${LAN_CIDR}\" port port=\"${port}\" protocol=\"tcp\" accept"
  if run_fw --permanent --query-rich-rule="${rule}" 2>/dev/null; then
    echo "OK    ${port}/tcp already allowed for ${LAN_CIDR}"
  else
    run_fw --permanent --add-rich-rule="${rule}"
    echo "ADD   ${port}/tcp for ${LAN_CIDR}"
  fi
done

run_fw --reload
echo ""
echo "Active rich rules (lab):"
firewall-cmd --list-rich-rules | rg '5432|8443|8444|8765' || true
echo ""
echo "Test from Windows/WSL:  nc -zv 192.168.0.114 5432"
echo "Or PowerShell:          Test-NetConnection 192.168.0.114 -Port 5432"
