#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALL_DIR={{INSTALL_DIR|shell}}
EXPECTED_IMAGE_PREFIX={{GHCR_IMAGE|shell}}:{{ENVIRONMENT|shell}}-
ENVIRONMENT={{ENVIRONMENT|shell}}
PRIMARY_DOMAIN={{PRIMARY_DOMAIN|shell}}
IMAGE="${1:-}"
[[ "$IMAGE" == "$EXPECTED_IMAGE_PREFIX"* ]] || { echo "Invalid immutable deployment image: $IMAGE" >&2; exit 1; }
IMAGE_DIGEST="${IMAGE#"$EXPECTED_IMAGE_PREFIX"}"
[[ "$IMAGE_DIGEST" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid immutable deployment image: $IMAGE" >&2; exit 1; }

cd "$INSTALL_DIR"
COMPOSE=(docker compose --env-file .env.compose -f compose.yaml)
CURRENT_IMAGE="$(python3 - .env.compose <<'PY'
import pathlib, shlex, sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('SHOPWARE_IMAGE='):
        print(shlex.split(line.split('=', 1)[1])[0])
        break
PY
)"
MIGRATION_COMPLETED=0

set_shopware_image() {
  python3 - .env.compose "$1" <<'PY'
import pathlib, sys
path, image = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = path.read_text().splitlines()
found = False
for index, line in enumerate(lines):
    if line.startswith('SHOPWARE_IMAGE='):
        lines[index] = f'SHOPWARE_IMAGE="{image}"'
        found = True
if not found:
    raise SystemExit('SHOPWARE_IMAGE missing')
tmp = path.with_suffix(path.suffix + '.tmp')
tmp.write_text('\n'.join(lines) + '\n')
tmp.chmod(0o640)
tmp.replace(path)
PY
}

on_error() {
  local code=$?
  if [[ "$MIGRATION_COMPLETED" == 0 && -n "$CURRENT_IMAGE" ]]; then set_shopware_image "$CURRENT_IMAGE" || true; fi
  echo "Deployment failed. Database migrations are never rolled back automatically." >&2
  exit "$code"
}
trap on_error ERR

echo "Deploying immutable image: $IMAGE"
"${COMPOSE[@]}" up -d --wait database redis rabbitmq

TABLE_COUNT="$("${COMPOSE[@]}" exec -T -e MYSQL_PWD="$(python3 - .env.compose <<'PY'
import pathlib, shlex
for line in pathlib.Path('.env.compose').read_text().splitlines():
    if line.startswith('DB_PASSWORD='):
        print(shlex.split(line.split('=', 1)[1])[0]); break
PY
)" database mariadb -u{{DB_USER|shell}} -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{{DB_NAME}}'" 2>/dev/null || printf 0)"
if [[ "$TABLE_COUNT" =~ ^[0-9]+$ && "$TABLE_COUNT" -gt 0 ]]; then
  echo "Creating mandatory encrypted offsite backup before deployment"
  systemctl start --wait "shopware-$ENVIRONMENT-backup.service"
fi

mkdir -p deployment-history
printf '%s\t%s\n' "$(date -Iseconds)" "$CURRENT_IMAGE" >> deployment-history/images.log
chmod 700 deployment-history
chmod 600 deployment-history/images.log

set_shopware_image "$IMAGE"
"${COMPOSE[@]}" pull init app worker scheduler
"${COMPOSE[@]}" up --force-recreate --abort-on-container-exit --exit-code-from init init
MIGRATION_COMPLETED=1
"${COMPOSE[@]}" up -d --wait app worker scheduler varnish caddy --remove-orphans

for service in app worker scheduler varnish caddy; do
  "${COMPOSE[@]}" ps --services --status running | grep -qx "$service" || { echo "Service not running: $service" >&2; exit 1; }
done
curl -fsSIL --retry 10 --retry-all-errors --retry-delay 3 --max-time 20 "https://$PRIMARY_DOMAIN/" >/dev/null
curl -fsSIL --retry 10 --retry-all-errors --retry-delay 3 --max-time 20 "https://$PRIMARY_DOMAIN/admin" >/dev/null
"${COMPOSE[@]}" exec -T app php bin/console --version
systemctl enable --now "shopware-$ENVIRONMENT-backup.timer" "shopware-$ENVIRONMENT-restore-verify.timer"

# The initial administrator password is only needed for the first installation.
python3 - .env.init <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = ['INSTALL_ADMIN_PASSWORD=""' if line.startswith('INSTALL_ADMIN_PASSWORD=') else line for line in path.read_text().splitlines()]
tmp = path.with_suffix(path.suffix + '.tmp')
tmp.write_text('\n'.join(lines) + '\n')
tmp.chmod(0o640)
tmp.replace(path)
PY

trap - ERR
echo "Deployment healthy for $ENVIRONMENT at $(date -Iseconds)"
