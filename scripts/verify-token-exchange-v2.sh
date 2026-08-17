#!/usr/bin/env bash
# Standard Token Exchange V2 (RFC 8693) smoke test on poc-realm.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/oidc-common.sh"

REQUESTER_ID="${REQUESTER_ID:-poc-exchange-requester}"
REQUESTER_SECRET="${REQUESTER_SECRET:-poc-exchange-requester-secret}"
TARGET_ID="${TARGET_ID:-poc-exchange-target}"
# Avoid shell USERNAME/PASSWORD (e.g. Linux login) — use OIDC_* overrides.
OIDC_USERNAME="${OIDC_USERNAME:-alice}"
OIDC_PASSWORD="${OIDC_PASSWORD:-alice}"

echo "=== Token exchange V2 (${REALM}) ==="
oidc_check_discovery

echo "Step 1: obtain subject token (password grant on ${REQUESTER_ID})..."
SUBJECT_JSON=$(oidc_password_token "${REQUESTER_ID}" "${REQUESTER_SECRET}" "${OIDC_USERNAME}" "${OIDC_PASSWORD}")
SUBJECT_TOKEN=$(echo "${SUBJECT_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")
if [[ -z "${SUBJECT_TOKEN}" ]]; then
  echo "FAIL: no access_token from password grant" >&2
  echo "${SUBJECT_JSON}" >&2
  exit 1
fi
oidc_assert_jwt_issuer "${SUBJECT_TOKEN}"
echo "PASS  subject token issued"

echo "Step 2: standard token exchange (audience=${TARGET_ID})..."
EXCHANGE_JSON=$(oidc_curl -X POST "${TOKEN_URL}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=${REQUESTER_ID}" \
  -d "client_secret=${REQUESTER_SECRET}" \
  -d "subject_token=${SUBJECT_TOKEN}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${TARGET_ID}")

EXCHANGED=$(echo "${EXCHANGE_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")
if [[ -z "${EXCHANGED}" ]]; then
  echo "FAIL: token exchange did not return access_token" >&2
  echo "${EXCHANGE_JSON}" >&2
  exit 1
fi

echo "${EXCHANGED}" | oidc_decode_jwt_payload | python3 -c "
import json, sys
p = json.load(sys.stdin)
iss = p.get('iss', '')
want = '${ISSUER}'
if iss != want:
    raise SystemExit(f'issuer mismatch: {iss}')
azp = p.get('azp', '')
if azp != '${REQUESTER_ID}':
    raise SystemExit(f'unexpected azp: {azp}')
aud = p.get('aud', [])
if isinstance(aud, str):
    aud = [aud]
if '${TARGET_ID}' not in aud:
    raise SystemExit(f'audience missing ${TARGET_ID}: {aud}')
print('PASS  exchanged token issuer/azp/aud OK')
print('      sub=' + str(p.get('sub', '')))
print('      aud=' + str(aud))
"

echo "=== Token exchange V2 OK ==="
