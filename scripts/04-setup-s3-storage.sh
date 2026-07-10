#!/usr/bin/env bash
# Provisions and verifies isolated runtime and backup S3 storage.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
CONFIG_FILE="$REPO_ROOT/generated/customer.env"; CREATE_BUCKETS=0

usage() { cat <<USAGE
Usage: bash scripts/04-setup-s3-storage.sh --target staging|production|all [--config generated/customer.env] [--create] [--dry-run]

Uses dedicated provisioning credentials for bucket creation/versioning/encryption,
then verifies runtime and backup credentials with real write/read/delete probes.
USAGE
}

args=()
while [[ $# -gt 0 ]]; do case "$1" in --create) CREATE_BUCKETS=1; shift ;; *) args+=("$1"); shift ;; esac; done
if ! parse_common_args "${args[@]}"; then usage; exit 0; fi
[[ -n "$TARGET" ]] || die "--target staging|production|all fehlt."
[[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/generated/customer.env"
if [[ "$DRY_RUN" == 1 ]]; then SHOPWARE_INFRA_TOTAL=2; elif [[ "$TARGET" == all ]]; then SHOPWARE_INFRA_TOTAL=4; else SHOPWARE_INFRA_TOTAL=3; fi

step "Konfiguration sicher laden und Isolation validieren"
assert_private_file "$CONFIG_FILE"
load_env_file "$CONFIG_FILE" "${GENERATED_CUSTOMER_CONFIG_KEYS[@]}"
validate_customer_config
require_command aws; require_command curl

if [[ "$DRY_RUN" == 1 ]]; then
  step "Änderungsfreien Plan ausgeben"
  log "[DRY-RUN] Würde getrennte Runtime-/Backup-Buckets prüfen, Versionierung und AES256 aktivieren und Zugriffssonden wieder löschen."
  ok "S3-Dry-run ohne Netzwerkmutation abgeschlossen"
  exit 0
fi

set_aws_credentials() {
  export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_DEFAULT_REGION="$3"
}

bucket_exists() { aws --endpoint-url "$1" s3api head-bucket --bucket "$2" >/dev/null 2>&1; }

PROBE_LOCAL_FILES=()
PROBE_ENDPOINTS=()
PROBE_REGIONS=()
PROBE_BUCKETS=()
PROBE_KEYS=()
PROBE_ACCESS_KEYS=()
PROBE_SECRET_KEYS=()
REGISTERED_PROBE_INDEX=-1

register_probe() {
  PROBE_ENDPOINTS+=("$1"); PROBE_REGIONS+=("$2"); PROBE_BUCKETS+=("$3"); PROBE_KEYS+=("$4"); PROBE_ACCESS_KEYS+=("$5"); PROBE_SECRET_KEYS+=("$6")
  REGISTERED_PROBE_INDEX=$((${#PROBE_BUCKETS[@]} - 1))
}

purge_probe_versions() {
  local endpoint="$1" region="$2" bucket="$3" key="$4" access="$5" secret="$6" kind version_id version_ids
  set_aws_credentials "$access" "$secret" "$region"
  for kind in Versions DeleteMarkers; do
    version_ids="$(aws --endpoint-url "$endpoint" s3api list-object-versions --bucket "$bucket" --prefix "$key" --query "${kind}[?Key=='$key'].VersionId" --output text)" || return 1
    while IFS= read -r version_id; do
      [[ -n "$version_id" && "$version_id" != None ]] || continue
      aws --endpoint-url "$endpoint" s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version_id" >/dev/null || return 1
    done < <(printf '%s' "$version_ids" | tr '\t' '\n')
    version_ids="$(aws --endpoint-url "$endpoint" s3api list-object-versions --bucket "$bucket" --prefix "$key" --query "${kind}[?Key=='$key'].VersionId" --output text)" || return 1
    [[ -z "$version_ids" || "$version_ids" == None ]] || return 1
  done
}

cleanup_probes() {
  local file i
  set +e
  for file in "${PROBE_LOCAL_FILES[@]}"; do rm -f -- "$file"; done
  for ((i=0; i<${#PROBE_BUCKETS[@]}; i++)); do
    [[ -n "${PROBE_BUCKETS[$i]}" ]] || continue
    purge_probe_versions "${PROBE_ENDPOINTS[$i]}" "${PROBE_REGIONS[$i]}" "${PROBE_BUCKETS[$i]}" "${PROBE_KEYS[$i]}" "${PROBE_ACCESS_KEYS[$i]}" "${PROBE_SECRET_KEYS[$i]}" || true
  done
}
trap cleanup_probes EXIT

provision_bucket() {
  local endpoint="$1" bucket="$2" backup_prefix="${3:-}" lifecycle_configuration
  if ! bucket_exists "$endpoint" "$bucket"; then
    [[ "$CREATE_BUCKETS" == 1 ]] || die "Bucket fehlt: $bucket. Nach Prüfung mit --create anlegen."
    aws --endpoint-url "$endpoint" s3 mb "s3://$bucket"
  fi
  aws --endpoint-url "$endpoint" s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
  aws --endpoint-url "$endpoint" s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  local status
  status="$(aws --endpoint-url "$endpoint" s3api get-bucket-versioning --bucket "$bucket" --query Status --output text)"
  [[ "$status" == Enabled ]] || die "Versionierung ist nicht aktiv: $bucket"
  if [[ -n "$backup_prefix" ]]; then
    lifecycle_configuration="{\"Rules\":[{\"ID\":\"expire-encrypted-archives\",\"Status\":\"Enabled\",\"Filter\":{\"Prefix\":\"$backup_prefix/archives/\"},\"Expiration\":{\"Days\":$BACKUP_RETENTION_DAYS},\"NoncurrentVersionExpiration\":{\"NoncurrentDays\":$BACKUP_RETENTION_DAYS}},{\"ID\":\"expire-old-file-versions\",\"Status\":\"Enabled\",\"Filter\":{\"Prefix\":\"$backup_prefix/files/\"},\"Expiration\":{\"ExpiredObjectDeleteMarker\":true},\"NoncurrentVersionExpiration\":{\"NoncurrentDays\":$BACKUP_RETENTION_DAYS}}]}"
    aws --endpoint-url "$endpoint" s3api put-bucket-lifecycle-configuration --bucket "$bucket" --lifecycle-configuration "$lifecycle_configuration"
    aws --endpoint-url "$endpoint" s3api get-bucket-lifecycle-configuration --bucket "$bucket" >/dev/null
  fi
}

probe_runtime_storage() {
  local endpoint="$1" region="$2" path_style="$3" public_bucket="$4" private_bucket="$5" public_url="$6" access="$7" secret="$8" reader_access="$9" reader_secret="${10}" provisioning_access="${11}" provisioning_secret="${12}"
  local token key tmp private_url public_status private_status public_probe private_probe reader_write_probe
  token="shopware-storage-probe-$(date +%s)-$$"; key=".shopware-preflight/$token.txt"; tmp="$(mktemp)"
  public_probe="$key"; private_probe="$key"; reader_write_probe="$key.reader-write"
  PROBE_LOCAL_FILES+=("$tmp" "$tmp.read" "$tmp.private" "$tmp.reader-public" "$tmp.reader-private")
  chmod 600 "$tmp"; printf '%s' "$token" > "$tmp"
  register_probe "$endpoint" "$region" "$public_bucket" "$public_probe" "$provisioning_access" "$provisioning_secret"; local public_index=$REGISTERED_PROBE_INDEX
  register_probe "$endpoint" "$region" "$private_bucket" "$private_probe" "$provisioning_access" "$provisioning_secret"; local private_index=$REGISTERED_PROBE_INDEX
  register_probe "$endpoint" "$region" "$private_bucket" "$reader_write_probe" "$provisioning_access" "$provisioning_secret"; local reader_write_index=$REGISTERED_PROBE_INDEX
  set_aws_credentials "$access" "$secret" "$region"
  aws --endpoint-url "$endpoint" s3api put-object --bucket "$public_bucket" --key "$public_probe" --body "$tmp" --acl public-read >/dev/null
  aws --endpoint-url "$endpoint" s3api get-object --bucket "$public_bucket" --key "$public_probe" "$tmp.read" >/dev/null
  [[ "$(<"$tmp.read")" == "$token" ]] || die "Public runtime readback failed."
  public_status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${public_url%/}/$public_probe")"
  [[ "$public_status" == 200 ]] || die "Public S3 URL is not anonymously readable (HTTP $public_status)."

  aws --endpoint-url "$endpoint" s3api put-object --bucket "$private_bucket" --key "$private_probe" --body "$tmp" --acl private >/dev/null
  aws --endpoint-url "$endpoint" s3api get-object --bucket "$private_bucket" --key "$private_probe" "$tmp.private" >/dev/null
  if [[ "$endpoint" == https://* ]]; then
    if [[ "$path_style" == true ]]; then private_url="${endpoint%/}/$private_bucket/$private_probe"; else private_url="https://$private_bucket.${endpoint#https://}/$private_probe"; fi
  else die "S3 endpoint must use HTTPS."; fi
  private_status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$private_url")"
  [[ "$private_status" != 200 ]] || die "Private bucket object is anonymously readable."
  set_aws_credentials "$reader_access" "$reader_secret" "$region"
  aws --endpoint-url "$endpoint" s3api list-objects-v2 --bucket "$public_bucket" --prefix "$public_probe" --max-keys 1 >/dev/null
  aws --endpoint-url "$endpoint" s3api list-objects-v2 --bucket "$private_bucket" --prefix "$private_probe" --max-keys 1 >/dev/null
  aws --endpoint-url "$endpoint" s3api get-object --bucket "$public_bucket" --key "$public_probe" "$tmp.reader-public" >/dev/null
  aws --endpoint-url "$endpoint" s3api get-object --bucket "$private_bucket" --key "$private_probe" "$tmp.reader-private" >/dev/null
  if aws --endpoint-url "$endpoint" s3api put-object --bucket "$private_bucket" --key "$reader_write_probe" --body "$tmp" >/dev/null 2>&1; then die "Backup reader credential can write runtime objects."; fi
  if aws --endpoint-url "$endpoint" s3api delete-object --bucket "$private_bucket" --key "$private_probe" >/dev/null 2>&1; then die "Backup reader credential can delete runtime objects."; fi
  set_aws_credentials "$access" "$secret" "$region"
  aws --endpoint-url "$endpoint" s3api delete-object --bucket "$public_bucket" --key "$public_probe" >/dev/null
  aws --endpoint-url "$endpoint" s3api delete-object --bucket "$private_bucket" --key "$private_probe" >/dev/null
  purge_probe_versions "$endpoint" "$region" "$public_bucket" "$public_probe" "$provisioning_access" "$provisioning_secret"; PROBE_BUCKETS[public_index]=""
  purge_probe_versions "$endpoint" "$region" "$private_bucket" "$private_probe" "$provisioning_access" "$provisioning_secret"; PROBE_BUCKETS[private_index]=""
  purge_probe_versions "$endpoint" "$region" "$private_bucket" "$reader_write_probe" "$provisioning_access" "$provisioning_secret"; PROBE_BUCKETS[reader_write_index]=""
}

probe_backup_storage() {
  local endpoint="$1" region="$2" bucket="$3" access="$4" secret="$5" provisioning_access="$6" provisioning_secret="$7" token key tmp anonymous_status probe_index
  token="shopware-backup-probe-$(date +%s)-$$"; key=".shopware-preflight/$token.txt"; tmp="$(mktemp)"
  PROBE_LOCAL_FILES+=("$tmp" "$tmp.read")
  chmod 600 "$tmp"; printf '%s' "$token" > "$tmp"
  register_probe "$endpoint" "$region" "$bucket" "$key" "$provisioning_access" "$provisioning_secret"; probe_index=$REGISTERED_PROBE_INDEX
  set_aws_credentials "$access" "$secret" "$region"
  aws --endpoint-url "$endpoint" s3api put-object --bucket "$bucket" --key "$key" --body "$tmp" --server-side-encryption AES256 >/dev/null
  aws --endpoint-url "$endpoint" s3api get-object --bucket "$bucket" --key "$key" "$tmp.read" >/dev/null
  aws --endpoint-url "$endpoint" s3api list-objects-v2 --bucket "$bucket" --prefix "$key" --max-keys 1 >/dev/null
  [[ "$(<"$tmp.read")" == "$token" ]] || die "Backup readback failed."
  anonymous_status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${endpoint%/}/$bucket/$key")"
  [[ "$anonymous_status" != 200 ]] || die "Backup bucket object is anonymously readable."
  aws --endpoint-url "$endpoint" s3api delete-object --bucket "$bucket" --key "$key" >/dev/null
  purge_probe_versions "$endpoint" "$region" "$bucket" "$key" "$provisioning_access" "$provisioning_secret"; PROBE_BUCKETS[probe_index]=""
}

assert_no_bucket_access() {
  local endpoint="$1" region="$2" bucket="$3" access="$4" secret="$5" provisioning_access="$6" provisioning_secret="$7" label="$8"
  local key tmp probe_index
  key=".shopware-preflight/cross-boundary-$(date +%s)-$$.txt"; tmp="$(mktemp)"
  PROBE_LOCAL_FILES+=("$tmp" "$tmp.read")
  chmod 600 "$tmp"; printf '%s' cross-boundary-probe > "$tmp"
  register_probe "$endpoint" "$region" "$bucket" "$key" "$provisioning_access" "$provisioning_secret"; probe_index=$REGISTERED_PROBE_INDEX
  set_aws_credentials "$provisioning_access" "$provisioning_secret" "$region"
  aws --endpoint-url "$endpoint" s3api put-object --bucket "$bucket" --key "$key" --body "$tmp" --server-side-encryption AES256 >/dev/null
  set_aws_credentials "$access" "$secret" "$region"
  if aws --endpoint-url "$endpoint" s3api list-objects-v2 --bucket "$bucket" --prefix "$key" --max-keys 1 >/dev/null 2>&1; then die "$label can list the isolated bucket."; fi
  if aws --endpoint-url "$endpoint" s3api get-object --bucket "$bucket" --key "$key" "$tmp.read" >/dev/null 2>&1; then die "$label can read the isolated bucket."; fi
  if aws --endpoint-url "$endpoint" s3api put-object --bucket "$bucket" --key "$key" --body "$tmp" >/dev/null 2>&1; then die "$label can write the isolated bucket."; fi
  if aws --endpoint-url "$endpoint" s3api delete-object --bucket "$bucket" --key "$key" >/dev/null 2>&1; then die "$label can delete from the isolated bucket."; fi
  purge_probe_versions "$endpoint" "$region" "$bucket" "$key" "$provisioning_access" "$provisioning_secret"; PROBE_BUCKETS[probe_index]=""
}

process_environment() {
  local prefix="$1" label="$2" name marker_name path_style_name path_style
  local endpoint region public_bucket private_bucket public_url access_key secret_key backup_reader_access_key backup_reader_secret_key provisioning_access_key provisioning_secret_key runtime_access runtime_secret reader_access reader_secret provisioning_access provisioning_secret backup_endpoint backup_region backup_bucket backup_access_key backup_secret_key backup_access backup_secret
  for variable in endpoint region public_bucket private_bucket public_url access_key secret_key backup_reader_access_key backup_reader_secret_key provisioning_access_key provisioning_secret_key; do name="${prefix}_S3_$(printf '%s' "$variable" | tr '[:lower:]' '[:upper:]')"; printf -v "$variable" '%s' "${!name}"; done
  for variable in endpoint region bucket access_key secret_key; do name="${prefix}_BACKUP_S3_$(printf '%s' "$variable" | tr '[:lower:]' '[:upper:]')"; printf -v "backup_$variable" '%s' "${!name}"; done
  runtime_access="$access_key"; runtime_secret="$secret_key"
  reader_access="$backup_reader_access_key"; reader_secret="$backup_reader_secret_key"
  provisioning_access="$provisioning_access_key"; provisioning_secret="$provisioning_secret_key"
  backup_access="$backup_access_key"; backup_secret="$backup_secret_key"

  marker_name="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  step "$label Buckets provisionieren und Policies prüfen"
  set_aws_credentials "$provisioning_access" "$provisioning_secret" "$region"
  provision_bucket "$endpoint" "$public_bucket"
  provision_bucket "$endpoint" "$private_bucket"
  set_aws_credentials "$provisioning_access" "$provisioning_secret" "$backup_region"
  provision_bucket "$backup_endpoint" "$backup_bucket" "$PROJECT_SLUG/$marker_name"
  path_style_name="${prefix}_S3_USE_PATH_STYLE"; path_style="${!path_style_name}"
  probe_runtime_storage "$endpoint" "$region" "$path_style" "$public_bucket" "$private_bucket" "$public_url" "$runtime_access" "$runtime_secret" "$reader_access" "$reader_secret" "$provisioning_access" "$provisioning_secret"
  probe_backup_storage "$backup_endpoint" "$backup_region" "$backup_bucket" "$backup_access" "$backup_secret" "$provisioning_access" "$provisioning_secret"
  assert_no_bucket_access "$backup_endpoint" "$backup_region" "$backup_bucket" "$runtime_access" "$runtime_secret" "$provisioning_access" "$provisioning_secret" "$label runtime credential"
  assert_no_bucket_access "$endpoint" "$region" "$public_bucket" "$backup_access" "$backup_secret" "$provisioning_access" "$provisioning_secret" "$label backup credential"
  printf 'environment=%s\nconfig_sha256=%s\nverified=%s\n' "$label" "$(file_sha256 "$CONFIG_FILE")" "$(date -Iseconds)" > "$REPO_ROOT/generated/s3-${marker_name}.verified"
  chmod 600 "$REPO_ROOT/generated/s3-${marker_name}.verified"
  ok "$label S3-Isolation, Verschlüsselung, Versionierung und Zugriff verifiziert"
}

case "$TARGET" in
  staging) process_environment STAGING Staging ;;
  production) process_environment PRODUCTION Production ;;
  all) process_environment STAGING Staging; process_environment PRODUCTION Production ;;
  *) die "Ungültiges Target: $TARGET" ;;
esac

step "S3-Prüfung abschließen"
ok "Alle temporären Zugriffssonden wurden gelöscht."
