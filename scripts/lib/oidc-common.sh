#!/usr/bin/env bash
# Shared OIDC test helpers for rhbk-mc lab scripts.
set -euo pipefail

AUTH_URL="${AUTH_URL:-https://auth.lan.local:8443}"
REALM="${REALM:-poc-realm}"
ISSUER="${ISSUER:-${AUTH_URL}/realms/${REALM}}"
TOKEN_URL="${TOKEN_URL:-${ISSUER}/protocol/openid-connect/token}"
DISCOVERY_URL="${DISCOVERY_URL:-${ISSUER}/.well-known/openid-configuration}"
CURL_TLS="${CURL_TLS:--sk}"

oidc_curl() {
  curl ${CURL_TLS} --max-time "${CURL_TIMEOUT:-15}" "$@"
}

oidc_check_discovery() {
  oidc_curl "${DISCOVERY_URL}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('issuer') == '${ISSUER}', d.get('issuer')
print('discovery_ok issuer=' + d['issuer'])
"
}

oidc_password_token() {
  local client_id="$1" client_secret="$2" username="$3" password="$4"
  oidc_curl -X POST "${TOKEN_URL}" \
    -d "grant_type=password" \
    -d "client_id=${client_id}" \
    -d "client_secret=${client_secret}" \
    -d "username=${username}" \
    -d "password=${password}" \
    -d "scope=openid"
}

oidc_decode_jwt_payload() {
  python3 -c "
import json, sys, base64
tok = sys.stdin.read().strip()
payload = tok.split('.')[1]
payload += '=' * (-len(payload) % 4)
print(base64.urlsafe_b64decode(payload).decode())
"
}

oidc_assert_jwt_issuer() {
  local token="$1"
  echo "${token}" | oidc_decode_jwt_payload | python3 -c "
import json, sys
p = json.load(sys.stdin)
iss = p.get('iss', '')
want = '${ISSUER}'
if iss != want:
    raise SystemExit(f'issuer mismatch: {iss} != {want}')
print('jwt_issuer_ok')
"
}
