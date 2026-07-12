#!/usr/bin/env bash
# One-shot Shopware production-project initialization.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
CONFIG_FILE="$REPO_ROOT/generated/customer.env"
RESUME=0

usage() { cat <<USAGE
Usage: bash scripts/05-setup-repo.sh [--config generated/customer.env] [--dry-run] [--resume]

Creates an exact Shopware production project once, installs the official Docker
and Deployment Helper packages, then writes the hardened project overlays.
--resume completes a validated bootstrap that failed after Shopware was copied.
USAGE
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume) RESUME=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if ! parse_common_args "${args[@]}"; then usage; exit 0; fi
[[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/generated/customer.env"
if [[ "$DRY_RUN" == 1 ]]; then SHOPWARE_INFRA_TOTAL=3; else SHOPWARE_INFRA_TOTAL=13; fi
MARKER="$REPO_ROOT/.shopware-initialized-by-template"

step "Konfiguration sicher laden"
assert_private_file "$CONFIG_FILE"
load_env_file "$CONFIG_FILE" "${GENERATED_CUSTOMER_CONFIG_KEYS[@]}"
validate_customer_config
[[ -f "$REPO_ROOT/generated/.prepared" ]] || die "scripts/00-prepare-customer.sh muss erfolgreich abgeschlossen sein."
[[ ! -e "$MARKER" ]] || die "Shopware-Projekt wurde bereits initialisiert; das One-shot-Skript wird nicht erneut ausgeführt."

step "Lokale Werkzeuge prüfen"
require_not_root; require_command git; require_command python3; require_command composer; require_command rsync
if command_exists docker; then ok "Docker vorhanden"; else warn "Docker fehlt; der verpflichtende Image-Test kann erst später erfolgen."; fi

if [[ "$DRY_RUN" == 1 ]]; then
  step "Änderungsfreien Plan ausgeben"
  log "[DRY-RUN] Würde Shopware $SHOPWARE_VERSION exakt erstellen, offizielle Pakete installieren und gehärtete Dateien rendern."
  ok "Repo-Dry-run ohne Mutation abgeschlossen"
  exit 0
fi

[[ -d "$REPO_ROOT/.git" ]] || die "Dieses Template muss in einem Git-Repository liegen."
if [[ "$RESUME" == 1 ]]; then
  for file in "$REPO_ROOT/composer.json" "$REPO_ROOT/composer.lock" "$REPO_ROOT/bin/console"; do assert_file_exists "$file"; done
else
  [[ ! -f "$REPO_ROOT/composer.json" && ! -f "$REPO_ROOT/bin/console" ]] || die "Bestehendes Shopware-Projekt erkannt; Initialisierung abgebrochen. Nach einem validierten Teilfehler ausschließlich --resume verwenden."
fi
TMP_DIR="$REPO_ROOT/.shopware-bootstrap-tmp"
[[ ! -e "$TMP_DIR" && ! -L "$TMP_DIR" ]] || die "Temporärer Bootstrap-Ordner existiert bereits oder ist ein Symlink: $TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

step "Exaktes Shopware Production Template erzeugen"
if [[ "$RESUME" == 1 ]]; then
  ok "Vorhandenes, noch nicht markiertes Shopware-Projekt wird strikt validiert und fortgesetzt"
else
  composer create-project "shopware/production:$SHOPWARE_VERSION" "$TMP_DIR" --no-interaction
fi

step "Offizielle Hosting-Pakete installieren"
# The pinned Shopware CLI and production images provide ext-amqp. The local
# bootstrap PHP may not, so only this local dependency-resolution check ignores it.
if [[ "$RESUME" == 1 ]]; then
  for package in shopware/docker shopware/deployment-helper league/flysystem-async-aws-s3 symfony/amqp-messenger; do
    (cd "$REPO_ROOT" && composer show "$package" --locked --format=json >/dev/null) || die "Fortsetzung verweigert: $package fehlt im Lockfile."
  done
else
  (cd "$TMP_DIR" && composer config --no-interaction allow-plugins.php-http/discovery true)
  (cd "$TMP_DIR" && composer require shopware/docker shopware/deployment-helper league/flysystem-async-aws-s3 symfony/amqp-messenger --no-interaction --ignore-platform-req=ext-amqp)
fi
project_dir="$TMP_DIR"; [[ "$RESUME" == 1 ]] && project_dir="$REPO_ROOT"
actual_shopware_version="$(cd "$project_dir" && composer show shopware/core --locked --format=json | python3 -c 'import json, sys; print(json.load(sys.stdin)["versions"][0].removeprefix("* ").lstrip("v"))')"
[[ "$actual_shopware_version" == "$SHOPWARE_VERSION" ]] || die "Composer hat unerwartet Shopware $actual_shopware_version statt $SHOPWARE_VERSION aufgelöst."

step "Vollständig aufgelöstes Projekt übernehmen"
if [[ "$RESUME" == 1 ]]; then
  ok "Vorhandenes Lockfile enthält Shopware $actual_shopware_version und alle Hosting-Pakete"
else
  rsync -a --exclude .git --ignore-existing "$TMP_DIR/" "$REPO_ROOT/"
  rm -rf "$TMP_DIR"
fi

step "Gepinntes offizielles Produktions-Image und lokale Integration schreiben"
export PROJECT_SLUG PHP_VERSION SHOPWARE_DOCKER_BASE_IMAGE SHOPWARE_CLI_IMAGE MARIADB_IMAGE VALKEY_IMAGE RABBITMQ_IMAGE
render_template "$REPO_ROOT/templates/docker/Dockerfile.tpl" "$REPO_ROOT/Dockerfile"
render_template "$REPO_ROOT/templates/docker/compose.local.yaml.tpl" "$REPO_ROOT/compose.local.yaml"

step "Shopware-Konfiguration schreiben"
mkdir -p "$REPO_ROOT/config/packages"
render_template "$REPO_ROOT/templates/shopware/shopware-project.yml.tpl" "$REPO_ROOT/.shopware-project.yml"
render_template "$REPO_ROOT/templates/shopware/filesystem-s3.yaml.tpl" "$REPO_ROOT/config/packages/filesystem-s3.yaml"
render_template "$REPO_ROOT/templates/shopware/varnish.yaml.tpl" "$REPO_ROOT/config/packages/varnish.yaml"
render_template "$REPO_ROOT/templates/shopware/trusted_env.yaml.tpl" "$REPO_ROOT/config/packages/trusted_env.yaml"
render_template "$REPO_ROOT/templates/shopware/shopware-infra.yaml.tpl" "$REPO_ROOT/config/packages/z-shopware-infra.yaml"

step "Lokale, nicht produktive Umgebung schreiben"
export INSTALL_LOCALE INSTALL_CURRENCY INSTALL_ADMIN_USERNAME ADMIN_EMAIL SHOPWARE_USAGE_DATA_CONSENT
render_template "$REPO_ROOT/templates/shopware/env.local.tpl" "$REPO_ROOT/.env.local.example"
cp "$REPO_ROOT/.env.local.example" "$REPO_ROOT/.env.local"
chmod 600 "$REPO_ROOT/.env.local"

step "Gepinnte GitHub-Automation schreiben"
mkdir -p "$REPO_ROOT/.github/workflows"
render_template "$REPO_ROOT/templates/github/ci.yml.tpl" "$REPO_ROOT/.github/workflows/ci.yml"
render_template "$REPO_ROOT/templates/github/deploy-staging.yml.tpl" "$REPO_ROOT/.github/workflows/deploy-staging.yml"
render_template "$REPO_ROOT/templates/github/deploy-production.yml.tpl" "$REPO_ROOT/.github/workflows/deploy-production.yml"
render_template "$REPO_ROOT/templates/github/dependabot.yml.tpl" "$REPO_ROOT/.github/dependabot.yml"

step "Composer-Metadaten und Advisories prüfen"
(cd "$REPO_ROOT" && composer validate --no-check-publish && composer audit --locked --no-interaction)

step "Sicherheitsinvarianten prüfen"
bash "$REPO_ROOT/scripts/08-preflight.sh" --local-only

step "Initialisierung unveränderlich markieren"
printf 'shopware=%s\ncreated=%s\n' "$SHOPWARE_VERSION" "$(date -Iseconds)" > "$MARKER"
chmod 600 "$MARKER"
trap - EXIT INT TERM

step "Repo-Setup abschließen"
ok "Shopware $SHOPWARE_VERSION wurde einmalig vorbereitet. Vor einem Commit müssen Tests und Image-Scan vollständig grün sein."
