#!/usr/bin/env bash
# Optional backup server skeleton for future larger customers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
usage() { cat <<USAGE
Usage: sudo bash scripts/03-setup-backup-server.sh --config backup-server.env [--dry-run]

Variant A does not require a separate backup server. This prepares a hardened Ubuntu host for later Borg/Restic/rclone-based offsite backups.
USAGE
}
if ! parse_common_args "$@"; then usage; exit 0; fi
[[ -n "$CONFIG_FILE" ]] || die "Bitte --config backup-server.env angeben."
SHOPWARE_INFRA_TOTAL=7
step "Config laden"; load_env_file "$CONFIG_FILE"; for var in BACKUP_USER BACKUP_PUBLIC_KEY TIMEZONE; do assert_not_empty "$var"; done
step "Ubuntu prüfen"; require_root; check_ubuntu
step "Basispakete installieren"; apt_install_base_packages; [[ "$TEST_MODE" == "1" ]] || run_cmd apt-get install -y borgbackup restic rclone
step "Backup User anlegen"; ensure_linux_user "$BACKUP_USER" "$BACKUP_PUBLIC_KEY" 0
step "SSH/Firewall härten"; harden_ssh; configure_firewall; enable_security_services
step "Backup-Verzeichnisse vorbereiten"; mkdir -p /srv/backups; chown root:"$BACKUP_USER" /srv/backups; chmod 770 /srv/backups
step "Fertig"; ok "Backup-Server vorbereitet. Für Variante A meist optional; Object Storage + Cloud Backup reichen oft."
