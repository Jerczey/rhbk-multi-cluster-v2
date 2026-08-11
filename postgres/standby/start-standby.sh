#!/usr/bin/env bash
# Run on Windows Site B (Podman Desktop / WSL / PowerShell-friendly bash)
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:-192.168.0.114}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-ReplicatorPoC2026!}" # notsecret
POSTGRES_IMAGE="${POSTGRES_IMAGE:-registry.access.redhat.com/hi/postgresql:17}"
CONTAINER_NAME="${CONTAINER_NAME:-pg-standby-site-b}"
DATA_DIR="${DATA_DIR:-${PWD}/data}"
SLOT_NAME="site_b_standby"
APP_NAME="site_b_standby"

mkdir -p "${DATA_DIR}"

if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
  podman stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  podman rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

if [[ -f "${DATA_DIR}/PG_VERSION" ]]; then
  echo "Existing data found in ${DATA_DIR}; remove it to re-basebackup."
  echo "  rm -rf ${DATA_DIR}/*"
  exit 1
fi

echo "Taking basebackup from ${PRIMARY_HOST}..."
podman run --rm \
  -e PGPASSWORD="${REPLICATION_PASSWORD}" \
  -v "${DATA_DIR}:/var/lib/postgresql/data:Z" \
  "${POSTGRES_IMAGE}" \
  pg_basebackup -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" \
    -U "${REPLICATION_USER}" -D /var/lib/postgresql/data \
    -Fp -Xs -P -R -S "${SLOT_NAME}"

# Ensure application_name matches synchronous_standby_names
cat > "${DATA_DIR}/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=${REPLICATION_USER} password=${REPLICATION_PASSWORD} application_name=${APP_NAME}'
primary_slot_name = '${SLOT_NAME}'
EOF

touch "${DATA_DIR}/standby.signal"

podman run -d --name "${CONTAINER_NAME}" \
  --restart=unless-stopped \
  -v "${DATA_DIR}:/var/lib/postgresql/data:Z" \
  -p 5432:5432 \
  "${POSTGRES_IMAGE}"

echo "Standby started. On primary, run: scripts/enable-sync-replication.sh"
echo "Then verify: podman exec pg-primary-site-a psql -U keycloak -d keycloak -c 'SELECT * FROM pg_stat_replication;'"
