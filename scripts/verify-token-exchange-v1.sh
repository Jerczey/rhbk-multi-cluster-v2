#!/usr/bin/env bash
# Legacy Token Exchange V1 smoke test (preview/deprecated). Exits 2 if feature disabled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/oidc-common.sh"

SOURCE_ID="${SOURCE_ID:-poc-exchange-source}"
SOURCE_SECRET="${SOURCE_SECRET:-poc-exchange-source-secret}"
REQUESTER_ID="${REQUESTER_ID:-poc-exchange-requester}"
REQUESTER_SECRET="${REQUESTER_SECRET:-poc-exchange-requester-secret}"
TARGET_ID="${TARGET_ID:-poc-exchange-target}"
OIDC_USERNAME="${OIDC_USERNAME:-alice}"
OIDC_PASSWORD="${OIDC_PASSWORD:-alice}"

if command -v oc >/dev/null 2>&1; then
  FEATURES=$(oc -n rhbk-mc get keycloak keycloak -o jsonpath='{.spec.features.enabled[*]}' 2>/dev/null || true)
  if ! grep -q token-exchange <<< "${FEATURES}"; then
    echo "SKIP  Legacy V1: token-exchange preview feature not enabled on Keycloak CR"
    echo "      Apply manifests/lab/keycloak-token-exchange-v1.yaml and wait for rollout"
    exit 2
  fi
fi

echo "=== Token exchange V1 legacy (${REALM}) ==="
echo "WARN  V1 is deprecated in Keycloak 26.7 — migrate to V2 for new integrations"

SUBJECT_JSON=$(oidc_curl -X POST "${TOKEN_URL}" \
  -d "grant_type=password" \
  -d "client_id=${SOURCE_ID}" \
  -d "client_secret=${SOURCE_SECRET}" \
  -d "username=${OIDC_USERNAME}" \
  -d "password=${OIDC_PASSWORD}" \
  -d "scope=openid")
SUBJECT_TOKEN=$(echo "${SUBJECT_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")
if [[ -z "${SUBJECT_TOKEN}" ]]; then
  echo "FAIL: no subject token from ${SOURCE_ID}" >&2
  echo "${SUBJECT_JSON}" >&2
  exit 1
fi

EXCHANGE_JSON=$(oidc_curl -X POST "${TOKEN_URL}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=${REQUESTER_ID}" \
  -d "client_secret=${REQUESTER_SECRET}" \
  -d "subject_token=${SUBJECT_TOKEN}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${TARGET_ID}")

if echo "${EXCHANGE_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('access_token') else 1)"; then
  echo "PASS  legacy V1 exchange returned access_token"
  echo "=== Token exchange V1 OK ==="
else
  echo "FAIL  legacy V1 exchange (often needs FGAP v1 + target client token-exchange permission)" >&2
  echo "${EXCHANGE_JSON}" >&2
  echo "See docs/OIDC-FLOW-TESTS.md § Legacy V1 setup" >&2
  exit 1
fi
