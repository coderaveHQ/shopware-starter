#!/usr/bin/env bash
# Read-only freshness check for every external image pinned in customer.env.example.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
stale=0
while IFS= read -r line; do
  name="${line%%=*}"; pinned="${line#*=\"}"; pinned="${pinned%\"}"
  reference="${pinned%@sha256:*}"; expected="sha256:${pinned##*@sha256:}"
  current="$(docker buildx imagetools inspect "$reference" --format '{{.Manifest.Digest}}')"
  if [[ "$current" != "$expected" ]]; then echo "$name is stale: $expected -> $current" >&2; stale=1; else echo "$name is current: $expected"; fi
done < <(grep -E '^(SHOPWARE_DOCKER_BASE_IMAGE|SHOPWARE_CLI_IMAGE|MARIADB_IMAGE|VALKEY_IMAGE|RABBITMQ_IMAGE|VARNISH_IMAGE|CADDY_IMAGE)=' "$REPO_ROOT/templates/customer/customer.env.example")
[[ "$stale" == 0 ]] || { echo "Review upstream changes, update digests and run the full image scan." >&2; exit 1; }
