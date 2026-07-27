#!/usr/bin/env bash
set -euo pipefail
echo "=== /lb-check ==="
curl -sk https://keycloak-a.apps-crc.testing/lb-check; echo " (site-a)"
curl -sk https://keycloak-b.apps-crc.testing/lb-check; echo " (site-b)"
curl -sk https://127.0.0.1:8443/lb-check; echo " (haproxy)"
echo "=== Keycloak CRs ==="
oc get keycloak -n rhbk-mc -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status
echo "=== Postgres replication ==="
podman exec pg-primary-site-a psql -U keycloak -d keycloak -c \
  "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
echo "=== Cross-site realm (OIDC discovery on both sites) ==="
for site in keycloak-a keycloak-b; do
  curl -sk "https://${site}.apps-crc.testing/realms/poc-realm/.well-known/openid-configuration" \
    | python3 -c "import json,sys; r=json.load(sys.stdin); assert 'poc-realm' in r.get('issuer',''), r; print('${site}:', r['issuer'])"
done
echo "OK — multi-cluster v2 PoC verified"
