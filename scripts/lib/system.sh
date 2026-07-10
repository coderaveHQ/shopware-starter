#!/usr/bin/env bash
# Ubuntu host setup helpers.

apt_install_base_packages() {
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: apt-Installation übersprungen"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  run_cmd apt-get update
  run_cmd apt-get -y upgrade
  run_cmd apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban unattended-upgrades openssh-server git jq unzip rsync python3 openssl cron logrotate
}

set_system_basics() {
  local hostname_value="$1" timezone_value="$2"
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: Hostname/Timezone würden gesetzt: $hostname_value / $timezone_value"; return 0; fi
  run_cmd hostnamectl set-hostname "$hostname_value"
  run_cmd timedatectl set-timezone "$timezone_value"
  ok "Hostname und Zeitzone gesetzt"
}

ensure_linux_user() {
  local username="$1" public_key="$2" sudo_enabled="${3:-0}"
  if id "$username" >/dev/null 2>&1; then ok "Benutzer existiert bereits: $username"; else run_cmd useradd -m -s /bin/bash "$username"; ok "Benutzer angelegt: $username"; fi
  local home_dir; home_dir="$(getent passwd "$username" | cut -d: -f6)"
  mkdir -p "$home_dir/.ssh"; chmod 700 "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"; chmod 600 "$home_dir/.ssh/authorized_keys"
  if [[ -n "$public_key" ]] && ! grep -qxF "$public_key" "$home_dir/.ssh/authorized_keys"; then printf '%s\n' "$public_key" >> "$home_dir/.ssh/authorized_keys"; ok "SSH Public Key für $username hinterlegt"; fi
  chown -R "$username:$username" "$home_dir/.ssh"
  if [[ "$sudo_enabled" == "1" ]]; then usermod -aG sudo "$username"; printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$username" > "/etc/sudoers.d/90-$username"; chmod 440 "/etc/sudoers.d/90-$username"; ok "sudo-Rechte für $username eingerichtet"; fi
}

harden_ssh() {
  local ssh_port="${SSH_PORT:-22}" disable_root="${DISABLE_ROOT_SSH:-0}"
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: SSH-Hardening übersprungen"; return 0; fi
  mkdir -p /etc/ssh/sshd_config.d
  local permit_root="prohibit-password"; [[ "$disable_root" == "1" ]] && permit_root="no"
  cat > /etc/ssh/sshd_config.d/99-shopware-infra.conf <<EOFSSH
Port $ssh_port
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin $permit_root
X11Forwarding no
AllowTcpForwarding yes
ClientAliveInterval 300
ClientAliveCountMax 2
EOFSSH
  sshd -t
  if command_exists systemctl; then run_cmd systemctl reload ssh || run_cmd systemctl reload sshd; else run_cmd service ssh reload; fi
  ok "SSH gehärtet: Passwort-Login aus, Root=$permit_root"
}

configure_firewall() {
  local ssh_port="${SSH_PORT:-22}"
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: UFW-Konfiguration übersprungen"; return 0; fi
  run_cmd ufw --force reset
  run_cmd ufw default deny incoming
  run_cmd ufw default allow outgoing
  run_cmd ufw allow "$ssh_port/tcp"
  run_cmd ufw allow 80/tcp
  run_cmd ufw allow 443/tcp
  run_cmd ufw --force enable
  run_cmd ufw status verbose
  ok "Firewall aktiv"
}

enable_security_services() {
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: fail2ban/unattended-upgrades übersprungen"; return 0; fi
  if command_exists systemctl; then run_cmd systemctl enable --now fail2ban; run_cmd systemctl enable --now cron; fi
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
  ok "Basis-Sicherheitsdienste aktiviert"
}
