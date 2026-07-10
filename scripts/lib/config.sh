#!/usr/bin/env bash
# Config loading helpers. Config files are shell-style KEY=value files.

load_env_file() {
  local file="$1"
  assert_file_exists "$file"
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
  ok "Konfiguration geladen: $file"
}

write_kv() { local file="$1" key="$2" value="$3"; printf '%s=%q\n' "$key" "$value" >> "$file"; }

normalize_slug() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  printf '%s' "$value"
}

bool_enabled() { case "${1:-}" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac; }
