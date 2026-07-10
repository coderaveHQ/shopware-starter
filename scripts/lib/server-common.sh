#!/usr/bin/env bash
# Hardened one-shot implementation for staging/production server setup.

SERVER_SETUP_CONFIG_CLEANUP_FILE=""

cleanup_plaintext_setup_config() {
  local exit_code=$? file="${SERVER_SETUP_CONFIG_CLEANUP_FILE:-}"
  if [[ -n "$file" && -f "$file" && ! -L "$file" ]]; then
    if command_exists shred; then shred -u -- "$file" 2>/dev/null || rm -f -- "$file"; else rm -f -- "$file"; fi
  fi
  return "$exit_code"
}

write_runtime_files() {
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] Getrennte Runtime-, Init-, Compose- und Backup-Dateien schreiben"; return 0; fi
  [[ ! -L "$INSTALL_BASE_DIR" && ! -L "$INSTALL_DIR" ]] || die "Symlinks im Installationspfad sind verboten."
  mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/backups" "$INSTALL_DIR/deployment-history"
  [[ "$(readlink -f "$INSTALL_DIR")" == "$INSTALL_DIR" ]] || die "INSTALL_DIR löst unerwartet auf."
  chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/backups" "$INSTALL_DIR/deployment-history"

  DATABASE_URL="mysql://$DB_USER:$DB_PASSWORD@database:3306/$DB_NAME"
  REDIS_URL="redis://:$REDIS_PASSWORD@redis:6379/0"
  CACHE_URL="redis://:$REDIS_PASSWORD@redis:6379/1"
  PHP_SESSION_SAVE_PATH="tcp://redis:6379?auth=$REDIS_PASSWORD"
  MESSENGER_TRANSPORT_DSN="amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@rabbitmq:5672/shopware/messages"
  MESSENGER_TRANSPORT_LOW_PRIORITY_DSN="amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@rabbitmq:5672/shopware/low_priority"
  MESSENGER_TRANSPORT_FAILURE_DSN="amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@rabbitmq:5672/shopware/failed"
  export DATABASE_URL REDIS_URL CACHE_URL PHP_SESSION_SAVE_PATH MESSENGER_TRANSPORT_DSN MESSENGER_TRANSPORT_LOW_PRIORITY_DSN MESSENGER_TRANSPORT_FAILURE_DSN

  render_template "$REPO_ROOT/templates/shopware/env.compose.tpl" "$INSTALL_DIR/.env.compose"
  render_template "$REPO_ROOT/templates/shopware/env.runtime.tpl" "$INSTALL_DIR/.env.runtime"
  render_template "$REPO_ROOT/templates/shopware/env.init.tpl" "$INSTALL_DIR/.env.init"
  render_template "$REPO_ROOT/templates/shopware/env.backup.tpl" "$INSTALL_DIR/.env.backup"
  render_template "$REPO_ROOT/templates/docker/compose.server.yaml.tpl" "$INSTALL_DIR/compose.yaml"
  render_template "$REPO_ROOT/templates/docker/Caddyfile.tpl" "$INSTALL_DIR/Caddyfile"
  render_template "$REPO_ROOT/templates/server/deploy.sh.tpl" "$INSTALL_DIR/deploy.sh"
  render_template "$REPO_ROOT/templates/server/rollback.sh.tpl" "$INSTALL_DIR/rollback.sh"
  render_template "$REPO_ROOT/templates/server/status.sh.tpl" "$INSTALL_DIR/status.sh"
  render_template "$REPO_ROOT/templates/server/backup.sh.tpl" "$INSTALL_DIR/backup.sh"
  render_template "$REPO_ROOT/templates/server/restore-verify.sh.tpl" "$INSTALL_DIR/restore-verify.sh"
  render_template "$REPO_ROOT/templates/server/deploy-wrapper.sh.tpl" "/usr/local/sbin/shopware-deploy-$ENVIRONMENT"
  render_template "$REPO_ROOT/templates/server/ssh-gate.sh.tpl" "/usr/local/sbin/shopware-ssh-gate-$ENVIRONMENT"

  chown -R root:root "$INSTALL_DIR"
  chmod 600 "$INSTALL_DIR/.env.compose" "$INSTALL_DIR/.env.runtime" "$INSTALL_DIR/.env.init" "$INSTALL_DIR/.env.backup" "$INSTALL_DIR/compose.yaml" "$INSTALL_DIR/Caddyfile"
  chmod 700 "$INSTALL_DIR/deploy.sh" "$INSTALL_DIR/rollback.sh" "$INSTALL_DIR/status.sh" "$INSTALL_DIR/backup.sh" "$INSTALL_DIR/restore-verify.sh"
  chown root:root "/usr/local/sbin/shopware-deploy-$ENVIRONMENT" "/usr/local/sbin/shopware-ssh-gate-$ENVIRONMENT"
  chmod 755 "/usr/local/sbin/shopware-deploy-$ENVIRONMENT" "/usr/local/sbin/shopware-ssh-gate-$ENVIRONMENT"
  printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/shopware-deploy-%s *\n' "$DEPLOY_USER" "$ENVIRONMENT" > "/etc/sudoers.d/91-shopware-deploy-$ENVIRONMENT"
  chmod 440 "/etc/sudoers.d/91-shopware-deploy-$ENVIRONMENT"
  visudo -cf "/etc/sudoers.d/91-shopware-deploy-$ENVIRONMENT" >/dev/null
  ok "Runtime-Dateien und eingeschränkter Deployment-Einstieg geschrieben"
}

