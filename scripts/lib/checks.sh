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
assert_private_file() {
  local file="$1"
  assert_file_exists "$file"
  [[ ! -L "$file" ]] || die "Private Datei darf kein Symlink sein: $file"
  if ! python3 - "$file" <<'PYPRIVATE' >/dev/null
import os, stat, sys
info = os.stat(sys.argv[1], follow_symlinks=False)
mode = stat.S_IMODE(info.st_mode)
if info.st_uid != os.geteuid() or mode & 0o077:
    raise SystemExit(1)
PYPRIVATE
  then
    die "Private Datei gehört nicht dem aktuellen Benutzer oder ist für Gruppe/Andere zugänglich: $file"
  fi
}
assert_equal() { [[ "$1" == "$2" ]] || die "$3"; }
assert_distinct() { [[ "$1" != "$2" ]] || die "$3"; }
assert_no_placeholder() {
  local name="$1" value="${!1:-}" lower
  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in *change_me*|*change-me*|*example.*|*.invalid*|your-*|203.0.113.*|192.0.2.*|198.51.100.*) die "$name enthält noch einen Platzhalter." ;; esac
}

is_valid_slug() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
is_valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_valid_github_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; }
is_valid_email() { [[ "$1" =~ ^[A-Za-z0-9.!#$%\&\'*+/=?^_\`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]]; }
is_valid_uint_range() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge "$2" && "$1" -le "$3" ]]; }
is_valid_bool() { case "$1" in true|false|0|1) return 0 ;; *) return 1 ;; esac; }
is_valid_region() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,31}$ ]]; }
is_valid_locale() { [[ "$1" =~ ^[a-z]{2}-[A-Z]{2}$ ]]; }
is_valid_currency() { [[ "$1" =~ ^[A-Z]{3}$ ]]; }
is_valid_alnum_secret() { [[ "$1" =~ ^[A-Za-z0-9]{32,128}$ ]]; }
is_valid_sha256_fingerprint() { [[ "$1" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; }
is_valid_pinned_image() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9./:_-]*@sha256:[a-f0-9]{64}$ ]]; }
is_valid_ssh_public_key() { [[ "$1" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; }
is_valid_bucket() { [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] && [[ "$1" != *".."* ]]; }
is_valid_install_base() { [[ "$1" == "/opt/shopware" ]]; }
is_valid_install_dir() { [[ "$1" =~ ^/opt/shopware/[a-z0-9][a-z0-9-]*/(staging|production)$ ]]; }
is_safe_env_value() { [[ "$1" =~ ^[A-Za-z0-9._~!@#%+=:,/\?-]*$ ]]; }
is_valid_external_secret() { [[ "${#1}" -ge 8 ]] && is_safe_env_value "$1"; }

is_valid_timezone() {
  python3 - "$1" <<'PYTIMEZONE' >/dev/null
import pathlib, re, sys
value = sys.argv[1]
if not re.fullmatch(r'[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+-]+)+', value) or '..' in value.split('/'):
    raise SystemExit(1)
root = pathlib.Path('/usr/share/zoneinfo').resolve()
candidate = (root / value).resolve()
try:
    candidate.relative_to(root)
except ValueError:
    raise SystemExit(1)
if not candidate.is_file():
    raise SystemExit(1)
PYTIMEZONE
}

is_valid_domain() {
  python3 - "$1" <<'PYDOMAIN' >/dev/null
import re, sys
value = sys.argv[1]
if len(value) > 253 or value.endswith('.') or '.' not in value:
    raise SystemExit(1)
for label in value.split('.'):
    if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label):
        raise SystemExit(1)
PYDOMAIN
}

is_valid_domain_list() {
  python3 - "$1" <<'PYDOMAINLIST' >/dev/null
import re, sys
value = sys.argv[1]
domains = value.split(',')
if not 1 <= len(domains) <= 20 or len(set(domains)) != len(domains):
    raise SystemExit(1)
for domain in domains:
    if len(domain) > 253 or domain.endswith('.') or '.' not in domain:
        raise SystemExit(1)
    for label in domain.split('.'):
        if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label):
            raise SystemExit(1)
PYDOMAINLIST
}

domain_list_contains() {
  local list="$1" wanted="$2" domain
  local -a domains
  IFS=',' read -r -a domains <<< "$list"
  for domain in "${domains[@]}"; do [[ "$domain" == "$wanted" ]] && return 0; done
  return 1
}

is_valid_host() {
  python3 - "$1" <<'PYHOST' >/dev/null
import ipaddress, re, sys
value = sys.argv[1]
try:
    ipaddress.ip_address(value)
except ValueError:
    if len(value) > 253 or value.endswith('.'):
        raise SystemExit(1)
    for label in value.split('.'):
        if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label):
            raise SystemExit(1)
PYHOST
}

is_valid_https_url() {
  python3 - "$1" <<'PYURL' >/dev/null
import sys
from urllib.parse import urlparse
parsed = urlparse(sys.argv[1])
if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
    raise SystemExit(1)
PYURL
}

is_valid_https_endpoint() {
  python3 - "$1" <<'PYENDPOINT' >/dev/null
import sys
from urllib.parse import urlparse
parsed = urlparse(sys.argv[1])
if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
        or parsed.query or parsed.fragment or parsed.path not in ('', '/')):
    raise SystemExit(1)
PYENDPOINT
}

get_os_release_value() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PYOS'
import pathlib, re, sys
path, wanted = pathlib.Path(sys.argv[1]), sys.argv[2]
for line in path.read_text(encoding='utf-8').splitlines():
    match = re.fullmatch(r'([A-Z_]+)=(.*)', line)
    if not match or match.group(1) != wanted:
        continue
    value = match.group(2).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    print(value)
    raise SystemExit(0)
raise SystemExit(1)
PYOS
}

check_ubuntu() {
  local os_release_file="${1:-/etc/os-release}" architecture_bits os_id version_id pretty_name
  assert_file_exists "$os_release_file"
  os_id="$(get_os_release_value "$os_release_file" ID)"
  version_id="$(get_os_release_value "$os_release_file" VERSION_ID)"
  pretty_name="$(get_os_release_value "$os_release_file" PRETTY_NAME 2>/dev/null || printf unknown)"
  [[ "$os_id" == "ubuntu" ]] || die "Dieses Skript ist für Ubuntu gedacht. Erkannt: $pretty_name"
  case "$version_id" in 24.04|26.04) ;; *) die "Nicht unterstützte Ubuntu-Version: $version_id. Unterstützt werden 24.04 LTS und 26.04 LTS." ;; esac
  architecture_bits="$(getconf LONG_BIT 2>/dev/null || true)"
  [[ "$architecture_bits" == "64" ]] || die "Shopware benötigt ein 64-Bit-Linux. Erkannt: ${architecture_bits:-unknown}-Bit."
  ok "Unterstütztes 64-Bit-Ubuntu erkannt: $pretty_name"
}

