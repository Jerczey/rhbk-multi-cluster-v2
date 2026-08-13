#!/usr/bin/env bash
# Build and optionally push the prebuilt optimized Keycloak image for the HPA lab.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-rhbk-mc}"
TAG="${TAG:-26.7.0-optimized}"
REGISTRY="${REGISTRY:-default-route-openshift-image-registry.apps-crc.testing}"
IMAGE="${REGISTRY}/${NS}/keycloak:${TAG}"
CONTAINERFILE="${ROOT}/images/keycloak-optimized/Containerfile"
PUSH="${PUSH:-1}"

if [[ ! -f "${CONTAINERFILE}" ]]; then
  echo "Containerfile not found: ${CONTAINERFILE}" >&2
  exit 1
fi

echo "=== Build optimized Keycloak image ==="
echo "image=${IMAGE}"
podman build -f "${CONTAINERFILE}" -t "${IMAGE}" "${ROOT}/images/keycloak-optimized"

if [[ "${PUSH}" == "1" ]]; then
  if ! command -v oc >/dev/null 2>&1; then
    echo "WARN: oc not found; skipping push. Set PUSH=0 or install oc to push." >&2
    exit 0
  fi
  eval "$(oc oc-env 2>/dev/null || true)"
  TOKEN="$(oc whoami -t 2>/dev/null || true)"
  if [[ -z "${TOKEN}" ]]; then
    echo "WARN: not logged in to OpenShift; skipping push." >&2
    exit 0
  fi
  echo "${TOKEN}" | podman login -u "$(oc whoami)" --password-stdin "${REGISTRY}"
  podman push "${IMAGE}"
  echo "Pushed ${IMAGE}"
else
  echo "Build complete (PUSH=0, image not pushed)."
fi

echo "Apply HPA lab with:"
echo "  OPT_IMAGE=${IMAGE} bash scripts/apply-hpa-lab.sh cpu"
