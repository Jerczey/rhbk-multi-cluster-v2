#!/usr/bin/env bash
# Run commands on Windows Site B via SSH (password from secrets/site-b-ssh.env).
# Requires: sshpass, OpenSSH client. Lab use only.
set -euo pipefail

_SITE_B_REMOTE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_SITE_B_ENV="${SITE_B_SSH_ENV:-${_SITE_B_REMOTE_ROOT}/secrets/site-b-ssh.env}"

site_b_load_env() {
  if [[ ! -f "${_SITE_B_ENV}" ]]; then
    echo "Missing ${_SITE_B_ENV}" >&2
    echo "  cp secrets/site-b-ssh.env.example secrets/site-b-ssh.env" >&2
    echo "  # edit SITE_B_SSH_PASSWORD (and user/host if needed)" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "${_SITE_B_ENV}"
  : "${SITE_B_SSH_HOST:?SITE_B_SSH_HOST required in site-b-ssh.env}"
  : "${SITE_B_SSH_USER:?SITE_B_SSH_USER required}"
  : "${SITE_B_SSH_PASSWORD:?SITE_B_SSH_PASSWORD required}"
  SITE_B_OC_NAMESPACE="${SITE_B_OC_NAMESPACE:-rhbk-mc}"
  SITE_B_KEYCLOAK_STS="${SITE_B_KEYCLOAK_STS:-keycloak-b}"
}

site_b_ssh() {
  site_b_load_env
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass not installed (dnf install sshpass)" >&2
    return 1
  fi
  SSHPASS="${SITE_B_SSH_PASSWORD}" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${SITE_B_SSH_USER}@${SITE_B_SSH_HOST}" "$@"
}

# Run oc on Windows (cmd session; oc must be on PATH for the SSH user).
site_b_oc() {
  site_b_load_env
  site_b_ssh oc -n "${SITE_B_OC_NAMESPACE}" "$@"
}

site_b_keycloak_scale() {
  local replicas="${1:?replicas required}"
  site_b_load_env
  site_b_oc scale "statefulset/${SITE_B_KEYCLOAK_STS}" "--replicas=${replicas}"
}

site_b_keycloak_ready() {
  site_b_load_env
  site_b_oc get "keycloak/${SITE_B_KEYCLOAK_STS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
    | grep -q True
}

site_b_wait_keycloak_ready() {
  local timeout="${1:-180}" i
  for ((i = 1; i <= timeout / 5; i++)); do
    if site_b_keycloak_ready; then
      echo "Site B Keycloak Ready"
      return 0
    fi
    sleep 5
  done
  echo "Timeout waiting for Site B Keycloak Ready" >&2
  return 1
}
