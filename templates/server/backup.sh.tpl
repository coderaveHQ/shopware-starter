#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALL_DIR={{INSTALL_DIR|shell}}
cd "$INSTALL_DIR"
COMPOSE=(docker compose --env-file .env.compose -f compose.yaml)
BACKUP_DIR="$INSTALL_DIR/backups"
PREFIX="$PROJECT_SLUG/$ENVIRONMENT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_DIR="$(mktemp -d "$BACKUP_DIR/.backup-$STAMP.XXXXXX")"
DB_FILE="$WORK_DIR/$PROJECT_SLUG-$ENVIRONMENT-db-$STAMP.sql.gz"
CONFIG_FILE="$WORK_DIR/$PROJECT_SLUG-$ENVIRONMENT-config-$STAMP.tar.gz"
ARCHIVE_NAME="$PROJECT_SLUG-$ENVIRONMENT-$STAMP.tar.gz"
ARCHIVE_FILE="$WORK_DIR/$ARCHIVE_NAME"
ENCRYPTED_FILE="$BACKUP_DIR/$ARCHIVE_NAME.enc"
AUTH_FILE="$ENCRYPTED_FILE.hmac"
STATUS=failed
QUIESCED=0
RUNNING_WRITE_SERVICES=()

notify() {
  local suffix="${1:-}"
  curl -fsS --max-time 10 "$BACKUP_HEALTHCHECK_URL$suffix" >/dev/null 2>&1 || true
}

