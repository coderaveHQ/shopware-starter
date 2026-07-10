#!/usr/bin/env bash
set -Eeuo pipefail
set -f
EXPECTED_WRAPPER="/usr/local/sbin/shopware-deploy-{{ENVIRONMENT}}"
EXPECTED_IMAGE_PREFIX={{GHCR_IMAGE|shell}}:{{ENVIRONMENT|shell}}-
ORIGINAL="${SSH_ORIGINAL_COMMAND:-}"
read -r command image actor extra <<EOF
$ORIGINAL
EOF
[[ "$command" == "$EXPECTED_WRAPPER" && -n "$image" && -n "$actor" && -z "${extra:-}" ]] || { echo "Command rejected" >&2; exit 1; }
[[ "$image" == "$EXPECTED_IMAGE_PREFIX"* ]] || { echo "Image rejected" >&2; exit 1; }
image_digest="${image#"$EXPECTED_IMAGE_PREFIX"}"
[[ "$image_digest" =~ ^[0-9a-f]{40}$ ]] || { echo "Image rejected" >&2; exit 1; }
[[ "$actor" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { echo "Actor rejected" >&2; exit 1; }
exec sudo "$EXPECTED_WRAPPER" "$image" "$actor"
