#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="${1:-}"
COMMIT_SHA="${2:-}"
REGISTRY_USER="${3:-}"
EXPECTED_REPOSITORY={{GHCR_IMAGE|shell}}
ENVIRONMENT={{ENVIRONMENT|shell}}
[[ "$IMAGE" == "$EXPECTED_REPOSITORY@sha256:"* ]] || { echo "Rejected image repository" >&2; exit 1; }
IMAGE_DIGEST="${IMAGE#"$EXPECTED_REPOSITORY@sha256:"}"
[[ "$IMAGE_DIGEST" =~ ^[0-9a-f]{64}$ ]] || { echo "Rejected image digest" >&2; exit 1; }
[[ "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "Rejected commit" >&2; exit 1; }
[[ "$REGISTRY_USER" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { echo "Rejected registry user" >&2; exit 1; }

cleanup() { docker logout ghcr.io >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null
EXPECTED_ENVIRONMENT_TAG="$EXPECTED_REPOSITORY:$ENVIRONMENT-$COMMIT_SHA"
DIGEST_FORMAT=$'\x7b\x7b.Manifest.Digest\x7d\x7d'
TAG_DIGEST="$(docker buildx imagetools inspect "$EXPECTED_ENVIRONMENT_TAG" --format "$DIGEST_FORMAT")"
[[ "$TAG_DIGEST" == "sha256:$IMAGE_DIGEST" ]] || { echo "Digest does not match the environment/commit tag" >&2; exit 1; }
{{INSTALL_DIR|shell}}/deploy.sh "$IMAGE" "$COMMIT_SHA"
