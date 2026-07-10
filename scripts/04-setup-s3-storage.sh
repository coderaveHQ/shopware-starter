#!/usr/bin/env bash
# Local helper to validate/create S3-compatible buckets via aws-cli, if available.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
CONFIG_FILE="$REPO_ROOT/generated/customer.env"; CREATE_BUCKETS=0
usage() { cat <<USAGE
Usage: bash scripts/04-setup-s3-storage.sh [--config generated/customer.env] [--dry-run] [--create]

Validates S3-compatible object storage variables. If aws-cli is installed and --create is set, creates configured buckets when absent.
USAGE
}
args=(); while [[ $# -gt 0 ]]; do case "$1" in --create) CREATE_BUCKETS=1; shift ;; *) args+=("$1"); shift ;; esac; done
if ! parse_common_args "${args[@]}"; then usage; exit 0; fi
[[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/generated/customer.env"; SHOPWARE_INFRA_TOTAL=5
step "Config laden"; load_env_file "$CONFIG_FILE"; for var in S3_ENDPOINT S3_REGION S3_PUBLIC_BUCKET S3_PRIVATE_BUCKET S3_BACKUP_BUCKET S3_ACCESS_KEY S3_SECRET_KEY; do assert_not_empty "$var"; done
step "AWS CLI prüfen"; if ! command_exists aws; then warn "aws-cli fehlt. Buckets manuell im IONOS/Object-Storage-Panel anlegen."; exit 0; fi; ok "AWS CLI vorhanden: $(aws --version 2>&1)"
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" AWS_DEFAULT_REGION="$S3_REGION"
bucket_exists(){ aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$1" >/dev/null 2>&1; }
create_bucket_if_needed(){ local bucket="$1"; if bucket_exists "$bucket"; then ok "Bucket vorhanden: $bucket"; elif [[ "$CREATE_BUCKETS" == "1" ]]; then [[ "$DRY_RUN" == "1" ]] && log "[DRY-RUN] aws --endpoint-url $S3_ENDPOINT s3 mb s3://$bucket" || aws --endpoint-url "$S3_ENDPOINT" s3 mb "s3://$bucket"; ok "Bucket angelegt: $bucket"; else warn "Bucket fehlt: $bucket. Mit --create automatisch anlegen oder manuell erstellen."; fi; }
step "Buckets prüfen/anlegen"; create_bucket_if_needed "$S3_PUBLIC_BUCKET"; create_bucket_if_needed "$S3_PRIVATE_BUCKET"; create_bucket_if_needed "$S3_BACKUP_BUCKET"
step "Vault erweitern"; VAULT_FILE="$REPO_ROOT/generated/customer-vault.md"; if [[ -f "$VAULT_FILE" ]]; then vault_section "$VAULT_FILE" "S3 Check"; vault_kv "$VAULT_FILE" "S3_ENDPOINT" "$S3_ENDPOINT"; vault_kv "$VAULT_FILE" "S3_PUBLIC_BUCKET" "$S3_PUBLIC_BUCKET"; vault_kv "$VAULT_FILE" "S3_PRIVATE_BUCKET" "$S3_PRIVATE_BUCKET"; vault_kv "$VAULT_FILE" "S3_BACKUP_BUCKET" "$S3_BACKUP_BUCKET"; fi
step "Fertig"; ok "S3-Konfiguration geprüft."
