#!/bin/bash
#
# deploy.sh — Deployment script for Home Gym Tracker
#
# Run 1 (migration): Installs Docker, stops bare-metal services,
#                     migrates DB into Docker volumes, starts containers.
# Run 2+ (update):   Pulls latest code, rebuilds & restarts containers.
#
# Usage:
#   Deploy/update:     ./deploy.sh
#   Update dev only:   ./deploy.sh --dev
#   Rollback:          ./deploy.sh --rollback
#
# Both main and dev branches run simultaneously as Docker containers.
# Users switch between them via Settings → Developer → "Use dev version".
#

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"
BACKUP_DIR="$APP_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }
info() { echo -e "${CYAN}[info]${NC} $*"; }

# ── Check if Docker is running ────────────────────────────────────────────────

is_docker_mode() {
  [ -f "$APP_DIR/.docker-mode" ]
}

docker_available() {
  command -v docker &>/dev/null && docker info &>/dev/null
}

# ── Install Docker if needed ──────────────────────────────────────────────────

install_docker() {
  if docker_available; then
    log "Docker already installed"
    return 0
  fi

  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sh || {
    err "Docker installation failed. Install manually: https://docs.docker.com/engine/install/"
    exit 1
  }

  # Add current user to docker group (avoids sudo for future runs)
  sudo usermod -aG docker "$USER" 2>/dev/null || true

  # Start Docker service
  sudo systemctl enable docker 2>/dev/null || true
  sudo systemctl start docker 2>/dev/null || true

  log "Docker installed successfully"
}

# ── Migrate from bare-metal to Docker ─────────────────────────────────────────

migrate_to_docker() {
  log "═══════════════════════════════════════════════"
  log " Migrating from bare-metal to Docker"
  log "═══════════════════════════════════════════════"

  # 1. Install Docker
  install_docker

  # 2. Backup current database
  mkdir -p "$BACKUP_DIR"
  if [ -f "$APP_DIR/homegym.db" ]; then
    local backup_path="$BACKUP_DIR/homegym_pre_docker_${TIMESTAMP}.db"
    log "Backing up database to: $(basename "$backup_path")"
    cp "$APP_DIR/homegym.db" "$backup_path"
  fi

  # 3. Stop old bare-metal services
  log "Stopping bare-metal services..."
  if [ -f "$APP_DIR/.deploy-pids" ]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$APP_DIR/.deploy-pids"
    rm -f "$APP_DIR/.deploy-pids"
  fi
  lsof -ti :8000 2>/dev/null | xargs kill 2>/dev/null || true
  lsof -ti :3000 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 1

  # 4. Disable old nginx config (Docker handles routing now)
  if [ -f /etc/nginx/sites-enabled/gymtracker ]; then
    log "Removing old nginx site config (Docker takes over routing)..."
    sudo rm -f /etc/nginx/sites-enabled/gymtracker
    sudo systemctl stop nginx 2>/dev/null || true
    sudo systemctl disable nginx 2>/dev/null || true
  fi

  # 5. Ensure .env exists and export vars for docker compose
  ensure_env
  set -a; source "$APP_DIR/.env"; set +a

  # 6. Ensure dev branch exists
  ensure_dev_branch

  # 7. Build and start Docker containers
  log "Building Docker containers (this takes a few minutes the first time)..."
  docker compose build || {
    err "Docker build failed"
    exit 1
  }

  # 8. Copy existing database into Docker volumes
  if [ -f "$APP_DIR/homegym.db" ]; then
    log "Copying existing database into main container volume..."
    # Create volumes and copy data
    docker compose up -d main
    sleep 2
    docker compose cp "$APP_DIR/homegym.db" main:/app/data/homegym.db
    docker compose restart main
  fi

  # 9. Start everything
  docker compose up -d
  sleep 3

  # 10. Mark as Docker mode
  touch "$APP_DIR/.docker-mode"

  # 11. Health check
  docker_health_check

  log ""
  log "═══════════════════════════════════════════════"
  log " Migration complete! Now running on Docker."
  log ""
  log " Main:  http://localhost (default)"
  log " Dev:   http://localhost (toggle in Settings)"
  log ""
  log " Logs:  docker compose logs -f"
  log " Stop:  docker compose down"
  log "═══════════════════════════════════════════════"
}

# ── Docker deploy (update) ────────────────────────────────────────────────────

docker_deploy() {
  local target="${1:-all}"

  log "Starting Docker deployment at $TIMESTAMP"
  mkdir -p "$BACKUP_DIR"

  # Load env vars for docker compose
  if [ -f "$APP_DIR/.env" ]; then
    set -a; source "$APP_DIR/.env"; set +a
  fi

  # 1. Pull latest code
  log "Pulling latest code..."
  git fetch origin

  if [ "$target" = "dev" ]; then
    log "Updating dev branch only..."
    # Stash current branch, update dev, come back
    local current_branch
    current_branch=$(git branch --show-current)
    git checkout dev 2>/dev/null || git checkout -b dev origin/dev
    git reset --hard origin/dev
    git checkout "$current_branch"

    # Rebuild only the dev container
    log "Rebuilding dev container..."
    docker compose build dev
    docker compose up -d dev
  else
    log "Updating all branches..."
    git reset --hard origin/main

    # Also update dev branch
    local current_branch
    current_branch=$(git branch --show-current)
    if git rev-parse --verify origin/dev &>/dev/null; then
      git checkout dev 2>/dev/null || git checkout -b dev origin/dev
      git reset --hard origin/dev
      git checkout "$current_branch"
    fi

    # Rebuild both containers
    log "Rebuilding containers..."
    docker compose build
    docker compose up -d
  fi

  sleep 3
  docker_health_check

  log ""
  log "========================================="
  log " Docker deployment successful!"
  log " Commit (main): $(git log --oneline -1 origin/main)"
  if git rev-parse --verify origin/dev &>/dev/null; then
    log " Commit (dev):  $(git log --oneline -1 origin/dev)"
  fi
  log "========================================="
}

