#!/usr/bin/env bash
# Enable synchronous commit wait for Site B standby (run on Linux primary host)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-pg-primary-site-a}"
# shellcheck disable=SC1091
source "${ROOT}/secrets/postgres.env"

SYNC_VALUE="FIRST 1 (site_b_standby)"

# Keep host-side conf in sync for future restarts (do NOT chown the live data dir)
if grep -q '^synchronous_standby_names' "${ROOT}/postgres/primary/postgresql.conf"; then
  sed -i "s/^synchronous_standby_names.*/synchronous_standby_names = '${SYNC_VALUE}'/" \
    "${ROOT}/postgres/primary/postgresql.conf"
else
  echo "synchronous_standby_names = '${SYNC_VALUE}'" >> "${ROOT}/postgres/primary/postgresql.conf"
fi

# Apply at runtime without remounting/relabeling the data volume
podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -v ON_ERROR_STOP=1 \
  -c "ALTER SYSTEM SET synchronous_standby_names = '${SYNC_VALUE}';" \
  -c "SELECT pg_reload_conf();"

SHOW_VAL=$(podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -tAc "SHOW synchronous_standby_names;")
echo "synchronous_standby_names = ${SHOW_VAL}"

# If conf file still wins over auto.conf, bounce primary and overlay conf safely
if [[ -z "${SHOW_VAL// }" ]]; then
  echo "Reload did not apply; restarting primary with updated postgresql.conf..."
  podman stop "${CONTAINER_NAME}"
  podman run --rm \
    -v "${ROOT}/postgres/primary/data:/data:Z" \
    -v "${ROOT}/postgres/primary/postgresql.conf:/cfg/postgresql.conf:Z" \
    "${POSTGRES_IMAGE}" \
    sh -c 'cp /cfg/postgresql.conf /data/postgresql.conf && chown -R postgres:postgres /data && chmod 700 /data'
  podman start "${CONTAINER_NAME}"
  for _ in $(seq 1 30); do
    podman exec "${CONTAINER_NAME}" pg_isready -U keycloak >/dev/null 2>&1 && break
    sleep 1
  done
  SHOW_VAL=$(podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -tAc "SHOW synchronous_standby_names;")
  echo "after restart: synchronous_standby_names = ${SHOW_VAL}"
fi

podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -c \
  "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"

echo "Synchronous replication enabled for application_name=site_b_standby"
echo "If sync_state is empty/async, confirm Windows standby is streaming first."
