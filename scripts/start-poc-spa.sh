#!/usr/bin/env bash
# Start the PoC SPA on Linux Site A (apps/poc-spa).
#
# Default: HTTP :8080 + HTTPS :8444 when lab certs exist. Node accepts the lab
# self-signed Keycloak cert when validating JWTs (protected API / JWKS fetch).
#
#   ./scripts/start-poc-spa.sh
#
# HTTP only (no SPA TLS listener — localhost / debugging; LAN browsers need HTTPS):
#
#   ./scripts/start-poc-spa.sh --http-only
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPA="${ROOT}/apps/poc-spa"
HTTP_ONLY=false
OPEN_FIREWALL=false

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --http-only) HTTP_ONLY=true; shift ;;
    --firewall) OPEN_FIREWALL=true; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ ! -d "${SPA}/node_modules" ]]; then
  echo "Installing poc-spa dependencies..."
  (cd "${SPA}" && npm install)
fi

if [[ -f "${ROOT}/secrets/postgres.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/secrets/postgres.env"
  export PRIMARY_HOST
fi

export NODE_TLS_REJECT_UNAUTHORIZED=0
export AUTH_URL="${AUTH_URL:-https://auth.lan.local:8443}"

if [[ "${HTTP_ONLY}" == true ]]; then
  export SPA_SKIP_HTTPS=1
  echo "=== PoC SPA (HTTP only, no TLS listener on :8444) ==="
  echo "    http://localhost:8080  — Web Crypto OK on localhost only"
else
  if [[ ! -f "${ROOT}/secrets/tls.crt" || ! -f "${ROOT}/secrets/tls.key" ]]; then
    echo "WARN  Missing secrets/tls.crt or tls.key — run: bash ${ROOT}/scripts/gen-tls-secret.sh" >&2
  fi
  echo "=== PoC SPA (lab — Node skips TLS verify for Keycloak JWKS) ==="
  echo "    https://auth.lan.local:8444  — preferred from Windows (accept browser cert once)"
  echo "    http://localhost:8080"
fi

if [[ "${OPEN_FIREWALL}" == true && -x "${ROOT}/scripts/open-lab-firewall.sh" ]]; then
  bash "${ROOT}/scripts/open-lab-firewall.sh" || true
fi

cd "${SPA}"
exec npm start
