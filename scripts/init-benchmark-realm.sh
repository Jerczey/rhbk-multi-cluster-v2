#!/usr/bin/env bash
# Create test-realm entities for keycloak-benchmark via kcadm inside the Keycloak pod.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-rhbk-mc}"
REALM="${REALM:-test-realm}"
CLIENT_ID="${CLIENT_ID:-gatling}"
USER_NAME="${USER_NAME:-user-0}"
DELETE="${DELETE:-false}"

INIT_SCRIPT="${INIT_SCRIPT:-/home/jgodoy/Desktop/yes/crc/keycloak-benchmark/benchmark/target/keycloak-benchmark-999.0.0-SNAPSHOT/bin/initialize-benchmark-entities.sh}"

echo "Waiting for Keycloak pod..."
oc -n "${NS}" wait --for=condition=Ready pod -l app=keycloak --timeout=300s

POD=$(oc -n "${NS}" get pods -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
echo "Using pod ${POD}"

# Configure kcadm inside pod (local HTTPS to Keycloak service)
ADMIN_PASS=$(oc -n "${NS}" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)
oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server "https://localhost:8443" \
  --realm master \
  --user temp-admin \
  --password "${ADMIN_PASS}" \
  --truststore /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  --config /tmp/kcadm.config

# Run entity creation via kcadm in pod (initialize script expects KEYCLOAK_HOME on host)
if [[ "${DELETE}" == "true" ]]; then
  oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh delete "realms/${REALM}" \
    --config /tmp/kcadm.config 2>/dev/null || true
fi

# Realm
if ! oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh get "realms/${REALM}" \
  --config /tmp/kcadm.config 2>/dev/null | grep -q "${REALM}"; then
  oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh create realms \
    -s "realm=${REALM}" -s enabled=true --config /tmp/kcadm.config
  echo "Created realm ${REALM}"
else
  echo "Realm ${REALM} already exists"
fi

# gatling service-account client
if ! oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh get clients -r "${REALM}" -q "clientId=${CLIENT_ID}" \
  --config /tmp/kcadm.config 2>/dev/null | grep -q "${CLIENT_ID}"; then
  oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh create clients -r "${REALM}" \
    -s "clientId=${CLIENT_ID}" -s enabled=true \
    -s clientAuthenticatorType=client-secret -s secret=setup-for-benchmark \
    -s 'redirectUris=["*"]' -s serviceAccountsEnabled=true -s publicClient=false \
    -s protocol=openid-connect --config /tmp/kcadm.config
  oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh add-roles -r "${REALM}" \
    --uusername "service-account-${CLIENT_ID}" --cclientid realm-management \
    --rolename manage-clients --rolename view-users --rolename manage-realm --rolename manage-users \
    --config /tmp/kcadm.config
  echo "Created client ${CLIENT_ID}"
fi

# client-0 for auth scenarios
if ! oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh get clients -r "${REALM}" -q clientId=client-0 \
  --config /tmp/kcadm.config 2>/dev/null | grep -q client-0; then
  oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh create clients -r "${REALM}" \
    -s clientId=client-0 -s enabled=true \
    -s clientAuthenticatorType=client-secret -s secret=client-0-secret \
    -s 'redirectUris=["*"]' -s serviceAccountsEnabled=true -s publicClient=false \
    -s protocol=openid-connect --config /tmp/kcadm.config
  echo "Created client-0"
fi

# user-0
if ! oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh get users -r "${REALM}" -q username="${USER_NAME}" \
  --config /tmp/kcadm.config 2>/dev/null | grep -q "${USER_NAME}"; then
  oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh create users -r "${REALM}" \
    -s "username=${USER_NAME}" -s enabled=true \
    -s "firstName=Firstname" -s "lastName=Lastname" \
    -s "email=${USER_NAME}@keycloak.org" --config /tmp/kcadm.config
  oc -n "${NS}" exec "${POD}" -- /opt/keycloak/bin/kcadm.sh set-password -r "${REALM}" \
    --username "${USER_NAME}" --new-password "${USER_NAME}-password" --config /tmp/kcadm.config
  echo "Created user ${USER_NAME}"
fi

echo "Benchmark realm ${REALM} ready."
