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
