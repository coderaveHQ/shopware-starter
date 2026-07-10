#!/usr/bin/env bash
# Common implementation for staging/production server setup.

validate_server_env() {
  for var in ENVIRONMENT CUSTOMER_NAME PROJECT_SLUG PRIMARY_DOMAIN ADMIN_EMAIL TIMEZONE ADMIN_USER DEPLOY_USER ADMIN_PUBLIC_KEY GITHUB_ACTIONS_DEPLOY_PUBLIC_KEY SSH_PORT INSTALL_DIR COMPOSE_PROJECT_NAME GHCR_IMAGE SHOPWARE_IMAGE APP_URL APP_SECRET INSTALL_ADMIN_USERNAME INSTALL_ADMIN_PASSWORD DB_NAME DB_USER DB_ROOT_PASSWORD DB_PASSWORD REDIS_PASSWORD RABBITMQ_USER RABBITMQ_PASSWORD MARIADB_IMAGE VALKEY_IMAGE RABBITMQ_IMAGE VARNISH_IMAGE CADDY_IMAGE BACKUP_RETENTION_DAYS BACKUP_HOUR BACKUP_MINUTE; do
    assert_not_empty "$var"
  done
  [[ "$EXPECTED_ENVIRONMENT" == "$ENVIRONMENT" ]] || die "Falsche Config: erwartet $EXPECTED_ENVIRONMENT, erhalten $ENVIRONMENT"
  is_valid_domainish "$PRIMARY_DOMAIN" || die "Ungültige PRIMARY_DOMAIN: $PRIMARY_DOMAIN"
  ok "Server-Konfiguration validiert: $ENVIRONMENT / $PRIMARY_DOMAIN"
}

write_runtime_files() {
  mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/backups"
  chmod 750 "$INSTALL_DIR" "$INSTALL_DIR/backups"
  render_template "$REPO_ROOT/templates/shopware/env.example.tpl" "$INSTALL_DIR/.env"
  render_template "$REPO_ROOT/templates/docker/compose.server.yaml.tpl" "$INSTALL_DIR/compose.yaml"
  render_template "$REPO_ROOT/templates/docker/Caddyfile.tpl" "$INSTALL_DIR/Caddyfile"
  render_template "$REPO_ROOT/templates/server/deploy.sh.tpl" "$INSTALL_DIR/deploy.sh"
  render_template "$REPO_ROOT/templates/server/status.sh.tpl" "$INSTALL_DIR/status.sh"
  render_template "$REPO_ROOT/templates/server/backup.sh.tpl" "$INSTALL_DIR/backup.sh"
  chmod 640 "$INSTALL_DIR/.env" "$INSTALL_DIR/compose.yaml" "$INSTALL_DIR/Caddyfile"
  chmod 750 "$INSTALL_DIR/deploy.sh" "$INSTALL_DIR/status.sh" "$INSTALL_DIR/backup.sh"
  chown -R root:"$DEPLOY_USER" "$INSTALL_DIR"
  ok "Runtime-Dateien geschrieben: $INSTALL_DIR"
}

install_systemd_backup_timer() {
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: systemd Backup Timer übersprungen"; return 0; fi
  render_template "$REPO_ROOT/templates/systemd/backup.service.tpl" "/etc/systemd/system/shopware-$ENVIRONMENT-backup.service"
  render_template "$REPO_ROOT/templates/systemd/backup.timer.tpl" "/etc/systemd/system/shopware-$ENVIRONMENT-backup.timer"
  systemctl daemon-reload
  systemctl enable --now "shopware-$ENVIRONMENT-backup.timer"
  ok "Backup Timer aktiviert: shopware-$ENVIRONMENT-backup.timer"
}

