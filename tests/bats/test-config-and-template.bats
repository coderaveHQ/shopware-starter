#!/usr/bin/env bats
setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  TEST_TMPDIR="$(mktemp -d)"
  source "$REPO_ROOT/scripts/lib/logging.sh"
  source "$REPO_ROOT/scripts/lib/checks.sh"
  source "$REPO_ROOT/scripts/lib/config.sh"
  source "$REPO_ROOT/scripts/lib/templates.sh"
  DRY_RUN=0
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "normalize_slug normalizes names" {
  run normalize_slug "Heinz Hesse GmbH & Co. KG"
  [ "$status" -eq 0 ]
  [ "$output" = "heinz-hesse-gmbh-co-kg" ]
}

@test "render_template applies explicit filters and preserves GitHub expressions" {
  printf 'raw={{NAME}} dotenv={{VALUE|dotenv}} yaml={{VALUE|yaml}} keep=${{ github.sha }}\n' > "$TEST_TMPDIR/input.tpl"
  export NAME="Shopware" VALUE="safe-value"
  run render_template "$TEST_TMPDIR/input.tpl" "$TEST_TMPDIR/output.txt"
  [ "$status" -eq 0 ]
  grep -q 'raw=Shopware' "$TEST_TMPDIR/output.txt"
  grep -q 'dotenv="safe-value"' "$TEST_TMPDIR/output.txt"
  grep -q '\${{ github.sha }}' "$TEST_TMPDIR/output.txt"
}

@test "load_env_file treats command substitution as inert data" {
  printf 'SAFE_VALUE='"'"'$(touch %s)'"'"'\n' "$TEST_TMPDIR/pwned" > "$TEST_TMPDIR/safe.env"
  load_env_file "$TEST_TMPDIR/safe.env" SAFE_VALUE
  [ ! -e "$TEST_TMPDIR/pwned" ]
  [ "$SAFE_VALUE" = "\$(touch $TEST_TMPDIR/pwned)" ]
}

@test "load_env_file rejects non-allowlisted variables" {
  printf 'PATH="/tmp/evil"\n' > "$TEST_TMPDIR/unsafe.env"
  run load_env_file "$TEST_TMPDIR/unsafe.env" SAFE_VALUE
  [ "$status" -ne 0 ]
}

@test "load_env_file never inherits a missing value from the process" {
  printf '# intentionally empty\n' > "$TEST_TMPDIR/empty.env"
  export SAFE_VALUE="inherited-value"
  load_env_file "$TEST_TMPDIR/empty.env" SAFE_VALUE
  [ -z "${SAFE_VALUE+x}" ]
}

@test "render_template dry-run does not create destination" {
  printf 'Hello {{NAME}}\n' > "$TEST_TMPDIR/input.tpl"
  export NAME=Shopware DRY_RUN=1
  render_template "$TEST_TMPDIR/input.tpl" "$TEST_TMPDIR/output.txt"
  [ ! -e "$TEST_TMPDIR/output.txt" ]
}

@test "check_ubuntu accepts supported 64-bit releases" {
  printf 'ID=ubuntu\nVERSION_ID="26.04"\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' > "$TEST_TMPDIR/os-release"
  run check_ubuntu "$TEST_TMPDIR/os-release"
  [ "$status" -eq 0 ]
}

@test "check_ubuntu rejects unsupported releases without sourcing them" {
  printf 'ID=ubuntu\nVERSION_ID="25.10"\nPRETTY_NAME="Ubuntu 25.10"\nMALICIOUS="$(touch %s)"\n' "$TEST_TMPDIR/pwned" > "$TEST_TMPDIR/os-release"
  run check_ubuntu "$TEST_TMPDIR/os-release"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/pwned" ]
}

@test "check_server_resources enforces Shopware memory and disk minimums" {
  TEST_MODE=1
  SHOPWARE_INFRA_TEST_MEMORY_KB=$((8 * 1024 * 1024))
  SHOPWARE_INFRA_TEST_DISK_KB=$((10 * 1024 * 1024))
  SHOPWARE_INFRA_TEST_CPU_COUNT=4
  run check_server_resources
  [ "$status" -eq 0 ]

  SHOPWARE_INFRA_TEST_MEMORY_KB=$((8 * 1024 * 1024 - 1))
  run check_server_resources
  [ "$status" -ne 0 ]
}
