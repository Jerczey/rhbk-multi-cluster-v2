#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/secrets/postgres.env"

DATA_DIR="${ROOT}/postgres/primary/data"
CONTAINER_NAME="pg-primary-site-a"

mkdir -p "${DATA_DIR}"

copy_configs() {
  podman run --rm --user root \
    -v "${DATA_DIR}:/var/lib/postgresql/data:Z" \
    -v "${ROOT}/postgres/primary/postgresql.conf:/cfg/postgresql.conf:Z" \
    -v "${ROOT}/postgres/primary/pg_hba.conf:/cfg/pg_hba.conf:Z" \
    "${POSTGRES_IMAGE}" \
    sh -c 'cp /cfg/postgresql.conf /var/lib/postgresql/data/postgresql.conf && cp /cfg/pg_hba.conf /var/lib/postgresql/data/pg_hba.conf && chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data'
}

if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
  if podman exec "${CONTAINER_NAME}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    echo "Primary already running and healthy (${CONTAINER_NAME}). Skipping recreate."
    podman exec "${CONTAINER_NAME}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
      "SELECT application_name, state, sync_state FROM pg_stat_replication;" 2>/dev/null || true
    exit 0
  fi
  echo "Stopping unhealthy ${CONTAINER_NAME}..."
  podman stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  podman rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

# Detect initialized data dir (host may lack permission to read container-owned files)
initialized=false
if podman run --rm -v "${DATA_DIR}:/var/lib/postgresql/data:Z" "${POSTGRES_IMAGE}" \
    test -f /var/lib/postgresql/data/PG_VERSION 2>/dev/null; then
  initialized=true
fi

if [[ "${initialized}" != "true" ]]; then
  echo "Initializing primary data directory..."
  podman run -d --name "${CONTAINER_NAME}" \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
    -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256" \
    -v "${DATA_DIR}:/var/lib/postgresql/data:Z" \
    -p 5432:5432 \
    "${POSTGRES_IMAGE}"

  echo "Waiting for Postgres to accept connections..."
  for _ in $(seq 1 60); do
    if podman exec "${CONTAINER_NAME}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  podman exec -i "${CONTAINER_NAME}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    < "${ROOT}/postgres/primary/init-replication.sql"

  podman stop "${CONTAINER_NAME}"
  podman rm "${CONTAINER_NAME}"
  copy_configs
fi

copy_configs

podman run -d --name "${CONTAINER_NAME}" \
  --restart=unless-stopped \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  -v "${DATA_DIR}:/var/lib/postgresql/data:Z" \
  -p 5432:5432 \
  "${POSTGRES_IMAGE}" \
  -c config_file=/var/lib/postgresql/data/postgresql.conf \
  -c hba_file=/var/lib/postgresql/data/pg_hba.conf

echo "Waiting for primary..."
for _ in $(seq 1 60); do
  if podman exec "${CONTAINER_NAME}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    echo "Primary is ready on ${PRIMARY_HOST}:${PRIMARY_PORT}"
    # Ensure replication role/slot exist (idempotent)
    podman exec -i "${CONTAINER_NAME}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
      < "${ROOT}/postgres/primary/init-replication.sql" >/dev/null
    podman exec "${CONTAINER_NAME}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
      "SELECT application_name, state, sync_state FROM pg_stat_replication;"
    if [[ -x "${ROOT}/scripts/open-lab-firewall.sh" ]]; then
      echo "Ensuring LAN firewall allows Postgres (5432) from Site B..."
      bash "${ROOT}/scripts/open-lab-firewall.sh" || echo "WARN: open-lab-firewall.sh failed (run manually if remote DB cannot connect)" >&2
    fi
    exit 0
  fi
  sleep 1
done

echo "ERROR: primary did not become ready" >&2
podman logs "${CONTAINER_NAME}" | tail -40
exit 1
