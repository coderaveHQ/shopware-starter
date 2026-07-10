#!/usr/bin/env bash
# Docker installation helpers.

install_docker_engine() {
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: Docker-Installation übersprungen"; return 0; fi
  if command_exists docker; then
    ok "Docker bereits vorhanden: $(docker --version)"
  else
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then run_shell 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc'; chmod a+r /etc/apt/keyrings/docker.asc; fi
    local codename arch
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-$(lsb_release -cs)}"; arch="$(dpkg --print-architecture)"
    cat > /etc/apt/sources.list.d/docker.list <<EOFD
# Docker official apt repository
deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable
EOFD
    run_cmd apt-get update
    run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ok "Docker Engine installiert"
  fi
  if command_exists systemctl; then run_cmd systemctl enable --now docker; fi
}

add_user_to_docker_group() {
  local username="$1"
  if [[ "$TEST_MODE" == "1" ]]; then ok "TEST_MODE: Docker-Gruppe für $username würde gesetzt"; return 0; fi
  getent group docker >/dev/null || groupadd docker
  usermod -aG docker "$username"
  ok "Benutzer $username zur docker-Gruppe hinzugefügt"
}

check_docker_compose() {
  if command_exists docker; then
    docker version >/dev/null 2>&1 && ok "Docker Daemon erreichbar" || warn "Docker-Befehl vorhanden, Daemon aber nicht erreichbar"
    docker compose version >/dev/null 2>&1 && ok "Docker Compose Plugin vorhanden" || die "Docker Compose Plugin fehlt"
  else
    [[ "$TEST_MODE" == "1" ]] && ok "TEST_MODE: Docker-Check übersprungen" || die "Docker fehlt"
  fi
}
