#!/usr/bin/env bash
# One-file password-manager/vault output helpers.

vault_init() {
  local file="$1"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then log "[DRY-RUN] Vault anlegen: $file"; return 0; fi
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<EOFV
# Customer Infrastructure Vault

Created: $(date -Iseconds)

> Diese Datei enthält sensible Zugangsdaten, private SSH-Keys, Pfade und GitHub-Secret-Namen. Nicht committen. Nach dem Import in den Passwort-Manager sicher löschen oder verschlüsselt archivieren.

EOFV
  chmod 600 "$file"
  ok "Vault-Datei angelegt: $file"
}

vault_section() {
  local file="$1" title="$2"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  {
    printf '\n---\n\n'
    printf '## %s\n\n' "$title"
    # Backticks are intentional Markdown.
    # shellcheck disable=SC2016
    printf 'Zeitpunkt: `%s`\n\n' "$(date -Iseconds)"
  } >> "$file"
}

# Backticks are intentional Markdown.
# shellcheck disable=SC2016
vault_kv() { local file="$1" key="$2" value="$3"; [[ "${DRY_RUN:-0}" == "1" ]] && return 0; printf -- '- `%s`: `%s`\n' "$key" "$value" >> "$file"; }
# Code fences are intentional Markdown.
# shellcheck disable=SC2016
vault_block() { local file="$1" title="$2" value="$3"; [[ "${DRY_RUN:-0}" == "1" ]] && return 0; { printf '\n### %s\n\n' "$title"; printf '```text\n%s\n```\n' "$value"; } >> "$file"; }
vault_append_file() { local vault="$1" title="$2" src="$3"; [[ "${DRY_RUN:-0}" == "1" || ! -f "$src" ]] && return 0; vault_section "$vault" "$title"; cat "$src" >> "$vault"; printf '\n' >> "$vault"; }