install_systemd_backup_timers() {
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] Backup- und Restore-Verifikationstimer installieren"; return 0; fi
  if [[ "$TEST_MODE" == 1 ]]; then ok "TEST_MODE: systemd Timer übersprungen"; return 0; fi
  render_template "$REPO_ROOT/templates/systemd/backup.service.tpl" "/etc/systemd/system/shopware-$ENVIRONMENT-backup.service"
  render_template "$REPO_ROOT/templates/systemd/backup.timer.tpl" "/etc/systemd/system/shopware-$ENVIRONMENT-backup.timer"
  render_template "$REPO_ROOT/templates/systemd/restore-verify.service.tpl" "/etc/systemd/system/shopware-$ENVIRONMENT-restore-verify.service"
  render_template "$REPO_ROOT/templates/systemd/restore-verify.timer.tpl" "/etc/systemd/system/shopware-$ENVIRONMENT-restore-verify.timer"
  systemctl daemon-reload
  ok "Backup- und Restore-Verifikationstimer installiert; Aktivierung erfolgt nach dem ersten gesunden Deployment"
}

write_server_summary() {
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] Nicht-sensible Server-Summary schreiben"; return 0; fi
  local summary_dir="/root/shopware-setup" summary public_ip
  mkdir -p "$summary_dir"
  summary="$summary_dir/${ENVIRONMENT}-server-summary.md"
  public_ip="unknown"
  if command_exists curl && [[ "$TEST_MODE" != 1 ]]; then public_ip="$(curl -fsS --max-time 5 https://api.ipify.org || true)"; fi
  cat > "$summary" <<EOFS
# Server Summary: $PROJECT_SLUG / $ENVIRONMENT

- Generated: $(date -Iseconds)
- Domain: https://$PRIMARY_DOMAIN
- Public IP detected: $public_ip
- Install dir: $INSTALL_DIR
- Admin user: $ADMIN_USER
- Restricted deploy user: $DEPLOY_USER
- SSH port: $SSH_PORT
- Backup timer: shopware-$ENVIRONMENT-backup.timer
- Restore verification timer: shopware-$ENVIRONMENT-restore-verify.timer

The deploy user has no Docker-group membership and accepts only the forced deployment command.
EOFS
  chmod 600 "$summary"
}

start_infra_containers() {
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] Gepinnte Datenbank-, Valkey- und RabbitMQ-Container starten"; return 0; fi
  if [[ "$TEST_MODE" == 1 ]]; then ok "TEST_MODE: Infrastrukturstart übersprungen"; return 0; fi
  (cd "$INSTALL_DIR" && docker compose --env-file .env.compose -f compose.yaml up -d --wait database redis rabbitmq)
}

