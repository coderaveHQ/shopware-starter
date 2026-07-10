#!/usr/bin/env bash
set -Eeuo pipefail
cd "{{INSTALL_DIR}}"
echo "# {{PROJECT_SLUG}} {{ENVIRONMENT}} status"
date -Iseconds
docker compose ps || true
echo
docker compose exec -T app php bin/console --version || true
echo
docker compose exec -T app php bin/console scheduled-task:list || true
