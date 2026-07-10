#!/usr/bin/env bats
setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  source "$REPO_ROOT/scripts/lib/logging.sh"
  source "$REPO_ROOT/scripts/lib/checks.sh"
  source "$REPO_ROOT/scripts/lib/config.sh"
  source "$REPO_ROOT/scripts/lib/templates.sh"
}
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
