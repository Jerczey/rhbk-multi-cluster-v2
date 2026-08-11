#!/usr/bin/env bash
# Run the HPA benchmark matrix: direct then haproxy, ramping concurrent-users.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIOS="${SCENARIOS:-AuthorizationCode}"
MEASUREMENT="${MEASUREMENT:-60}"
RAMP="${RAMP:-100,250,500,1000}"
SUMMARY="${ROOT}/benchmark-results/matrix-summary-$(date -u +%Y%m%dT%H%M%SZ).md"

mkdir -p "${ROOT}/benchmark-results"
echo "# HPA benchmark matrix $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${SUMMARY}"
echo "" >> "${SUMMARY}"
echo "| target | scenario | concurrent | mean_ms | rps | pods | hpa_cpu% | top_cpu | top_mem |" >> "${SUMMARY}"
echo "|--------|----------|------------|---------|-----|------|----------|---------|---------|" >> "${SUMMARY}"

for target in direct haproxy; do
  IFS=',' read -ra SCEN_ARR <<< "${SCENARIOS}"
  for scen in "${SCEN_ARR[@]}"; do
    IFS=',' read -ra LEVELS <<< "${RAMP}"
    for c in "${LEVELS[@]}"; do
      echo ">>> ${target} ${scen} concurrent=${c}"
      TARGET="${target}" SCENARIO="${scen}" CONCURRENT="${c}" MEASUREMENT="${MEASUREMENT}" \
        bash "${ROOT}/scripts/run-hpa-benchmark.sh" || true
      RUN=$(ls -td "${ROOT}/benchmark-results/${target}-${scen}-c${c}-"* 2>/dev/null | head -1)
      MEAN="—"
      RPS="—"
      if [[ -f "${RUN}/stats-summary.json" ]]; then
        MEAN=$(jq -r '.meanResponseTime // "—"' "${RUN}/stats-summary.json" 2>/dev/null || echo "—")
        RPS=$(jq -r '.meanNumberOfRequestsPerSecond // "—"' "${RUN}/stats-summary.json" 2>/dev/null || echo "—")
        KO=$(jq -r '.ko // 0' "${RUN}/stats-summary.json" 2>/dev/null || echo "0")
        if [[ "${KO}" != "0" && "${KO}" != "—" ]]; then
          MEAN="${MEAN} (KO=${KO})"
        fi
      elif [[ -f "${RUN}/gatling-report/js/stats.json" ]]; then
        MEAN=$(jq -r '.stats.meanResponseTime.total // "—"' "${RUN}/gatling-report/js/stats.json" 2>/dev/null || echo "—")
        RPS=$(jq -r '.stats.meanNumberOfRequestsPerSecond.total // "—"' "${RUN}/gatling-report/js/stats.json" 2>/dev/null || echo "—")
      fi
      PODS=$(oc -n rhbk-mc get pods -l app=keycloak --no-headers 2>/dev/null | wc -l)
      HPA_CPU=$(oc -n rhbk-mc get hpa keycloak-hpa -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "—")
      TOP=$(oc adm top pod -n rhbk-mc -l app=keycloak --no-headers 2>/dev/null | awk '{cpu+=$2; mem+=$3; n++} END{if(n) printf "%s %s", cpu, mem; else print "— —"}')
      echo "| ${target} | ${scen} | ${c} | ${MEAN} | ${RPS} | ${PODS} | ${HPA_CPU} | ${TOP} |" >> "${SUMMARY}"
      sleep 20
    done
  done
done

echo "Matrix complete: ${SUMMARY}"
cat "${SUMMARY}"
