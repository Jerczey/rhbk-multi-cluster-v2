#!/usr/bin/env bash
set -euo pipefail
echo "=== /lb-check ==="
curl -sk https://auth.lan.local:8443/lb-check; echo " (auth.lan.local HAProxy)"
if curl -sk --max-time 5 --resolve auth.lan.local:443:192.168.0.102 \
    https://auth.lan.local/lb-check 2>/dev/null | grep -q UP; then
  echo "UP (site-b Windows route auth.lan.local)"
else
  echo "WARN site-b: apply manifests/site-b/keycloak.yaml on Windows (auth.lan.local)"
fi
echo "=== Keycloak CRs (Linux CRC) ==="
oc get keycloak -n rhbk-mc -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status 2>/dev/null || true
oc get route -n rhbk-mc -o custom-columns=NAME:.metadata.name,HOST:.spec.host 2>/dev/null || true
echo "=== OIDC issuer ==="
curl -sk "https://auth.lan.local:8443/realms/poc-realm/.well-known/openid-configuration" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); iss=r.get('issuer',''); print(iss); assert iss=='https://auth.lan.local:8443/realms/poc-realm', iss"
echo "=== Postgres replication ==="
podman exec pg-primary-site-a psql -U keycloak -d keycloak -c \
  "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
echo "=== SPA (optional) ==="
if curl -sk --max-time 3 https://auth.lan.local:8444/api/lb-check 2>/dev/null | grep -q UP; then
  echo "UP (https://auth.lan.local:8444/api/lb-check)"
elif curl -s --max-time 3 http://127.0.0.1:8080/api/lb-check 2>/dev/null | grep -q UP; then
  echo "UP (http://127.0.0.1:8080/api/lb-check)"
else
  echo "SPA not running (start: cd apps/poc-spa && npm start)"
fi
echo "OK — shared auth URL and multi-cluster DB look healthy"
