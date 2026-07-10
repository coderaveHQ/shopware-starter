#!/usr/bin/env bash
set -Eeuo pipefail
cd /repo
SHOPWARE_INFRA_TEST_MODE=1 bash scripts/02-setup-production-server.sh --config tests/fixtures/production-server.env --test-mode
[[ -f /opt/shopware/template-test/production/.env ]]
[[ -f /opt/shopware/template-test/production/compose.yaml ]]
[[ -x /opt/shopware/template-test/production/deploy.sh ]]
grep -q 'SHOPWARE_DEPLOYMENT_STAGING=0' /opt/shopware/template-test/production/.env
grep -q 'www.example.test' /opt/shopware/template-test/production/Caddyfile
