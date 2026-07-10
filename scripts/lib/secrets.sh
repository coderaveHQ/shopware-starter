#!/usr/bin/env bash
# Secret and SSH key generation helpers.

generate_password() {
  local length="${1:-48}"
  python3 - "$length" <<'PYSECRET'
import secrets, string, sys
length = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(length)))
PYSECRET
}

generate_hex_secret() { local bytes="${1:-32}"; openssl rand -hex "$bytes"; }

ensure_ssh_key() {
  local key_path="$1" comment="$2" force="${3:-0}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then log "[DRY-RUN] ED25519-Key erzeugen: $key_path"; return 0; fi
  mkdir -p "$(dirname "$key_path")"
  chmod 700 "$(dirname "$key_path")"
  if [[ -f "$key_path" && "$force" != "1" ]]; then ok "SSH-Key existiert bereits: $key_path"; return 0; fi
  rm -f "$key_path" "$key_path.pub"
  run_cmd ssh-keygen -t ed25519 -a 100 -f "$key_path" -C "$comment" -N ""
  chmod 600 "$key_path"; chmod 644 "$key_path.pub"
  ok "SSH-Key erzeugt: $key_path"
}

file_sha256() { if command_exists sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
