#!/usr/bin/env bash
# Token exchange V2 under cross-site conditions (TE-1..TE-4).
# Site drop/restore is manual or via env hints — script validates exchange when invoked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CASE="${1:-TE-1}"
echo "=== Token exchange failover case: ${CASE} ==="

wait_lb_up() {
  local i lb
  for i in $(seq 1 12); do
    lb=$(curl -sk --max-time 5 https://auth.lan.local:8443/lb-check 2>/dev/null || true)
    if grep -q UP <<< "${lb}"; then
      return 0
    fi
    sleep 5
  done
  echo "FAIL: lb-check not UP after 60s (last: ${lb:-empty})" >&2
  return 1
}

case "${CASE}" in
  TE-1)
    echo "Both sites should be UP"
    bash "${ROOT}/scripts/verify-token-exchange-v2.sh"
    ;;
  TE-2)
    echo "Expect Site A DOWN, Site B serving /lb-check"
    wait_lb_up
    bash "${ROOT}/scripts/verify-token-exchange-v2.sh"
    ;;
  TE-3)
    echo "Expect Site B DOWN, Site A serving /lb-check"
    if [[ -f "${ROOT}/secrets/site-b-ssh.env" ]]; then
      # shellcheck disable=SC1091
      source "${ROOT}/scripts/lib/site-b-remote.sh"
      echo "Scaling Site B Keycloak to 0 via SSH..."
      site_b_keycloak_scale 0
      sleep 15
    else
      echo "WARN  secrets/site-b-ssh.env missing — drop Site B manually, then press Enter"
      read -r _
    fi
    wait_lb_up
    bash "${ROOT}/scripts/verify-token-exchange-v2.sh"
    ;;
  TE-3-restore)
    # shellcheck disable=SC1091
    source "${ROOT}/scripts/lib/site-b-remote.sh"
    site_b_keycloak_scale 1
    site_b_wait_keycloak_ready 180
    ;;
  TE-4)
    echo "Obtain subject token, drop Site A, then exchange (manual Site A drop between steps)"
    SUBJECT_FILE="${ROOT}/benchmark-results/te4-subject-token.txt"
    mkdir -p "${ROOT}/benchmark-results"
    if [[ ! -f "${SUBJECT_FILE}" ]]; then
      # shellcheck disable=SC1091
      source "${ROOT}/scripts/lib/oidc-common.sh"
      oidc_password_token poc-exchange-requester poc-exchange-requester-secret "${OIDC_USERNAME:-alice}" "${OIDC_PASSWORD:-alice}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" > "${SUBJECT_FILE}"
      echo "Saved subject token to ${SUBJECT_FILE}"
      echo ">>> Now drop Site A, press Enter to continue exchange..."
      read -r _
    fi
    # shellcheck disable=SC1091
    source "${ROOT}/scripts/lib/oidc-common.sh"
    SUBJECT_TOKEN=$(cat "${SUBJECT_FILE}")
    EXCHANGE_JSON=$(oidc_curl -X POST "${TOKEN_URL}" \
      -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
      -d "client_id=poc-exchange-requester" \
      -d "client_secret=poc-exchange-requester-secret" \
      -d "subject_token=${SUBJECT_TOKEN}" \
      -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
      -d "audience=poc-exchange-target")
    echo "${EXCHANGE_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('access_token'); print('PASS TE-4 exchange after Site A drop')"
    ;;
  *)
    echo "Usage: $0 {TE-1|TE-2|TE-3|TE-3-restore|TE-4}" >&2
    exit 1
    ;;
esac
