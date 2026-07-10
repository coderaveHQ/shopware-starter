#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="${1:-}"
REGISTRY_USER="${2:-}"
EXPECTED_PREFIX={{GHCR_IMAGE|shell}}:{{ENVIRONMENT|shell}}-
[[ "$IMAGE" == "$EXPECTED_PREFIX"* ]] || { echo "Rejected image" >&2; exit 1; }
IMAGE_DIGEST="${IMAGE#"$EXPECTED_PREFIX"}"
[[ "$IMAGE_DIGEST" =~ ^[0-9a-f]{40}$ ]] || { echo "Rejected image" >&2; exit 1; }
[[ "$REGISTRY_USER" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { echo "Rejected registry user" >&2; exit 1; }

cleanup() { docker logout ghcr.io >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null
{{INSTALL_DIR|shell}}/deploy.sh "$IMAGE"
