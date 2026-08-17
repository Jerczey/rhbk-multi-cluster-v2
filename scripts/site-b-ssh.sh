#!/usr/bin/env bash
# Thin wrapper: run a command on Windows Site B over SSH.
# Usage:
#   ./scripts/site-b-ssh.sh oc get pods -n rhbk-mc
#   ./scripts/site-b-ssh.sh powershell -Command "Get-Date"
#   ./scripts/site-b-ssh.sh --shell   # interactive (password from secrets/site-b-ssh.env)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/site-b-remote.sh"

if [[ "${1:-}" == "--shell" ]]; then
  site_b_load_env
  export SSHPASS="${SITE_B_SSH_PASSWORD}"
  exec sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${SITE_B_SSH_USER}@${SITE_B_SSH_HOST}"
fi

if [[ "${1:-}" == "oc" ]]; then
  shift
  site_b_oc "$@"
else
  site_b_ssh "$@"
fi
