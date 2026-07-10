#!/usr/bin/env bash
# Common bootstrap for all scripts.
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"; else REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"; fi
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/logging.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/checks.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/config.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/validation.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/secrets.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/vault.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/templates.sh"

# These globals are consumed by the calling script after this library is sourced.
# shellcheck disable=SC2034
DRY_RUN=0; TEST_MODE="${SHOPWARE_INFRA_TEST_MODE:-0}"; CONFIG_FILE=""; TARGET=""; RUN_REMOTE=0

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) [[ $# -ge 2 ]] || die "--config benötigt einen Pfad"; CONFIG_FILE="$2"; shift 2 ;;
      --target) [[ $# -ge 2 ]] || die "--target benötigt einen Wert"; TARGET="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --test-mode) TEST_MODE=1; export SHOPWARE_INFRA_TEST_MODE=1; shift ;;
      --run) RUN_REMOTE=1; shift ;;
      -h|--help) return 1 ;;
      *) die "Unbekanntes Argument: $1" ;;
    esac
  done
}
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/system.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/docker.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/remote.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/server-common.sh"
