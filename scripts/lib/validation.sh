#!/usr/bin/env bash
# Project- and server-specific validation. Structural values are deliberately strict.

validate_pinned_images() {
  local name
  for name in SHOPWARE_DOCKER_BASE_IMAGE SHOPWARE_CLI_IMAGE MARIADB_IMAGE VALKEY_IMAGE RABBITMQ_IMAGE VARNISH_IMAGE CADDY_IMAGE; do
    assert_not_empty "$name"
    is_valid_pinned_image "${!name}" || die "$name muss Tag und sha256-Digest enthalten."
  done
  [[ "$SHOPWARE_DOCKER_BASE_IMAGE" == *":${PHP_VERSION}-frankenphp@sha256:"* ]] || die "SHOPWARE_DOCKER_BASE_IMAGE passt nicht zu PHP_VERSION=$PHP_VERSION."
  [[ "$SHOPWARE_CLI_IMAGE" == *"-php-${PHP_VERSION}@sha256:"* ]] || die "SHOPWARE_CLI_IMAGE passt nicht zu PHP_VERSION=$PHP_VERSION."
}

validate_s3_environment() {
  local prefix="$1" name endpoint public_url path_style public_bucket private_bucket backup_endpoint backup_bucket backup_url restore_url
  for suffix in ENDPOINT REGION USE_PATH_STYLE PUBLIC_BUCKET PRIVATE_BUCKET PUBLIC_URL ACCESS_KEY SECRET_KEY; do
    name="${prefix}_S3_${suffix}"
    assert_not_empty "$name"
  done
  name="${prefix}_S3_ENDPOINT"; endpoint="${!name}"
  name="${prefix}_S3_PUBLIC_URL"; public_url="${!name}"
  name="${prefix}_S3_USE_PATH_STYLE"; path_style="${!name}"
  name="${prefix}_S3_REGION"; is_valid_region "${!name}" || die "${prefix}_S3_REGION ist ungültig."
  name="${prefix}_S3_PUBLIC_BUCKET"; public_bucket="${!name}"
  name="${prefix}_S3_PRIVATE_BUCKET"; private_bucket="${!name}"
  is_valid_https_endpoint "$endpoint" || die "${prefix}_S3_ENDPOINT muss ein HTTPS-Origin ohne Pfad sein."
  is_valid_https_url "$public_url" || die "${prefix}_S3_PUBLIC_URL muss eine HTTPS-URL sein."
  is_valid_bool "$path_style" || die "${prefix}_S3_USE_PATH_STYLE muss true oder false sein."
  is_valid_bucket "$public_bucket" || die "${prefix}_S3_PUBLIC_BUCKET ist ungültig."
  is_valid_bucket "$private_bucket" || die "${prefix}_S3_PRIVATE_BUCKET ist ungültig."
  for suffix in ACCESS_KEY SECRET_KEY; do
    name="${prefix}_S3_${suffix}"; assert_no_placeholder "$name"; is_valid_external_secret "${!name}" || die "$name ist zu kurz oder enthält nicht unterstützte Sonderzeichen."
  done
  for suffix in ACCESS_KEY SECRET_KEY; do name="${prefix}_S3_PROVISIONING_${suffix}"; assert_not_empty "$name"; assert_no_placeholder "$name"; is_valid_external_secret "${!name}" || die "$name ist zu kurz oder enthält nicht unterstützte Sonderzeichen."; done
  for suffix in ACCESS_KEY SECRET_KEY; do name="${prefix}_S3_BACKUP_READER_${suffix}"; assert_not_empty "$name"; assert_no_placeholder "$name"; is_valid_external_secret "${!name}" || die "$name ist zu kurz oder enthält nicht unterstützte Sonderzeichen."; done
  for suffix in ENDPOINT PUBLIC_BUCKET PRIVATE_BUCKET PUBLIC_URL; do name="${prefix}_S3_${suffix}"; assert_no_placeholder "$name"; done

  for suffix in ENDPOINT REGION BUCKET ACCESS_KEY SECRET_KEY HEALTHCHECK_URL; do name="${prefix}_BACKUP_S3_${suffix}"; [[ "$suffix" == HEALTHCHECK_URL ]] && name="${prefix}_BACKUP_HEALTHCHECK_URL"; assert_not_empty "$name"; done
  name="${prefix}_RESTORE_HEALTHCHECK_URL"; assert_not_empty "$name"
  name="${prefix}_BACKUP_S3_ENDPOINT"; backup_endpoint="${!name}"
  name="${prefix}_BACKUP_S3_REGION"; is_valid_region "${!name}" || die "${prefix}_BACKUP_S3_REGION ist ungültig."
  name="${prefix}_BACKUP_S3_BUCKET"; backup_bucket="${!name}"
  name="${prefix}_BACKUP_HEALTHCHECK_URL"; backup_url="${!name}"
  name="${prefix}_RESTORE_HEALTHCHECK_URL"; restore_url="${!name}"
  is_valid_https_endpoint "$backup_endpoint" || die "${prefix}_BACKUP_S3_ENDPOINT muss ein HTTPS-Origin ohne Pfad sein."
  is_valid_bucket "$backup_bucket" || die "${prefix}_BACKUP_S3_BUCKET ist ungültig."
  is_valid_https_url "$backup_url" || die "${prefix}_BACKUP_HEALTHCHECK_URL muss eine HTTPS-URL sein."
  is_valid_https_url "$restore_url" || die "${prefix}_RESTORE_HEALTHCHECK_URL muss eine HTTPS-URL sein."
  for suffix in BUCKET ACCESS_KEY SECRET_KEY; do name="${prefix}_BACKUP_S3_${suffix}"; assert_no_placeholder "$name"; done
  name="${prefix}_BACKUP_HEALTHCHECK_URL"; assert_no_placeholder "$name"
  name="${prefix}_RESTORE_HEALTHCHECK_URL"; assert_no_placeholder "$name"
  for suffix in ACCESS_KEY SECRET_KEY; do name="${prefix}_BACKUP_S3_${suffix}"; is_valid_external_secret "${!name}" || die "$name ist zu kurz oder enthält nicht unterstützte Sonderzeichen."; done
}

