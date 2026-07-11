#!/usr/bin/env bash
set -Eeuo pipefail
cd /repo
cp tests/fixtures/production-server.env /tmp/production-server.env
chmod 600 /tmp/production-server.env
SHOPWARE_INFRA_TEST_MODE=1 bash scripts/02-setup-production-server.sh --config /tmp/production-server.env --test-mode --dry-run
[[ ! -e /opt/shopware/template-test/production ]]
[[ ! -e /usr/local/sbin/shopware-deploy-production ]]
mkdir -p /root/shopware-setup
cp tests/fixtures/staging-server.env /root/shopware-setup/invalid-production-server.env
chmod 600 /root/shopware-setup/invalid-production-server.env
if SHOPWARE_INFRA_TEST_MODE=1 bash scripts/02-setup-production-server.sh --config /root/shopware-setup/invalid-production-server.env --test-mode; then
  echo "Production setup unexpectedly accepted staging config" >&2
  exit 1
fi
[[ ! -e /root/shopware-setup/invalid-production-server.env ]]
cp /tmp/production-server.env /root/shopware-setup/production-server.env
chmod 600 /root/shopware-setup/production-server.env
SHOPWARE_INFRA_TEST_MODE=1 bash scripts/02-setup-production-server.sh --config /root/shopware-setup/production-server.env --test-mode
[[ ! -e /root/shopware-setup/production-server.env ]]
[[ -f /opt/shopware/template-test/production/.env.runtime ]]
[[ -f /opt/shopware/template-test/production/.env.compose ]]
[[ -f /opt/shopware/template-test/production/.env.backup ]]
[[ -f /opt/shopware/template-test/production/compose.yaml ]]
[[ -x /opt/shopware/template-test/production/deploy.sh ]]
grep -q 'SHOPWARE_DEPLOYMENT_STAGING="0"' /opt/shopware/template-test/production/.env.init
grep -Fxq 'shop.template.internal, storefront-2.template.internal, storefront-3.template.internal {' /opt/shopware/template-test/production/Caddyfile
grep -q 'forced deployment command' /root/shopware-setup/production-server-summary.md
! grep -Eqi 'opensearch|elasticsearch|SHOPWARE_ES' /opt/shopware/template-test/production/.env.runtime /opt/shopware/template-test/production/compose.yaml
! id -nG shopware-deploy | tr ' ' '\n' | grep -qx docker
grep -q 's3.storage.invalid' /opt/shopware/template-test/production/.env.backup
