#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# n8nDemo control script.
#
#   ./n8n.sh <command> [args]
#
# Run ./n8n.sh help for the command list.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"

cd "$REPO_DIR"

ENV_FILE="$REPO_DIR/.env"
BACKUP_DIR="$REPO_DIR/backups"
SHARED_NETWORK="n8n_shared"
COMPOSE_NETWORK="n8n_net"

need_env() {
  [ -f "$ENV_FILE" ] || die "No .env found. Run ./bootstrap.sh first."
}

data_dir() {
  env_get "$ENV_FILE" N8N_DATA_DIR
}

port() {
  env_get "$ENV_FILE" N8N_PORT || echo 5678
}

usage() {
  cat <<EOF
${C_BOLD}n8nDemo${C_RESET} - control script

  ${C_BOLD}up${C_RESET}                  Start the stack (does not re-run setup)
  ${C_BOLD}down${C_RESET}                Stop and remove the container, keep all data
  ${C_BOLD}restart${C_RESET}             Recreate the container, e.g. after changing .env
  ${C_BOLD}status${C_RESET}              Show container state, health, ports and networks
  ${C_BOLD}logs${C_RESET} [-f]           Show logs; -f to follow
  ${C_BOLD}shell${C_RESET}               Open a shell inside the running container
  ${C_BOLD}url${C_RESET}                 Print the local URL
  ${C_BOLD}backup${C_RESET}              Archive the data directory into ./backups/
  ${C_BOLD}restore${C_RESET} <file>      Restore a backup archive (destructive, confirms)
  ${C_BOLD}destroy${C_RESET} [--purge-data]
                      Remove container, image and the compose network.
                      With --purge-data also deletes the host data directory.
  ${C_BOLD}help${C_RESET}                This text

First-time setup is ./bootstrap.sh, not this script.
EOF
}

cmd_up() {
  need_env
  docker network inspect "$SHARED_NETWORK" >/dev/null 2>&1 \
    || docker network create "$SHARED_NETWORK" >/dev/null
  docker compose up -d
  ok "Started. URL: http://127.0.0.1:$(port)"
}

cmd_down() {
  need_env
  docker compose down
  ok "Stopped. Data in $(data_dir) is untouched; ./n8n.sh up brings it back."
}

cmd_restart() {
  need_env
  docker compose up -d --force-recreate
  ok "Recreated."
}

cmd_status() {
  need_env
  log "Compose services"
  docker compose ps
  echo
  log "Health"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' n8n 2>/dev/null \
    || echo "container not running"
  echo
  log "Networks attached to the n8n container"
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} ({{$v.IPAddress}}){{"\n"}}{{end}}' n8n 2>/dev/null \
    || echo "container not running"
  echo
  log "Host data directory"
  du -sh "$(data_dir)" 2>/dev/null || echo "$(data_dir) not present"
}

cmd_logs() {
  need_env
  if [ "${1:-}" = "-f" ]; then
    docker compose logs -f n8n
  else
    docker compose logs --tail 200 n8n
  fi
}

cmd_shell() {
  need_env
  docker exec -it n8n /bin/sh
}

cmd_url() {
  need_env
  echo "http://127.0.0.1:$(port)"
}

cmd_backup() {
  need_env
  local src stamp target
  src="$(data_dir)"
  [ -d "$src" ] || die "Data directory not found: $src"

  mkdir -p "$BACKUP_DIR"
  stamp="$(date +%Y%m%d-%H%M%S)"
  target="$BACKUP_DIR/n8n-data-$stamp.tar.gz"

  # Stopping first guarantees a consistent SQLite snapshot.
  local was_running=0
  if docker ps --format '{{.Names}}' | grep -qx 'n8n'; then
    was_running=1
    log "Stopping the container for a consistent snapshot"
    docker compose stop n8n >/dev/null
  fi

  log "Archiving $src"
  tar -czf "$target" -C "$(dirname "$src")" "$(basename "$src")"

  if [ "$was_running" -eq 1 ]; then
    docker compose start n8n >/dev/null
    log "Container restarted"
  fi

  ok "Backup written: $target"
  warn "Treat this archive as a secret: .n8n/config inside it holds the encryption key in plain text, which unlocks every stored credential."
}