setup_shopware_server() {
  local config_file="$1" expected="$2" marker in_progress project_dir deploy_key_options
  if [[ "${DRY_RUN:-0}" != 1 && "$config_file" == /root/shopware-setup/* ]]; then SERVER_SETUP_CONFIG_CLEANUP_FILE="$config_file"; fi
  trap cleanup_plaintext_setup_config EXIT
  EXPECTED_ENVIRONMENT="$expected"; export EXPECTED_ENVIRONMENT
  # Consumed by step() from logging.sh.
  if [[ "$DRY_RUN" == 1 ]]; then SHOPWARE_INFRA_TOTAL=3; else SHOPWARE_INFRA_TOTAL=14; fi
  export SHOPWARE_INFRA_TOTAL
  step "Konfiguration sicher laden"; assert_private_file "$config_file"; load_env_file "$config_file" "${SERVER_CONFIG_KEYS[@]}"; validate_server_config
  step "Fresh-VPS, Betriebssystem und Ressourcen prüfen"; require_root; check_ubuntu; check_server_resources; check_port_free 80; check_port_free 443
  project_dir="$INSTALL_BASE_DIR/$PROJECT_SLUG"
  marker="$INSTALL_DIR/.infrastructure-initialized"; in_progress="$INSTALL_DIR/.setup-in-progress"
  [[ ! -L "$INSTALL_BASE_DIR" && ! -L "$project_dir" && ! -L "$INSTALL_DIR" && ! -L "$marker" && ! -L "$in_progress" ]] || die "Symlink in kontrolliertem Installationspfad erkannt."
  [[ ! -e "$marker" ]] || die "Server ist bereits initialisiert; das One-shot-Setup wird nicht erneut ausgeführt."
  if [[ "$DRY_RUN" == 1 ]]; then
    step "Änderungsfreien Plan ausgeben"
    log "[DRY-RUN] Würde Fresh-VPS härten, gepinnte Infrastruktur schreiben und keine App deployen."
    ok "Server-Dry-run ohne Mutation abgeschlossen"
    return 0
  fi
  if [[ -e "$in_progress" ]]; then
    assert_private_file "$in_progress"
    [[ -f "$in_progress" && "$(<"$in_progress")" == "$PROJECT_SLUG/$ENVIRONMENT" ]] || die "Ungültiger oder fremder Setup-Zustand: $in_progress"
  elif [[ -d "$INSTALL_DIR" && -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "INSTALL_DIR enthält fremde Daten und wird nicht übernommen: $INSTALL_DIR"
  fi
  mkdir -p "$INSTALL_DIR"
  [[ "$(readlink -f "$INSTALL_DIR")" == "$INSTALL_DIR" ]] || die "INSTALL_DIR löst unerwartet auf."
  [[ "$(stat -c %u "$INSTALL_DIR")" == 0 ]] || die "INSTALL_DIR gehört nicht root: $INSTALL_DIR"
  printf '%s\n' "$PROJECT_SLUG/$ENVIRONMENT" > "$in_progress"; chmod 600 "$in_progress"
  step "System aktualisieren"; apt_install_base_packages
  step "Hostname und Zeitzone setzen"; set_system_basics "$PROJECT_SLUG-$ENVIRONMENT" "$TIMEZONE"
  step "Administrator und eingeschränkten Deploy-User anlegen"
  ensure_linux_user "$ADMIN_USER" "$ADMIN_PUBLIC_KEY" 1
  deploy_key_options="restrict,command=\"/usr/local/sbin/shopware-ssh-gate-$ENVIRONMENT\""
  ensure_linux_user "$DEPLOY_USER" "$GITHUB_ACTIONS_DEPLOY_PUBLIC_KEY" 0 "$deploy_key_options"
  step "Docker installieren"; install_docker_engine; add_user_to_docker_group "$ADMIN_USER"; check_docker_compose
  if id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx docker; then die "DEPLOY_USER darf nicht Mitglied der Docker-Gruppe sein."; fi
  step "Firewall sicher konfigurieren"; configure_firewall "$INITIAL_SSH_PORT"
  step "Runtime- und Deployment-Dateien schreiben"; write_runtime_files
  step "Sicherheitsdienste aktivieren"; enable_security_services
  step "Backup und Restore-Verifikation einrichten"; install_systemd_backup_timers
  step "Gepinnte Infrastruktur starten"; start_infra_containers
  step "Server Summary schreiben"; write_server_summary
  step "SSH härten und initialen Port schließen"; harden_ssh; close_initial_ssh_firewall_port "$INITIAL_SSH_PORT"
  step "Abschluss prüfen"
  [[ -f "$INSTALL_DIR/.env.runtime" && -f "$INSTALL_DIR/.env.backup" && -x "/usr/local/sbin/shopware-deploy-$ENVIRONMENT" ]] || die "Runtime-Dateien unvollständig."
  mv "$in_progress" "$marker"; chmod 600 "$marker"
  if [[ -f /var/run/reboot-required ]]; then warn "Ein kontrollierter Reboot ist vor dem ersten Deployment erforderlich."; fi
  ok "Server gehärtet und vorbereitet. Es wurde noch kein Shopware-App-Image gestartet."
}
