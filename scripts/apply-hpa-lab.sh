#!/usr/bin/env bash
# Apply HPA lab Keycloak CR (v2beta1, 2 instances) and CPU-based HPA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=rhbk-mc
METRIC="${1:-cpu}"
OPT_IMAGE="${OPT_IMAGE:-default-route-openshift-image-registry.apps-crc.testing/rhbk-mc/keycloak:26.7.0-optimized}"

if [[ -f "${ROOT}/secrets/postgres.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/secrets/postgres.env"
fi
PRIMARY_HOST="${PRIMARY_HOST:-$(hostname -I | awk '{print $1}')}"

echo "=== HPA lab: namespace=${NS} metric=${METRIC} db_host=${PRIMARY_HOST} ==="

# Patch JDBC URL in scalable CR for current host IP and apply explicit optimized image override.
TMP_CR=$(mktemp)
sed "s|jdbc:postgresql://[^:]*:5432|jdbc:postgresql://${PRIMARY_HOST}:5432|" \
  "${ROOT}/manifests/hpa/keycloak-scalable.yaml" > "${TMP_CR}"
sed -i "s|^[[:space:]]*image:.*|  image: ${OPT_IMAGE}|" "${TMP_CR}"

# Phase 1: single instance + local cache avoids bootstrap stall on CRC (#49203)
sed "s/^  instances: 2/  instances: 1/" "${TMP_CR}" > "${TMP_CR}.phase1"
awk '/name: db-tls-mode/{print; getline; print; print "    - name: cache"; print "      value: local"; next}1' \
  "${TMP_CR}.phase1" > "${TMP_CR}.phase1b"
oc apply -f "${TMP_CR}.phase1b"
rm -f "${TMP_CR}" "${TMP_CR}.phase1" "${TMP_CR}.phase1b"

echo "Waiting for first Keycloak pod Ready (image=${OPT_IMAGE})..."
oc -n "${NS}" wait --for=condition=Ready keycloaks.k8s.keycloak.org/keycloak --timeout=600s || {
  oc -n "${NS}" get pods -o wide
  oc -n "${NS}" logs statefulset/keycloak --tail=80 || true
  echo "ERROR: Keycloak did not become Ready. Verify OPT_IMAGE points to a prebuilt optimized image compatible with startOptimized=true." >&2
  exit 1
}

# Phase 2: scale to 2 instances for HPA lab
sed "s|jdbc:postgresql://[^:]*:5432|jdbc:postgresql://${PRIMARY_HOST}:5432|; s/^  instances: 1/  instances: 2/" \
  "${ROOT}/manifests/hpa/keycloak-scalable.yaml" > "${TMP_CR}"
oc apply -f "${TMP_CR}"
rm -f "${TMP_CR}"

echo "Waiting for second Keycloak pod..."
for _ in $(seq 1 120); do
  READY=$(oc -n "${NS}" get pods -l app=keycloak -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True || true)
  TOTAL=$(oc -n "${NS}" get pods -l app=keycloak --no-headers 2>/dev/null | wc -l)
  if [[ "${READY}" -ge 2 && "${TOTAL}" -ge 2 ]]; then
    break
  fi
  sleep 5
done

READY=$(oc -n "${NS}" get pods -l app=keycloak -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True || true)
if [[ "${READY}" -lt 2 ]]; then
  echo "ERROR: second pod did not become Ready. Check optimized image and startup compatibility." >&2
  oc -n "${NS}" get pods -l app=keycloak -o wide
  oc -n "${NS}" logs statefulset/keycloak --tail=120 || true
  exit 1
fi

# Remove alternate HPA if present
oc -n "${NS}" delete hpa keycloak-hpa --ignore-not-found

if [[ "${METRIC}" == "memory" ]]; then
  oc apply -f "${ROOT}/manifests/hpa/keycloak-hpa-memory.yaml"
else
  oc apply -f "${ROOT}/manifests/hpa/keycloak-hpa-cpu.yaml"
fi

oc -n "${NS}" wait --for=condition=Ready keycloaks.k8s.keycloak.org/keycloak --timeout=300s || true

oc -n "${NS}" get keycloak,hpa,pods -o wide
echo "HPA lab applied. Collect baseline: scripts/collect-keycloak-footprint.sh"
