#!/usr/bin/env bats
@test "production script refuses staging config" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  run bash "$REPO_ROOT/scripts/02-setup-production-server.sh" --config "$REPO_ROOT/tests/fixtures/staging-server.env" --test-mode
  [ "$status" -ne 0 ]
  [[ "$output" == *"Falsche Config"* || "$output" == *"ERROR"* ]]
}