write_server_summary() {
  local summary_dir="/root/shopware-setup"
  mkdir -p "$summary_dir"
  local summary="$summary_dir/${ENVIRONMENT}-server-summary.md"
  local public_ip="unknown"
  if command_exists curl && [[ "$TEST_MODE" != "1" ]]; then public_ip="$(curl -fsS --max-time 5 https://api.ipify.org || true)"; fi
  cat > "$summary" <<EOFS
# Server Summary: $PROJECT_SLUG / $ENVIRONMENT

Generated: $(date -Iseconds)

## Server

- Environment: $ENVIRONMENT
- Domain: https://$PRIMARY_DOMAIN
- Public IP detected: $public_ip
- Hostname: $(hostname)
- Install dir: $INSTALL_DIR
- Compose project: $COMPOSE_PROJECT_NAME

## Linux Users

- Admin user: $ADMIN_USER
- Deploy user: $DEPLOY_USER
- SSH port: $SSH_PORT

## Important files on server

- Runtime env: $INSTALL_DIR/.env
- Compose: $INSTALL_DIR/compose.yaml
- Caddyfile: $INSTALL_DIR/Caddyfile
- Deploy script: $INSTALL_DIR/deploy.sh
- Status script: $INSTALL_DIR/status.sh
- Backup script: $INSTALL_DIR/backup.sh
- Backup timer: shopware-$ENVIRONMENT-backup.timer

## Useful commands

~~~bash
sudo -iu $DEPLOY_USER
cd $INSTALL_DIR
docker compose ps
./status.sh
./backup.sh
~~~

## GitHub Actions values

- ${ENVIRONMENT^^}_SSH_HOST: $public_ip or configured server IP
- ${ENVIRONMENT^^}_SSH_PORT: $SSH_PORT
- ${ENVIRONMENT^^}_SSH_USER: $DEPLOY_USER
- ${ENVIRONMENT^^}_INSTALL_DIR: $INSTALL_DIR

EOFS
  chmod 600 "$summary"
  ok "Server-Summary geschrieben: $summary"
}

start_infra_containers_if_possible() {
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: Docker Compose Start übersprungen"; return 0; fi
  cd "$INSTALL_DIR"
  if docker image inspect "$SHOPWARE_IMAGE" >/dev/null 2>&1 || docker manifest inspect "$SHOPWARE_IMAGE" >/dev/null 2>&1; then
    warn "Shopware-Image scheint bereits verfügbar zu sein. Das eigentliche Deployment sollte trotzdem per GitHub Actions laufen."
  else
    warn "Shopware-Image ist noch nicht verfügbar: $SHOPWARE_IMAGE. Infrastruktur wird vorbereitet; erster App-Start erfolgt nach GitHub-Actions-Deployment."
  fi
  docker compose up -d database redis rabbitmq || warn "Infrastruktur-Container konnten noch nicht vollständig gestartet werden. Prüfe Docker Logs."
}

setup_shopware_server() {
  local config_file="$1" expected="$2"
  EXPECTED_ENVIRONMENT="$expected"; SHOPWARE_INFRA_TOTAL=14
  step "Config laden"; load_env_file "$config_file"; validate_server_env
  step "Ubuntu prüfen"; require_root; check_ubuntu
  step "System aktualisieren und Basispakete installieren"; apt_install_base_packages
  step "Hostname und Zeitzone setzen"; set_system_basics "$PROJECT_SLUG-$ENVIRONMENT" "$TIMEZONE"
  step "Benutzer und SSH-Keys anlegen"; ensure_linux_user "$ADMIN_USER" "$ADMIN_PUBLIC_KEY" 1; ensure_linux_user "$DEPLOY_USER" "$GITHUB_ACTIONS_DEPLOY_PUBLIC_KEY" 0
  local deploy_home; deploy_home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
  if [[ -n "$ADMIN_PUBLIC_KEY" ]] && ! grep -qxF "$ADMIN_PUBLIC_KEY" "$deploy_home/.ssh/authorized_keys"; then printf '%s\n' "$ADMIN_PUBLIC_KEY" >> "$deploy_home/.ssh/authorized_keys"; chown "$DEPLOY_USER:$DEPLOY_USER" "$deploy_home/.ssh/authorized_keys"; fi
  step "Docker installieren"; install_docker_engine; add_user_to_docker_group "$ADMIN_USER"; add_user_to_docker_group "$DEPLOY_USER"; check_docker_compose
  step "SSH absichern"; harden_ssh
  step "Firewall und Sicherheitsdienste einrichten"; configure_firewall; enable_security_services
  step "Ports prüfen"; check_port_free 80; check_port_free 443
  step "Shopware Runtime-Dateien schreiben"; write_runtime_files
  step "Backup Timer einrichten"; install_systemd_backup_timer
  step "Docker Infrastruktur vorbereiten"; start_infra_containers_if_possible
  step "Server Summary schreiben"; write_server_summary
  step "Abschluss-Checks"; [[ -f "$INSTALL_DIR/.env" ]] || die ".env fehlt"; [[ -f "$INSTALL_DIR/compose.yaml" ]] || die "compose.yaml fehlt"; [[ -x "$INSTALL_DIR/deploy.sh" ]] || die "deploy.sh ist nicht ausführbar"; ok "Server $ENVIRONMENT ist vorbereitet. Der Shop startet nach dem ersten GitHub-Actions-Deployment."
}
