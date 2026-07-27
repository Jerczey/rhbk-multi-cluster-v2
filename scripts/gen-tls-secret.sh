#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/secrets"
mkdir -p "${OUT_DIR}"

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${OUT_DIR}/tls.key" -out "${OUT_DIR}/tls.crt" \
  -subj "/CN=keycloak-a.apps-crc.testing" \
  -addext "subjectAltName=DNS:keycloak-a.apps-crc.testing,DNS:keycloak-b.apps-crc.testing,DNS:keycloak.apps-crc.testing,DNS:localhost"

echo "Wrote ${OUT_DIR}/tls.crt and ${OUT_DIR}/tls.key"
