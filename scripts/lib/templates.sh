#!/usr/bin/env bash
# Template rendering with explicit raw, dotenv, shell and YAML-scalar filters.

render_template() {
  local src="$1" dest="$2"
  assert_file_exists "$src"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "[DRY-RUN] Template $src -> $dest rendern"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  python3 - "$src" "$dest" <<'PYTEMPLATE'
import json
import os
import re
import shlex
import sys

src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
pattern = re.compile(r"\{\{([A-Z0-9_]+)(?:\|(dotenv|shell|yaml))?\}\}")
missing = set()

def dotenv_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
    return f'"{escaped}"'

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
    return value

rendered = pattern.sub(repl, text)
if missing:
    sys.stderr.write("ERROR: Missing template variables: " + ", ".join(sorted(missing)) + "\n")
    sys.exit(1)
with open(dest, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(rendered)
PYTEMPLATE
  ok "Template gerendert: $src -> $dest"
}
