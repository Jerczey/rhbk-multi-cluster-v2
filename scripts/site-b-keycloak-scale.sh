#!/usr/bin/env bash
# Scale Site B Keycloak on Windows CRC from Linux (uses secrets/site-b-ssh.env).
# Usage: ./scripts/site-b-keycloak-scale.sh 0|1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/site-b-remote.sh"

REPLICAS="${1:?usage: $0 <replicas>}"
echo "=== Site B Keycloak scale -> ${REPLICAS} ==="
site_b_keycloak_scale "${REPLICAS}"
if [[ "${REPLICAS}" != "0" ]]; then
  site_b_wait_keycloak_ready 180
fi
site_b_oc get statefulset "${SITE_B_KEYCLOAK_STS}" -o wide 2>/dev/null || true
