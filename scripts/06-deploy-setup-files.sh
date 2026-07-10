#!/usr/bin/env bash
# Local orchestrator: copies generated files and setup scripts to staging/production and optionally runs the remote setup.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
CONFIG_FILE="$REPO_ROOT/generated/customer.env"; REMOTE_DIR="/root/shopware-setup"; RUN_REMOTE=0
usage(){ cat <<USAGE
Usage: bash scripts/06-deploy-setup-files.sh --target staging|production|all [--config generated/customer.env] [--run] [--dry-run]

Copies scripts/, templates/ and generated <target>-server.env to the target server. With --run it executes the setup script remotely.
USAGE
}
if ! parse_common_args "$@"; then usage; exit 0; fi
[[ -n "$TARGET" ]] || die "Bitte --target staging|production|all angeben."; [[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/generated/customer.env"; SHOPWARE_INFRA_TOTAL=6
expand_path(){ local value="$1"; [[ "$value" == ~* ]] && printf '%s%s' "$HOME" "${value#~}" || printf '%s' "$value"; }
run_remote_command(){ local host="$1" port="$2" user="$3" key="$4" command="$5"; if [[ "$DRY_RUN" == "1" ]]; then log "[DRY-RUN] ssh -p $port -i $key $user@$host $command"; return 0; fi; ssh -p "$port" -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 "$user@$host" "$command"; }
copy_to_remote(){ local host="$1" port="$2" user="$3" key="$4" source="$5" dest="$6"; if [[ "$DRY_RUN" == "1" ]]; then log "[DRY-RUN] copy $source -> $user@$host:$dest"; return 0; fi; if command_exists rsync; then rsync -az --delete -e "ssh -p $port -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" "$source" "$user@$host:$dest"; else scp -P "$port" -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -r "$source" "$user@$host:$dest"; fi; }
known_hosts_for(){ local host="$1" port="$2"; command_exists ssh-keyscan && ssh-keyscan -p "$port" -H "$host" 2>/dev/null || true; }

deploy_one(){
  local env_name="$1" host user port key_path env_file setup_script env_upper known_hosts summary_tmp
  env_upper="$(printf '%s' "$env_name" | tr '[:lower:]' '[:upper:]')"
  case "$env_name" in
    staging) host="$STAGING_SERVER_HOST"; user="$STAGING_ROOT_SSH_USER"; port="${STAGING_ROOT_SSH_PORT:-22}"; key_path="$(expand_path "$STAGING_ROOT_SSH_KEY_PATH")"; env_file="$REPO_ROOT/generated/staging-server.env"; setup_script="scripts/01-setup-staging-server.sh" ;;
    production) host="$PRODUCTION_SERVER_HOST"; user="$PRODUCTION_ROOT_SSH_USER"; port="${PRODUCTION_ROOT_SSH_PORT:-22}"; key_path="$(expand_path "$PRODUCTION_ROOT_SSH_KEY_PATH")"; env_file="$REPO_ROOT/generated/production-server.env"; setup_script="scripts/02-setup-production-server.sh" ;;
    *) die "Ungültiges Target: $env_name" ;;
  esac
  assert_not_empty host; assert_not_empty user; assert_not_empty port; assert_not_empty key_path; assert_file_exists "$env_file"; assert_file_exists "$REPO_ROOT/$setup_script"; [[ -f "$key_path" ]] || die "SSH-Key für $env_name nicht gefunden: $key_path"
  step "$env_name: SSH-Verbindung prüfen"; run_remote_command "$host" "$port" "$user" "$key_path" "mkdir -p '$REMOTE_DIR' && chmod 700 '$REMOTE_DIR'"; ok "$env_name: Remote-Verzeichnis bereit"
  step "$env_name: Setup-Dateien kopieren"; copy_to_remote "$host" "$port" "$user" "$key_path" "$REPO_ROOT/scripts" "$REMOTE_DIR/"; copy_to_remote "$host" "$port" "$user" "$key_path" "$REPO_ROOT/templates" "$REMOTE_DIR/"; if [[ "$DRY_RUN" == "1" ]]; then log "[DRY-RUN] copy $env_file -> $user@$host:$REMOTE_DIR/${env_name}-server.env"; else scp -P "$port" -i "$key_path" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "$env_file" "$user@$host:$REMOTE_DIR/${env_name}-server.env"; fi; run_remote_command "$host" "$port" "$user" "$key_path" "chmod 600 '$REMOTE_DIR/${env_name}-server.env' && chmod -R u+rwX '$REMOTE_DIR/scripts' '$REMOTE_DIR/templates'"; ok "$env_name: Dateien kopiert"
  step "$env_name: Known Hosts und Vault erweitern"; known_hosts="$(known_hosts_for "$host" "$port")"; VAULT_FILE="$REPO_ROOT/generated/customer-vault.md"; if [[ -f "$VAULT_FILE" ]]; then vault_section "$VAULT_FILE" "$env_name Remote Setup Transfer"; vault_kv "$VAULT_FILE" "${env_upper}_SETUP_REMOTE_DIR" "$REMOTE_DIR"; vault_kv "$VAULT_FILE" "${env_upper}_SETUP_SCRIPT" "$REMOTE_DIR/$setup_script"; vault_kv "$VAULT_FILE" "${env_upper}_SERVER_ENV" "$REMOTE_DIR/${env_name}-server.env"; vault_block "$VAULT_FILE" "${env_upper}_SSH_KNOWN_HOSTS" "$known_hosts"; fi
  if [[ "$RUN_REMOTE" == "1" ]]; then step "$env_name: Remote Setup ausführen"; run_remote_command "$host" "$port" "$user" "$key_path" "cd '$REMOTE_DIR' && bash '$setup_script' --config '$REMOTE_DIR/${env_name}-server.env'"; ok "$env_name: Remote Setup beendet"; step "$env_name: Server Summary zurückholen"; summary_tmp="$REPO_ROOT/generated/server-summaries/${env_name}-server-summary.md"; mkdir -p "$(dirname "$summary_tmp")"; if [[ "$DRY_RUN" != "1" ]]; then scp -P "$port" -i "$key_path" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "$user@$host:$REMOTE_DIR/${env_name}-server-summary.md" "$summary_tmp" || warn "Server-Summary konnte nicht zurückkopiert werden."; [[ -f "$summary_tmp" && -f "$VAULT_FILE" ]] && vault_append_file "$VAULT_FILE" "$env_name Server Summary" "$summary_tmp"; fi; else warn "$env_name: --run nicht gesetzt; Setup wurde nur kopiert, nicht ausgeführt."; fi
}
step "Config laden"; load_env_file "$CONFIG_FILE"; for var in STAGING_SERVER_HOST PRODUCTION_SERVER_HOST STAGING_ROOT_SSH_USER PRODUCTION_ROOT_SSH_USER STAGING_ROOT_SSH_KEY_PATH PRODUCTION_ROOT_SSH_KEY_PATH; do assert_not_empty "$var"; done
case "$TARGET" in staging) deploy_one staging ;; production) deploy_one production ;; all) deploy_one staging; deploy_one production ;; *) die "Ungültiges Target: $TARGET" ;; esac
step "Fertig"; ok "Setup-Dateien wurden übertragen. Vault: $REPO_ROOT/generated/customer-vault.md"
