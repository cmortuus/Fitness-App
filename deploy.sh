#!/bin/bash
#
# deploy.sh — Safe deployment script for Home Gym Tracker
#
# Works for both first-time install and updates.
# Backs up the database before any migration, and supports instant rollback.
#
# Usage:
#   First install:  ./deploy.sh
#   Update:         ./deploy.sh
#   Rollback:       ./deploy.sh --rollback
#
# Requirements: git, python3, node/npm
#

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"  # All commands expect to run from project root
BACKUP_DIR="$APP_DIR/backups"
DB_FILE="$APP_DIR/homegym.db"
VENV_DIR="$APP_DIR/venv"
FRONTEND_DIR="$APP_DIR/frontend"
PID_FILE="$APP_DIR/.deploy-pids"
ROLLBACK_REF_FILE="$APP_DIR/.last-good-ref"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Stop running services ────────────────────────────────────────────────────

stop_services() {
  log "Stopping running services..."
  if [ -f "$PID_FILE" ]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$PID_FILE"
    rm -f "$PID_FILE"
  fi
  # Also kill any uvicorn/node on our ports
  lsof -ti :8000 2>/dev/null | xargs kill 2>/dev/null || true
  lsof -ti :3000 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 1
}

# ── Rollback ─────────────────────────────────────────────────────────────────

rollback() {
  err "Rolling back to last known good state..."

  # 1. Restore git ref
  if [ -f "$ROLLBACK_REF_FILE" ]; then
    local ref
    ref=$(cat "$ROLLBACK_REF_FILE")
    log "Checking out last good commit: $ref"
    git -C "$APP_DIR" checkout "$ref" -- .
  else
    warn "No rollback ref found — using git stash"
    git -C "$APP_DIR" checkout -- .
  fi

  # 2. Restore database backup
  local latest_backup
  latest_backup=$(ls -t "$BACKUP_DIR"/homegym_*.db 2>/dev/null | head -1)
  if [ -n "$latest_backup" ]; then
    log "Restoring database from: $(basename "$latest_backup")"
    cp "$latest_backup" "$DB_FILE"
  else
    warn "No database backup found to restore"
  fi

  # 3. Rebuild and restart
  log "Rebuilding after rollback..."
  source "$VENV_DIR/bin/activate"
  pip install -e . --quiet
  cd "$FRONTEND_DIR" && npm install --silent && npm run build
  cd "$APP_DIR"

  start_services
  log "Rollback complete."
}

# ── Start services ───────────────────────────────────────────────────────────

start_services() {
  log "Starting services..."
  source "$VENV_DIR/bin/activate"

  # Backend
  cd "$APP_DIR"
  nohup uvicorn app.main:app --host 0.0.0.0 --port 8000 \
    > "$APP_DIR/logs/backend.log" 2>&1 &
  echo $! > "$PID_FILE"
  log "Backend started (PID: $!)"

  # Frontend (production build served by node)
  cd "$FRONTEND_DIR"
  nohup node build/index.js \
    > "$APP_DIR/logs/frontend.log" 2>&1 &
  echo $! >> "$PID_FILE"
  log "Frontend started (PID: $!)"
  cd "$APP_DIR"
}

# ── Health check ─────────────────────────────────────────────────────────────

health_check() {
  log "Running health check..."
  local retries=10
  local delay=2

  for i in $(seq 1 $retries); do
    if curl -sf http://localhost:8000/docs > /dev/null 2>&1; then
      log "Backend is healthy (attempt $i/$retries)"
      return 0
    fi
    sleep $delay
  done

  err "Health check failed after $retries attempts"
  return 1
}

# ── Main deploy ──────────────────────────────────────────────────────────────

main() {
  # Handle --rollback flag
  if [ "${1:-}" = "--rollback" ]; then
    stop_services
    rollback
    exit 0
  fi

  log "Starting deployment at $TIMESTAMP"
  mkdir -p "$BACKUP_DIR" "$APP_DIR/logs"

  # 1. Save current git ref for rollback
  local current_ref
  current_ref=$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || echo "none")
  log "Current commit: $current_ref"

  # 2. Stop services
  stop_services

  # 3. Back up database (if it exists)
  if [ -f "$DB_FILE" ]; then
    local backup_path="$BACKUP_DIR/homegym_${TIMESTAMP}.db"
    log "Backing up database to: $(basename "$backup_path")"
    cp "$DB_FILE" "$backup_path"

    # Keep only last 10 backups
    ls -t "$BACKUP_DIR"/homegym_*.db 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
  else
    log "No existing database — fresh install"
  fi

  # 4. Pull latest code
  log "Pulling latest code..."
  git -C "$APP_DIR" fetch origin
  git -C "$APP_DIR" pull --ff-only || {
    err "Git pull failed (merge conflict?). Aborting."
    exit 1
  }

  # 5. Ensure .env exists with a secure JWT secret
  if [ ! -f "$APP_DIR/.env" ]; then
    log "Creating .env with random JWT secret..."
    local jwt_secret
    jwt_secret=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")
    cat > "$APP_DIR/.env" <<ENVEOF
JWT_SECRET_KEY=${jwt_secret}
ENVEOF
  fi

  # 6. Python venv + deps
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
  fi
  source "$VENV_DIR/bin/activate"

  log "Installing Python dependencies..."
  pip install -e . --quiet || {
    err "pip install failed"
    rollback
    exit 1
  }

  # 6. Run database migrations
  log "Running database migrations..."
  alembic upgrade head || {
    err "Migration failed — rolling back"
    rollback
    exit 1
  }

  # 7. Build frontend
  log "Building frontend..."
  cd "$FRONTEND_DIR"

  if [ ! -d "node_modules" ]; then
    log "Installing frontend dependencies..."
    npm install --silent
  else
    npm install --silent
  fi

  npm run build || {
    err "Frontend build failed — rolling back"
    cd "$APP_DIR"
    rollback
    exit 1
  }
  cd "$APP_DIR"

  # 8. Start services
  start_services

  # 9. Health check
  if health_check; then
    # Save this as the last known good state
    echo "$(git -C "$APP_DIR" rev-parse HEAD)" > "$ROLLBACK_REF_FILE"
    log ""
    log "========================================="
    log " Deployment successful!"
    log " Commit: $(git -C "$APP_DIR" log --oneline -1)"
    log " Backend:  http://localhost:8000"
    log " Frontend: http://localhost:3000"
    log " DB backup: backups/homegym_${TIMESTAMP}.db"
    log "========================================="
  else
    err "Deployment failed health check — rolling back"
    stop_services
    rollback
    exit 1
  fi
}

main "$@"
