#!/usr/bin/env bash
# Enable legacy token-exchange V1 on both Keycloak CRs (standard image, no optimized build).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "${ROOT}/scripts/lib/site-b-remote.sh" ]] && source "${ROOT}/scripts/lib/site-b-remote.sh" || true

echo "=== Site A: apply Keycloak CR (token-exchange + FGAP v1) ==="
oc apply -f "${ROOT}/manifests/site-a/keycloak.yaml"
oc -n rhbk-mc wait --for=condition=Ready keycloak/keycloak --timeout=600s

if [[ -f "${ROOT}/secrets/site-b-ssh.env" ]]; then
  echo "=== Site B: copy manifest and apply on Windows CRC ==="
  site_b_load_env
  REMOTE_YAML="keycloak-b-cr.yaml"
  SSHPASS="${SITE_B_SSH_PASSWORD}" sshpass -e scp \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${ROOT}/manifests/site-b/keycloak.yaml" \
    "${SITE_B_SSH_USER}@${SITE_B_SSH_HOST}:${REMOTE_YAML}"
  site_b_ssh oc apply -f "${REMOTE_YAML}"
  site_b_ssh oc -n rhbk-mc wait --for=condition=Ready keycloak/keycloak-b --timeout=600s
else
  echo "WARN  secrets/site-b-ssh.env missing — apply manifests/site-b/keycloak.yaml on Windows manually"
fi

echo "=== Realm clients + V1 FGAP hook (setup-realm) ==="
cd "${ROOT}/apps/poc-spa" && npm run setup-realm

echo "=== V1 smoke test ==="
bash "${ROOT}/scripts/verify-token-exchange-v1.sh"
