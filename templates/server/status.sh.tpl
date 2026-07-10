#!/usr/bin/env bash
set -Eeuo pipefail
cd {{INSTALL_DIR|shell}}
COMPOSE=(docker compose --env-file .env.compose -f compose.yaml)
echo "# {{PROJECT_SLUG}} {{ENVIRONMENT}} status"
date -Iseconds
"${COMPOSE[@]}" ps
for service in database redis rabbitmq app worker scheduler varnish caddy; do
  "${COMPOSE[@]}" ps --services --status running | grep -qx "$service" || { echo "NOT RUNNING: $service" >&2; exit 1; }
done
"${COMPOSE[@]}" exec -T app php bin/console --version
"${COMPOSE[@]}" exec -T app php bin/console scheduled-task:list
systemctl is-active "shopware-{{ENVIRONMENT}}-backup.timer"
systemctl is-active "shopware-{{ENVIRONMENT}}-restore-verify.timer"
for unit in "shopware-{{ENVIRONMENT}}-backup.service" "shopware-{{ENVIRONMENT}}-restore-verify.service"; do
  if systemctl is-failed --quiet "$unit"; then echo "FAILED SYSTEMD UNIT: $unit" >&2; exit 1; fi
done
systemctl --no-pager status "shopware-{{ENVIRONMENT}}-backup.service" || true
systemctl --no-pager status "shopware-{{ENVIRONMENT}}-restore-verify.service" || true
curl -fsSIL --max-time 20 https://{{PRIMARY_DOMAIN}}/ >/dev/null
echo "All required services and HTTPS checks passed."
