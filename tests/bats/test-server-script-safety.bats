#!/usr/bin/env bats
@test "production script refuses staging config" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  config="$(mktemp)"; cp "$REPO_ROOT/tests/fixtures/staging-server.env" "$config"; chmod 600 "$config"
  run bash "$REPO_ROOT/scripts/02-setup-production-server.sh" --config "$config" --test-mode
  rm -f "$config"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Falsche Config"* || "$output" == *"ERROR"* ]]
}

@test "dockerignore excludes every generated secret class" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  for value in generated customer.env customer-vault.md auth.json .env.local config/jwt backups; do
    grep -Fxq "$value" "$REPO_ROOT/.dockerignore"
  done
}

@test "local data services bind only to loopback" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  grep -q '127.0.0.1:3306:3306' "$REPO_ROOT/templates/docker/compose.local.yaml.tpl"
  grep -q '127.0.0.1:6379:6379' "$REPO_ROOT/templates/docker/compose.local.yaml.tpl"
  grep -q '127.0.0.1:5672:5672' "$REPO_ROOT/templates/docker/compose.local.yaml.tpl"
}

@test "customer preparation dry-run leaves repository unchanged" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  isolated_repo="$(mktemp -d)"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/templates" "$isolated_repo/"
  mkdir "$isolated_repo/generated"; cp "$REPO_ROOT/generated/.gitkeep" "$isolated_repo/generated/.gitkeep"
  config="$isolated_repo/customer.env"; cp "$REPO_ROOT/tests/fixtures/customer.env" "$config"; chmod 600 "$config"
  before="$(find "$isolated_repo/generated" -mindepth 1 -maxdepth 3 -type f -exec shasum -a 256 {} \; | sort)"
  run bash "$isolated_repo/scripts/00-prepare-customer.sh" --config "$config" --dry-run
  [ "$status" -eq 0 ]
  after="$(find "$isolated_repo/generated" -mindepth 1 -maxdepth 3 -type f -exec shasum -a 256 {} \; | sort)"
  [ "$before" = "$after" ]
  rm -rf "$isolated_repo"
}

@test "customer preparation rejects storefront domains shared across environments" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  config="$(mktemp)"
  cp "$REPO_ROOT/tests/fixtures/customer.env" "$config"
  sed -i.bak 's|PRODUCTION_STOREFRONT_DOMAINS=.*|PRODUCTION_STOREFRONT_DOMAINS="shop.customer.internal,staging.customer.internal,storefront-3.customer.internal"|' "$config"
  rm -f "$config.bak"
  chmod 600 "$config"
  run bash "$REPO_ROOT/scripts/00-prepare-customer.sh" --config "$config" --dry-run
  rm -f "$config"
  [ "$status" -ne 0 ]
  [[ "$output" == *"vollständig getrennt"* ]]
}

@test "deployment accepts registry digests only and is CI gated" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  grep -q '@sha256:' "$REPO_ROOT/templates/server/deploy-wrapper.sh.tpl"
  ! grep -q 'EXPECTED_PREFIX=.*ENVIRONMENT' "$REPO_ROOT/templates/server/deploy-wrapper.sh.tpl"
  grep -q 'workflow_run:' "$REPO_ROOT/templates/github/deploy-staging.yml.tpl"
  grep -q 'Require successful CI for this exact commit' "$REPO_ROOT/templates/github/deploy-production.yml.tpl"
}

@test "backup quiesces write services before the file and database snapshot" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  quiesce_line="$(grep -n '^quiesce_writes$' "$REPO_ROOT/templates/server/backup.sh.tpl" | cut -d: -f1)"
  sync_line="$(grep -n 'rclone sync.*S3_PUBLIC_BUCKET' "$REPO_ROOT/templates/server/backup.sh.tpl" | cut -d: -f1)"
  dump_line="$(grep -n 'mariadb-dump' "$REPO_ROOT/templates/server/backup.sh.tpl" | cut -d: -f1)"
  resume_line="$(grep -n '^resume_writes$' "$REPO_ROOT/templates/server/backup.sh.tpl" | cut -d: -f1)"
  [ "$quiesce_line" -lt "$sync_line" ]
  [ "$sync_line" -lt "$dump_line" ]
  [ "$dump_line" -lt "$resume_line" ]
}