# ── Docker health check ──────────────────────────────────────────────────────

docker_health_check() {
  log "Running health check..."
  local retries=15
  local delay=2

  for i in $(seq 1 $retries); do
    if curl -sf http://localhost/api/health > /dev/null 2>&1 || \
       curl -sf http://localhost/api/docs > /dev/null 2>&1; then
      log "App is healthy (attempt $i/$retries)"
      return 0
    fi
    sleep $delay
  done

  warn "Health check didn't pass — containers may still be starting."
  warn "Check logs: docker compose logs -f"
  return 1
}

# ── Docker rollback ───────────────────────────────────────────────────────────

docker_rollback() {
  log "Rolling back Docker deployment..."

  if [ -f "$APP_DIR/.last-good-ref" ]; then
    local ref
    ref=$(cat "$APP_DIR/.last-good-ref")
    log "Checking out last good commit: $ref"
    git checkout "$ref" -- .
  else
    warn "No rollback ref found"
  fi

  docker compose build
  docker compose up -d
  sleep 3
  docker_health_check
  log "Rollback complete."
}

# ── Ensure .env ───────────────────────────────────────────────────────────────

ensure_env() {
  if [ ! -f "$APP_DIR/.env" ]; then
    log "Creating .env with random JWT secret..."
    local jwt_secret
    jwt_secret=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")
    cat > "$APP_DIR/.env" <<ENVEOF
JWT_SECRET_KEY=${jwt_secret}
ENVEOF
  fi
}

# ── Ensure dev branch exists ──────────────────────────────────────────────────

ensure_dev_branch() {
  if ! git rev-parse --verify origin/dev &>/dev/null; then
    log "Creating dev branch from main..."
    git branch dev origin/main 2>/dev/null || true
    git push origin dev 2>/dev/null || true
  fi
}

# ── Legacy bare-metal deploy (fallback if not in Docker mode) ─────────────────
# Kept for compatibility. Once migrated to Docker, this is never used.

legacy_deploy() {
  warn "Running legacy bare-metal deploy. Run again to migrate to Docker."
  # ... (original deploy logic preserved below for one more run)

  log "Starting legacy deployment at $TIMESTAMP"
  mkdir -p "$BACKUP_DIR" "$APP_DIR/logs"

  local current_ref
  current_ref=$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || echo "none")

  if [ -f "$APP_DIR/homegym.db" ]; then
    cp "$APP_DIR/homegym.db" "$BACKUP_DIR/homegym_${TIMESTAMP}.db"
    ls -t "$BACKUP_DIR"/homegym_*.db 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
  fi

  git fetch origin
  git reset --hard origin/main

  ensure_env

  if [ ! -d "$APP_DIR/venv" ]; then
    python3 -m venv "$APP_DIR/venv"
  fi
  source "$APP_DIR/venv/bin/activate"
  pip install -e . --quiet

  cd "$APP_DIR/frontend"
  npm install --silent
  NODE_OPTIONS="--max-old-space-size=512" npm run build
  cd "$APP_DIR"

  # Stop old services
  if [ -f "$APP_DIR/.deploy-pids" ]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$APP_DIR/.deploy-pids"
    rm -f "$APP_DIR/.deploy-pids"
  fi
  lsof -ti :8000 2>/dev/null | xargs kill 2>/dev/null || true
  lsof -ti :3000 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 1

  alembic upgrade head

  # Start services
  source "$APP_DIR/venv/bin/activate"
  cd "$APP_DIR"
  nohup uvicorn app.main:app --host 0.0.0.0 --port 8000 > "$APP_DIR/logs/backend.log" 2>&1 &
  echo $! > "$APP_DIR/.deploy-pids"
  cd "$APP_DIR/frontend"
  nohup node build/index.js > "$APP_DIR/logs/frontend.log" 2>&1 &
  echo $! >> "$APP_DIR/.deploy-pids"
  cd "$APP_DIR"

  echo "$(git rev-parse HEAD)" > "$APP_DIR/.last-good-ref"
  log "Legacy deploy complete. Run ./deploy.sh again to migrate to Docker."
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    --rollback)
      if is_docker_mode; then
        docker_rollback
      else
        err "Rollback only supported in Docker mode. Run deploy.sh first to migrate."
      fi
      ;;
    --dev)
      if is_docker_mode; then
        docker_deploy dev
      else
        err "Dev deploy only available in Docker mode. Run deploy.sh first to migrate."
      fi
      ;;
    *)
      if is_docker_mode; then
        # Already on Docker — just update
        docker_deploy all
      else
        # First run: pull latest code (which includes Dockerfile), then migrate
        log "Pulling latest code..."
        git fetch origin
        git reset --hard origin/main

        # Now check if Dockerfile exists (it will after this commit)
        if [ -f "$APP_DIR/Dockerfile" ]; then
          migrate_to_docker
        else
          # Dockerfile not yet in main — do legacy deploy
          # Next deploy after Dockerfile lands will trigger migration
          legacy_deploy
        fi
      fi
      ;;
  esac
}

main "$@"
