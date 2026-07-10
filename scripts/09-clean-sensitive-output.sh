#!/usr/bin/env bash
# Removes local plaintext setup material only after explicit password-manager confirmation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
CONFIRMATION=""; CONFIG_FILE="$REPO_ROOT/generated/customer.env"
args=()
while [[ $# -gt 0 ]]; do case "$1" in --confirm) [[ $# -ge 2 ]] || die "--confirm benötigt PROJECT_SLUG"; CONFIRMATION="$2"; shift 2 ;; *) args+=("$1"); shift ;; esac; done
parse_common_args "${args[@]}"
assert_file_exists "$CONFIG_FILE"
assert_private_file "$CONFIG_FILE"
load_env_file "$CONFIG_FILE" "${GENERATED_CUSTOMER_CONFIG_KEYS[@]}"
[[ "$CONFIRMATION" == "$PROJECT_SLUG" ]] || die "Nach Passwort-Manager-Import mit --confirm $PROJECT_SLUG bestätigen."
if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] Würde customer.env, Vault, Server-Configs und lokale SSH Private Keys entfernen."; exit 0; fi
for file in "$REPO_ROOT/customer.env" "$REPO_ROOT/generated/customer.env" "$REPO_ROOT/generated/staging-server.env" "$REPO_ROOT/generated/production-server.env" "$REPO_ROOT/generated/customer-vault.md" "$REPO_ROOT/generated/ssh"/*; do
  [[ -e "$file" ]] || continue
  if command_exists shred && [[ -f "$file" ]]; then shred -u "$file" || rm -f "$file"; else rm -f "$file"; fi
done
rmdir "$REPO_ROOT/generated/ssh" 2>/dev/null || true
ok "Lokale Klartext-Secrets entfernt. SSD/Copy-on-write kann sichere physische Löschung nicht garantieren."
