#!/usr/bin/env bash
# Template rendering with explicit raw, dotenv, shell, YAML-scalar and Caddy-address filters.

render_template() {
  local src="$1" dest="$2"
  assert_file_exists "$src"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "[DRY-RUN] Template $src -> $dest rendern"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if ! python3 - "$src" "$dest" <<'PYTEMPLATE'
import json
import os
import re
import shlex
import sys

src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
pattern = re.compile(r"\{\{([A-Z0-9_]+)(?:\|(dotenv|shell|yaml|caddy))?\}\}")
missing = set()

def dotenv_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
    return f'"{escaped}"'

def caddy_addresses(value: str) -> str:
    domains = value.split(',')
    if not 1 <= len(domains) <= 20 or len(set(domains)) != len(domains):
        raise SystemExit("Caddy domain list must contain 1-20 unique domains")
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    for domain in domains:
        if len(domain) > 253 or domain.endswith('.') or '.' not in domain:
            raise SystemExit(f"Invalid Caddy domain: {domain}")
        if any(not re.fullmatch(label, part) for part in domain.split('.')):
            raise SystemExit(f"Invalid Caddy domain: {domain}")
    return ", ".join(domains)

def repl(match):
    key, output_filter = match.group(1), match.group(2)
    if key not in os.environ:
        missing.add(key)
        return match.group(0)
    value = os.environ[key]
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise SystemExit(f"Control characters are forbidden in template variable {key}")
    if output_filter == "dotenv":
        return dotenv_quote(value)
    if output_filter == "shell":
        return shlex.quote(value)
    if output_filter == "yaml":
        return json.dumps(value, ensure_ascii=False)
    if output_filter == "caddy":
        return caddy_addresses(value)
    return value

rendered = pattern.sub(repl, text)
if missing:
    sys.stderr.write("ERROR: Missing template variables: " + ", ".join(sorted(missing)) + "\n")
    sys.exit(1)
with open(dest, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(rendered)
PYTEMPLATE
  then
    rm -f -- "$dest"
    die "Template konnte nicht sicher gerendert werden: $src"
  fi
  ok "Template gerendert: $src -> $dest"
}
