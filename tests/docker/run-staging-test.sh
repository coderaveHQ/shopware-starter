#!/usr/bin/env bash
set -Eeuo pipefail
cd /repo
SHOPWARE_INFRA_TEST_MODE=1 bash scripts/01-setup-staging-server.sh --config tests/fixtures/staging-server.env --test-mode
[[ -f /opt/shopware/template-test/staging/.env ]]
[[ -f /opt/shopware/template-test/staging/compose.yaml ]]
[[ -x /opt/shopware/template-test/staging/deploy.sh ]]
grep -q 'SHOPWARE_DEPLOYMENT_STAGING=1' /opt/shopware/template-test/staging/.env
grep -q 'staging.example.test' /opt/shopware/template-test/staging/Caddyfile
