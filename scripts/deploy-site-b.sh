#!/usr/bin/env bash
# Deploy Site B (Windows CRC) — run after oc login to the Windows CRC cluster
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# oc on Windows needs native paths (Git Bash /d/... is not accepted)
if command -v cygpath >/dev/null 2>&1; then
  ROOT_OC="$(cygpath -w "${ROOT}")"
else
  ROOT_OC="${ROOT}"
fi
NS=rhbk-mc

# Optional: override hostname for this CRC's apps domain
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo apps-crc.testing)}"
HOSTNAME="keycloak-b.${APPS_DOMAIN}"

oc apply -f "${ROOT_OC}/manifests/operator/subscription.yaml"

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

# Lab PoC placeholder — not a production credential
DB_PASSWORD='KeycloakPoC2026!' # notsecret
oc -n "${NS}" create secret generic keycloak-db-secret \
  --from-literal=username=keycloak \
  --from-literal=password="${DB_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -

oc -n "${NS}" create secret tls keycloak-tls-secret \
  --cert="${ROOT_OC}/secrets/tls.crt" \
  --key="${ROOT_OC}/secrets/tls.key" \
  --dry-run=client -o yaml | oc apply -f -

# Patch hostname for this CRC domain
TMP=$(mktemp)
sed "s|hostname: keycloak-b.apps-crc.testing|hostname: ${HOSTNAME}|" \
  "${ROOT}/manifests/site-b/keycloak.yaml" > "${TMP}"
TMP_OC="${TMP}"
if command -v cygpath >/dev/null 2>&1; then
  TMP_OC="$(cygpath -w "${TMP}")"
fi
oc apply -f "${TMP_OC}"
rm -f "${TMP}"

echo "Waiting for Keycloak Ready..."
oc -n "${NS}" wait --for=condition=Ready keycloaks.k8s.keycloak.org/keycloak-b --timeout=600s || {
  oc -n "${NS}" get keycloak keycloak-b -o yaml | tail -80
  oc -n "${NS}" get pods -o wide
  exit 1
}

oc -n "${NS}" get keycloak,pods,route
echo "Site B URL: https://${HOSTNAME}"
echo "LB check:   curl -k https://${HOSTNAME}/lb-check"
echo "Prove DB path: oc run pgcheck --rm -i --restart=Never --image=postgres:17-alpine -- env PGPASSWORD='KeycloakPoC2026!' psql -h 192.168.0.114 -U keycloak -d keycloak -c 'SELECT 1'" # notsecret
