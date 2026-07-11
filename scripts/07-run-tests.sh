#!/usr/bin/env bash
# Safe local checks. Docker and remote checks are opt-in only.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
MODE="static"; TESTINFRA_SCOPE="full"; TESTINFRA_HOST=""; TESTINFRA_SSH_CONFIG=""

usage() { cat <<USAGE
Usage: bash scripts/07-run-tests.sh [--syntax-only|--bats|--ci-static|--docker|--testinfra-predeploy|--testinfra] [--host ssh://user@host] [--ssh-config path]

Default and --ci-static never build or start containers. --docker is explicit.
USAGE
}

while [[ $# -gt 0 ]]; do case "$1" in
  --syntax-only) MODE=syntax; shift ;;
  --bats) MODE=bats; shift ;;
  --ci-static) MODE=ci-static; shift ;;
  --docker) MODE=docker; shift ;;
  --testinfra-predeploy) MODE=testinfra; TESTINFRA_SCOPE=predeploy; shift ;;
  --testinfra) MODE=testinfra; shift ;;
  --host) [[ $# -ge 2 ]] || die "--host benötigt einen Wert"; TESTINFRA_HOST="$2"; shift 2 ;;
  --ssh-config) [[ $# -ge 2 ]] || die "--ssh-config benötigt einen Wert"; TESTINFRA_SSH_CONFIG="$2"; shift 2 ;;
  -h|--help) usage; exit 0 ;;
  *) die "Unbekanntes Argument: $1" ;;
esac; done

syntax_tests() {
  step "Bash-Syntax prüfen"
  local file
  while IFS= read -r -d '' file; do bash -n "$file"; done < <(find "$REPO_ROOT/scripts" -type f -name '*.sh' -print0 | sort -z)
  python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pattern = re.compile(r"(?<!\$)\{\{([^}]+)\}\}")
for path in sorted((root / 'templates').rglob('*.tpl')):
    for token in pattern.findall(path.read_text(encoding='utf-8')):
        if not re.fullmatch(r"[A-Z0-9_]+(?:\|(dotenv|shell|yaml|caddy))?", token):
            raise SystemExit(f"Unsupported template token {token!r} in {path}")
print('template placeholder check ok')
PY
}

rendered_template_tests() {
  step "Server- und lokale Templates mit gehärteter Fixture rendern"
  local tmp file
  tmp="$(mktemp -d)"
  load_env_file "$REPO_ROOT/tests/fixtures/production-server.env" "${SERVER_CONFIG_KEYS[@]}"
  EXPECTED_ENVIRONMENT=production; validate_server_config
  DATABASE_URL="mysql://$DB_USER:$DB_PASSWORD@database:3306/$DB_NAME"; REDIS_URL="redis://:$REDIS_PASSWORD@redis:6379/0"; CACHE_URL="redis://:$REDIS_PASSWORD@redis:6379/1"; PHP_SESSION_SAVE_PATH="tcp://redis:6379?auth=$REDIS_PASSWORD"; MESSENGER_TRANSPORT_DSN="amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@rabbitmq:5672/shopware/messages"; MESSENGER_TRANSPORT_LOW_PRIORITY_DSN="amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@rabbitmq:5672/shopware/low_priority"; MESSENGER_TRANSPORT_FAILURE_DSN="amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@rabbitmq:5672/shopware/failed"; export DATABASE_URL REDIS_URL CACHE_URL PHP_SESSION_SAVE_PATH MESSENGER_TRANSPORT_DSN MESSENGER_TRANSPORT_LOW_PRIORITY_DSN MESSENGER_TRANSPORT_FAILURE_DSN
  for file in "$REPO_ROOT"/templates/server/*.tpl; do render_template "$file" "$tmp/$(basename "${file%.tpl}")"; bash -n "$tmp/$(basename "${file%.tpl}")"; done
  render_template "$REPO_ROOT/templates/shopware/env.compose.tpl" "$tmp/.env.compose"
  render_template "$REPO_ROOT/templates/shopware/env.runtime.tpl" "$tmp/.env.runtime"
  render_template "$REPO_ROOT/templates/shopware/env.init.tpl" "$tmp/.env.init"
  render_template "$REPO_ROOT/templates/shopware/env.backup.tpl" "$tmp/.env.backup"
  render_template "$REPO_ROOT/templates/docker/compose.server.yaml.tpl" "$tmp/compose.yaml"
  render_template "$REPO_ROOT/templates/docker/Caddyfile.tpl" "$tmp/Caddyfile"
  grep -Fxq 'shop.template.internal, storefront-2.template.internal, storefront-3.template.internal {' "$tmp/Caddyfile"
  mkdir "$tmp/local"
  render_template "$REPO_ROOT/templates/shopware/env.local.tpl" "$tmp/local/.env.local"
  render_template "$REPO_ROOT/templates/docker/compose.local.yaml.tpl" "$tmp/local/compose.local.yaml"
  render_template "$REPO_ROOT/templates/docker/Dockerfile.tpl" "$tmp/local/Dockerfile"
  if command_exists docker; then
    (cd "$tmp" && docker compose --env-file .env.compose -f compose.yaml config --quiet)
    (cd "$tmp/local" && docker compose --env-file .env.local -f compose.local.yaml config --quiet)
  fi
  if command_exists shellcheck; then shellcheck -x "$tmp"/*.sh; fi
  rm -rf "$tmp"
}

shellcheck_tests() {
  step "ShellCheck ausführen"
  command_exists shellcheck || die "shellcheck fehlt"
  shellcheck -x "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh
}

bats_tests() { step "Bats ausführen"; command_exists bats || die "bats fehlt"; bats "$REPO_ROOT/tests/bats"; }

actionlint_tests() {
  step "GitHub Workflows prüfen"
  command_exists actionlint || die "actionlint fehlt"
  if [[ -d "$REPO_ROOT/.github/workflows" ]]; then actionlint -shellcheck= "$REPO_ROOT"/.github/workflows/*.yml; else
    local tmp file; tmp="$(mktemp -d)"; for file in "$REPO_ROOT"/templates/github/ci.yml.tpl "$REPO_ROOT"/templates/github/deploy-*.yml.tpl; do render_template "$file" "$tmp/$(basename "${file%.tpl}")"; done; actionlint -shellcheck= "$tmp"/*.yml; rm -rf "$tmp"
  fi
}

docker_tests() {
  step "Explizite Ubuntu-Container-Simulation"
  require_command docker; docker info >/dev/null 2>&1 || die "Docker-Daemon nicht erreichbar"
  local image image_tag context
  context="$(mktemp -d)"; cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/templates" "$REPO_ROOT/tests" "$context/"
  for image in "ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90" "ubuntu:26.04@sha256:b7f48194d4d8b763a478a621cdc81c27be222ba2206ca3ca6bc42b49685f3d9e"; do
    image_tag="shopware-infra-test-$(printf '%s' "$image" | sha256sum | cut -c1-12)"
    docker build --build-arg "UBUNTU_IMAGE=$image" -f "$context/tests/docker/Dockerfile.ubuntu-test" -t "$image_tag" "$context"
    docker run --rm -e SHOPWARE_INFRA_TEST_MODE=1 "$image_tag" bash tests/docker/run-staging-test.sh
    docker run --rm -e SHOPWARE_INFRA_TEST_MODE=1 "$image_tag" bash tests/docker/run-production-test.sh
    docker image rm "$image_tag" >/dev/null
  done
  rm -rf "$context"
}

testinfra_tests() {
  step "Testinfra gegen echten Server"
  [[ -n "$TESTINFRA_HOST" ]] || die "--host fehlt"
  python3 -c 'import pytest, testinfra' >/dev/null 2>&1 || die "pytest/testinfra fehlen"
  local options=("--hosts=$TESTINFRA_HOST"); [[ -n "$TESTINFRA_SSH_CONFIG" ]] && options+=("--ssh-config=$TESTINFRA_SSH_CONFIG")
  if [[ "$TESTINFRA_SCOPE" == predeploy ]]; then
    pytest "${options[@]}" "$REPO_ROOT/tests/testinfra/test_common_server.py"
  else
    pytest "${options[@]}" "$REPO_ROOT/tests/testinfra"
  fi
}

case "$MODE" in
  syntax) SHOPWARE_INFRA_TOTAL=2; syntax_tests; rendered_template_tests ;;
  bats) SHOPWARE_INFRA_TOTAL=1; bats_tests ;;
  ci-static) SHOPWARE_INFRA_TOTAL=6; syntax_tests; rendered_template_tests; shellcheck_tests; bats_tests; actionlint_tests; bash "$REPO_ROOT/scripts/08-preflight.sh" --local-only ;;
  docker) SHOPWARE_INFRA_TOTAL=1; docker_tests ;;
  testinfra) SHOPWARE_INFRA_TOTAL=1; testinfra_tests ;;
  static) SHOPWARE_INFRA_TOTAL=3; syntax_tests; rendered_template_tests; bash "$REPO_ROOT/scripts/08-preflight.sh" --local-only ;;
esac
ok "Angeforderte Tests abgeschlossen"
