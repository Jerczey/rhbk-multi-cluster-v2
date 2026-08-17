#!/usr/bin/env bash
# Non-browser smoke checks for authorization code flow readiness + failover checklist.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/oidc-common.sh"

PASS=0
FAIL=0
WARN=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  ${name}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  ${name}"
    FAIL=$((FAIL + 1))
  fi
}

warn() {
  echo "WARN  $1"
  WARN=$((WARN + 1))
}

oidc_lb_check() {
  oidc_curl "${AUTH_URL}/lb-check" | grep -q UP
}

oidc_token_endpoint_reachable() {
  local code
  code=$(oidc_curl -o /dev/null -w '%{http_code}' -X POST "${TOKEN_URL}")
  grep -qE '400|401|403|200' <<< "${code}"
}

echo "=== OIDC auth-code preflight (${REALM}) ==="
check "OIDC discovery issuer" oidc_check_discovery
check "HAProxy lb-check" oidc_lb_check
check "Token endpoint reachable" oidc_token_endpoint_reachable

if command -v oc >/dev/null 2>&1; then
  if oc -n rhbk-mc get keycloak keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    echo "PASS  Site A Keycloak CR Ready"
    PASS=$((PASS + 1))
  else
    echo "FAIL  Site A Keycloak CR Ready"
    FAIL=$((FAIL + 1))
  fi
else
  warn "oc not available — skip Keycloak CR check"
fi

if curl -sk --max-time 5 --resolve auth.lan.local:443:192.168.0.102 \
  https://auth.lan.local/lb-check 2>/dev/null | grep -q UP; then
  echo "PASS  Site B route /lb-check"
  PASS=$((PASS + 1))
else
  warn "Site B not UP — cross-site failover drills (AC-4/AC-5) need Windows CRC"
fi

echo ""
echo "=== Manual authorization code matrix (browser) ==="
cat <<'EOF'
| Step | Action | Record pass/fail in docs/OIDC-FLOW-TESTS.md |
|------|--------|---------------------------------------------|
| AC-1 | Login https://auth.lan.local:8444 (alice/alice) | Issuer https://auth.lan.local:8443/realms/poc-realm |
| AC-2 | Refresh token in SPA | New access token, same issuer |
| AC-3 | Call protected API | HTTP 200 from /api/protected/profile |
| AC-4 | Drop Site A; refresh + API again | Still works via Site B |
| AC-5 | Restore A; drop Site B; refresh + API | Still works via Site A |
| AC-6 | Drop both sites | /lb-check 503; refresh/login fail |
| AC-7 | Repeat AC-4; Network tab shows no sticky cookie | HAProxy round-robin, stateless OK |
EOF

echo ""
echo "=== Summary ==="
echo "pass=${PASS} fail=${FAIL} warn=${WARN}"
[[ "${FAIL}" -eq 0 ]]
