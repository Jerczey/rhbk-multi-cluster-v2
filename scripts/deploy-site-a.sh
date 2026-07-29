#!/usr/bin/env bash
# Deploy Site A (Linux CRC) Keycloak multi-cluster v2 instance
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=rhbk-mc

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

oc apply -f "${ROOT}/manifests/site-a/keycloak.yaml"

echo "Waiting for Keycloak Ready..."
oc -n "${NS}" wait --for=condition=Ready keycloaks.k8s.keycloak.org/keycloak --timeout=600s || {
  oc -n "${NS}" get keycloak keycloak -o yaml | tail -80
  oc -n "${NS}" get pods -o wide
  oc -n "${NS}" logs statefulset/keycloak --tail=80 || true
  exit 1
}

oc -n "${NS}" get keycloak,pods,route
echo "Site A hostname: https://auth.lan.local:8443 (via HAProxy)"
echo "LB check:        curl -sk https://auth.lan.local:8443/lb-check"
