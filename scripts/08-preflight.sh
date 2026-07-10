#!/usr/bin/env bash
# Repository invariants plus optional GitHub/S3 external-control verification.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
LOCAL_ONLY=0
[[ "${1:-}" == --local-only ]] && LOCAL_ONLY=1

step "Secret- und Build-Kontext-Invarianten prüfen"
require_command rg
for pattern in generated customer.env customer-vault.md auth.json .env.local config/jwt backups; do grep -Fxq "$pattern" "$REPO_ROOT/.dockerignore" || die ".dockerignore schließt $pattern nicht exakt aus."; done
for pattern in customer.env .env.local .shopware-project.local.yml auth.json; do git -C "$REPO_ROOT" check-ignore -q "$pattern" || die "$pattern ist nicht git-ignored."; done
[[ "$(git -C "$REPO_ROOT" ls-files generated | tr '\n' ' ')" == "generated/.gitkeep " ]] || die "generated/ enthält getrackte Dateien."
! rg -n 'StrictHostKeyChecking=accept-new|source[[:space:]]+.*\.env|\.[[:space:]]+"?\$file' "$REPO_ROOT/scripts" -g '!08-preflight.sh' >/dev/null || die "Unsichere Konfigurations- oder SSH-Primitive gefunden."

step "Unveränderliche Supply-Chain-Referenzen prüfen"
while IFS= read -r line; do image="${line#*=\"}"; image="${image%\"}"; is_valid_pinned_image "$image" || die "Ungepinnte Image-Referenz in customer.env.example: $image"; done < <(grep -E '^(SHOPWARE_DOCKER_BASE_IMAGE|SHOPWARE_CLI_IMAGE|MARIADB_IMAGE|VALKEY_IMAGE|RABBITMQ_IMAGE|VARNISH_IMAGE|CADDY_IMAGE)=' "$REPO_ROOT/templates/customer/customer.env.example")
python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
paths = list((root / 'templates/github').glob('*.yml.tpl')) + list((root / '.github/workflows').glob('*.yml'))
for path in paths:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if re.search(r'^\s*-?\s*uses:', line) and not re.search(r'@[0-9a-f]{40}(?:\s|$)', line):
            raise SystemExit(f'{path}:{number}: action is not pinned to a full commit SHA')
PY

step "Netzwerk-, Storage- und Deployment-Invarianten prüfen"
grep -Fq '127.0.0.1:3306:3306' "$REPO_ROOT/templates/docker/compose.local.yaml.tpl" || die "Lokale DB ist nicht loopback-only."
grep -Fq '127.0.0.1:6379:6379' "$REPO_ROOT/templates/docker/compose.local.yaml.tpl" || die "Lokales Valkey ist nicht loopback-only."
! rg -n 'ENABLE_(S3|RABBITMQ|VARNISH)' "$REPO_ROOT" >/dev/null || die "Nicht implementierte Feature-Toggles gefunden."
grep -Fq 'BACKUP_S3_BUCKET' "$REPO_ROOT/templates/server/backup.sh.tpl" || die "Offsite Backup fehlt."
grep -Fq 'openssl enc -aes-256-cbc' "$REPO_ROOT/templates/server/backup.sh.tpl" || die "Backup-Verschlüsselung fehlt."
grep -Fq 'hmac.new' "$REPO_ROOT/templates/server/backup.sh.tpl" || die "Authentifizierte Backup-Integritätsprüfung fehlt."
grep -Fq 'restore_verify' "$REPO_ROOT/templates/server/restore-verify.sh.tpl" || die "Restore-Verifikation fehlt."
grep -Fq 'file-restore-probe' "$REPO_ROOT/templates/server/restore-verify.sh.tpl" || die "Restore-Verifikation für Shopware-Dateien fehlt."

if [[ -f "$REPO_ROOT/generated/customer.env" ]]; then
  step "Generierte Kundenkonfiguration erneut validieren"
  assert_private_file "$REPO_ROOT/generated/customer.env"
  load_env_file "$REPO_ROOT/generated/customer.env" "${GENERATED_CUSTOMER_CONFIG_KEYS[@]}"; validate_customer_config
fi

if [[ -f "$REPO_ROOT/Dockerfile" ]]; then
  grep -Eq '^FROM .+@sha256:[a-f0-9]{64}' "$REPO_ROOT/Dockerfile" || die "Generiertes Dockerfile ist nicht digest-gepinnt."
  grep -Fq 'test ! -e /src/generated' "$REPO_ROOT/Dockerfile" || die "Dockerfile Build-Kontext-Guard fehlt."
fi

if [[ "$LOCAL_ONLY" == 1 ]]; then ok "Lokale Preflight-Invarianten erfüllt"; exit 0; fi

step "Externe S3- und GitHub-Sicherheitskontrollen prüfen"
config_hash="$(file_sha256 "$REPO_ROOT/generated/customer.env")"
for env_name in staging production; do
  marker="$REPO_ROOT/generated/s3-$env_name.verified"
  assert_private_file "$marker"
  [[ "$(awk -F= '$1=="config_sha256" {print $2}' "$marker")" == "$config_hash" ]] || die "S3-Verifikation ist nach einer Konfigurationsänderung veraltet: $env_name"
done
require_command gh; require_command jq
gh auth status >/dev/null
actual_repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner | tr '[:upper:]' '[:lower:]')"
[[ "$actual_repository" == "$GITHUB_OWNER/$GITHUB_REPO" ]] || die "Aktuelles Repository stimmt nicht mit GITHUB_OWNER/GITHUB_REPO überein: $actual_repository"
for branch in staging production; do
  protection="$(gh api "repos/$GITHUB_OWNER/$GITHUB_REPO/branches/$branch/protection")"
  [[ "$(printf '%s' "$protection" | jq -r '.enforce_admins.enabled')" == true ]] || die "Admin enforcement fehlt für $branch."
  [[ "$(printf '%s' "$protection" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')" -ge 1 ]] || die "PR-Review-Schutz fehlt für $branch."
done
production_environment="$(gh api "repos/$GITHUB_OWNER/$GITHUB_REPO/environments/production")"
printf '%s' "$production_environment" | jq -e '.protection_rules | any(.type == "required_reviewers")' >/dev/null || die "Production Environment benötigt Required Reviewers."
gh api "repos/$GITHUB_OWNER/$GITHUB_REPO/environments/staging" >/dev/null
ok "Externe Sicherheitskontrollen sind aktiv"
