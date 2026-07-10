#!/usr/bin/env bats
setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  source "$REPO_ROOT/scripts/lib/logging.sh"
  source "$REPO_ROOT/scripts/lib/checks.sh"
  source "$REPO_ROOT/scripts/lib/secrets.sh"
}
@test "generate_password creates requested length" {
  run generate_password 32
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 32 ]
}
@test "generate_hex_secret creates hex output" {
  run generate_hex_secret 16
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{32}$ ]]
}