cleanup() {
  local exit_code=$?
  if [[ "$QUIESCED" == 1 && "${#RUNNING_WRITE_SERVICES[@]}" -gt 0 ]]; then
    if ! "${COMPOSE[@]}" up -d --no-deps "${RUNNING_WRITE_SERVICES[@]}" >/dev/null; then
      echo "Failed to resume Shopware services after backup" >&2
      exit_code=1
      STATUS=failed
    fi
  fi
  rm -rf "$WORK_DIR"
  rm -f "$ENCRYPTED_FILE" "$AUTH_FILE"
  if [[ "$STATUS" != success || "$exit_code" -ne 0 ]]; then notify /fail; fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

quiesce_writes() {
  local service running
  running="$("${COMPOSE[@]}" ps --services --status running 2>/dev/null || true)"
  for service in app worker scheduler; do
    if printf '%s\n' "$running" | grep -qx "$service"; then RUNNING_WRITE_SERVICES+=("$service"); fi
  done
  if [[ "${#RUNNING_WRITE_SERVICES[@]}" -gt 0 ]]; then
    echo "Quiescing Shopware write services for a coherent database/files snapshot"
    "${COMPOSE[@]}" stop --timeout 60 "${RUNNING_WRITE_SERVICES[@]}"
    QUIESCED=1
  fi
}

resume_writes() {
  if [[ "$QUIESCED" == 1 && "${#RUNNING_WRITE_SERVICES[@]}" -gt 0 ]]; then
    "${COMPOSE[@]}" up -d --no-deps "${RUNNING_WRITE_SERVICES[@]}"
    QUIESCED=0
  fi
}

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
notify /start
quiesce_writes

echo "Copying quiesced public and private Shopware files to versioned backup storage"
export RCLONE_CONFIG_SOURCE_TYPE=s3
export RCLONE_CONFIG_SOURCE_PROVIDER=Other
export RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID="$S3_BACKUP_READER_ACCESS_KEY"
export RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY="$S3_BACKUP_READER_SECRET_KEY"
export RCLONE_CONFIG_SOURCE_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_SOURCE_REGION="$S3_REGION"
export RCLONE_CONFIG_SOURCE_FORCE_PATH_STYLE="$S3_USE_PATH_STYLE"
export RCLONE_CONFIG_DEST_TYPE=s3
export RCLONE_CONFIG_DEST_PROVIDER=Other
export RCLONE_CONFIG_DEST_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY"
export RCLONE_CONFIG_DEST_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY"
export RCLONE_CONFIG_DEST_ENDPOINT="$BACKUP_S3_ENDPOINT"
export RCLONE_CONFIG_DEST_REGION="$BACKUP_S3_REGION"
export RCLONE_CONFIG_DEST_FORCE_PATH_STYLE=true
export RCLONE_CONFIG_DEST_SERVER_SIDE_ENCRYPTION=AES256
rclone sync "source:$S3_PUBLIC_BUCKET" "dest:$BACKUP_S3_BUCKET/$PREFIX/files/public" --checkers 8 --transfers 4 --s3-no-check-bucket --log-level NOTICE
rclone sync "source:$S3_PRIVATE_BUCKET" "dest:$BACKUP_S3_BUCKET/$PREFIX/files/private" --checkers 8 --transfers 4 --s3-no-check-bucket --log-level NOTICE
rclone check "source:$S3_PUBLIC_BUCKET" "dest:$BACKUP_S3_BUCKET/$PREFIX/files/public" --one-way --checkers 8 --s3-no-check-bucket
rclone check "source:$S3_PRIVATE_BUCKET" "dest:$BACKUP_S3_BUCKET/$PREFIX/files/private" --one-way --checkers 8 --s3-no-check-bucket

echo "Creating consistent database dump"
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$DB_PASSWORD" database \
  mariadb-dump --single-transaction --quick --routines --events --triggers -u"$DB_USER" "$DB_NAME" \
  | gzip -9 > "$DB_FILE"
gzip -t "$DB_FILE"
resume_writes

echo "Creating configuration archive"
tar -czf "$CONFIG_FILE" .env.compose .env.runtime .env.init compose.yaml Caddyfile deploy.sh status.sh rollback.sh
tar -tzf "$CONFIG_FILE" >/dev/null

printf 'project=%s\nenvironment=%s\ncreated=%s\nwrite_services_quiesced=true\ndatabase=%s\nconfig=%s\n' \
  "$PROJECT_SLUG" "$ENVIRONMENT" "$(date -Iseconds)" "$(basename "$DB_FILE")" "$(basename "$CONFIG_FILE")" \
  > "$WORK_DIR/manifest.txt"
tar -C "$WORK_DIR" -czf "$ARCHIVE_FILE" "$(basename "$DB_FILE")" "$(basename "$CONFIG_FILE")" manifest.txt

echo "Encrypting backup"
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
  -in "$ARCHIVE_FILE" -out "$ENCRYPTED_FILE" -pass env:BACKUP_ENCRYPTION_PASSPHRASE
python3 - "$ENCRYPTED_FILE" "$AUTH_FILE" <<'PY'
import hashlib, hmac, os, pathlib, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
key = hashlib.pbkdf2_hmac('sha256', os.environ['BACKUP_ENCRYPTION_PASSPHRASE'].encode(), b'shopware-backup-hmac-v1', 600_000)
mac = hmac.new(key, digestmod=hashlib.sha256)
with source.open('rb') as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b''):
        mac.update(chunk)
digest = mac.hexdigest()
target.write_text(f'{digest}  {source.name}\n', encoding='ascii')
target.chmod(0o600)
PY

export AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$BACKUP_S3_REGION"
REMOTE_KEY="$PREFIX/archives/$(basename "$ENCRYPTED_FILE")"
echo "Uploading encrypted backup to s3://$BACKUP_S3_BUCKET/$REMOTE_KEY"
aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3 cp "$ENCRYPTED_FILE" "s3://$BACKUP_S3_BUCKET/$REMOTE_KEY" --sse AES256 --only-show-errors
aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3 cp "$AUTH_FILE" "s3://$BACKUP_S3_BUCKET/$REMOTE_KEY.hmac" --sse AES256 --only-show-errors
aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3api head-object --bucket "$BACKUP_S3_BUCKET" --key "$REMOTE_KEY" >/dev/null
aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3api head-object --bucket "$BACKUP_S3_BUCKET" --key "$REMOTE_KEY.hmac" >/dev/null

rm -f "$ENCRYPTED_FILE" "$AUTH_FILE"
STATUS=success
notify
echo "Encrypted offsite backup verified: $(date -Iseconds)"
