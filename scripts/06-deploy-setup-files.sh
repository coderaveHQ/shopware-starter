#!/usr/bin/env bash
# Verified local transfer and optional one-shot remote setup orchestrator.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
CONFIG_FILE="$REPO_ROOT/generated/customer.env"; REMOTE_DIR="/root/shopware-setup"

usage() { cat <<USAGE
Usage: bash scripts/06-deploy-setup-files.sh --target staging|production|all [--config generated/customer.env] [--run] [--dry-run]

The first SSH connection is allowed only when the scanned ED25519 host key
matches the independently supplied SHA256 fingerprint.
USAGE
}

if ! parse_common_args "$@"; then usage; exit 0; fi
[[ -n "$TARGET" ]] || die "--target staging|production|all fehlt."
[[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/generated/customer.env"
if [[ "$DRY_RUN" == 1 ]]; then
  SHOPWARE_INFRA_TOTAL=2
elif [[ "$RUN_REMOTE" == 1 && "$TARGET" == all ]]; then
  SHOPWARE_INFRA_TOTAL=12
elif [[ "$RUN_REMOTE" == 1 ]]; then
  SHOPWARE_INFRA_TOTAL=7
elif [[ "$TARGET" == all ]]; then
  SHOPWARE_INFRA_TOTAL=6
else
  SHOPWARE_INFRA_TOTAL=4
fi

expand_path() { local value="$1"; [[ "$value" == ~* ]] && printf '%s%s' "$HOME" "${value#~}" || printf '%s' "$value"; }

verify_host_key() {
  local host="$1" port="$2" expected="$3" destination="$4" scan fingerprint
  scan="$(mktemp)"; chmod 600 "$scan"
  ssh-keyscan -p "$port" -t ed25519 "$host" > "$scan" 2>/dev/null || { rm -f "$scan"; die "ED25519 Host Key konnte nicht gelesen werden: $host:$port"; }
  fingerprint="$(ssh-keygen -lf "$scan" -E sha256 | awk 'NR==1 {print $2}')"
  [[ "$fingerprint" == "$expected" ]] || { rm -f "$scan"; die "SSH Host-Key-Fingerprint stimmt nicht: erwartet $expected, erhalten $fingerprint"; }
  mkdir -p "$(dirname "$destination")"; cp "$scan" "$destination"; chmod 600 "$destination"; rm -f "$scan"
  ok "SSH Host Key unabhängig bestätigt: $host:$port / $fingerprint"
}

run_remote_command() {
  local host="$1" port="$2" user="$3" key="$4" known_hosts="$5" command="$6"
  ssh -p "$port" -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ServerAliveInterval=30 "$user@$host" "$command"
}

copy_to_remote() {
  local host="$1" port="$2" user="$3" key="$4" known_hosts="$5" source="$6" dest="$7" scp_host="$1"
  [[ "$scp_host" == *:* ]] && scp_host="[$scp_host]"
  scp -P "$port" -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -r "$source" "$user@$scp_host:$dest"
}

step "Konfiguration und lokale Dateien validieren"
assert_private_file "$CONFIG_FILE"
load_env_file "$CONFIG_FILE" "${GENERATED_CUSTOMER_CONFIG_KEYS[@]}"
validate_customer_config
for file in "$REPO_ROOT/generated/staging-server.env" "$REPO_ROOT/generated/production-server.env" "$REPO_ROOT/generated/ssh/staging-admin-ed25519" "$REPO_ROOT/generated/ssh/production-admin-ed25519"; do assert_file_exists "$file"; done
require_command ssh; require_command scp; require_command ssh-keyscan; require_command ssh-keygen

if [[ "$DRY_RUN" == 1 ]]; then
  step "Änderungsfreien Plan ausgeben"
  log "[DRY-RUN] Würde Host Key gegen hinterlegten Fingerprint prüfen, Setup kopieren und --run respektieren."
  ok "Transfer-Dry-run ohne Netzwerkzugriff oder Dateimutation abgeschlossen"
  exit 0
fi

deploy_one() {
  local env_name="$1" prefix host scp_host root_user root_port root_key fingerprint env_file setup_script s3_marker initial_known admin_key final_known summary_tmp vault known_hosts_value
  prefix="$(printf '%s' "$env_name" | tr '[:lower:]' '[:upper:]')"
  case "$env_name" in
    staging) host="$STAGING_SERVER_HOST"; root_user="$STAGING_ROOT_SSH_USER"; root_port="$STAGING_ROOT_SSH_PORT"; root_key="$(expand_path "$STAGING_ROOT_SSH_KEY_PATH")"; fingerprint="$STAGING_SSH_HOST_KEY_SHA256"; env_file="$REPO_ROOT/generated/staging-server.env"; setup_script="scripts/01-setup-staging-server.sh"; admin_key="$REPO_ROOT/generated/ssh/staging-admin-ed25519" ;;
    production) host="$PRODUCTION_SERVER_HOST"; root_user="$PRODUCTION_ROOT_SSH_USER"; root_port="$PRODUCTION_ROOT_SSH_PORT"; root_key="$(expand_path "$PRODUCTION_ROOT_SSH_KEY_PATH")"; fingerprint="$PRODUCTION_SSH_HOST_KEY_SHA256"; env_file="$REPO_ROOT/generated/production-server.env"; setup_script="scripts/02-setup-production-server.sh"; admin_key="$REPO_ROOT/generated/ssh/production-admin-ed25519" ;;
    *) die "Ungültiges Target: $env_name" ;;
  esac
  scp_host="$host"; [[ "$scp_host" == *:* ]] && scp_host="[$scp_host]"
  s3_marker="$REPO_ROOT/generated/s3-$env_name.verified"
  assert_private_file "$s3_marker"
  [[ "$(awk -F= '$1=="config_sha256" {print $2}' "$s3_marker")" == "$(file_sha256 "$CONFIG_FILE")" ]] || die "$env_name S3-Verifikation fehlt oder ist nach einer Konfigurationsänderung veraltet."
  for file in "$root_key" "$admin_key" "$env_file" "$REPO_ROOT/$setup_script"; do assert_file_exists "$file"; done
  assert_private_file "$root_key"
  assert_private_file "$admin_key"
  assert_private_file "$env_file"
  initial_known="$REPO_ROOT/generated/known-hosts/${env_name}-initial"
  final_known="$REPO_ROOT/generated/known-hosts/${env_name}-deploy"

  step "$env_name: Host Key vor erster Verbindung verifizieren"
  verify_host_key "$host" "$root_port" "$fingerprint" "$initial_known"
  run_remote_command "$host" "$root_port" "$root_user" "$root_key" "$initial_known" "install -d -m 700 '$REMOTE_DIR'"

  step "$env_name: Setup-Dateien sicher kopieren"
  copy_to_remote "$host" "$root_port" "$root_user" "$root_key" "$initial_known" "$REPO_ROOT/scripts" "$REMOTE_DIR/"
  copy_to_remote "$host" "$root_port" "$root_user" "$root_key" "$initial_known" "$REPO_ROOT/templates" "$REMOTE_DIR/"
  scp -P "$root_port" -i "$root_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$initial_known" "$env_file" "$root_user@$scp_host:$REMOTE_DIR/${env_name}-server.env"
  run_remote_command "$host" "$root_port" "$root_user" "$root_key" "$initial_known" "chmod 600 '$REMOTE_DIR/${env_name}-server.env' && chmod -R u+rwX '$REMOTE_DIR/scripts' '$REMOTE_DIR/templates'"

  if [[ "$RUN_REMOTE" != 1 ]]; then warn "$env_name: Dateien verifiziert kopiert; Server-Setup wurde ohne --run nicht gestartet."; return 0; fi

  step "$env_name: One-shot-Server-Setup ausführen"
  run_remote_command "$host" "$root_port" "$root_user" "$root_key" "$initial_known" "cd '$REMOTE_DIR' && bash '$setup_script' --config '$REMOTE_DIR/${env_name}-server.env'"

  step "$env_name: Gehärteten Admin-Zugang verifizieren"
  verify_host_key "$host" "$SSH_PORT" "$fingerprint" "$final_known"
  run_remote_command "$host" "$SSH_PORT" "$ADMIN_USER" "$admin_key" "$final_known" "sudo test -f '$REMOTE_DIR/${env_name}-server-summary.md'"
  summary_tmp="$REPO_ROOT/generated/server-summaries/${env_name}-server-summary.md"
  scp -P "$SSH_PORT" -i "$admin_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$final_known" "$ADMIN_USER@$scp_host:$REMOTE_DIR/${env_name}-server-summary.md" "$summary_tmp"

  step "$env_name: GitHub Known Host speichern und Setup-Secrets entfernen"
  known_hosts_value="$(<"$final_known")"; vault="$REPO_ROOT/generated/customer-vault.md"
  if [[ -f "$vault" ]]; then vault_section "$vault" "$env_name verified deploy access"; vault_block "$vault" "${prefix}_SSH_KNOWN_HOSTS" "$known_hosts_value"; vault_append_file "$vault" "$env_name Server Summary" "$summary_tmp"; fi
  run_remote_command "$host" "$SSH_PORT" "$ADMIN_USER" "$admin_key" "$final_known" "sudo find '$REMOTE_DIR' -type f -exec shred -u {} + 2>/dev/null || true; sudo rm -rf '$REMOTE_DIR'"
  ok "$env_name: Server vorbereitet, Root-SSH deaktiviert und Setup-Kopie entfernt"
}

case "$TARGET" in staging) deploy_one staging ;; production) deploy_one production ;; all) deploy_one staging; deploy_one production ;; *) die "Ungültiges Target: $TARGET" ;; esac
step "Transfer abschließen"
ok "Verifizierter Setup-Transfer abgeschlossen."
