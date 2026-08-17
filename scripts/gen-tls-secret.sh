#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/secrets"
mkdir -p "${OUT_DIR}"

PRIMARY_HOST=""
if [[ -f "${ROOT}/secrets/postgres.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/secrets/postgres.env"
  PRIMARY_HOST="${PRIMARY_HOST:-}"
fi
if [[ -z "${PRIMARY_HOST}" ]]; then
  PRIMARY_HOST="$(hostname -I | awk '{print $1}')"
fi
if [[ -z "${PRIMARY_HOST}" ]]; then
  PRIMARY_HOST="192.168.0.114"
fi

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${OUT_DIR}/tls.key" -out "${OUT_DIR}/tls.crt" \
  -subj "/CN=auth.lan.local" \
  -addext "subjectAltName=DNS:auth.lan.local,DNS:keycloak-a.apps-crc.testing,DNS:keycloak-b.apps-crc.testing,DNS:keycloak.apps-crc.testing,DNS:localhost,IP:${PRIMARY_HOST},IP:127.0.0.1"

echo "Wrote ${OUT_DIR}/tls.crt and ${OUT_DIR}/tls.key (SAN IP: ${PRIMARY_HOST})"
