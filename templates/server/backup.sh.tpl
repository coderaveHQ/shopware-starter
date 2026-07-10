#!/usr/bin/env bash
set -Eeuo pipefail
cd "{{INSTALL_DIR}}"
BACKUP_DIR="{{INSTALL_DIR}}/backups"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
DB_FILE="$BACKUP_DIR/{{PROJECT_SLUG}}-{{ENVIRONMENT}}-db-$STAMP.sql.gz"
CONFIG_FILE="$BACKUP_DIR/{{PROJECT_SLUG}}-{{ENVIRONMENT}}-config-$STAMP.tar.gz"

echo "Creating database backup: $DB_FILE"
docker compose exec -T database mariadb-dump -u"{{DB_USER}}" -p"{{DB_PASSWORD}}" "{{DB_NAME}}" | gzip -9 > "$DB_FILE"
chmod 600 "$DB_FILE"

echo "Creating config backup: $CONFIG_FILE"
tar -czf "$CONFIG_FILE" .env compose.yaml Caddyfile deploy.sh status.sh 2>/dev/null || true
chmod 600 "$CONFIG_FILE"

find "$BACKUP_DIR" -type f -mtime +{{BACKUP_RETENTION_DAYS}} -delete

echo "Backup complete: $(date -Iseconds)"
