#!/usr/bin/env bash
set -Eeuo pipefail
cd "{{INSTALL_DIR}}"

IMAGE="${SHOPWARE_IMAGE:-{{SHOPWARE_IMAGE}}}"
if [[ -z "$IMAGE" ]]; then echo "SHOPWARE_IMAGE is missing" >&2; exit 1; fi
export SHOPWARE_IMAGE="$IMAGE"

echo "Deploying image: $SHOPWARE_IMAGE"
docker compose pull database redis rabbitmq opensearch varnish caddy || true
docker compose up -d database redis rabbitmq opensearch

docker compose pull app init worker scheduler
docker compose run --rm init
docker compose up -d app worker scheduler varnish caddy --remove-orphans

docker compose ps
docker compose exec -T app php bin/console --version

echo "Deployment finished for {{ENVIRONMENT}} at $(date -Iseconds)"
