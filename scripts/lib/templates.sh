#!/usr/bin/env bash
# Template rendering: replaces {{VAR_NAME}} placeholders with environment values.

render_template() {
  local src="$1" dest="$2"
  assert_file_exists "$src"
  mkdir -p "$(dirname "$dest")"
  python3 - "$src" "$dest" <<'PYTEMPLATE'
import os, re, sys
src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
pattern = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
missing = set()
def repl(match):
    key = match.group(1)
    if key not in os.environ:
        missing.add(key)
        return match.group(0)
    return os.environ[key]
rendered = pattern.sub(repl, text)
if missing:
    sys.stderr.write("ERROR: Missing template variables: " + ", ".join(sorted(missing)) + "\n")
    sys.exit(1)
open(dest, 'w', encoding='utf-8').write(rendered)
PYTEMPLATE
  ok "Template gerendert: $src -> $dest"
}
