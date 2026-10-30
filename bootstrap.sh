#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# n8nDemo bootstrap
#
# One-shot, idempotent setup. Safe to re-run: it never overwrites an existing
# .env and never touches existing data.
#
#   ./bootstrap.sh
#
# Steps:
#   1. preflight  - docker, compose plugin, daemon, free port
#   2. data dirs  - $HOME/docker/n8n_data/{.n8n,files}
#   3. .env       - generated from .env.example with a random encryption key
#   4. network    - external docker network n8n_shared
#   5. start      - docker compose up -d, wait until healthy
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"

cd "$REPO_DIR"

OS="$(detect_os)"
ENV_FILE="$REPO_DIR/.env"
ENV_TEMPLATE="$REPO_DIR/.env.example"
DEFAULT_DATA_DIR="$HOME/docker/n8n_data"
SHARED_NETWORK="n8n_shared"

# --- 1. preflight ----------------------------------------------------------
log "Preflight checks (detected OS: $OS)"
require_docker
ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') and Compose plugin available"

require_cmd openssl "needed to generate the n8n encryption key"

# --- 2. data directories ---------------------------------------------------
# If .env already exists, honour the data directory it points at so that a
# re-run never silently relocates existing data.
DATA_DIR="$(env_get "$ENV_FILE" N8N_DATA_DIR 2>/dev/null || true)"
[ -n "${DATA_DIR:-}" ] || DATA_DIR="$DEFAULT_DATA_DIR"

log "Preparing data directory: $DATA_DIR"
mkdir -p "$DATA_DIR/.n8n" "$DATA_DIR/files"

if [ "$OS" = "linux" ]; then
  # The n8n image runs as the unprivileged user "node" (uid/gid 1000). On Linux
  # bind mounts preserve host ownership, so the directories must be handed over
  # explicitly or n8n cannot write its database.
  current_uid="$(stat -c '%u' "$DATA_DIR/.n8n")"
  if [ "$current_uid" != "1000" ]; then
    log "Setting ownership to 1000:1000 (the 'node' user inside the container)"
    if [ "$(id -u)" -eq 0 ]; then
      chown -R 1000:1000 "$DATA_DIR"
    else
      sudo chown -R 1000:1000 "$DATA_DIR" \
        || die "Could not chown $DATA_DIR to 1000:1000. Run: sudo chown -R 1000:1000 '$DATA_DIR'"
    fi
  fi
fi
ok "Data directory ready ($DATA_DIR/.n8n, $DATA_DIR/files)"

# --- 3. .env ---------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  ok ".env already exists - left untouched"
else
  [ -f "$ENV_TEMPLATE" ] || die "Missing $ENV_TEMPLATE - the repository is incomplete."
  log "Generating .env"

  encryption_key="$(openssl rand -hex 32)"

  # Use a non-/ delimiter: both the path and the key are substituted verbatim.
  sed \
    -e "s|^N8N_DATA_DIR=.*|N8N_DATA_DIR=$DATA_DIR|" \
    -e "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$encryption_key|" \
    "$ENV_TEMPLATE" > "$ENV_FILE"

  chmod 600 "$ENV_FILE"
  ok ".env created (mode 600)"
  warn "Back up N8N_ENCRYPTION_KEY from .env. Without it, restored credentials are unrecoverable."
fi

# Port conflict check uses the value actually in .env.
N8N_PORT="$(env_get "$ENV_FILE" N8N_PORT || echo 5678)"
if docker ps --format '{{.Names}}' | grep -qx 'n8n'; then
  : # our own container already holds the port; compose will handle it
elif command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$N8N_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "Port $N8N_PORT is already in use on this host. Change N8N_PORT in .env and re-run."
fi

# --- 4. shared network -----------------------------------------------------
if docker network inspect "$SHARED_NETWORK" >/dev/null 2>&1; then
  ok "Network '$SHARED_NETWORK' already exists"
else
  log "Creating external network '$SHARED_NETWORK'"
  docker network create "$SHARED_NETWORK" >/dev/null
  ok "Network '$SHARED_NETWORK' created"
fi

# --- 5. start --------------------------------------------------------------
log "Starting n8n (image tag: $(env_get "$ENV_FILE" N8N_VERSION || echo '?'))"
docker compose up -d

log "Waiting for the container to report healthy"
deadline=$(( $(date +%s) + 180 ))
status='starting'
while [ "$(date +%s)" -lt "$deadline" ]; do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' n8n 2>/dev/null || echo 'missing')"
  case "$status" in
    healthy) break ;;
    unhealthy)
      docker compose logs --tail 40 n8n || true
      die "Container reported unhealthy. Logs above; full log: ./n8n.sh logs"
      ;;
  esac
  sleep 3
done

[ "$status" = "healthy" ] || {
  docker compose logs --tail 40 n8n || true
  die "Timed out waiting for a healthy container (last status: $status)."
}

ok "n8n is healthy"

cat <<EOF

${C_BOLD}n8n is running.${C_RESET}

  URL          http://127.0.0.1:${N8N_PORT}
  Data (host)  ${DATA_DIR}
    .n8n/        SQLite database and internal state
    files/       file exchange, mounted at /data/files in the container
  Control      ./n8n.sh status | logs | down | destroy

Next: open the URL and create the owner account (local, nothing is sent anywhere).
Then see README.md for the REST API, webhooks and connecting other containers.
EOF
