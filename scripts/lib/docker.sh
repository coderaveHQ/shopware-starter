#!/usr/bin/env bash
# Docker installation helpers.

install_docker_engine() {
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: Docker-Installation übersprungen"; return 0; fi
  if command_exists docker \
    && dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed' \
    && dpkg-query -W -f='${Status}' docker-compose-plugin 2>/dev/null | grep -q 'install ok installed'; then
    ok "Docker CE bereits vorhanden: $(docker --version)"
  else
    local package conflicting_packages=() codename arch
    for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
      if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
        conflicting_packages+=("$package")
      fi
    done
    if [[ "${#conflicting_packages[@]}" -gt 0 ]]; then
      warn "Entferne mit Docker CE kollidierende Pakete: ${conflicting_packages[*]}"
      run_cmd apt-get remove -y "${conflicting_packages[@]}"
    fi
    run_cmd install -m 0755 -d /etc/apt/keyrings
    run_cmd curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    run_cmd chmod a+r /etc/apt/keyrings/docker.asc
    codename="$(get_os_release_value /etc/os-release UBUNTU_CODENAME 2>/dev/null || get_os_release_value /etc/os-release VERSION_CODENAME)"; arch="$(dpkg --print-architecture)"
    [[ -n "$codename" ]] || die "Ubuntu-Codename konnte nicht aus /etc/os-release gelesen werden."
    if [[ "$DRY_RUN" == "1" ]]; then
      log "[DRY-RUN] Docker APT-Quelle für $codename/$arch schreiben"
    else
      rm -f /etc/apt/sources.list.d/docker.list
      cat > /etc/apt/sources.list.d/docker.sources <<EOFD
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOFD
    fi
    run_cmd apt-get update
    run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ok "Docker Engine installiert"
  fi
  if command_exists systemctl; then run_cmd systemctl enable --now docker; fi
}

add_user_to_docker_group() {
  local username="$1"
  if [[ "$DRY_RUN" == "1" ]]; then log "[DRY-RUN] Docker-Gruppe für Administrator $username"; return 0; fi
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: Docker-Gruppe für $username würde gesetzt"; return 0; fi
  getent group docker >/dev/null || groupadd docker
  usermod -aG docker "$username"
  ok "Benutzer $username zur docker-Gruppe hinzugefügt"
}

check_docker_compose() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then ok "DRY-RUN: Docker-Check übersprungen"; return 0; fi
  if command_exists docker; then
    if docker version >/dev/null 2>&1; then ok "Docker Daemon erreichbar"; else warn "Docker-Befehl vorhanden, Daemon aber nicht erreichbar"; fi
    if docker compose version >/dev/null 2>&1; then ok "Docker Compose Plugin vorhanden"; else die "Docker Compose Plugin fehlt"; fi
  else
    if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: Docker-Check übersprungen"; else die "Docker fehlt"; fi
  fi
}
