#!/usr/bin/env bash
# Dry-run / documented promote of Windows standby to writable primary
set -euo pipefail
CONTAINER_NAME="${CONTAINER_NAME:-pg-standby-site-b}"
MODE="${1:-dry-run}"

echo "=== Postgres standby promote (${MODE}) ==="
echo "1) Stop writers on old primary (Site A Keycloak + pg-primary-site-a)"
echo "2) On Windows, promote standby:"
echo "     podman exec ${CONTAINER_NAME} pg_ctl promote -D /var/lib/postgresql/data"
echo "   or: podman exec ${CONTAINER_NAME} psql -U keycloak -d keycloak -c \"SELECT pg_promote();\""
echo "3) Point both Keycloak CRs db.url to Windows host 192.168.0.102:5432"
echo "4) Restart Keycloak pods / wait Ready"
echo "5) Rebuild old primary as new standby later (not automated in PoC)"

if [[ "${MODE}" == "execute" ]]; then
  podman exec "${CONTAINER_NAME}" psql -U postgres -d postgres -c "SELECT pg_promote();"
  echo "Promote issued."
else
  echo "Dry-run only. Re-run with: $0 execute   (on the Windows host)"
fi