validate_optional_store_config() {
  local prefix="$1" email_name password_name secret_name domain_name
  email_name="${prefix}_SHOPWARE_STORE_ACCOUNT_EMAIL"; password_name="${prefix}_SHOPWARE_STORE_ACCOUNT_PASSWORD"; secret_name="${prefix}_SHOPWARE_STORE_SHOP_SECRET"; domain_name="${prefix}_SHOPWARE_STORE_LICENSE_DOMAIN"
  local email="${!email_name:-}" password="${!password_name:-}" secret="${!secret_name:-}" domain="${!domain_name:-}"
  [[ -z "$email" ]] || is_valid_email "$email" || die "$email_name ist ungültig."
  [[ -z "$domain" ]] || is_valid_domain "$domain" || die "$domain_name ist ungültig."
  [[ -z "$password" ]] || is_safe_env_value "$password" || die "$password_name enthält nicht unterstützte Sonderzeichen."
  [[ -z "$secret" ]] || is_safe_env_value "$secret" || die "$secret_name enthält nicht unterstützte Sonderzeichen."
  if [[ -n "$password" && -z "$email" ]]; then die "$password_name erfordert $email_name."; fi
}

validate_customer_config() {
  local name first second i j
  local buckets keys
  for name in CUSTOMER_NAME PROJECT_SLUG ADMIN_EMAIL TECHNICAL_CONTACT_EMAIL TIMEZONE GITHUB_OWNER GITHUB_REPO STAGING_SERVER_HOST PRODUCTION_SERVER_HOST STAGING_ROOT_SSH_USER PRODUCTION_ROOT_SSH_USER STAGING_ROOT_SSH_PORT PRODUCTION_ROOT_SSH_PORT STAGING_ROOT_SSH_KEY_PATH PRODUCTION_ROOT_SSH_KEY_PATH STAGING_SSH_HOST_KEY_SHA256 PRODUCTION_SSH_HOST_KEY_SHA256 STAGING_DOMAIN PRODUCTION_DOMAIN ADMIN_USER DEPLOY_USER SSH_PORT DISABLE_ROOT_SSH INSTALL_BASE_DIR SHOPWARE_VERSION PHP_VERSION INSTALL_LOCALE INSTALL_CURRENCY INSTALL_ADMIN_USERNAME SHOPWARE_USAGE_DATA_CONSENT BACKUP_RETENTION_DAYS BACKUP_HOUR BACKUP_MINUTE RESTORE_TEST_DAY RESTORE_TEST_HOUR RESTORE_TEST_MINUTE; do assert_not_empty "$name"; done
  for name in CUSTOMER_NAME PROJECT_SLUG ADMIN_EMAIL TECHNICAL_CONTACT_EMAIL GITHUB_OWNER GITHUB_REPO STAGING_SERVER_HOST PRODUCTION_SERVER_HOST STAGING_DOMAIN PRODUCTION_DOMAIN ADMIN_USER; do assert_no_placeholder "$name"; done
  is_valid_slug "$PROJECT_SLUG" || die "PROJECT_SLUG ist ungültig."
  is_valid_email "$ADMIN_EMAIL" || die "ADMIN_EMAIL ist ungültig."
  is_valid_email "$TECHNICAL_CONTACT_EMAIL" || die "TECHNICAL_CONTACT_EMAIL ist ungültig."
  is_valid_github_name "$GITHUB_OWNER" || die "GITHUB_OWNER ist ungültig."
  is_valid_github_name "$GITHUB_REPO" || die "GITHUB_REPO ist ungültig."
  is_valid_domain "$STAGING_DOMAIN" || die "STAGING_DOMAIN ist ungültig."
  is_valid_domain "$PRODUCTION_DOMAIN" || die "PRODUCTION_DOMAIN ist ungültig."
  is_valid_host "$STAGING_SERVER_HOST" || die "STAGING_SERVER_HOST ist ungültig."
  is_valid_host "$PRODUCTION_SERVER_HOST" || die "PRODUCTION_SERVER_HOST ist ungültig."
  assert_distinct "$STAGING_DOMAIN" "$PRODUCTION_DOMAIN" "Staging- und Production-Domain müssen verschieden sein."
  assert_distinct "$STAGING_SERVER_HOST" "$PRODUCTION_SERVER_HOST" "Staging und Production müssen getrennte Server verwenden."
  [[ "$STAGING_ROOT_SSH_USER" == root && "$PRODUCTION_ROOT_SSH_USER" == root ]] || die "Fresh-VPS-Setup unterstützt initial ausschließlich root."
  is_valid_port "$STAGING_ROOT_SSH_PORT" || die "STAGING_ROOT_SSH_PORT ist ungültig."
  is_valid_port "$PRODUCTION_ROOT_SSH_PORT" || die "PRODUCTION_ROOT_SSH_PORT ist ungültig."
  is_valid_port "$SSH_PORT" || die "SSH_PORT ist ungültig."
  is_valid_sha256_fingerprint "$STAGING_SSH_HOST_KEY_SHA256" || die "STAGING_SSH_HOST_KEY_SHA256 ist ungültig."
  is_valid_sha256_fingerprint "$PRODUCTION_SSH_HOST_KEY_SHA256" || die "PRODUCTION_SSH_HOST_KEY_SHA256 ist ungültig."
  is_valid_username "$ADMIN_USER" || die "ADMIN_USER ist ungültig."
  is_valid_username "$DEPLOY_USER" || die "DEPLOY_USER ist ungültig."
  [[ "$ADMIN_USER" != root && "$DEPLOY_USER" != root ]] || die "ADMIN_USER und DEPLOY_USER dürfen nicht root sein."
  assert_distinct "$ADMIN_USER" "$DEPLOY_USER" "ADMIN_USER und DEPLOY_USER müssen verschieden sein."
  [[ "$DISABLE_ROOT_SSH" == 1 ]] || die "DISABLE_ROOT_SSH muss für dieses gehärtete Template 1 sein."
  is_valid_install_base "$INSTALL_BASE_DIR" || die "INSTALL_BASE_DIR muss /opt/shopware sein."
  [[ "$SHOPWARE_VERSION" =~ ^6\.7\.[0-9]+\.[0-9]+$ ]] || die "SHOPWARE_VERSION muss exakt auf eine 6.7-Patchversion gesetzt sein."
  [[ "$PHP_VERSION" == 8.4 ]] || die "Dieses Template ist aktuell für PHP 8.4 validiert."
  is_valid_timezone "$TIMEZONE" || die "TIMEZONE ist ungültig oder unbekannt: $TIMEZONE"
  is_valid_locale "$INSTALL_LOCALE" || die "INSTALL_LOCALE muss dem Format de-DE entsprechen."
  is_valid_currency "$INSTALL_CURRENCY" || die "INSTALL_CURRENCY muss ein ISO-4217-Code aus drei Großbuchstaben sein."
  [[ "$INSTALL_ADMIN_USERNAME" =~ ^[A-Za-z0-9_.@-]{3,64}$ ]] || die "INSTALL_ADMIN_USERNAME ist ungültig."
  case "$SHOPWARE_USAGE_DATA_CONSENT" in accepted|revoked) ;; *) die "SHOPWARE_USAGE_DATA_CONSENT muss accepted oder revoked sein." ;; esac
  validate_pinned_images
  validate_s3_environment STAGING
  validate_s3_environment PRODUCTION
  validate_optional_store_config STAGING
  validate_optional_store_config PRODUCTION
  is_valid_uint_range "$BACKUP_RETENTION_DAYS" 7 365 || die "BACKUP_RETENTION_DAYS muss zwischen 7 und 365 liegen."
  is_valid_uint_range "$BACKUP_HOUR" 0 23 || die "BACKUP_HOUR ist ungültig."
  is_valid_uint_range "$BACKUP_MINUTE" 0 59 || die "BACKUP_MINUTE ist ungültig."
  case "$RESTORE_TEST_DAY" in Mon|Tue|Wed|Thu|Fri|Sat|Sun) ;; *) die "RESTORE_TEST_DAY ist ungültig." ;; esac
  is_valid_uint_range "$RESTORE_TEST_HOUR" 0 23 || die "RESTORE_TEST_HOUR ist ungültig."
  is_valid_uint_range "$RESTORE_TEST_MINUTE" 0 59 || die "RESTORE_TEST_MINUTE ist ungültig."
  buckets=("$STAGING_S3_PUBLIC_BUCKET" "$STAGING_S3_PRIVATE_BUCKET" "$STAGING_BACKUP_S3_BUCKET" "$PRODUCTION_S3_PUBLIC_BUCKET" "$PRODUCTION_S3_PRIVATE_BUCKET" "$PRODUCTION_BACKUP_S3_BUCKET")
  for ((i=0; i<${#buckets[@]}; i++)); do for ((j=i+1; j<${#buckets[@]}; j++)); do first="${buckets[$i]}"; second="${buckets[$j]}"; assert_distinct "$first" "$second" "Alle Runtime- und Backup-Buckets müssen eindeutig sein: $first"; done; done
  keys=("$STAGING_S3_ACCESS_KEY" "$STAGING_S3_BACKUP_READER_ACCESS_KEY" "$STAGING_BACKUP_S3_ACCESS_KEY" "$STAGING_S3_PROVISIONING_ACCESS_KEY" "$PRODUCTION_S3_ACCESS_KEY" "$PRODUCTION_S3_BACKUP_READER_ACCESS_KEY" "$PRODUCTION_BACKUP_S3_ACCESS_KEY" "$PRODUCTION_S3_PROVISIONING_ACCESS_KEY")
  for ((i=0; i<${#keys[@]}; i++)); do for ((j=i+1; j<${#keys[@]}; j++)); do first="${keys[$i]}"; second="${keys[$j]}"; assert_distinct "$first" "$second" "Runtime, Backup und Provisioning benötigen getrennte Access Keys."; done; done
  keys=("$STAGING_S3_SECRET_KEY" "$STAGING_S3_BACKUP_READER_SECRET_KEY" "$STAGING_BACKUP_S3_SECRET_KEY" "$STAGING_S3_PROVISIONING_SECRET_KEY" "$PRODUCTION_S3_SECRET_KEY" "$PRODUCTION_S3_BACKUP_READER_SECRET_KEY" "$PRODUCTION_BACKUP_S3_SECRET_KEY" "$PRODUCTION_S3_PROVISIONING_SECRET_KEY")
  for ((i=0; i<${#keys[@]}; i++)); do for ((j=i+1; j<${#keys[@]}; j++)); do first="${keys[$i]}"; second="${keys[$j]}"; assert_distinct "$first" "$second" "Runtime, Backup und Provisioning benötigen getrennte Secret Keys."; done; done
  keys=("$STAGING_BACKUP_HEALTHCHECK_URL" "$STAGING_RESTORE_HEALTHCHECK_URL" "$PRODUCTION_BACKUP_HEALTHCHECK_URL" "$PRODUCTION_RESTORE_HEALTHCHECK_URL")
  for ((i=0; i<${#keys[@]}; i++)); do for ((j=i+1; j<${#keys[@]}; j++)); do first="${keys[$i]}"; second="${keys[$j]}"; assert_distinct "$first" "$second" "Backup und Restore benötigen vier unabhängige Monitoring-URLs."; done; done
  ok "Kundenkonfiguration vollständig und isoliert validiert"
}

validate_server_config() {
  local name expected_install expected_image_prefix
  for name in "${SERVER_CONFIG_KEYS[@]}"; do
    case "$name" in SHOPWARE_STORE_ACCOUNT_EMAIL|SHOPWARE_STORE_ACCOUNT_PASSWORD|SHOPWARE_STORE_SHOP_SECRET|SHOPWARE_STORE_LICENSE_DOMAIN) ;; *) assert_not_empty "$name" ;; esac
  done
  [[ "$EXPECTED_ENVIRONMENT" == "$ENVIRONMENT" ]] || die "Falsche Config: erwartet $EXPECTED_ENVIRONMENT, erhalten $ENVIRONMENT"
  is_valid_slug "$PROJECT_SLUG" || die "PROJECT_SLUG ist ungültig."
  is_valid_domain "$PRIMARY_DOMAIN" || die "PRIMARY_DOMAIN ist ungültig."
  is_valid_email "$ADMIN_EMAIL" || die "ADMIN_EMAIL ist ungültig."
  is_valid_username "$ADMIN_USER" || die "ADMIN_USER ist ungültig."
  is_valid_username "$DEPLOY_USER" || die "DEPLOY_USER ist ungültig."
  assert_distinct "$ADMIN_USER" "$DEPLOY_USER" "ADMIN_USER und DEPLOY_USER müssen verschieden sein."
  is_valid_ssh_public_key "$ADMIN_PUBLIC_KEY" || die "ADMIN_PUBLIC_KEY ist ungültig."
  is_valid_ssh_public_key "$GITHUB_ACTIONS_DEPLOY_PUBLIC_KEY" || die "GITHUB_ACTIONS_DEPLOY_PUBLIC_KEY ist ungültig."
  is_valid_port "$INITIAL_SSH_PORT" || die "INITIAL_SSH_PORT ist ungültig."
  is_valid_port "$SSH_PORT" || die "SSH_PORT ist ungültig."
  [[ "$DISABLE_ROOT_SSH" == 1 ]] || die "Root SSH muss deaktiviert werden."
  is_valid_install_base "$INSTALL_BASE_DIR" || die "INSTALL_BASE_DIR muss /opt/shopware sein."
  expected_install="$INSTALL_BASE_DIR/$PROJECT_SLUG/$ENVIRONMENT"
  assert_equal "$INSTALL_DIR" "$expected_install" "INSTALL_DIR muss exakt $expected_install sein."
  is_valid_install_dir "$INSTALL_DIR" || die "INSTALL_DIR ist außerhalb des erlaubten Pfads."
  [[ "$COMPOSE_PROJECT_NAME" == "${PROJECT_SLUG}_${ENVIRONMENT}" ]] || die "COMPOSE_PROJECT_NAME ist inkonsistent."
  [[ "$GHCR_IMAGE" == "ghcr.io/$GITHUB_OWNER/$GITHUB_REPO/shopware" ]] || die "GHCR_IMAGE ist inkonsistent."
  expected_image_prefix="$GHCR_IMAGE:${ENVIRONMENT}-"
  [[ "$SHOPWARE_IMAGE" == "${expected_image_prefix}bootstrap" ]] || die "Initiales SHOPWARE_IMAGE muss der nicht deploybare Bootstrap-Tag sein."
  [[ "$APP_URL" == "https://$PRIMARY_DOMAIN" ]] || die "APP_URL ist inkonsistent."
  [[ "$APP_ENV" == prod ]] || die "APP_ENV muss prod sein."
  is_valid_timezone "$TIMEZONE" || die "TIMEZONE ist ungültig oder unbekannt: $TIMEZONE"
  is_valid_locale "$INSTALL_LOCALE" || die "INSTALL_LOCALE ist ungültig."
  is_valid_currency "$INSTALL_CURRENCY" || die "INSTALL_CURRENCY ist ungültig."
  [[ "$INSTALL_ADMIN_USERNAME" =~ ^[A-Za-z0-9_.@-]{3,64}$ ]] || die "INSTALL_ADMIN_USERNAME ist ungültig."
  case "$SHOPWARE_USAGE_DATA_CONSENT" in accepted|revoked) ;; *) die "SHOPWARE_USAGE_DATA_CONSENT ist ungültig." ;; esac
  [[ "$APP_SECRET" =~ ^[a-f0-9]{64}$ ]] || die "APP_SECRET muss ein 64-stelliges Hex-Secret sein."
  for name in INSTALL_ADMIN_PASSWORD DB_ROOT_PASSWORD DB_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD BACKUP_ENCRYPTION_PASSPHRASE; do is_valid_alnum_secret "${!name}" || die "$name muss ein generiertes alphanumerisches Secret sein."; done
  [[ "$DB_NAME" == shopware && "$DB_USER" == shopware && "$RABBITMQ_USER" == shopware ]] || die "DB- und RabbitMQ-Namen weichen vom gehärteten Template ab."
  case "$ENVIRONMENT:$SHOPWARE_DEPLOYMENT_STAGING" in staging:1|production:0) ;; *) die "SHOPWARE_DEPLOYMENT_STAGING ist für $ENVIRONMENT falsch." ;; esac
  validate_pinned_images
  is_valid_https_endpoint "$S3_ENDPOINT" || die "S3_ENDPOINT ist ungültig."
  is_valid_region "$S3_REGION" || die "S3_REGION ist ungültig."
  is_valid_bool "$S3_USE_PATH_STYLE" || die "S3_USE_PATH_STYLE ist ungültig."
  is_valid_https_url "$S3_PUBLIC_URL" || die "S3_PUBLIC_URL ist ungültig."
  is_valid_bucket "$S3_PUBLIC_BUCKET" || die "S3_PUBLIC_BUCKET ist ungültig."
  is_valid_bucket "$S3_PRIVATE_BUCKET" || die "S3_PRIVATE_BUCKET ist ungültig."
  is_valid_https_endpoint "$BACKUP_S3_ENDPOINT" || die "BACKUP_S3_ENDPOINT ist ungültig."
  is_valid_region "$BACKUP_S3_REGION" || die "BACKUP_S3_REGION ist ungültig."
  is_valid_bucket "$BACKUP_S3_BUCKET" || die "BACKUP_S3_BUCKET ist ungültig."
  is_valid_https_url "$BACKUP_HEALTHCHECK_URL" || die "BACKUP_HEALTHCHECK_URL ist ungültig."
  is_valid_https_url "$RESTORE_HEALTHCHECK_URL" || die "RESTORE_HEALTHCHECK_URL ist ungültig."
  assert_distinct "$BACKUP_HEALTHCHECK_URL" "$RESTORE_HEALTHCHECK_URL" "Backup- und Restore-Monitoring müssen getrennt sein."
  for name in S3_ACCESS_KEY S3_SECRET_KEY S3_BACKUP_READER_ACCESS_KEY S3_BACKUP_READER_SECRET_KEY BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY; do is_valid_external_secret "${!name}" || die "$name ist zu kurz oder enthält nicht unterstützte Sonderzeichen."; done
  is_valid_uint_range "$BACKUP_RETENTION_DAYS" 7 365 || die "BACKUP_RETENTION_DAYS ist ungültig."
  is_valid_uint_range "$BACKUP_HOUR" 0 23 || die "BACKUP_HOUR ist ungültig."
  is_valid_uint_range "$BACKUP_MINUTE" 0 59 || die "BACKUP_MINUTE ist ungültig."
  case "$RESTORE_TEST_DAY" in Mon|Tue|Wed|Thu|Fri|Sat|Sun) ;; *) die "RESTORE_TEST_DAY ist ungültig." ;; esac
  ok "Server-Konfiguration validiert: $ENVIRONMENT / $PRIMARY_DOMAIN"
}
