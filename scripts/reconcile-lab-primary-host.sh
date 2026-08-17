#!/usr/bin/env bash
# Detect laptop LAN IP (home vs office) and reconcile Postgres host references.
# Site A Keycloak (CRC) JDBC uses the libvirt bridge IP (stable). LAN PRIMARY_HOST
# is for /etc/hosts, TLS, Windows Site B JDBC, and SPA redirect URIs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=rhbk-mc
PG_ENV="${ROOT}/secrets/postgres.env"
PG_ENV_EXAMPLE="${ROOT}/secrets/postgres.env.example"
SITE_A_CR="${ROOT}/manifests/site-a/keycloak.yaml"
SITE_B_CR="${ROOT}/manifests/site-b/keycloak.yaml"
HPA_CR="${ROOT}/manifests/hpa/keycloak-scalable.yaml"
CONTAINER_NAME="pg-primary-site-a"

is_valid_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

detect_lan_ip() {
  local ip
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}' | head -1 || true)"
  if [[ -n "$ip" ]] && is_valid_ip "$ip" && [[ "$ip" != 127.* ]]; then
    echo "$ip"
    return 0
  fi
  for ip in $(hostname -I 2>/dev/null); do
    if [[ -n "$ip" ]] && is_valid_ip "$ip" && [[ "$ip" != 127.* ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

detect_crc_db_host() {
  # CRC pods reach host Postgres via the libvirt bridge (stable across office/home).
  local ip
  ip="$(ip -4 -o addr show virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
  if [[ -n "$ip" ]] && is_valid_ip "$ip"; then
    echo "$ip"
    return 0
  fi
  ip="$(ip route 2>/dev/null | awk '/^default.*virbr0/ {print $3; exit}')"
  if [[ -n "$ip" ]] && is_valid_ip "$ip"; then
    echo "$ip"
    return 0
  fi
  echo "192.168.122.1"
}

same_subnet_24() {
  local a="$1" b="$2"
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 _ <<< "$a"
  IFS=. read -r b1 b2 b3 _ <<< "$b"
  [[ "$a1" == "$b1" && "$a2" == "$b2" && "$a3" == "$b3" ]]
}

extract_jdbc_host() {
  local file="$1"
  grep -oE 'jdbc:postgresql://[^:/]+' "$file" 2>/dev/null | head -1 | sed 's|jdbc:postgresql://||'
}

ensure_postgres_env() {
  if [[ ! -f "${PG_ENV}" ]]; then
    if [[ -f "${PG_ENV_EXAMPLE}" ]]; then
      echo "WARN  ${PG_ENV} missing — copying from postgres.env.example"
      cp "${PG_ENV_EXAMPLE}" "${PG_ENV}"
    else
      echo "ERROR: ${PG_ENV} not found and no example to copy" >&2
      exit 1
    fi
  fi
}

update_primary_host_env() {
  local new_ip="$1"
  if grep -q '^PRIMARY_HOST=' "${PG_ENV}"; then
    sed -i "s/^PRIMARY_HOST=.*/PRIMARY_HOST=${new_ip}/" "${PG_ENV}"
  else
    echo "PRIMARY_HOST=${new_ip}" >> "${PG_ENV}"
  fi
}

update_crc_db_host_env() {
  local new_ip="$1"
  if grep -q '^CRC_DB_HOST=' "${PG_ENV}"; then
    sed -i "s/^CRC_DB_HOST=.*/CRC_DB_HOST=${new_ip}/" "${PG_ENV}"
  else
    echo "CRC_DB_HOST=${new_ip}" >> "${PG_ENV}"
  fi
}

update_manifest_jdbc() {
  local new_ip="$1"
  local file="$2"
  sed -i "s|jdbc:postgresql://[^:]*:5432|jdbc:postgresql://${new_ip}:5432|g" "${file}"
}

apply_tls_secret() {
  oc -n "${NS}" create secret tls keycloak-tls-secret \
    --cert="${ROOT}/secrets/tls.crt" \
    --key="${ROOT}/secrets/tls.key" \
    --dry-run=client -o yaml | oc apply -f -
}

print_subnet_warnings() {
  local old_ip="$1" new_ip="$2"
  if same_subnet_24 "$old_ip" "$new_ip"; then
    return 0
  fi
  echo ""
  echo "=== Subnet change detected (${old_ip} → ${new_ip}) ==="
  echo "WARN  Firewall: open-lab-firewall.sh defaults to LAN_CIDR=192.168.0.0/24."
  echo "      Office LAN may need: sudo LAN_CIDR=<office-CIDR> ${ROOT}/scripts/open-lab-firewall.sh"
  echo "WARN  pg_hba: lab fallbacks allow keycloak from 0.0.0.0/0 — CRC JDBC should work."
  echo "WARN  Site B (Windows) JDBC uses PRIMARY_HOST (LAN IP), not CRC bridge IP."
  echo "WARN  Site B at home cannot reach office PRIMARY_HOST until networks align."
  echo ""
}

print_post_checklist() {
  local lan_ip="$1"
  local crc_ip="$2"
  echo ""
  echo "=== Manual follow-up ==="
  echo "1. Linux /etc/hosts:  ${lan_ip}  auth.lan.local"
  echo "2. Windows hosts + Site B JDBC → ${lan_ip} (manual; Site B uses LAN IP)"
  echo "3. Site A JDBC stays on CRC bridge: ${crc_ip} (for pods on this CRC)"
  echo "4. curl -sk https://auth.lan.local:8443/lb-check"
  echo "5. bash ${ROOT}/scripts/verify-poc.sh"
  echo "6. Optional: cd apps/poc-spa && npm run setup-realm"
  echo "7. Other Keycloak CRs (e.g. keycloak-rhhi): patch db.url if still on old IP"
}

ensure_postgres_env
# shellcheck disable=SC1091
source "${PG_ENV}"

DETECTED_LAN="$(detect_lan_ip || true)"
DETECTED_CRC="$(detect_crc_db_host)"

if [[ -z "${DETECTED_LAN}" ]]; then
  echo "ERROR: could not detect a non-loopback LAN IP" >&2
  exit 1
fi

CONFIGURED_LAN="${PRIMARY_HOST:-}"
CONFIGURED_CRC="${CRC_DB_HOST:-}"
CRC_DB_HOST="${DETECTED_CRC}"
SITE_A_JDBC="$(extract_jdbc_host "${SITE_A_CR}")"
SITE_B_JDBC="$(extract_jdbc_host "${SITE_B_CR}")"

echo "=== Lab primary host reconcile ==="
echo "Detected LAN IP:       ${DETECTED_LAN}  (hosts, TLS, Site B JDBC)"
echo "CRC bridge DB host:    ${CRC_DB_HOST}  (Site A Keycloak JDBC)"
echo "Configured PRIMARY:    ${CONFIGURED_LAN:-<unset>}"
echo "Configured CRC_DB:     ${CONFIGURED_CRC:-<unset>}"
echo "Site A JDBC host:      ${SITE_A_JDBC:-<not found>}:${PRIMARY_PORT:-5432}"
echo "Site B JDBC host:      ${SITE_B_JDBC:-<not found>}:${PRIMARY_PORT:-5432}"

lan_ok=false
crc_ok=false
if [[ "${CONFIGURED_LAN}" == "${DETECTED_LAN}" ]] && [[ "${SITE_B_JDBC}" == "${DETECTED_LAN}" ]]; then
  lan_ok=true
fi
if [[ "${SITE_A_JDBC}" == "${CRC_DB_HOST}" ]]; then
  crc_ok=true
fi

if [[ "${lan_ok}" == true ]] && [[ "${crc_ok}" == true ]]; then
  echo "OK    PRIMARY_HOST, Site A JDBC (CRC bridge), and Site B JDBC (LAN) look correct."
  if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    if podman exec "${CONTAINER_NAME}" pg_isready -U keycloak -d keycloak >/dev/null 2>&1; then
      echo "OK    Postgres container ${CONTAINER_NAME} is accepting connections."
    else
      echo "WARN  Postgres container exists but pg_isready failed — try: bash ${ROOT}/postgres/primary/start-primary.sh"
    fi
  else
    echo "NOTE  Postgres container not running — start with: bash ${ROOT}/postgres/primary/start-primary.sh"
  fi
  exit 0
fi

if [[ -n "${CONFIGURED_LAN}" ]]; then
  print_subnet_warnings "${CONFIGURED_LAN}" "${DETECTED_LAN}"
fi

echo ""
echo "NOTE  Do not point Site A JDBC at the office WiFi IP — CRC pods use bridge ${CRC_DB_HOST}."
read -r -p "Update PRIMARY_HOST=${DETECTED_LAN}, Site A JDBC=${CRC_DB_HOST}, re-apply Keycloak? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "No changes made."
  exit 0
fi

echo "=== Updating ${PG_ENV} ==="
update_primary_host_env "${DETECTED_LAN}"
update_crc_db_host_env "${CRC_DB_HOST}"

echo "=== Updating JDBC URLs in manifests ==="
update_manifest_jdbc "${CRC_DB_HOST}" "${SITE_A_CR}"
update_manifest_jdbc "${DETECTED_LAN}" "${SITE_B_CR}"
update_manifest_jdbc "${CRC_DB_HOST}" "${HPA_CR}"

if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
  if podman exec "${CONTAINER_NAME}" pg_isready -U keycloak -d keycloak >/dev/null 2>&1; then
    echo "OK    Postgres ${CONTAINER_NAME} accepting connections on host :5432"
  else
    echo "WARN  Postgres container unhealthy — consider: bash ${ROOT}/postgres/primary/start-primary.sh"
  fi
else
  echo "NOTE  Postgres container not running — JDBC fix only; start DB when ready."
fi

echo "=== Applying Site A Keycloak CR ==="
oc apply -f "${SITE_A_CR}"
if oc -n "${NS}" wait --for=condition=Ready "keycloak/keycloak" --timeout=600s 2>/dev/null; then
  echo "OK    keycloak/keycloak Ready"
else
  echo "WARN  Keycloak not Ready within timeout — check logs:" >&2
  oc -n "${NS}" get pods -l app=keycloak -o wide 2>/dev/null || true
  oc -n "${NS}" logs statefulset/keycloak --tail=40 2>/dev/null || true
fi

read -r -p "Regenerate TLS cert with LAN IP ${DETECTED_LAN} and re-apply keycloak-tls-secret? [y/N] " tls_confirm
if [[ "${tls_confirm}" == "y" || "${tls_confirm}" == "Y" ]]; then
  bash "${ROOT}/scripts/gen-tls-secret.sh"
  apply_tls_secret
  echo "OK    TLS secret updated — Keycloak pods may restart to pick up cert."
fi

print_post_checklist "${DETECTED_LAN}" "${CRC_DB_HOST}"
echo "Done."
