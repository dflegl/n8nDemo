#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared helpers for bootstrap.sh, n8n.sh and scripts/github-init.sh.
# Sourced, never executed directly.
# ---------------------------------------------------------------------------

# Colours, disabled when stdout is not a terminal (CI, pipes, logs).
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD=''
fi

log()   { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%sfail%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

# detect_os -> "macos" | "linux"
detect_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux)  printf 'linux' ;;
    *)      die "Unsupported operating system: $(uname -s). Only macOS and Linux are supported." ;;
  esac
}

# require_cmd <command> [hint]
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1${2:+ ($2)}"
}

# Verify Docker CLI, the Compose v2 plugin and a reachable daemon.
require_docker() {
  require_cmd docker "install Docker Desktop or Docker Engine"
  docker compose version >/dev/null 2>&1 \
    || die "The 'docker compose' plugin (Compose v2) is not available. The legacy 'docker-compose' binary is not supported."
  docker info >/dev/null 2>&1 \
    || die "Cannot reach the Docker daemon. Start Docker Desktop (macOS) or the docker service (Linux) and retry."
}

# Read a single KEY from an env file without sourcing it.
# env_get <file> <key>
env_get() {
  [ -f "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# Ask for confirmation. Returns non-zero unless the user types the exact word.
# confirm_word <word> <prompt>
confirm_word() {
  local want="$1" prompt="$2" answer=''
  printf '%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET"
  printf 'Type %s%s%s to continue: ' "$C_BOLD" "$want" "$C_RESET"
  read -r answer || true
  [ "$answer" = "$want" ]
}
