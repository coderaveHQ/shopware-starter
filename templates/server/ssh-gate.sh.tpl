#!/usr/bin/env bash
set -Eeuo pipefail
set -f
EXPECTED_WRAPPER="/usr/local/sbin/shopware-deploy-{{ENVIRONMENT}}"
EXPECTED_IMAGE_REPOSITORY={{GHCR_IMAGE|shell}}
ORIGINAL="${SSH_ORIGINAL_COMMAND:-}"
read -r command image commit actor extra <<EOF
$ORIGINAL
EOF
[[ "$command" == "$EXPECTED_WRAPPER" && -n "$image" && -n "$commit" && -n "$actor" && -z "${extra:-}" ]] || { echo "Command rejected" >&2; exit 1; }
[[ "$image" == "$EXPECTED_IMAGE_REPOSITORY@sha256:"* ]] || { echo "Image repository rejected" >&2; exit 1; }
image_digest="${image#"$EXPECTED_IMAGE_REPOSITORY@sha256:"}"
[[ "$image_digest" =~ ^[0-9a-f]{64}$ ]] || { echo "Image digest rejected" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "Commit rejected" >&2; exit 1; }
[[ "$actor" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { echo "Actor rejected" >&2; exit 1; }
exec sudo "$EXPECTED_WRAPPER" "$image" "$commit" "$actor"
