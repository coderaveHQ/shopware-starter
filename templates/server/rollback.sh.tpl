#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR={{INSTALL_DIR|shell}}
EXPECTED_IMAGE_PREFIX={{GHCR_IMAGE|shell}}:{{ENVIRONMENT|shell}}-
IMAGE="${1:-}"
ACK="${2:-}"
[[ "$IMAGE" == "$EXPECTED_IMAGE_PREFIX"* ]] || { echo "Invalid rollback image" >&2; exit 1; }
IMAGE_DIGEST="${IMAGE#"$EXPECTED_IMAGE_PREFIX"}"
[[ "$IMAGE_DIGEST" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid rollback image" >&2; exit 1; }
[[ "$ACK" == acknowledge-database-compatibility ]] || { echo "Rollback requires explicit database-compatibility acknowledgement" >&2; exit 1; }

cd "$INSTALL_DIR"
COMPOSE=(docker compose --env-file .env.compose -f compose.yaml)
python3 - .env.compose "$IMAGE" <<'PY'
import pathlib, sys
path, image = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = [f'SHOPWARE_IMAGE="{image}"' if line.startswith('SHOPWARE_IMAGE=') else line for line in path.read_text().splitlines()]
tmp = path.with_suffix(path.suffix + '.tmp')
tmp.write_text('\n'.join(lines) + '\n'); tmp.chmod(0o640); tmp.replace(path)
PY
"${COMPOSE[@]}" pull app worker scheduler
# Deliberately bypass init: database migrations are never run backwards.
"${COMPOSE[@]}" up -d --no-deps --wait app worker scheduler
"${COMPOSE[@]}" up -d --wait varnish caddy
curl -fsSIL --retry 10 --retry-all-errors --retry-delay 3 --max-time 20 https://{{PRIMARY_DOMAIN}}/ >/dev/null
echo "Code rollback completed. Verify data compatibility immediately."
