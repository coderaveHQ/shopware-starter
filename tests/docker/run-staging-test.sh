#!/usr/bin/env bash
set -Eeuo pipefail
cd /repo
cp tests/fixtures/staging-server.env /tmp/staging-server.env
chmod 600 /tmp/staging-server.env
SHOPWARE_INFRA_TEST_MODE=1 bash scripts/01-setup-staging-server.sh --config /tmp/staging-server.env --test-mode --dry-run
[[ ! -e /opt/shopware/template-test/staging ]]
[[ ! -e /usr/local/sbin/shopware-deploy-staging ]]
mkdir -p /root/shopware-setup
cp /tmp/staging-server.env /root/shopware-setup/staging-server.env
chmod 600 /root/shopware-setup/staging-server.env
SHOPWARE_INFRA_TEST_MODE=1 bash scripts/01-setup-staging-server.sh --config /root/shopware-setup/staging-server.env --test-mode
[[ ! -e /root/shopware-setup/staging-server.env ]]
[[ -f /opt/shopware/template-test/staging/.env.runtime ]]
[[ -f /opt/shopware/template-test/staging/.env.compose ]]
[[ -f /opt/shopware/template-test/staging/.env.backup ]]
[[ -f /opt/shopware/template-test/staging/compose.yaml ]]
[[ -x /opt/shopware/template-test/staging/deploy.sh ]]
grep -q 'SHOPWARE_DEPLOYMENT_STAGING="1"' /opt/shopware/template-test/staging/.env.init
grep -Fxq 'staging.template.internal, staging-storefront-2.template.internal, staging-storefront-3.template.internal {' /opt/shopware/template-test/staging/Caddyfile
grep -q 'forced deployment command' /root/shopware-setup/staging-server-summary.md
! grep -Eqi 'opensearch|elasticsearch|SHOPWARE_ES' /opt/shopware/template-test/staging/.env.runtime /opt/shopware/template-test/staging/compose.yaml
! id -nG shopware-deploy | tr ' ' '\n' | grep -qx docker
grep -q 's3.storage.invalid' /opt/shopware/template-test/staging/.env.backup
