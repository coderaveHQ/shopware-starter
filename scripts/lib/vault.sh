#!/usr/bin/env bash
# One-file password-manager/vault output helpers.

vault_init() {
  local file="$1"
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
  {
    printf '\n---\n\n'
    printf '## %s\n\n' "$title"
    printf 'Zeitpunkt: `%s`\n\n' "$(date -Iseconds)"
  } >> "$file"
}

vault_kv() { local file="$1" key="$2" value="$3"; printf -- '- `%s`: `%s`\n' "$key" "$value" >> "$file"; }
vault_block() { local file="$1" title="$2" value="$3"; { printf '\n### %s\n\n' "$title"; printf '```text\n%s\n```\n' "$value"; } >> "$file"; }
vault_append_file() { local vault="$1" title="$2" src="$3"; [[ -f "$src" ]] || return 0; vault_section "$vault" "$title"; cat "$src" >> "$vault"; printf '\n' >> "$vault"; }
