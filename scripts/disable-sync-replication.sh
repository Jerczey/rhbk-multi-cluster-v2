#!/usr/bin/env bash
# Drop synchronous standby requirement when Site B is down (Site A solo / HPA lab).
# Without this, COMMIT blocks on SyncRep and Keycloak never becomes Ready.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-pg-primary-site-a}"
# shellcheck disable=SC1091
source "${ROOT}/secrets/postgres.env"

if grep -q '^synchronous_standby_names' "${ROOT}/postgres/primary/postgresql.conf"; then
  sed -i "s/^synchronous_standby_names.*/synchronous_standby_names = ''/" \
    "${ROOT}/postgres/primary/postgresql.conf"
else
  echo "synchronous_standby_names = ''" >> "${ROOT}/postgres/primary/postgresql.conf"
fi

podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -v ON_ERROR_STOP=1 \
  -c "ALTER SYSTEM SET synchronous_standby_names = '';"
podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -c "SELECT pg_reload_conf();"

SHOW_VAL=$(podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -tAc "SHOW synchronous_standby_names;")
echo "synchronous_standby_names = ${SHOW_VAL:-<empty>}"
echo "Synchronous replication wait disabled. Re-run scripts/enable-sync-replication.sh when Site B streams."
