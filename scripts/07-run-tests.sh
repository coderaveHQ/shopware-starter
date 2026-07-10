#!/usr/bin/env bash
# Runs local safety checks, Bash tests, Docker simulation tests and optional Testinfra checks.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/bootstrap.sh"
MODE="all"; TESTINFRA_HOST=""; TESTINFRA_SSH_CONFIG=""
usage(){ cat <<USAGE
Usage: bash scripts/07-run-tests.sh [--syntax-only|--bats|--docker|--testinfra] [--host ssh://user@host] [--ssh-config path]

Modes:
  --syntax-only  Run bash -n on all scripts and template checks.
  --bats         Run Bats tests if bats is installed.
  --docker       Run Ubuntu container simulation for staging/production scripts.
  --testinfra    Run pytest/testinfra against a real server. Requires --host.
  default        Run syntax, bats when available and docker when Docker is available.
USAGE
}
args=(); while [[ $# -gt 0 ]]; do case "$1" in --syntax-only) MODE="syntax"; shift ;; --bats) MODE="bats"; shift ;; --docker) MODE="docker"; shift ;; --testinfra) MODE="testinfra"; shift ;; --host) TESTINFRA_HOST="$2"; shift 2 ;; --ssh-config) TESTINFRA_SSH_CONFIG="$2"; shift 2 ;; -h|--help) usage; exit 0 ;; *) args+=("$1"); shift ;; esac; done
if [[ "${#args[@]}" -gt 0 ]]; then parse_common_args "${args[@]}"; else parse_common_args; fi
syntax_tests(){ step "Bash-Syntax prüfen"; local f; while IFS= read -r -d '' f; do bash -n "$f"; ok "bash -n: ${f#$REPO_ROOT/}"; done < <(find "$REPO_ROOT/scripts" -type f -name '*.sh' -print0 | sort -z); step "Template-Platzhalter prüfen"; python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1])
for path in sorted((root/'templates').rglob('*.tpl')):
    text=path.read_text(encoding='utf-8')
    for match in re.finditer(r"(?<!\$)\{\{([^}]+)\}\}", text):
        token=match.group(1)
        if not re.fullmatch(r"[A-Z0-9_]+", token):
            raise SystemExit(f"Unsupported template token {token!r} in {path}")
print('template placeholder check ok')
PY
ok "Template-Prüfung abgeschlossen"; }
bats_tests(){ step "Bats-Tests ausführen"; if ! command_exists bats; then warn "bats ist nicht installiert; Bats-Tests werden übersprungen."; return 0; fi; bats "$REPO_ROOT/tests/bats"; }
docker_tests(){
  step "Docker-Simulation für unterstützte Ubuntu-Versionen ausführen"
  if ! command_exists docker; then warn "Docker fehlt; Docker-Simulation wird übersprungen."; return 0; fi
  docker info >/dev/null 2>&1 || die "Docker ist installiert, aber der Docker-Daemon ist nicht erreichbar."
  local ubuntu_version image_tag
  for ubuntu_version in 24.04 26.04; do
    image_tag="shopware-infra-template-ubuntu-${ubuntu_version//./-}-test"
    docker build --build-arg "UBUNTU_VERSION=$ubuntu_version" -f "$REPO_ROOT/tests/docker/Dockerfile.ubuntu-test" -t "$image_tag" "$REPO_ROOT"
    docker run --rm --privileged -e SHOPWARE_INFRA_TEST_MODE=1 "$image_tag" bash tests/docker/run-staging-test.sh
    docker run --rm --privileged -e SHOPWARE_INFRA_TEST_MODE=1 "$image_tag" bash tests/docker/run-production-test.sh
  done
}
testinfra_tests(){ step "Testinfra gegen echten Server ausführen"; [[ -n "$TESTINFRA_HOST" ]] || die "--host fehlt, z. B. --host ssh://deploy@example.com"; require_command python3; python3 -c 'import pytest, testinfra' >/dev/null 2>&1 || die "pytest/testinfra fehlen. Installieren mit: python3 -m pip install pytest testinfra"; local opts=("--hosts=$TESTINFRA_HOST"); [[ -n "$TESTINFRA_SSH_CONFIG" ]] && opts+=("--ssh-config=$TESTINFRA_SSH_CONFIG"); pytest "${opts[@]}" "$REPO_ROOT/tests/testinfra"; }
case "$MODE" in syntax) SHOPWARE_INFRA_TOTAL=2; syntax_tests ;; bats) SHOPWARE_INFRA_TOTAL=1; bats_tests ;; docker) SHOPWARE_INFRA_TOTAL=1; docker_tests ;; testinfra) SHOPWARE_INFRA_TOTAL=1; testinfra_tests ;; all) SHOPWARE_INFRA_TOTAL=4; syntax_tests; bats_tests; docker_tests ;; *) die "Unbekannter Testmodus: $MODE" ;; esac
ok "Tests abgeschlossen"
