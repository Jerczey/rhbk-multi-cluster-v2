#!/usr/bin/env bash
# Snapshot Keycloak pod resource usage and HPA status for HPA lab notes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-rhbk-mc}"
LABEL="${LABEL:-app=keycloak}"
OUT_DIR="${OUT_DIR:-${ROOT}/benchmark-results}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="${OUT_DIR}/footprint-${STAMP}.txt"

mkdir -p "${OUT_DIR}"

{
  echo "=== Keycloak footprint ${STAMP} ==="
  echo "namespace: ${NS}"
  echo

  echo "--- HPA ---"
  oc -n "${NS}" get hpa keycloak-hpa -o wide 2>/dev/null || echo "(no HPA)"
  oc -n "${NS}" describe hpa keycloak-hpa 2>/dev/null | sed -n '1,25p' || true
  echo

  echo "--- Pods ---"
  oc -n "${NS}" get pods -l "${LABEL}" -o wide
  echo

  echo "--- Top pods (requires metrics-server) ---"
  oc adm top pod -n "${NS}" -l "${LABEL}" 2>/dev/null || echo "(oc adm top failed)"
  echo

  echo "--- Keycloak CR ---"
  oc -n "${NS}" get keycloak keycloak -o jsonpath='instances={.spec.instances} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null || true

  echo "--- Resource requests (for HPA % calc) ---"
  oc -n "${NS}" get keycloak keycloak -o jsonpath='cpu_request={.spec.resources.requests.cpu} memory_request={.spec.resources.requests.memory}{"\n"}' 2>/dev/null || true
} | tee "${OUT}"

echo "Wrote ${OUT}"
