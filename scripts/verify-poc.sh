#!/usr/bin/env bash
set -euo pipefail
echo "=== /lb-check ==="
curl -sk https://keycloak-a.apps-crc.testing/lb-check; echo " (site-a)"
if curl -sk --max-time 5 --resolve keycloak-b.apps-crc.testing:443:192.168.0.102 \
    https://keycloak-b.apps-crc.testing/lb-check 2>/dev/null | grep -q UP; then
  echo -n "UP"; echo " (site-b @ 192.168.0.102)"
else
  # Fallback: local hosts may still point site-b at Linux
  curl -sk --max-time 5 https://keycloak-b.apps-crc.testing/lb-check 2>/dev/null || echo -n "DOWN"
  echo " (site-b via local resolver)"
fi
curl -sk https://127.0.0.1:8443/lb-check; echo " (haproxy)"
echo "=== Keycloak CRs (Linux CRC) ==="
oc get keycloak -n rhbk-mc -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status 2>/dev/null || true
echo "=== Postgres replication ==="
podman exec pg-primary-site-a psql -U keycloak -d keycloak -c \
  "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
echo "=== Cross-site realm (OIDC discovery) ==="
curl -sk "https://keycloak-a.apps-crc.testing/realms/poc-realm/.well-known/openid-configuration" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); assert 'poc-realm' in r.get('issuer',''), r; print('keycloak-a:', r['issuer'])"
curl -sk --resolve keycloak-b.apps-crc.testing:443:192.168.0.102 \
  "https://keycloak-b.apps-crc.testing/realms/poc-realm/.well-known/openid-configuration" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); assert 'poc-realm' in r.get('issuer',''), r; print('keycloak-b:', r['issuer'])"
echo "OK — multi-cluster v2 PoC verified"
