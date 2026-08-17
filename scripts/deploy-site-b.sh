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

# Build/push optimized image unless skipped (faster pod starts with startOptimized: true)
if [[ "${SKIP_BUILD_OPT:-0}" != "1" ]]; then
  if command -v podman >/dev/null 2>&1; then
    echo "Building optimized Keycloak image (SKIP_BUILD_OPT=1 to skip)..."
    bash "${ROOT}/scripts/build-keycloak-optimized-image.sh" || {
      echo "WARN: optimized image build/push failed; ensure image exists before Keycloak starts." >&2
    }
  else
    echo "WARN: podman not found; skip build. Run scripts/build-keycloak-optimized-image.ps1 on Windows." >&2
  fi
fi

# Optional: override hostname for this CRC's apps domain
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo apps-crc.testing)}"
HOSTNAME="keycloak-b.${APPS_DOMAIN}"

oc apply -f "${ROOT_OC}/manifests/operator/subscription.yaml"

echo "Waiting for Keycloak operator CSV..."
for _ in $(seq 1 120); do
  CSV_NAME=$(oc get csv -n "${NS}" -o name 2>/dev/null | grep keycloak-operator | head -1 || true)
  if [[ -n "${CSV_NAME}" ]]; then
    PHASE=$(oc get "${CSV_NAME}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "${PHASE}" == "Succeeded" ]] && break
  fi
  sleep 5
done
oc get csv -n "${NS}" | grep keycloak-operator || true

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
echo "Prove DB path: oc run pgcheck --rm -i --restart=Never --image=registry.access.redhat.com/hi/postgresql:18 -- env PGPASSWORD='${DB_PASSWORD}' psql -h 192.168.0.114 -U keycloak -d keycloak -c 'SELECT 1'" # notsecret
