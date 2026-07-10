#!/usr/bin/env bash
# Shared validation helpers.

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_command() {
  local cmd="$1"
  command_exists "$cmd" || die "Benötigter Befehl fehlt: $cmd"
  ok "Befehl vorhanden: $cmd ($(command -v "$cmd"))"
}

require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Dieses Skript muss als root ausgeführt werden."; }
require_not_root() { [[ "${EUID:-$(id -u)}" -ne 0 ]] || die "Dieses Skript soll lokal als normaler Benutzer laufen, nicht als root."; }

assert_not_empty() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" ]] || die "Pflichtvariable fehlt oder ist leer: $name"
}

assert_file_exists() { [[ -f "$1" ]] || die "Datei fehlt: $1"; }
assert_dir_exists() { [[ -d "$1" ]] || die "Ordner fehlt: $1"; }
is_valid_domainish() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
is_valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

check_ubuntu() {
  local os_release_file="${1:-/etc/os-release}" architecture_bits
  assert_file_exists "$os_release_file"
  # shellcheck disable=SC1091
  . "$os_release_file"
  [[ "${ID:-}" == "ubuntu" ]] || die "Dieses Skript ist für Ubuntu gedacht. Erkannt: ${PRETTY_NAME:-unknown}"
  case "${VERSION_ID:-}" in
    24.04|26.04) ;;
    *) die "Nicht unterstützte Ubuntu-Version: ${VERSION_ID:-unknown}. Unterstützt werden 24.04 LTS und 26.04 LTS." ;;
  esac
  architecture_bits="$(getconf LONG_BIT 2>/dev/null || true)"
  [[ "$architecture_bits" == "64" ]] || die "Shopware benötigt ein 64-Bit-Linux. Erkannt: ${architecture_bits:-unknown}-Bit."
  ok "Unterstütztes 64-Bit-Ubuntu erkannt: ${PRETTY_NAME:-unknown}"
}

check_port_free() {
  local port="$1"
  if command_exists ss && ss -ltn "sport = :$port" | grep -q ":$port"; then
    ss -ltnp "sport = :$port" || true
    die "Port $port ist bereits belegt."
  fi
  ok "Port $port ist frei"
}

check_url_optional() {
  local url="$1"
  if command_exists curl; then
    if curl -fsSIL --max-time 10 "$url" >/dev/null 2>&1; then ok "URL erreichbar: $url"; else warn "URL noch nicht erreichbar: $url"; fi
  else
    warn "curl fehlt, URL-Check übersprungen: $url"
  fi
}
