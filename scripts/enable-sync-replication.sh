#!/usr/bin/env bash
# Enable synchronous commit wait for Site B standby (run on Linux primary host)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-pg-primary-site-a}"
# shellcheck disable=SC1091
source "${ROOT}/secrets/postgres.env"

# Persist in the mounted postgresql.conf (ALTER SYSTEM alone can be overridden
# when config_file points at a conf that also sets synchronous_standby_names)
sed -i "s/^synchronous_standby_names.*/synchronous_standby_names = 'FIRST 1 (site_b_standby)'/" \
  "${ROOT}/postgres/primary/postgresql.conf"

podman run --rm \
  -v "${ROOT}/postgres/primary/data:/data:Z" \
  -v "${ROOT}/postgres/primary/postgresql.conf:/cfg/postgresql.conf:Z" \
  "${POSTGRES_IMAGE}" \
  sh -c 'cp /cfg/postgresql.conf /data/postgresql.conf && chown -R postgres:postgres /data && chmod 700 /data'

podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -c "SELECT pg_reload_conf();"
podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -c "SHOW synchronous_standby_names;"
podman exec "${CONTAINER_NAME}" psql -U keycloak -d keycloak -c \
  "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"

echo "Synchronous replication enabled for application_name=site_b_standby"
