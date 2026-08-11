#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=kc-haproxy-lb
LISTEN_HOST="$(hostname -I | awk '{print $1}')"
if [[ -f "${ROOT}/secrets/postgres.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/secrets/postgres.env"
  LISTEN_HOST="${PRIMARY_HOST:-$LISTEN_HOST}"
fi

if [[ ! -f "${ROOT}/secrets/tls.crt" ]]; then
  bash "${ROOT}/scripts/gen-tls-secret.sh"
fi
cat "${ROOT}/secrets/tls.crt" "${ROOT}/secrets/tls.key" > "${ROOT}/secrets/keycloak.pem"

podman rm -f "${NAME}" >/dev/null 2>&1 || true
# Host network: CRC router is on 127.0.0.1:443; pasta hairpin to LAN IP fails from bridge netns
podman run -d --name "${NAME}" --restart=unless-stopped \
  --network=host \
  -v "${ROOT}/lb/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:Z" \
  -v "${ROOT}/secrets/keycloak.pem:/etc/haproxy/certs/keycloak.pem:Z,ro" \
  registry.access.redhat.com/hi/haproxy:3

echo "HAProxy listening on https://${LISTEN_HOST}:8443"
echo "Test: curl -sk https://auth.lan.local:8443/lb-check"
