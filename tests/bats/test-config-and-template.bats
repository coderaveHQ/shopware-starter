#!/usr/bin/env bats
setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  TEST_TMPDIR="$(mktemp -d)"
  source "$REPO_ROOT/scripts/lib/logging.sh"
  source "$REPO_ROOT/scripts/lib/checks.sh"
  source "$REPO_ROOT/scripts/lib/config.sh"
  source "$REPO_ROOT/scripts/lib/templates.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }
@test "normalize_slug normalizes names" {
  run normalize_slug "Heinz Hesse GmbH & Co. KG"
  [ "$status" -eq 0 ]
  [ "$output" = "heinz-hesse-gmbh-co-kg" ]
}
@test "render_template replaces uppercase placeholders" {
  tmpdir="$(mktemp -d)"
  printf 'Hello {{NAME}} / keep ${{ github.sha }}\n' > "$tmpdir/input.tpl"
  export NAME="Shopware"
  run render_template "$tmpdir/input.tpl" "$tmpdir/output.txt"
  [ "$status" -eq 0 ]
  grep -q 'Hello Shopware' "$tmpdir/output.txt"
  grep -q '\${{ github.sha }}' "$tmpdir/output.txt"
}
@test "check_ubuntu accepts supported 64-bit LTS releases" {
  printf 'ID=ubuntu\nVERSION_ID="26.04"\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' > "$TEST_TMPDIR/os-release"
  run check_ubuntu "$TEST_TMPDIR/os-release"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unterstütztes 64-Bit-Ubuntu erkannt"* ]]
}
@test "check_ubuntu rejects unsupported Ubuntu releases" {
  printf 'ID=ubuntu\nVERSION_ID="25.10"\nPRETTY_NAME="Ubuntu 25.10"\n' > "$TEST_TMPDIR/os-release"
  run check_ubuntu "$TEST_TMPDIR/os-release"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Nicht unterstützte Ubuntu-Version"* ]]
}