cmd_restore() {
  need_env
  local archive="${1:-}" src
  [ -n "$archive" ] || die "Usage: ./n8n.sh restore <path-to-archive.tar.gz>"
  [ -f "$archive" ] || die "Archive not found: $archive"
  src="$(data_dir)"

  confirm_word "RESTORE" "This replaces everything in $src with the contents of $archive." \
    || die "Aborted."

  if docker ps -a --format '{{.Names}}' | grep -qx 'n8n'; then
    log "Stopping the container"
    docker compose down >/dev/null
  fi

  log "Removing current data directory"
  rm -rf "$src"

  log "Extracting archive"
  mkdir -p "$(dirname "$src")"
  tar -xzf "$archive" -C "$(dirname "$src")"

  if [ "$(detect_os)" = "linux" ]; then
    sudo chown -R 1000:1000 "$src" 2>/dev/null || chown -R 1000:1000 "$src" 2>/dev/null || \
      warn "Could not chown $src to 1000:1000 - do it manually if n8n fails to start."
  fi

  # The restored .n8n/config carries the key the backup was taken with. n8n
  # gives N8N_ENCRYPTION_KEY from the environment precedence, so a mismatch
  # between .env and the archive makes credentials fail to decrypt.
  local archived_key current_key
  archived_key="$(sed -n 's/.*"encryptionKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src/.n8n/config" 2>/dev/null | head -n 1)"
  current_key="$(env_get "$ENV_FILE" N8N_ENCRYPTION_KEY || true)"
  if [ -n "$archived_key" ] && [ -n "$current_key" ] && [ "$archived_key" != "$current_key" ]; then
    warn "Encryption key mismatch: .env differs from the key inside the archive."
    warn "Credentials will not decrypt. To use the archive's key, set it in .env:"
    warn "    N8N_ENCRYPTION_KEY=$archived_key"
    warn "then run ./n8n.sh restart."
  fi

  cmd_up
  ok "Restored from $archive"
}

cmd_destroy() {
  need_env
  local purge=0
  [ "${1:-}" = "--purge-data" ] && purge=1

  confirm_word "DESTROY" "This removes the n8n container, its image and the '$COMPOSE_NETWORK' network." \
    || die "Aborted."

  log "Removing container, volumes and the compose network"
  docker compose down --volumes --remove-orphans || true

  local image
  image="docker.n8n.io/n8nio/n8n:$(env_get "$ENV_FILE" N8N_VERSION || echo '')"
  if docker image inspect "$image" >/dev/null 2>&1; then
    log "Removing image $image"
    docker image rm "$image" >/dev/null 2>&1 || warn "Image still in use by another container - left in place."
  fi

  # n8n_shared is shared with other stacks: only remove it when nothing is attached.
  if docker network inspect "$SHARED_NETWORK" >/dev/null 2>&1; then
    local attached
    attached="$(docker network inspect -f '{{len .Containers}}' "$SHARED_NETWORK")"
    if [ "$attached" = "0" ]; then
      docker network rm "$SHARED_NETWORK" >/dev/null && ok "Removed network '$SHARED_NETWORK'"
    else
      warn "Network '$SHARED_NETWORK' still has $attached container(s) attached - left in place."
    fi
  fi

  if [ "$purge" -eq 1 ]; then
    local src
    src="$(data_dir)"
    echo
    confirm_word "DELETE-DATA" "FINAL CONFIRMATION: permanently delete $src including all workflows, executions and credentials?" \
      || die "Data preserved. Container and image were still removed."
    rm -rf "$src"
    ok "Deleted $src"
    rm -f "$ENV_FILE"
    ok "Deleted .env"
  else
    ok "Data preserved at $(data_dir) and .env is still present."
    echo "    Use './n8n.sh destroy --purge-data' to remove those as well."
  fi

  ok "Destroy complete."
}

case "${1:-help}" in
  up)       shift; cmd_up "$@" ;;
  down)     shift; cmd_down "$@" ;;
  restart)  shift; cmd_restart "$@" ;;
  status)   shift; cmd_status "$@" ;;
  logs)     shift; cmd_logs "$@" ;;
  shell)    shift; cmd_shell "$@" ;;
  url)      shift; cmd_url "$@" ;;
  backup)   shift; cmd_backup "$@" ;;
  restore)  shift; cmd_restore "$@" ;;
  destroy)  shift; cmd_destroy "$@" ;;
  help|-h|--help) usage ;;
  *)        usage; die "Unknown command: $1" ;;
esac