check_server_resources() {
  local memory_kb disk_kb cpu_count disk_path="/"
  local minimum_memory_kb=$((8 * 1024 * 1024)) minimum_disk_kb=$((10 * 1024 * 1024))
  if [[ -d /opt ]]; then disk_path=/opt; fi

  if [[ "${TEST_MODE:-0}" == 1 ]]; then
    if [[ -z "${SHOPWARE_INFRA_TEST_MEMORY_KB:-}" || -z "${SHOPWARE_INFRA_TEST_DISK_KB:-}" || -z "${SHOPWARE_INFRA_TEST_CPU_COUNT:-}" ]]; then
      ok "TEST_MODE: Hardware-Ressourcenprüfung übersprungen"
      return 0
    fi
    memory_kb="$SHOPWARE_INFRA_TEST_MEMORY_KB"
    disk_kb="$SHOPWARE_INFRA_TEST_DISK_KB"
    cpu_count="$SHOPWARE_INFRA_TEST_CPU_COUNT"
  else
    memory_kb="$(awk '$1=="MemTotal:" {print $2}' /proc/meminfo)"
    disk_kb="$(df -Pk "$disk_path" | awk 'NR==2 {print $4}')"
    cpu_count="$(getconf _NPROCESSORS_ONLN)"
  fi

  [[ "$memory_kb" =~ ^[0-9]+$ && "$disk_kb" =~ ^[0-9]+$ && "$cpu_count" =~ ^[0-9]+$ ]] || die "Server-Ressourcen konnten nicht zuverlässig ermittelt werden."
  [[ "$memory_kb" -ge "$minimum_memory_kb" ]] || die "Shopware benötigt mindestens 8 GiB RAM; erkannt: $((memory_kb / 1024)) MiB."
  [[ "$disk_kb" -ge "$minimum_disk_kb" ]] || die "Shopware benötigt vor dem Setup mindestens 10 GiB freien Speicher; erkannt: $((disk_kb / 1024)) MiB auf $disk_path."
  if [[ "$cpu_count" -lt 4 ]]; then warn "Shopware empfiehlt mindestens vier CPU-Kerne; erkannt: $cpu_count."; fi
  ok "Server-Ressourcen ausreichend: $((memory_kb / 1024)) MiB RAM, $((disk_kb / 1024)) MiB frei, $cpu_count CPU-Kerne"
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
