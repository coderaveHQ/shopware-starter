#!/usr/bin/env bash
# Shared colored logging helpers.

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_MAGENTA=''; C_CYAN=''; C_BOLD=''
fi

SHOPWARE_INFRA_STEP=${SHOPWARE_INFRA_STEP:-0}
SHOPWARE_INFRA_TOTAL=${SHOPWARE_INFRA_TOTAL:-0}

log_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %b%s%b\n' "$(log_ts)" "$C_CYAN" "$*" "$C_RESET"; }
ok() { printf '%s %b[OK]%b %s\n' "$(log_ts)" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s %b[WARN]%b %s\n' "$(log_ts)" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '%s %b[ERROR]%b %s\n' "$(log_ts)" "$C_RED" "$C_RESET" "$*" >&2; }
die() { err "$*"; exit 1; }

step() {
  SHOPWARE_INFRA_STEP=$((SHOPWARE_INFRA_STEP + 1))
  if [[ "${SHOPWARE_INFRA_TOTAL}" -gt 0 ]]; then
    printf '\n%b[%02d/%02d] %s%b\n' "$C_BOLD$C_BLUE" "$SHOPWARE_INFRA_STEP" "$SHOPWARE_INFRA_TOTAL" "$*" "$C_RESET"
  else
    printf '\n%b[%02d] %s%b\n' "$C_BOLD$C_BLUE" "$SHOPWARE_INFRA_STEP" "$*" "$C_RESET"
  fi
}

run_cmd() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s %b[DRY-RUN]%b %s\n' "$(log_ts)" "$C_MAGENTA" "$C_RESET" "$*"
    return 0
  fi
  log "+ $*"
  "$@"
}

run_shell() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s %b[DRY-RUN]%b %s\n' "$(log_ts)" "$C_MAGENTA" "$C_RESET" "$*"
    return 0
  fi
  log "+ $*"
  bash -lc "$*"
}
