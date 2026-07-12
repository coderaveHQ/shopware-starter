#!/usr/bin/env bash
# One-shot local preparation. Generates isolated credentials without executing config as shell code.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"

SHOPWARE_INFRA_TOTAL=9
CONFIG_FILE="$REPO_ROOT/customer.env"
ROTATE_SECRETS=0
ROTATION_CONFIRMATION=""

usage() { cat <<USAGE
Usage: bash scripts/00-prepare-customer.sh [--config customer.env] [--dry-run]

First run creates generated customer/server configs, four SSH keys and the vault.
An existing preparation is never overwritten. Intentional rotation requires:
  --rotate-secrets --confirm-rotation <PROJECT_SLUG>
USAGE
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate-secrets) ROTATE_SECRETS=1; shift ;;
    --confirm-rotation) [[ $# -ge 2 ]] || die "--confirm-rotation benötigt PROJECT_SLUG"; ROTATION_CONFIRMATION="$2"; shift 2 ;;
    --force) die "--force ist für Secret-Erzeugung gesperrt. Verwende die explizite Rotation laut --help." ;;
    *) args+=("$1"); shift ;;
  esac
done
if ! parse_common_args "${args[@]}"; then usage; exit 0; fi
[[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/customer.env"
[[ "$DRY_RUN" == 1 ]] && SHOPWARE_INFRA_TOTAL=4

step "Lokale Voraussetzungen prüfen"
require_not_root
for command in bash python3 openssl ssh-keygen ssh scp git; do require_command "$command"; done
if command_exists composer; then ok "Composer vorhanden: $(composer --version | head -n1)"; else warn "Composer fehlt; Repo-Initialisierung benötigt Composer."; fi
if command_exists docker; then ok "Docker vorhanden: $(docker --version)"; else warn "Docker fehlt; Image-Validierung ist später nicht möglich."; fi

step "Kundenkonfiguration laden"
if [[ ! -f "$CONFIG_FILE" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    die "Konfiguration fehlt. Dry-run erstellt keine Datei: $CONFIG_FILE"
  fi
  cp "$REPO_ROOT/templates/customer/customer.env.example" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  warn "customer.env wurde als Vorlage erzeugt. Ausfüllen und erneut starten: $CONFIG_FILE"
  exit 2
fi
assert_private_file "$CONFIG_FILE"
load_env_file "$CONFIG_FILE" "${CUSTOMER_CONFIG_KEYS[@]}"
PROJECT_SLUG="${PROJECT_SLUG:-$(normalize_slug "${CUSTOMER_NAME:-shopware-project}")}"
export PROJECT_SLUG

step "Konfiguration strikt validieren"
validate_customer_config
GHCR_IMAGE="ghcr.io/$GITHUB_OWNER/$GITHUB_REPO/shopware"
export GHCR_IMAGE

GENERATED_DIR="$REPO_ROOT/generated"
SSH_DIR="$GENERATED_DIR/ssh"
VAULT_FILE="$GENERATED_DIR/customer-vault.md"
PREPARATION_MARKER="$GENERATED_DIR/.prepared"
if [[ -e "$PREPARATION_MARKER" || -e "$VAULT_FILE" || -e "$GENERATED_DIR/staging-server.env" || -e "$GENERATED_DIR/production-server.env" ]]; then
  if [[ "$ROTATE_SECRETS" != 1 ]]; then
    die "Vorbereitung existiert bereits. Dateien werden nicht überschrieben. Für eine geplante Rotation die dokumentierte Rotation verwenden."
  fi
  [[ "$ROTATION_CONFIRMATION" == "$PROJECT_SLUG" ]] || die "Rotation erfordert --confirm-rotation $PROJECT_SLUG"
  warn "Explizit bestätigte vollständige Secret- und SSH-Key-Rotation"
elif [[ "$ROTATE_SECRETS" == 1 ]]; then
  die "Keine bestehende Vorbereitung gefunden; --rotate-secrets ist nicht zulässig."
fi

if [[ "$DRY_RUN" == 1 ]]; then
  step "Änderungsfreien Plan ausgeben"
  log "[DRY-RUN] Würde isolierte Staging-/Production-Secrets und vier SSH-Keys unter generated/ erzeugen."
  log "[DRY-RUN] Würde keine Datei anlegen, ändern oder löschen."
  ok "Dry-run ohne Mutation abgeschlossen"
  exit 0
fi

umask 077
step "Secret-Verzeichnis und SSH-Keys erzeugen"
mkdir -p "$SSH_DIR" "$GENERATED_DIR/server-summaries" "$GENERATED_DIR/known-hosts"
chmod 700 "$GENERATED_DIR" "$SSH_DIR" "$GENERATED_DIR/server-summaries" "$GENERATED_DIR/known-hosts"
ensure_ssh_key "$SSH_DIR/staging-admin-ed25519" "$PROJECT_SLUG staging admin" "$ROTATE_SECRETS"
ensure_ssh_key "$SSH_DIR/staging-github-actions-ed25519" "$PROJECT_SLUG staging github-actions" "$ROTATE_SECRETS"
ensure_ssh_key "$SSH_DIR/production-admin-ed25519" "$PROJECT_SLUG production admin" "$ROTATE_SECRETS"
ensure_ssh_key "$SSH_DIR/production-github-actions-ed25519" "$PROJECT_SLUG production github-actions" "$ROTATE_SECRETS"

STAGING_ADMIN_PUBLIC_KEY="$(<"$SSH_DIR/staging-admin-ed25519.pub")"
STAGING_GITHUB_ACTIONS_PUBLIC_KEY="$(<"$SSH_DIR/staging-github-actions-ed25519.pub")"
PRODUCTION_ADMIN_PUBLIC_KEY="$(<"$SSH_DIR/production-admin-ed25519.pub")"
PRODUCTION_GITHUB_ACTIONS_PUBLIC_KEY="$(<"$SSH_DIR/production-github-actions-ed25519.pub")"

step "Getrennte Anwendungs- und Backup-Secrets erzeugen"
APP_SECRET_STAGING="$(generate_hex_secret 32)"; APP_SECRET_PRODUCTION="$(generate_hex_secret 32)"
INSTALL_ADMIN_PASSWORD_STAGING="$(generate_password 32)"; INSTALL_ADMIN_PASSWORD_PRODUCTION="$(generate_password 32)"
DB_ROOT_PASSWORD_STAGING="$(generate_password 48)"; DB_PASSWORD_STAGING="$(generate_password 48)"
DB_ROOT_PASSWORD_PRODUCTION="$(generate_password 48)"; DB_PASSWORD_PRODUCTION="$(generate_password 48)"
REDIS_PASSWORD_STAGING="$(generate_password 48)"; REDIS_PASSWORD_PRODUCTION="$(generate_password 48)"
RABBITMQ_PASSWORD_STAGING="$(generate_password 48)"; RABBITMQ_PASSWORD_PRODUCTION="$(generate_password 48)"
BACKUP_ENCRYPTION_PASSPHRASE_STAGING="$(generate_password 64)"; BACKUP_ENCRYPTION_PASSPHRASE_PRODUCTION="$(generate_password 64)"

step "Gemeinsame, nicht ausführbare Konfiguration schreiben"
CUSTOMER_GENERATED_ENV="$GENERATED_DIR/customer.env"
: > "$CUSTOMER_GENERATED_ENV"
for key in "${CUSTOMER_CONFIG_KEYS[@]}"; do write_kv "$CUSTOMER_GENERATED_ENV" "$key" "${!key:-}"; done
write_kv "$CUSTOMER_GENERATED_ENV" GHCR_IMAGE "$GHCR_IMAGE"
chmod 600 "$CUSTOMER_GENERATED_ENV"

write_server_env() {
  local env_name="$1" prefix="$2" domain="$3" app_secret="$4" admin_password="$5" db_root_password="$6" db_password="$7" redis_password="$8" rabbit_password="$9" admin_pub="${10}" gha_pub="${11}" backup_passphrase="${12}"
  local out="$GENERATED_DIR/${env_name}-server.env" install_dir="$INSTALL_BASE_DIR/$PROJECT_SLUG/$env_name" staging_flag=0 name storefront_domains_name
  [[ "$env_name" == staging ]] && staging_flag=1
  : > "$out"
  write_kv "$out" ENVIRONMENT "$env_name"
  write_kv "$out" CUSTOMER_NAME "$CUSTOMER_NAME"
  write_kv "$out" PROJECT_SLUG "$PROJECT_SLUG"
  write_kv "$out" PRIMARY_DOMAIN "$domain"
  storefront_domains_name="${prefix}_STOREFRONT_DOMAINS"; write_kv "$out" STOREFRONT_DOMAINS "${!storefront_domains_name}"
  write_kv "$out" ADMIN_EMAIL "$ADMIN_EMAIL"
  write_kv "$out" TIMEZONE "$TIMEZONE"
  write_kv "$out" ADMIN_USER "$ADMIN_USER"
  write_kv "$out" DEPLOY_USER "$DEPLOY_USER"
  write_kv "$out" ADMIN_PUBLIC_KEY "$admin_pub"
  write_kv "$out" GITHUB_ACTIONS_DEPLOY_PUBLIC_KEY "$gha_pub"
  name="${prefix}_ROOT_SSH_PORT"; write_kv "$out" INITIAL_SSH_PORT "${!name}"
  write_kv "$out" SSH_PORT "$SSH_PORT"
  write_kv "$out" DISABLE_ROOT_SSH "$DISABLE_ROOT_SSH"
  write_kv "$out" INSTALL_BASE_DIR "$INSTALL_BASE_DIR"
  write_kv "$out" INSTALL_DIR "$install_dir"
  write_kv "$out" COMPOSE_PROJECT_NAME "${PROJECT_SLUG}_${env_name}"
  write_kv "$out" GITHUB_OWNER "$GITHUB_OWNER"
  write_kv "$out" GITHUB_REPO "$GITHUB_REPO"
  write_kv "$out" GHCR_IMAGE "$GHCR_IMAGE"
  write_kv "$out" SHOPWARE_IMAGE "$GHCR_IMAGE:${env_name}-bootstrap"
  for key in PHP_VERSION SHOPWARE_DOCKER_BASE_IMAGE SHOPWARE_CLI_IMAGE MARIADB_IMAGE VALKEY_IMAGE RABBITMQ_IMAGE VARNISH_IMAGE CADDY_IMAGE; do write_kv "$out" "$key" "${!key}"; done
  write_kv "$out" APP_ENV prod
  write_kv "$out" APP_URL "https://$domain"
  write_kv "$out" APP_SECRET "$app_secret"
  write_kv "$out" INSTALL_LOCALE "$INSTALL_LOCALE"
  write_kv "$out" INSTALL_CURRENCY "$INSTALL_CURRENCY"
  write_kv "$out" INSTALL_ADMIN_USERNAME "$INSTALL_ADMIN_USERNAME"
  write_kv "$out" INSTALL_ADMIN_PASSWORD "$admin_password"
  write_kv "$out" SHOPWARE_USAGE_DATA_CONSENT "$SHOPWARE_USAGE_DATA_CONSENT"
  write_kv "$out" SHOPWARE_DEPLOYMENT_STAGING "$staging_flag"
  write_kv "$out" DB_NAME shopware
  write_kv "$out" DB_USER shopware
  write_kv "$out" DB_ROOT_PASSWORD "$db_root_password"
  write_kv "$out" DB_PASSWORD "$db_password"
  write_kv "$out" REDIS_PASSWORD "$redis_password"
  write_kv "$out" RABBITMQ_USER shopware
  write_kv "$out" RABBITMQ_PASSWORD "$rabbit_password"
  for suffix in ENDPOINT REGION USE_PATH_STYLE PUBLIC_BUCKET PRIVATE_BUCKET PUBLIC_URL ACCESS_KEY SECRET_KEY; do name="${prefix}_S3_${suffix}"; write_kv "$out" "S3_${suffix}" "${!name}"; done
  for suffix in ACCESS_KEY SECRET_KEY; do name="${prefix}_S3_BACKUP_READER_${suffix}"; write_kv "$out" "S3_BACKUP_READER_${suffix}" "${!name}"; done
  for suffix in ENDPOINT REGION BUCKET ACCESS_KEY SECRET_KEY; do name="${prefix}_BACKUP_S3_${suffix}"; write_kv "$out" "BACKUP_S3_${suffix}" "${!name}"; done
  name="${prefix}_BACKUP_HEALTHCHECK_URL"; write_kv "$out" BACKUP_HEALTHCHECK_URL "${!name}"
  name="${prefix}_RESTORE_HEALTHCHECK_URL"; write_kv "$out" RESTORE_HEALTHCHECK_URL "${!name}"
  write_kv "$out" BACKUP_ENCRYPTION_PASSPHRASE "$backup_passphrase"
  for key in BACKUP_RETENTION_DAYS BACKUP_HOUR BACKUP_MINUTE RESTORE_TEST_DAY RESTORE_TEST_HOUR RESTORE_TEST_MINUTE; do write_kv "$out" "$key" "${!key}"; done
  for suffix in ACCOUNT_EMAIL ACCOUNT_PASSWORD SHOP_SECRET LICENSE_DOMAIN; do name="${prefix}_SHOPWARE_STORE_${suffix}"; write_kv "$out" "SHOPWARE_STORE_${suffix}" "${!name:-}"; done
  chmod 600 "$out"
}

step "Strikt getrennte Server-Konfigurationen schreiben"
write_server_env staging STAGING "$STAGING_DOMAIN" "$APP_SECRET_STAGING" "$INSTALL_ADMIN_PASSWORD_STAGING" "$DB_ROOT_PASSWORD_STAGING" "$DB_PASSWORD_STAGING" "$REDIS_PASSWORD_STAGING" "$RABBITMQ_PASSWORD_STAGING" "$STAGING_ADMIN_PUBLIC_KEY" "$STAGING_GITHUB_ACTIONS_PUBLIC_KEY" "$BACKUP_ENCRYPTION_PASSPHRASE_STAGING"
write_server_env production PRODUCTION "$PRODUCTION_DOMAIN" "$APP_SECRET_PRODUCTION" "$INSTALL_ADMIN_PASSWORD_PRODUCTION" "$DB_ROOT_PASSWORD_PRODUCTION" "$DB_PASSWORD_PRODUCTION" "$REDIS_PASSWORD_PRODUCTION" "$RABBITMQ_PASSWORD_PRODUCTION" "$PRODUCTION_ADMIN_PUBLIC_KEY" "$PRODUCTION_GITHUB_ACTIONS_PUBLIC_KEY" "$BACKUP_ENCRYPTION_PASSPHRASE_PRODUCTION"

step "Vault für sofortigen Passwort-Manager-Import schreiben"
vault_init "$VAULT_FILE"
vault_section "$VAULT_FILE" "Projekt"
vault_kv "$VAULT_FILE" CUSTOMER_NAME "$CUSTOMER_NAME"
vault_kv "$VAULT_FILE" PROJECT_SLUG "$PROJECT_SLUG"
vault_kv "$VAULT_FILE" GITHUB_REPOSITORY "$GITHUB_OWNER/$GITHUB_REPO"
vault_kv "$VAULT_FILE" SHOPWARE_VERSION "$SHOPWARE_VERSION"
vault_kv "$VAULT_FILE" STAGING_URL "https://$STAGING_DOMAIN"
vault_kv "$VAULT_FILE" STAGING_STOREFRONT_DOMAINS "$STAGING_STOREFRONT_DOMAINS"
vault_kv "$VAULT_FILE" PRODUCTION_URL "https://$PRODUCTION_DOMAIN"
vault_kv "$VAULT_FILE" PRODUCTION_STOREFRONT_DOMAINS "$PRODUCTION_STOREFRONT_DOMAINS"

vault_section "$VAULT_FILE" "SSH Private Keys"
for key in "$SSH_DIR"/*-ed25519; do vault_block "$VAULT_FILE" "$(basename "$key")" "$(<"$key")"; done
vault_section "$VAULT_FILE" "SSH Host Fingerprints"
vault_kv "$VAULT_FILE" STAGING_SSH_HOST_KEY_SHA256 "$STAGING_SSH_HOST_KEY_SHA256"
vault_kv "$VAULT_FILE" PRODUCTION_SSH_HOST_KEY_SHA256 "$PRODUCTION_SSH_HOST_KEY_SHA256"

vault_section "$VAULT_FILE" "Staging Secrets"
for pair in "Shopware Admin Password|$INSTALL_ADMIN_PASSWORD_STAGING" "DB Root Password|$DB_ROOT_PASSWORD_STAGING" "DB Password|$DB_PASSWORD_STAGING" "Redis Password|$REDIS_PASSWORD_STAGING" "RabbitMQ Password|$RABBITMQ_PASSWORD_STAGING" "APP_SECRET|$APP_SECRET_STAGING" "Backup Encryption Passphrase|$BACKUP_ENCRYPTION_PASSPHRASE_STAGING"; do vault_kv "$VAULT_FILE" "${pair%%|*}" "${pair#*|}"; done
vault_section "$VAULT_FILE" "Production Secrets"
for pair in "Shopware Admin Password|$INSTALL_ADMIN_PASSWORD_PRODUCTION" "DB Root Password|$DB_ROOT_PASSWORD_PRODUCTION" "DB Password|$DB_PASSWORD_PRODUCTION" "Redis Password|$REDIS_PASSWORD_PRODUCTION" "RabbitMQ Password|$RABBITMQ_PASSWORD_PRODUCTION" "APP_SECRET|$APP_SECRET_PRODUCTION" "Backup Encryption Passphrase|$BACKUP_ENCRYPTION_PASSPHRASE_PRODUCTION"; do vault_kv "$VAULT_FILE" "${pair%%|*}" "${pair#*|}"; done

vault_section "$VAULT_FILE" "GitHub Environment Secrets"
vault_kv "$VAULT_FILE" STAGING_SSH_HOST "$STAGING_SERVER_HOST"
vault_kv "$VAULT_FILE" STAGING_SSH_PORT "$SSH_PORT"
vault_kv "$VAULT_FILE" STAGING_SSH_USER "$DEPLOY_USER"
vault_block "$VAULT_FILE" STAGING_SSH_PRIVATE_KEY "$(<"$SSH_DIR/staging-github-actions-ed25519")"
vault_kv "$VAULT_FILE" STAGING_SSH_KNOWN_HOSTS "wird nach verifizierter Übertragung ergänzt"
vault_kv "$VAULT_FILE" STAGING_INSTALL_DIR "$INSTALL_BASE_DIR/$PROJECT_SLUG/staging"
vault_kv "$VAULT_FILE" PRODUCTION_SSH_HOST "$PRODUCTION_SERVER_HOST"
vault_kv "$VAULT_FILE" PRODUCTION_SSH_PORT "$SSH_PORT"
vault_kv "$VAULT_FILE" PRODUCTION_SSH_USER "$DEPLOY_USER"
vault_block "$VAULT_FILE" PRODUCTION_SSH_PRIVATE_KEY "$(<"$SSH_DIR/production-github-actions-ed25519")"
vault_kv "$VAULT_FILE" PRODUCTION_SSH_KNOWN_HOSTS "wird nach verifizierter Übertragung ergänzt"
vault_kv "$VAULT_FILE" PRODUCTION_INSTALL_DIR "$INSTALL_BASE_DIR/$PROJECT_SLUG/production"

vault_section "$VAULT_FILE" "Object Storage Credentials"
for prefix in STAGING PRODUCTION; do for suffix in S3_PUBLIC_BUCKET S3_PRIVATE_BUCKET S3_ACCESS_KEY S3_SECRET_KEY S3_BACKUP_READER_ACCESS_KEY S3_BACKUP_READER_SECRET_KEY BACKUP_S3_BUCKET BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY; do key="${prefix}_${suffix}"; vault_kv "$VAULT_FILE" "$key" "${!key}"; done; done

printf 'project=%s\nconfig_sha256=%s\ncreated=%s\n' "$PROJECT_SLUG" "$(file_sha256 "$CONFIG_FILE")" "$(date -Iseconds)" > "$PREPARATION_MARKER"
chmod 600 "$PREPARATION_MARKER" "$VAULT_FILE"

step "Vorbereitung abschließen"
ok "Vorbereitung einmalig abgeschlossen: $GENERATED_DIR"
warn "Vault sofort in den Passwort-Manager importieren und danach lokal mit scripts/09-clean-sensitive-output.sh entfernen."
