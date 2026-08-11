#!/usr/bin/env bash
# Run keycloak-benchmark Gatling scenarios against direct CRC route or HAProxy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KCB_HOME="${KCB_HOME:-/home/jgodoy/Desktop/yes/crc/keycloak-benchmark/benchmark/target/keycloak-benchmark-999.0.0-SNAPSHOT}"
KCB_BIN="${KCB_HOME}/bin"
RESULTS_ROOT="${RESULTS_ROOT:-${ROOT}/benchmark-results}"

TARGET="${TARGET:-direct}"
SCENARIO="${SCENARIO:-AuthorizationCode}"
CONCURRENT="${CONCURRENT:-100}"
MEASUREMENT="${MEASUREMENT:-60}"
RAMP="${RAMP:-}"

REALM="${REALM:-poc-realm}"
CLIENT_ID="${CLIENT_ID:-poc-load}"
CLIENT_SECRET="${CLIENT_SECRET:-poc-load-secret}"
BENCH_USER="${BENCH_USER:-user-0}"
BENCH_PASSWORD="${BENCH_PASSWORD:-user-0-password}"

HOST_IP="$(hostname -I | awk '{print $1}')"

case "${SCENARIO}" in
  AuthorizationCode) SCENARIO_CLASS="keycloak.scenario.authentication.AuthorizationCode" ;;
  LoginUserPassword) SCENARIO_CLASS="keycloak.scenario.authentication.LoginUserPassword" ;;
  ClientSecret) SCENARIO_CLASS="keycloak.scenario.authentication.ClientSecret" ;;
  *) echo "Unknown SCENARIO=${SCENARIO}" >&2; exit 1 ;;
esac

case "${TARGET}" in
  direct) SERVER_URL="https://auth.lan.local:443/" ;;
  haproxy) SERVER_URL="https://auth.lan.local:8443/" ;;
  *) echo "TARGET must be direct or haproxy" >&2; exit 1 ;;
esac

if [[ ! -x "${KCB_BIN}/kcb.sh" ]]; then
  echo "kcb.sh not found at ${KCB_BIN}/kcb.sh" >&2
  exit 1
fi

if command -v oc >/dev/null 2>&1; then
  echo "Waiting for Keycloak pods Ready..."
  oc -n rhbk-mc wait --for=condition=Ready pod -l app=keycloak --timeout=300s 2>/dev/null || true
  LB=$(curl -sk --max-time 5 https://127.0.0.1:8443/lb-check 2>/dev/null || echo DOWN)
  echo "HAProxy lb-check: ${LB}"
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="${RESULTS_ROOT}/${TARGET}-${SCENARIO}-c${CONCURRENT}-${STAMP}"
mkdir -p "${RUN_DIR}"

echo "=== HPA benchmark run ==="
echo "target=${TARGET} url=${SERVER_URL}"
echo "realm=${REALM} client=${CLIENT_ID}"
echo "scenario=${SCENARIO_CLASS} concurrent-users=${CONCURRENT} measurement=${MEASUREMENT}s"
echo "results=${RUN_DIR}"

# Baseline footprint before load
"${ROOT}/scripts/collect-keycloak-footprint.sh" || true
cp "${ROOT}/benchmark-results"/footprint-*.txt "${RUN_DIR}/" 2>/dev/null || true

cd "${KCB_BIN}"
RUN_TIMEOUT="${RUN_TIMEOUT:-$((MEASUREMENT + 300))}"

set +e
timeout "${RUN_TIMEOUT}" ./kcb.sh \
  --scenario="${SCENARIO_CLASS}" \
  --server-url="${SERVER_URL}" \
  --realm-name="${REALM}" \
  --concurrent-users="${CONCURRENT}" \
  --measurement="${MEASUREMENT}" \
  --client-id="${CLIENT_ID}" \
  --client-secret="${CLIENT_SECRET}" \
  --username="${BENCH_USER}" \
  --user-password="${BENCH_PASSWORD}" \
  --client-redirect-uri="http://${HOST_IP}:8080" \
  2>&1 | tee "${RUN_DIR}/kcb.log"
KCB_EXIT=${PIPESTATUS[0]}
set -e
if [[ ${KCB_EXIT} -eq 124 ]]; then
  echo "kcb timeout after ${RUN_TIMEOUT}s" | tee -a "${RUN_DIR}/kcb.log"
fi

# Copy latest gatling output
LATEST=$(ls -td "${KCB_HOME}"/results/*/ 2>/dev/null | head -1 || true)
if [[ -n "${LATEST}" ]]; then
  cp -a "${LATEST}" "${RUN_DIR}/gatling-report" 2>/dev/null || true
  if [[ -f "${LATEST}/js/stats.json" ]]; then
    jq '.stats | {
      meanResponseTime: .meanResponseTime.total,
      meanNumberOfRequestsPerSecond: .meanNumberOfRequestsPerSecond.total,
      numberOfRequests: .numberOfRequests.total,
      ok: .numberOfRequests.ok,
      ko: .numberOfRequests.ko
    }' "${LATEST}/js/stats.json" > "${RUN_DIR}/stats-summary.json" 2>/dev/null || \
      cp "${LATEST}/js/stats.json" "${RUN_DIR}/stats.json"
  fi
fi

sleep 10
"${ROOT}/scripts/collect-keycloak-footprint.sh" || true
LATEST_FP=$(ls -t "${ROOT}/benchmark-results"/footprint-*.txt 2>/dev/null | head -1)
[[ -n "${LATEST_FP}" ]] && cp "${LATEST_FP}" "${RUN_DIR}/footprint-after.txt"

echo "Done. Review ${RUN_DIR}"

if [[ -n "${RAMP}" ]]; then
  echo "Running ramp: ${RAMP}"
  IFS=',' read -ra LEVELS <<< "${RAMP}"
  for level in "${LEVELS[@]}"; do
    CONCURRENT="${level}"
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    RUN_DIR="${RESULTS_ROOT}/${TARGET}-${SCENARIO}-c${CONCURRENT}-${STAMP}"
    mkdir -p "${RUN_DIR}"
    echo "--- ramp concurrent-users=${CONCURRENT} ---"
    set +e
    timeout "${RUN_TIMEOUT}" ./kcb.sh \
      --scenario="${SCENARIO_CLASS}" \
      --server-url="${SERVER_URL}" \
      --realm-name="${REALM}" \
      --concurrent-users="${CONCURRENT}" \
      --measurement="${MEASUREMENT}" \
      --client-id="${CLIENT_ID}" \
      --client-secret="${CLIENT_SECRET}" \
      --username="${BENCH_USER}" \
      --user-password="${BENCH_PASSWORD}" \
      --client-redirect-uri="http://${HOST_IP}:8080" \
      2>&1 | tee "${RUN_DIR}/kcb.log"
    KCB_EXIT=${PIPESTATUS[0]}
    set -e
    if [[ ${KCB_EXIT} -eq 124 ]]; then
      echo "kcb timeout after ${RUN_TIMEOUT}s" | tee -a "${RUN_DIR}/kcb.log"
    fi
    "${ROOT}/scripts/collect-keycloak-footprint.sh" || true
    sleep 15
  done
fi
