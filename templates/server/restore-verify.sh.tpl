#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALL_DIR={{INSTALL_DIR|shell}}
cd "$INSTALL_DIR"
COMPOSE=(docker compose --env-file .env.compose -f compose.yaml)
PREFIX="$PROJECT_SLUG/$ENVIRONMENT"
WORK_DIR="$(mktemp -d "$INSTALL_DIR/backups/.restore-verify.XXXXXX")"
RESTORE_DB="${DB_NAME}_restore_verify"
DB_CREATED=0
STATUS=failed

notify() {
  local suffix="${1:-}"
  curl -fsS --max-time 10 "$RESTORE_HEALTHCHECK_URL$suffix" >/dev/null 2>&1 || true
}

db_root() {
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" database mariadb -uroot "$@"
}

cleanup() {
  local exit_code=$?
  if [[ "$DB_CREATED" == 1 ]]; then db_root -e "DROP DATABASE IF EXISTS \`$RESTORE_DB\`" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK_DIR"
  if [[ "$STATUS" != success || "$exit_code" -ne 0 ]]; then notify /fail; fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
notify /start

export AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$BACKUP_S3_REGION"
for file_tree in public private; do
  first_file="$(aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3api list-objects-v2 --bucket "$BACKUP_S3_BUCKET" --prefix "$PREFIX/files/$file_tree/" --max-keys 1 --query 'Contents[0].Key' --output text)"
  if [[ -n "$first_file" && "$first_file" != None ]]; then
    aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3api get-object --bucket "$BACKUP_S3_BUCKET" --key "$first_file" "$WORK_DIR/$file_tree-file-restore-probe" >/dev/null
    [[ -f "$WORK_DIR/$file_tree-file-restore-probe" ]] || { echo "$file_tree file restore probe failed" >&2; exit 1; }
  fi
done

LATEST_KEY="$(aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3 ls "s3://$BACKUP_S3_BUCKET/$PREFIX/archives/" --recursive | awk '$4 ~ /\.tar\.gz\.enc$/ {print $4}' | sort | tail -n1)"
[[ -n "$LATEST_KEY" ]] || { echo "No encrypted backup found" >&2; exit 1; }

ENCRYPTED_FILE="$WORK_DIR/$(basename "$LATEST_KEY")"
AUTH_FILE="$ENCRYPTED_FILE.hmac"
DECRYPTED_FILE="$WORK_DIR/backup.tar.gz"
aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3 cp "s3://$BACKUP_S3_BUCKET/$LATEST_KEY" "$ENCRYPTED_FILE" --only-show-errors
aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3 cp "s3://$BACKUP_S3_BUCKET/$LATEST_KEY.hmac" "$AUTH_FILE" --only-show-errors
[[ "$(wc -c < "$AUTH_FILE")" -le 512 ]] || { echo "Backup HMAC file is unexpectedly large" >&2; exit 1; }
python3 - "$ENCRYPTED_FILE" "$AUTH_FILE" <<'PY'
import hashlib, hmac, os, pathlib, sys
source, auth_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
expected = auth_file.read_text(encoding='ascii').split()[0]
key = hashlib.pbkdf2_hmac('sha256', os.environ['BACKUP_ENCRYPTION_PASSPHRASE'].encode(), b'shopware-backup-hmac-v1', 600_000)
mac = hmac.new(key, digestmod=hashlib.sha256)
with source.open('rb') as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b''):
        mac.update(chunk)
actual = mac.hexdigest()
if not hmac.compare_digest(actual, expected):
    raise SystemExit('Encrypted backup HMAC verification failed')
PY
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in "$ENCRYPTED_FILE" -out "$DECRYPTED_FILE" -pass env:BACKUP_ENCRYPTION_PASSPHRASE
tar -tzf "$DECRYPTED_FILE" > "$WORK_DIR/archive-members.txt"
python3 - "$WORK_DIR/archive-members.txt" <<'PY'
import pathlib, sys
names = pathlib.Path(sys.argv[1]).read_text().splitlines()
if len(names) != 3 or 'manifest.txt' not in names:
    raise SystemExit('Unexpected backup archive contents')
for name in names:
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or len(path.parts) != 1:
        raise SystemExit(f'Unsafe backup archive member: {name}')
PY
tar --no-same-owner --no-same-permissions -xzf "$DECRYPTED_FILE" -C "$WORK_DIR"

DB_DUMP="$(find "$WORK_DIR" -maxdepth 1 -name '*-db-*.sql.gz' -type f -print -quit)"
CONFIG_ARCHIVE="$(find "$WORK_DIR" -maxdepth 1 -name '*-config-*.tar.gz' -type f -print -quit)"
[[ -n "$DB_DUMP" && -n "$CONFIG_ARCHIVE" && -f "$WORK_DIR/manifest.txt" ]] || { echo "Backup archive incomplete" >&2; exit 1; }
gzip -t "$DB_DUMP"
tar -tzf "$CONFIG_ARCHIVE" > "$WORK_DIR/config-members.txt"
python3 - "$WORK_DIR/config-members.txt" <<'PY'
import pathlib, sys
for name in pathlib.Path(sys.argv[1]).read_text().splitlines():
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts:
        raise SystemExit(f'Unsafe configuration archive member: {name}')
PY

db_root -e "DROP DATABASE IF EXISTS \`$RESTORE_DB\`; CREATE DATABASE \`$RESTORE_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
DB_CREATED=1
gunzip -c "$DB_DUMP" | "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" database mariadb -uroot "$RESTORE_DB"
TABLE_COUNT="$(db_root -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$RESTORE_DB'")"
[[ "$TABLE_COUNT" =~ ^[0-9]+$ && "$TABLE_COUNT" -gt 0 ]] || { echo "Restored database contains no tables" >&2; exit 1; }
db_root -e "DROP DATABASE \`$RESTORE_DB\`"
DB_CREATED=0

STATUS=success
notify
echo "Restore verification succeeded with $TABLE_COUNT tables: $(date -Iseconds)"
