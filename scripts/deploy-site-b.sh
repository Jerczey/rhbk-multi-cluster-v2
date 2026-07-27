#!/usr/bin/env bash
# Deploy Site B (Windows CRC) — run after oc login to the Windows CRC cluster
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=rhbk-mc

# Optional: override hostname for this CRC's apps domain
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo apps-crc.testing)}"
HOSTNAME="keycloak-b.${APPS_DOMAIN}"

oc apply -f "${ROOT}/manifests/operator/subscription.yaml"

echo "Waiting for Keycloak operator CSV..."
for _ in $(seq 1 120); do
  PHASE=$(oc get csv keycloak-operator.v26.7.0 -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "${PHASE}" == "Succeeded" ]] && break
  sleep 5
done
oc get csv keycloak-operator.v26.7.0 -n "${NS}"

if [[ ! -f "${ROOT}/secrets/tls.crt" ]]; then
  bash "${ROOT}/scripts/gen-tls-secret.sh"
fi

oc -n "${NS}" create secret generic keycloak-db-secret \
  --from-literal=username=keycloak \
  --from-literal=password='KeycloakPoC2026!' \
  --dry-run=client -o yaml | oc apply -f -

oc -n "${NS}" create secret tls keycloak-tls-secret \
  --cert="${ROOT}/secrets/tls.crt" \
  --key="${ROOT}/secrets/tls.key" \
  --dry-run=client -o yaml | oc apply -f -

# Patch hostname for this CRC domain
TMP=$(mktemp)
sed "s|hostname: keycloak-b.apps-crc.testing|hostname: ${HOSTNAME}|" \
  "${ROOT}/manifests/site-b/keycloak.yaml" > "${TMP}"
oc apply -f "${TMP}"
rm -f "${TMP}"

echo "Waiting for Keycloak Ready..."
oc -n "${NS}" wait --for=condition=Ready keycloaks.k8s.keycloak.org/keycloak --timeout=600s || {
  oc -n "${NS}" get keycloak keycloak -o yaml | tail -80
  oc -n "${NS}" get pods -o wide
  exit 1
}

oc -n "${NS}" get keycloak,pods,route
echo "Site B URL: https://${HOSTNAME}"
echo "LB check:   curl -k https://${HOSTNAME}/lb-check"
echo "Prove DB path: oc run pgcheck --rm -i --restart=Never --image=postgres:17-alpine -- env PGPASSWORD='KeycloakPoC2026!' psql -h 192.168.0.114 -U keycloak -d keycloak -c 'SELECT 1'"
