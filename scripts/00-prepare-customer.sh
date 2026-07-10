#!/usr/bin/env bash
# Local preparation script. Generates customer config, SSH keys, passwords and the one-file vault.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"

SHOPWARE_INFRA_TOTAL=9
CONFIG_FILE="$REPO_ROOT/customer.env"
usage() { cat <<USAGE
Usage: bash scripts/00-prepare-customer.sh [--config customer.env] [--force] [--dry-run]

Creates generated/customer.env, generated/*-server.env, SSH keys and generated/customer-vault.md.
USAGE
}

if ! parse_common_args "$@"; then usage; exit 0; fi
[[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/customer.env"

step "Local prerequisites prüfen"
require_not_root
for c in bash python3 openssl ssh-keygen ssh scp git; do require_command "$c"; done
if command_exists docker; then ok "Docker lokal vorhanden: $(docker --version)"; else warn "Docker lokal fehlt. Für lokale Shopware- und Docker-Tests später installieren."; fi
if command_exists composer; then ok "Composer vorhanden: $(composer --version | head -n1)"; else warn "Composer fehlt. scripts/05-setup-repo.sh braucht Composer."; fi
if command_exists gh; then ok "GitHub CLI vorhanden: $(gh --version | head -n1)"; else warn "GitHub CLI fehlt optional. GitHub-Secrets können trotzdem manuell gesetzt werden."; fi

step "customer.env vorbereiten/laden"
if [[ ! -f "$CONFIG_FILE" ]]; then
  cp "$REPO_ROOT/templates/customer/customer.env.example" "$CONFIG_FILE"
  warn "customer.env wurde aus dem Example erzeugt. Bitte ausfüllen und Skript erneut starten: $CONFIG_FILE"
  exit 2
fi
load_env_file "$CONFIG_FILE"

step "Pflichtwerte validieren"
PROJECT_SLUG="${PROJECT_SLUG:-$(normalize_slug "${CUSTOMER_NAME:-shopware-project}")}"
GHCR_IMAGE="ghcr.io/${GITHUB_OWNER}/${GITHUB_REPO}/shopware"
for var in CUSTOMER_NAME PROJECT_SLUG ADMIN_EMAIL GITHUB_OWNER GITHUB_REPO STAGING_DOMAIN PRODUCTION_DOMAIN STAGING_SERVER_HOST PRODUCTION_SERVER_HOST STAGING_ROOT_SSH_USER PRODUCTION_ROOT_SSH_USER STAGING_ROOT_SSH_KEY_PATH PRODUCTION_ROOT_SSH_KEY_PATH ADMIN_USER DEPLOY_USER INSTALL_BASE_DIR PHP_VERSION; do assert_not_empty "$var"; done
is_valid_domainish "$STAGING_DOMAIN" || die "Ungültige STAGING_DOMAIN: $STAGING_DOMAIN"
is_valid_domainish "$PRODUCTION_DOMAIN" || die "Ungültige PRODUCTION_DOMAIN: $PRODUCTION_DOMAIN"
ok "Pflichtwerte sind plausibel"

step "Generated-Ordner vorbereiten"
GENERATED_DIR="$REPO_ROOT/generated"; SSH_DIR="$GENERATED_DIR/ssh"; SERVER_SUMMARY_DIR="$GENERATED_DIR/server-summaries"
mkdir -p "$SSH_DIR" "$SERVER_SUMMARY_DIR"
chmod 700 "$GENERATED_DIR" "$SSH_DIR"
VAULT_FILE="$GENERATED_DIR/customer-vault.md"
vault_init "$VAULT_FILE"

step "SSH-Keys für Admin, Deploy und GitHub Actions erzeugen"
ensure_ssh_key "$SSH_DIR/staging-admin-ed25519" "$PROJECT_SLUG staging admin" "$FORCE"
ensure_ssh_key "$SSH_DIR/staging-github-actions-ed25519" "$PROJECT_SLUG staging github-actions" "$FORCE"
ensure_ssh_key "$SSH_DIR/production-admin-ed25519" "$PROJECT_SLUG production admin" "$FORCE"
ensure_ssh_key "$SSH_DIR/production-github-actions-ed25519" "$PROJECT_SLUG production github-actions" "$FORCE"
STAGING_ADMIN_PUBLIC_KEY="$(cat "$SSH_DIR/staging-admin-ed25519.pub")"
STAGING_GITHUB_ACTIONS_PUBLIC_KEY="$(cat "$SSH_DIR/staging-github-actions-ed25519.pub")"
PRODUCTION_ADMIN_PUBLIC_KEY="$(cat "$SSH_DIR/production-admin-ed25519.pub")"
PRODUCTION_GITHUB_ACTIONS_PUBLIC_KEY="$(cat "$SSH_DIR/production-github-actions-ed25519.pub")"

step "Passwörter und App-Secrets erzeugen"
APP_SECRET_STAGING="$(generate_hex_secret 32)"; APP_SECRET_PRODUCTION="$(generate_hex_secret 32)"
INSTALL_ADMIN_PASSWORD_STAGING="$(generate_password 32)"; INSTALL_ADMIN_PASSWORD_PRODUCTION="$(generate_password 32)"
DB_ROOT_PASSWORD_STAGING="$(generate_password 48)"; DB_PASSWORD_STAGING="$(generate_password 48)"
DB_ROOT_PASSWORD_PRODUCTION="$(generate_password 48)"; DB_PASSWORD_PRODUCTION="$(generate_password 48)"
REDIS_PASSWORD_STAGING="$(generate_password 48)"; REDIS_PASSWORD_PRODUCTION="$(generate_password 48)"
RABBITMQ_PASSWORD_STAGING="$(generate_password 48)"; RABBITMQ_PASSWORD_PRODUCTION="$(generate_password 48)"
ok "Secrets generiert"

step "Gemeinsame customer.env für weitere Skripte schreiben"
CUSTOMER_GENERATED_ENV="$GENERATED_DIR/customer.env"
cat > "$CUSTOMER_GENERATED_ENV" <<EOFGEN
CUSTOMER_NAME="$CUSTOMER_NAME"
PROJECT_SLUG="$PROJECT_SLUG"
ADMIN_EMAIL="$ADMIN_EMAIL"
TECHNICAL_CONTACT_EMAIL="${TECHNICAL_CONTACT_EMAIL:-$ADMIN_EMAIL}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
GITHUB_OWNER="$GITHUB_OWNER"
GITHUB_REPO="$GITHUB_REPO"
GHCR_IMAGE="$GHCR_IMAGE"
STAGING_SERVER_HOST="$STAGING_SERVER_HOST"
PRODUCTION_SERVER_HOST="$PRODUCTION_SERVER_HOST"
STAGING_ROOT_SSH_USER="$STAGING_ROOT_SSH_USER"
PRODUCTION_ROOT_SSH_USER="$PRODUCTION_ROOT_SSH_USER"
STAGING_ROOT_SSH_PORT="${STAGING_ROOT_SSH_PORT:-22}"
PRODUCTION_ROOT_SSH_PORT="${PRODUCTION_ROOT_SSH_PORT:-22}"
STAGING_ROOT_SSH_KEY_PATH="$STAGING_ROOT_SSH_KEY_PATH"
PRODUCTION_ROOT_SSH_KEY_PATH="$PRODUCTION_ROOT_SSH_KEY_PATH"
STAGING_DOMAIN="$STAGING_DOMAIN"
PRODUCTION_DOMAIN="$PRODUCTION_DOMAIN"
ADMIN_USER="$ADMIN_USER"
DEPLOY_USER="$DEPLOY_USER"
SSH_PORT="${SSH_PORT:-22}"
DISABLE_ROOT_SSH="${DISABLE_ROOT_SSH:-0}"
SHOPWARE_VERSION="${SHOPWARE_VERSION:-}"
PHP_VERSION="$PHP_VERSION"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.4}"
VALKEY_IMAGE="${VALKEY_IMAGE:-valkey/valkey:8-alpine}"
RABBITMQ_IMAGE="${RABBITMQ_IMAGE:-rabbitmq:3-management-alpine}"
VARNISH_IMAGE="${VARNISH_IMAGE:-ghcr.io/shopware/varnish:6.7}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
ENABLE_S3="${ENABLE_S3:-1}"
ENABLE_RABBITMQ="${ENABLE_RABBITMQ:-1}"
ENABLE_VARNISH="${ENABLE_VARNISH:-1}"
INSTALL_LOCALE="${INSTALL_LOCALE:-de-DE}"
INSTALL_CURRENCY="${INSTALL_CURRENCY:-EUR}"
INSTALL_ADMIN_USERNAME="${INSTALL_ADMIN_USERNAME:-admin}"
SHOPWARE_USAGE_DATA_CONSENT="${SHOPWARE_USAGE_DATA_CONSENT:-revoked}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-eu-central-1}"
S3_USE_PATH_STYLE="${S3_USE_PATH_STYLE:-true}"
S3_PUBLIC_BUCKET="${S3_PUBLIC_BUCKET:-${PROJECT_SLUG}-public}"
S3_PRIVATE_BUCKET="${S3_PRIVATE_BUCKET:-${PROJECT_SLUG}-private}"
S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-${PROJECT_SLUG}-backups}"
S3_PUBLIC_URL="${S3_PUBLIC_URL:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_HOUR="${BACKUP_HOUR:-2}"
BACKUP_MINUTE="${BACKUP_MINUTE:-30}"
INSTALL_BASE_DIR="$INSTALL_BASE_DIR"
SHOPWARE_STORE_ACCOUNT_EMAIL="${SHOPWARE_STORE_ACCOUNT_EMAIL:-}"
SHOPWARE_STORE_ACCOUNT_PASSWORD="${SHOPWARE_STORE_ACCOUNT_PASSWORD:-}"
SHOPWARE_STORE_SHOP_SECRET="${SHOPWARE_STORE_SHOP_SECRET:-}"
SHOPWARE_STORE_LICENSE_DOMAIN="${SHOPWARE_STORE_LICENSE_DOMAIN:-}"
EOFGEN
chmod 600 "$CUSTOMER_GENERATED_ENV"
ok "Generated customer.env geschrieben: $CUSTOMER_GENERATED_ENV"

write_server_env() {
  local env_name="$1" domain="$2" app_secret="$3" admin_password="$4" db_root_password="$5" db_password="$6" redis_password="$7" rabbit_password="$8" admin_pub="$9" gha_pub="${10}" image_tag="${11}"
  local out="$GENERATED_DIR/${env_name}-server.env" install_dir="$INSTALL_BASE_DIR/$PROJECT_SLUG/$env_name" staging_flag=0
  [[ "$env_name" == "staging" ]] && staging_flag=1
  cat > "$out" <<EOFSERVER
ENVIRONMENT="$env_name"
CUSTOMER_NAME="$CUSTOMER_NAME"
PROJECT_SLUG="$PROJECT_SLUG"
PRIMARY_DOMAIN="$domain"
ADMIN_EMAIL="$ADMIN_EMAIL"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
ADMIN_USER="$ADMIN_USER"
DEPLOY_USER="$DEPLOY_USER"
ADMIN_PUBLIC_KEY="$admin_pub"
GITHUB_ACTIONS_DEPLOY_PUBLIC_KEY="$gha_pub"
SSH_PORT="${SSH_PORT:-22}"
DISABLE_ROOT_SSH="${DISABLE_ROOT_SSH:-0}"
INSTALL_BASE_DIR="$INSTALL_BASE_DIR"
INSTALL_DIR="$install_dir"
COMPOSE_PROJECT_NAME="${PROJECT_SLUG}_${env_name}"
GHCR_IMAGE="$GHCR_IMAGE"
SHOPWARE_IMAGE="$GHCR_IMAGE:${image_tag}-latest"
PHP_VERSION="$PHP_VERSION"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.4}"
VALKEY_IMAGE="${VALKEY_IMAGE:-valkey/valkey:8-alpine}"
RABBITMQ_IMAGE="${RABBITMQ_IMAGE:-rabbitmq:3-management-alpine}"
VARNISH_IMAGE="${VARNISH_IMAGE:-ghcr.io/shopware/varnish:6.7}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
APP_ENV="prod"
APP_URL="https://$domain"
APP_SECRET="$app_secret"
INSTALL_LOCALE="${INSTALL_LOCALE:-de-DE}"
INSTALL_CURRENCY="${INSTALL_CURRENCY:-EUR}"
INSTALL_ADMIN_USERNAME="${INSTALL_ADMIN_USERNAME:-admin}"
INSTALL_ADMIN_PASSWORD="$admin_password"
SHOPWARE_USAGE_DATA_CONSENT="${SHOPWARE_USAGE_DATA_CONSENT:-revoked}"
SHOPWARE_DEPLOYMENT_STAGING="$staging_flag"
DB_NAME="shopware"
DB_USER="shopware"
DB_ROOT_PASSWORD="$db_root_password"
DB_PASSWORD="$db_password"
REDIS_PASSWORD="$redis_password"
RABBITMQ_USER="shopware"
RABBITMQ_PASSWORD="$rabbit_password"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-eu-central-1}"
S3_USE_PATH_STYLE="${S3_USE_PATH_STYLE:-true}"
S3_PUBLIC_BUCKET="${S3_PUBLIC_BUCKET:-${PROJECT_SLUG}-public}"
S3_PRIVATE_BUCKET="${S3_PRIVATE_BUCKET:-${PROJECT_SLUG}-private}"
S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-${PROJECT_SLUG}-backups}"
S3_PUBLIC_URL="${S3_PUBLIC_URL:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_HOUR="${BACKUP_HOUR:-2}"
BACKUP_MINUTE="${BACKUP_MINUTE:-30}"
SHOPWARE_STORE_ACCOUNT_EMAIL="${SHOPWARE_STORE_ACCOUNT_EMAIL:-}"
SHOPWARE_STORE_ACCOUNT_PASSWORD="${SHOPWARE_STORE_ACCOUNT_PASSWORD:-}"
SHOPWARE_STORE_SHOP_SECRET="${SHOPWARE_STORE_SHOP_SECRET:-}"
SHOPWARE_STORE_LICENSE_DOMAIN="${SHOPWARE_STORE_LICENSE_DOMAIN:-}"
EOFSERVER
  chmod 600 "$out"
  ok "Server-Env geschrieben: $out"
}

step "Server-Konfigurationen schreiben"
write_server_env staging "$STAGING_DOMAIN" "$APP_SECRET_STAGING" "$INSTALL_ADMIN_PASSWORD_STAGING" "$DB_ROOT_PASSWORD_STAGING" "$DB_PASSWORD_STAGING" "$REDIS_PASSWORD_STAGING" "$RABBITMQ_PASSWORD_STAGING" "$STAGING_ADMIN_PUBLIC_KEY" "$STAGING_GITHUB_ACTIONS_PUBLIC_KEY" staging
write_server_env production "$PRODUCTION_DOMAIN" "$APP_SECRET_PRODUCTION" "$INSTALL_ADMIN_PASSWORD_PRODUCTION" "$DB_ROOT_PASSWORD_PRODUCTION" "$DB_PASSWORD_PRODUCTION" "$REDIS_PASSWORD_PRODUCTION" "$RABBITMQ_PASSWORD_PRODUCTION" "$PRODUCTION_ADMIN_PUBLIC_KEY" "$PRODUCTION_GITHUB_ACTIONS_PUBLIC_KEY" production

step "Vault-Datei mit allen relevanten Daten füllen"
vault_section "$VAULT_FILE" "Projekt"
vault_kv "$VAULT_FILE" "CUSTOMER_NAME" "$CUSTOMER_NAME"
vault_kv "$VAULT_FILE" "PROJECT_SLUG" "$PROJECT_SLUG"
vault_kv "$VAULT_FILE" "GITHUB_REPOSITORY" "$GITHUB_OWNER/$GITHUB_REPO"
vault_kv "$VAULT_FILE" "GHCR_IMAGE" "$GHCR_IMAGE"
vault_kv "$VAULT_FILE" "STAGING_URL" "https://$STAGING_DOMAIN"
vault_kv "$VAULT_FILE" "PRODUCTION_URL" "https://$PRODUCTION_DOMAIN"

vault_section "$VAULT_FILE" "Lokale Generated-Dateien"
vault_kv "$VAULT_FILE" "generated/customer.env" "$CUSTOMER_GENERATED_ENV"
vault_kv "$VAULT_FILE" "generated/staging-server.env" "$GENERATED_DIR/staging-server.env"
vault_kv "$VAULT_FILE" "generated/production-server.env" "$GENERATED_DIR/production-server.env"

vault_section "$VAULT_FILE" "SSH Keys"
for key in "$SSH_DIR"/*-ed25519; do [[ -f "$key" ]] || continue; vault_kv "$VAULT_FILE" "Private Key $(basename "$key")" "$key"; vault_block "$VAULT_FILE" "Public Key $(basename "$key").pub" "$(cat "$key.pub")"; done

vault_section "$VAULT_FILE" "Staging Zugangsdaten"
vault_kv "$VAULT_FILE" "Server Host" "$STAGING_SERVER_HOST"; vault_kv "$VAULT_FILE" "Initial SSH" "$STAGING_ROOT_SSH_USER@$STAGING_SERVER_HOST:${STAGING_ROOT_SSH_PORT:-22} mit $STAGING_ROOT_SSH_KEY_PATH"
vault_kv "$VAULT_FILE" "Linux Admin User" "$ADMIN_USER"; vault_kv "$VAULT_FILE" "Deploy User" "$DEPLOY_USER"; vault_kv "$VAULT_FILE" "Shopware Admin Username" "${INSTALL_ADMIN_USERNAME:-admin}"; vault_kv "$VAULT_FILE" "Shopware Admin Password" "$INSTALL_ADMIN_PASSWORD_STAGING"
vault_kv "$VAULT_FILE" "DB Root Password" "$DB_ROOT_PASSWORD_STAGING"; vault_kv "$VAULT_FILE" "DB User" "shopware"; vault_kv "$VAULT_FILE" "DB Password" "$DB_PASSWORD_STAGING"; vault_kv "$VAULT_FILE" "Redis/Valkey Password" "$REDIS_PASSWORD_STAGING"; vault_kv "$VAULT_FILE" "RabbitMQ User" "shopware"; vault_kv "$VAULT_FILE" "RabbitMQ Password" "$RABBITMQ_PASSWORD_STAGING"; vault_kv "$VAULT_FILE" "APP_SECRET" "$APP_SECRET_STAGING"

vault_section "$VAULT_FILE" "Production Zugangsdaten"
vault_kv "$VAULT_FILE" "Server Host" "$PRODUCTION_SERVER_HOST"; vault_kv "$VAULT_FILE" "Initial SSH" "$PRODUCTION_ROOT_SSH_USER@$PRODUCTION_SERVER_HOST:${PRODUCTION_ROOT_SSH_PORT:-22} mit $PRODUCTION_ROOT_SSH_KEY_PATH"
vault_kv "$VAULT_FILE" "Linux Admin User" "$ADMIN_USER"; vault_kv "$VAULT_FILE" "Deploy User" "$DEPLOY_USER"; vault_kv "$VAULT_FILE" "Shopware Admin Username" "${INSTALL_ADMIN_USERNAME:-admin}"; vault_kv "$VAULT_FILE" "Shopware Admin Password" "$INSTALL_ADMIN_PASSWORD_PRODUCTION"
vault_kv "$VAULT_FILE" "DB Root Password" "$DB_ROOT_PASSWORD_PRODUCTION"; vault_kv "$VAULT_FILE" "DB User" "shopware"; vault_kv "$VAULT_FILE" "DB Password" "$DB_PASSWORD_PRODUCTION"; vault_kv "$VAULT_FILE" "Redis/Valkey Password" "$REDIS_PASSWORD_PRODUCTION"; vault_kv "$VAULT_FILE" "RabbitMQ User" "shopware"; vault_kv "$VAULT_FILE" "RabbitMQ Password" "$RABBITMQ_PASSWORD_PRODUCTION"; vault_kv "$VAULT_FILE" "APP_SECRET" "$APP_SECRET_PRODUCTION"

vault_section "$VAULT_FILE" "S3/Object Storage"
for key in S3_ENDPOINT S3_REGION S3_PUBLIC_BUCKET S3_PRIVATE_BUCKET S3_BACKUP_BUCKET S3_ACCESS_KEY S3_SECRET_KEY; do vault_kv "$VAULT_FILE" "$key" "${!key:-}"; done

vault_section "$VAULT_FILE" "GitHub Environments und Secrets"
vault_kv "$VAULT_FILE" "Environments" "staging, production"; vault_kv "$VAULT_FILE" "Branches" "staging, production"
vault_kv "$VAULT_FILE" "STAGING_SSH_HOST" "$STAGING_SERVER_HOST"; vault_kv "$VAULT_FILE" "STAGING_SSH_PORT" "${STAGING_ROOT_SSH_PORT:-22}"; vault_kv "$VAULT_FILE" "STAGING_SSH_USER" "$DEPLOY_USER"; vault_block "$VAULT_FILE" "STAGING_SSH_PRIVATE_KEY" "$(cat "$SSH_DIR/staging-github-actions-ed25519")"; vault_kv "$VAULT_FILE" "STAGING_INSTALL_DIR" "$INSTALL_BASE_DIR/$PROJECT_SLUG/staging"
vault_kv "$VAULT_FILE" "PRODUCTION_SSH_HOST" "$PRODUCTION_SERVER_HOST"; vault_kv "$VAULT_FILE" "PRODUCTION_SSH_PORT" "${PRODUCTION_ROOT_SSH_PORT:-22}"; vault_kv "$VAULT_FILE" "PRODUCTION_SSH_USER" "$DEPLOY_USER"; vault_block "$VAULT_FILE" "PRODUCTION_SSH_PRIVATE_KEY" "$(cat "$SSH_DIR/production-github-actions-ed25519")"; vault_kv "$VAULT_FILE" "PRODUCTION_INSTALL_DIR" "$INSTALL_BASE_DIR/$PROJECT_SLUG/production"
vault_kv "$VAULT_FILE" "SHOPWARE_PACKAGES_TOKEN" "optional, nur falls private Shopware Packages nötig sind"; vault_kv "$VAULT_FILE" "COMPOSER_AUTH_JSON" "optional, nur falls private Composer-Repositories nötig sind"

step "Fertig"
ok "Vorbereitung abgeschlossen. Wichtigste Datei: $VAULT_FILE"
ok "Nächste Schritte: scripts/05-setup-repo.sh, scripts/04-setup-s3-storage.sh, scripts/06-deploy-setup-files.sh"
