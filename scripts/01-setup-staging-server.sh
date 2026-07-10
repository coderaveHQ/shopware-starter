#!/usr/bin/env bash
# Runs on the staging VPS. No manual variables in this script; it consumes staging-server.env.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
usage() { echo "Usage: sudo bash scripts/01-setup-staging-server.sh --config /root/shopware-setup/staging-server.env [--dry-run] [--test-mode]"; }
if ! parse_common_args "$@"; then usage; exit 0; fi
[[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="/root/shopware-setup/staging-server.env"
setup_shopware_server "$CONFIG_FILE" "staging"
