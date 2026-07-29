#!/usr/bin/env bash
# DEPRECATED — CRC nginx SPA deploy was abandoned. Use Linux:
#   cd apps/poc-spa && npm start  →  https://auth.lan.local:8444
# Historical script below is disabled.
# Deploy PoC SPA as nginx pod on Site B CRC — no host npm required.
# Run after: oc login to Windows CRC, namespace rhbk-mc exists.
set -euo pipefail
echo "DEPRECATED: use apps/poc-spa npm start on Linux (https://auth.lan.local:8444)." >&2
exit 1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# oc on Windows needs native paths (Git Bash /d/... is not accepted)
if command -v cygpath >/dev/null 2>&1; then
  path_oc() { cygpath -w "$1"; }
else
  path_oc() { printf '%s' "$1"; }
fi
NS=rhbk-mc
PUBLIC="${ROOT}/apps/poc-spa/public"
NGINX_CONF="${ROOT}/apps/poc-spa/nginx.conf"

APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo apps-crc.testing)}"
HOSTNAME="poc-spa.${APPS_DOMAIN}"
# HAProxy on Linux Site A (override if LAN IP differs)
AUTH_LB_IP="${AUTH_LB_IP:-192.168.0.114}"

for f in index.html styles.css app.mjs vendor/keycloak.js; do
  if [[ ! -f "${PUBLIC}/${f}" ]]; then
    echo "Missing ${PUBLIC}/${f}" >&2
    exit 1
  fi
done
if [[ ! -f "${NGINX_CONF}" ]]; then
  echo "Missing ${NGINX_CONF}" >&2
  exit 1
fi

echo "Creating ConfigMap poc-spa from static assets..."
# Explicit keys preserve vendor/keycloak.js → mounted as vendor/keycloak.js via subPath
oc -n "${NS}" create configmap poc-spa \
  --from-file=index.html="$(path_oc "${PUBLIC}/index.html")" \
  --from-file=styles.css="$(path_oc "${PUBLIC}/styles.css")" \
  --from-file=app.mjs="$(path_oc "${PUBLIC}/app.mjs")" \
  --from-file=keycloak.js="$(path_oc "${PUBLIC}/vendor/keycloak.js")" \
  --dry-run=client -o yaml | oc apply -f -

echo "Creating ConfigMap poc-spa-nginx (lb-check proxy → ${AUTH_LB_IP}:8443)..."
TMP_NGINX=$(mktemp)
sed "s|192.168.0.114|${AUTH_LB_IP}|g" "${NGINX_CONF}" > "${TMP_NGINX}"
oc -n "${NS}" create configmap poc-spa-nginx \
  --from-file=default.conf="$(path_oc "${TMP_NGINX}")" \
  --dry-run=client -o yaml | oc apply -f -
rm -f "${TMP_NGINX}"

echo "Applying Deployment / Service / Route (host ${HOSTNAME})..."
TMP=$(mktemp)
sed "s|host: poc-spa.apps-crc.testing|host: ${HOSTNAME}|" \
  "${ROOT}/manifests/poc-spa/deployment.yaml" > "${TMP}"
TMP_OC="$(path_oc "${TMP}")"
oc apply -f "${TMP_OC}"
rm -f "${TMP}"

# Reload pods when only ConfigMap changed
oc -n "${NS}" rollout restart deployment/poc-spa 2>/dev/null || true

echo "Waiting for poc-spa rollout..."
oc -n "${NS}" rollout status deployment/poc-spa --timeout=180s || {
  oc -n "${NS}" get pods -l app=poc-spa -o wide
  oc -n "${NS}" describe pod -l app=poc-spa | tail -40
  echo "If Pending with disk-pressure, free CRC disk before the SPA can schedule." >&2
  exit 1
}

oc -n "${NS}" get deploy,svc,route -l app=poc-spa
echo ""
echo "SPA URL: https://${HOSTNAME}"
echo "Ensure Keycloak client poc-spa allows redirect URI https://${HOSTNAME}/*"
echo "(see apps/poc-spa/config/realm-clients.json — patch in Admin UI if realm already exists)"
