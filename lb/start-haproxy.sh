#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=kc-haproxy-lb

if [[ ! -f "${ROOT}/secrets/tls.crt" ]]; then
  bash "${ROOT}/scripts/gen-tls-secret.sh"
fi
cat "${ROOT}/secrets/tls.crt" "${ROOT}/secrets/tls.key" > "${ROOT}/secrets/keycloak.pem"

podman rm -f "${NAME}" >/dev/null 2>&1 || true
podman run -d --name "${NAME}" --restart=unless-stopped \
  -v "${ROOT}/lb/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:Z" \
  -v "${ROOT}/secrets/keycloak.pem:/etc/haproxy/certs/keycloak.pem:Z,ro" \
  -p 8443:8443 \
  docker.io/library/haproxy:2.9

echo "HAProxy listening on https://192.168.0.114:8443"
echo "Test: curl -k https://192.168.0.114:8443/lb-check"
