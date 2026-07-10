#!/usr/bin/env bash
# Ubuntu host setup helpers. All mutating helpers honor DRY_RUN.

apt_install_base_packages() {
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] System aktualisieren und Basispakete installieren"; return 0; fi
  if [[ "$TEST_MODE" == 1 ]]; then ok "TEST_MODE: apt-Installation übersprungen"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  run_cmd apt-get update
  run_cmd apt-get -y upgrade
  run_cmd apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban unattended-upgrades openssh-server git jq unzip rsync rclone python3 openssl cron logrotate awscli util-linux
}

set_system_basics() {
  local hostname_value="$1" timezone_value="$2"
  if [[ "$DRY_RUN" == 1 || "$TEST_MODE" == 1 ]]; then ok "PLAN: Hostname/Timezone $hostname_value / $timezone_value"; return 0; fi
  run_cmd hostnamectl set-hostname "$hostname_value"
  run_cmd timedatectl set-timezone "$timezone_value"
  ok "Hostname und Zeitzone gesetzt"
}

ensure_linux_user() {
  local username="$1" public_key="$2" sudo_enabled="${3:-0}" key_options="${4:-}"
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] Linux-User und autorisierten ED25519-Key anlegen: $username"; return 0; fi
  if id "$username" >/dev/null 2>&1; then ok "Benutzer existiert bereits: $username"; else useradd -m -s /bin/bash "$username"; ok "Benutzer angelegt: $username"; fi
  local home_dir authorized_line
  home_dir="$(getent passwd "$username" | cut -d: -f6)"
  [[ -n "$home_dir" && "$home_dir" == /home/* ]] || die "Unerwartetes Home-Verzeichnis für $username: $home_dir"
  mkdir -p "$home_dir/.ssh"; chmod 700 "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"; chmod 600 "$home_dir/.ssh/authorized_keys"
  authorized_line="$public_key"; [[ -n "$key_options" ]] && authorized_line="$key_options $public_key"
  if [[ -n "$key_options" ]]; then
    # A forced-command account must never retain an older unrestricted key.
    printf '%s\n' "$authorized_line" > "$home_dir/.ssh/authorized_keys"
  elif ! grep -qxF "$authorized_line" "$home_dir/.ssh/authorized_keys"; then
    printf '%s\n' "$authorized_line" >> "$home_dir/.ssh/authorized_keys"
  fi
  chown -R "$username:$username" "$home_dir/.ssh"
  passwd -l "$username" >/dev/null 2>&1 || true
  if [[ "$sudo_enabled" == 1 ]]; then
    usermod -aG sudo "$username"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$username" > "/etc/sudoers.d/90-$username"
    chmod 440 "/etc/sudoers.d/90-$username"
    visudo -cf "/etc/sudoers.d/90-$username" >/dev/null
  fi
  ok "Benutzer und Key eingerichtet: $username"
}

harden_ssh() {
  local ssh_port="${SSH_PORT:-22}"
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] SSH härten und Root/Forwarding deaktivieren"; return 0; fi
  if [[ "$TEST_MODE" == 1 ]]; then ok "TEST_MODE: SSH-Hardening übersprungen"; return 0; fi
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-shopware-infra.conf <<EOFSSH
Port $ssh_port
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $ADMIN_USER $DEPLOY_USER
EOFSSH
  chmod 600 /etc/ssh/sshd_config.d/99-shopware-infra.conf
  sshd -t
  if command_exists systemctl; then systemctl reload ssh || systemctl reload sshd; else service ssh reload; fi
  ok "SSH gehärtet: Root aus, nur Public Key, kein Forwarding"
}

configure_firewall() {
  local ssh_port="${SSH_PORT:-22}" initial_ssh_port="${1:-${SSH_PORT:-22}}" existing_rules
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] UFW ausschließlich für SSH, HTTP und HTTPS konfigurieren"; return 0; fi
  if [[ "$TEST_MODE" == 1 ]]; then ok "TEST_MODE: UFW-Konfiguration übersprungen"; return 0; fi
  existing_rules="$(ufw show added 2>/dev/null || true)"
  if printf '%s' "$existing_rules" | grep -q '^ufw '; then
    die "UFW enthält bereits Regeln. Das Fresh-VPS-Setup setzt keine bestehende Firewall zurück."
  fi
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$ssh_port/tcp"
  if [[ "$initial_ssh_port" != "$ssh_port" ]]; then ufw allow "$initial_ssh_port/tcp"; fi
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  ufw status verbose
  ok "Firewall aktiv"
}

close_initial_ssh_firewall_port() {
  local initial_ssh_port="$1" ssh_port="${SSH_PORT:-22}"
  [[ "$initial_ssh_port" != "$ssh_port" ]] || return 0
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] Initialen SSH-Port $initial_ssh_port nach erfolgreichem Reload schließen"; return 0; fi
  if [[ "$TEST_MODE" == 1 ]]; then ok "TEST_MODE: initialer SSH-Port würde geschlossen"; return 0; fi
  ufw --force delete allow "$initial_ssh_port/tcp"
  ok "Initialer SSH-Port geschlossen: $initial_ssh_port"
}

enable_security_services() {
  if [[ "$DRY_RUN" == 1 ]]; then log "[DRY-RUN] fail2ban und unattended-upgrades aktivieren"; return 0; fi
  if [[ "$TEST_MODE" == 1 ]]; then ok "TEST_MODE: Sicherheitsdienste übersprungen"; return 0; fi
  cat > /etc/fail2ban/jail.d/shopware-sshd.conf <<EOFF2B
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
bantime = 1h
findtime = 10m
EOFF2B
  systemctl enable --now fail2ban cron
  dpkg-reconfigure -f noninteractive unattended-upgrades
  systemctl restart fail2ban
  ok "fail2ban und unattended-upgrades aktiviert"
}
