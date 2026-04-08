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
#   Auto-reload:       ./deploy.sh --watch [interval]
#                      Polls for changes every [interval] seconds (default 60).
#                      Only rebuilds the container(s) whose branch changed.
#   Install service:   ./deploy.sh --install
#                      Installs a systemd service that runs --watch automatically.
#   Uninstall service: ./deploy.sh --uninstall
#
# Both main and dev branches run simultaneously as Docker containers.
# Users switch between them via Settings → Developer → "Use dev version".
#

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"
BACKUP_DIR="$APP_DIR/backups"
LOG_TZ="${DEPLOY_LOG_TZ:-America/New_York}"

# Files that track the SHA last successfully deployed for each branch.
# Used by --watch so restarts pick up from what is actually running,
# not from the current remote HEAD at the moment the script opens.
LAST_DEPLOYED_MAIN="$APP_DIR/.last-deployed-main"
LAST_DEPLOYED_DEV="$APP_DIR/.last-deployed-dev"
FAILED_DEPLOYS="$APP_DIR/.failed-deploys"

fresh_timestamp() { date +%Y%m%d_%H%M%S; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_timestamp() {
  TZ="$LOG_TZ" date '+%Y-%m-%d %H:%M:%S %Z'
}

short_log_timestamp() {
  TZ="$LOG_TZ" date '+%H:%M:%S %Z'
}

log()  { echo -e "${GREEN}[deploy $(log_timestamp)]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn $(short_log_timestamp)]${NC} $*"; }
err()  { echo -e "${RED}[error $(short_log_timestamp)]${NC} $*" >&2; }
info() { echo -e "${CYAN}[info]${NC} $*"; }

# ── Git auto-healing ─────────────────────────────────────────────────────────
# Cleans dirty worktree state so git pull / reset never fails due to local
# modifications, untracked files, or interrupted rebases.

git_heal() {
  # Abort any in-progress rebase/merge/cherry-pick
  git rebase --abort 2>/dev/null || true
  git merge --abort 2>/dev/null || true
  git cherry-pick --abort 2>/dev/null || true

  # Discard all local changes and untracked files
  git reset --hard HEAD 2>/dev/null || true
  git clean -fd 2>/dev/null || true
}

# ── Failed deploy tracking ───────────────────────────────────────────────────
# Remembers SHAs that failed health checks so watch doesn't retry them
# until a NEW commit lands on that branch.

is_failed_sha() {
  local sha="$1"
  [ -f "$FAILED_DEPLOYS" ] && grep -q "^${sha}$" "$FAILED_DEPLOYS" 2>/dev/null
}

mark_failed_sha() {
  local sha="$1"
  echo "$sha" >> "$FAILED_DEPLOYS"
}

clear_failed_sha() {
  local sha="$1"
  [ -f "$FAILED_DEPLOYS" ] && sed -i "/^${sha}$/d" "$FAILED_DEPLOYS" 2>/dev/null || true
}

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
    local backup_path="$BACKUP_DIR/homegym_pre_docker_$(fresh_timestamp).db"
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

  # 5. Ensure .env exists (docker compose reads it via env_file directive)
  ensure_env

  # 6. Ensure dev branch exists
  ensure_dev_branch

  # 7. Build and start Docker containers
  log "Building Docker containers (this takes a few minutes the first time)..."
  docker compose build || {
    err "Docker build failed"
    exit 1
  }

  # 8. Copy existing database into Docker volumes
  # 8. Start PostgreSQL first, let it initialize
  log "Starting PostgreSQL..."
  docker compose up -d db
  sleep 5

  # 9. Start app containers (alembic runs in entrypoint)
  docker compose up -d
  sleep 10

  # 10. Migrate SQLite data to PostgreSQL if SQLite DB exists
  if [ -f "$APP_DIR/homegym.db" ]; then
    log "Migrating SQLite data to PostgreSQL..."
    docker compose cp "$APP_DIR/homegym.db" main:/tmp/homegym.db
    docker compose exec -T main bash -c "PYTHONPATH=/app python scripts/migrate_sqlite_to_pg.py /tmp/homegym.db" || {
      warn "SQLite migration had issues — check manually"
    }
    mv "$APP_DIR/homegym.db" "$BACKUP_DIR/homegym_pre_postgres_$(fresh_timestamp).db"
    log "SQLite backup saved. PostgreSQL is now the database."
  fi

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
  local ts
  ts=$(fresh_timestamp)   # fresh timestamp per deploy, not from script open

  log "Starting Docker deployment at $ts"
  mkdir -p "$BACKUP_DIR"

  # Heal any dirty git state before touching the worktree
  git_heal

  # 1. Pull latest code
  log "Pulling latest code..."
  git fetch origin || { warn "git fetch failed"; return 1; }

  if [ "$target" = "dev" ]; then
    log "Updating dev branch only..."

    local deployed_dev pre_dev
    deployed_dev=$(git rev-parse origin/dev 2>/dev/null || echo "none")

    # Save pre-deploy SHA for rollback
    pre_dev=""
    [ -f "$LAST_DEPLOYED_DEV" ] && pre_dev=$(cat "$LAST_DEPLOYED_DEV")

    log "Rebuilding dev container..."
    local tmpdir
    tmpdir=$(mktemp -d)
    git archive origin/dev | tar -x -C "$tmpdir"
    docker build -t fitness-app-dev "$tmpdir"
    rm -rf "$tmpdir"

    # Stop old container, then recreate with the freshly built image
    docker compose stop dev
    docker compose up -d --no-build --force-recreate dev

    # Blocking health check — rollback if it fails
    if docker_health_check dev; then
      echo "$deployed_dev" > "$LAST_DEPLOYED_DEV"
      clear_failed_sha "$deployed_dev"
      log "Dev deploy successful: ${deployed_dev:0:7}"
    else
      err "Dev health check FAILED for ${deployed_dev:0:7} — rolling back"
      mark_failed_sha "$deployed_dev"
      if [ -n "$pre_dev" ] && [ "$pre_dev" != "none" ]; then
        log "Reverting dev to ${pre_dev:0:7}..."
        tmpdir=$(mktemp -d)
        git archive "$pre_dev" | tar -x -C "$tmpdir"
        docker build -t fitness-app-dev "$tmpdir"
        rm -rf "$tmpdir"
        docker compose stop dev
        docker compose up -d --no-build --force-recreate dev
        docker_health_check dev || warn "Rollback health check also failed — manual intervention needed"
      fi
    fi
    return

  elif [ "$target" = "main" ]; then
    log "Updating main branch only..."

    local deployed_main pre_main
    deployed_main=$(git rev-parse origin/main 2>/dev/null || echo "none")

    # Save pre-deploy SHA for rollback
    pre_main=$(git rev-parse HEAD 2>/dev/null || echo "none")

    git reset --hard origin/main || {
      err "git reset failed, force-checking out"
      git checkout -f origin/main
    }

    log "Rebuilding main container..."
    docker compose build main
    docker compose up -d main

    if docker_health_check main; then
      echo "$deployed_main" > "$LAST_DEPLOYED_MAIN"
      clear_failed_sha "$deployed_main"
      log "Main deploy successful: ${deployed_main:0:7}"
    else
      err "Main health check FAILED for ${deployed_main:0:7} — rolling back"
      mark_failed_sha "$deployed_main"
      if [ "$pre_main" != "none" ]; then
        log "Reverting main to ${pre_main:0:7}..."
        git reset --hard "$pre_main"
        docker compose build main
        docker compose up -d main
        docker_health_check main || warn "Rollback health check also failed — manual intervention needed"
      fi
    fi
    return

  else
    log "Updating all branches..."
    git fetch origin

    local deployed_main deployed_dev pre_main
    deployed_main=$(git rev-parse origin/main 2>/dev/null || echo "none")
    deployed_dev=$(git rev-parse origin/dev 2>/dev/null || echo "none")
    pre_main=$(git rev-parse HEAD 2>/dev/null || echo "none")

    git reset --hard origin/main || {
      err "git reset failed, force-checking out"
      git checkout -f origin/main
    }

    log "Rebuilding main container..."
    docker compose build main

    log "Rebuilding dev container..."
    local tmpdir
    tmpdir=$(mktemp -d)
    git archive origin/dev | tar -x -C "$tmpdir"
    docker build -t fitness-app-dev "$tmpdir"
    rm -rf "$tmpdir"

    docker compose up -d --no-build --force-recreate

    echo "$deployed_main" > "$LAST_DEPLOYED_MAIN"
    echo "$deployed_dev"  > "$LAST_DEPLOYED_DEV"
  fi

  docker_health_check all

  log ""
  log "========================================="
  log " Docker deployment complete"
  log " Commit (main): $(git log --oneline -1 origin/main)"
  if git rev-parse --verify origin/dev &>/dev/null; then
    log " Commit (dev):  $(git log --oneline -1 origin/dev)"
  fi
  log "========================================="
}

# ── Docker health check ──────────────────────────────────────────────────────

docker_health_check() {
  local target="${1:-all}"
  local start_time=$SECONDS

  log "Health check (target: $target)..."

  for i in $(seq 1 20); do
    local ok=true

    if [ "$target" = "dev" ] || [ "$target" = "all" ]; then
      if ! docker compose exec -T dev curl -so /dev/null -w '' http://localhost:3000/ 2>/dev/null; then
        ok=false
      fi
    fi

    if [ "$target" = "main" ] || [ "$target" = "all" ]; then
      if ! docker compose exec -T main curl -so /dev/null -w '' http://localhost:3000/ 2>/dev/null; then
        ok=false
      fi
    fi

    if $ok; then
      log "Healthy after $(( SECONDS - start_time ))s"
      return 0
    fi
    sleep 5
  done

  warn "Health check didn't pass after 100s — check: docker compose logs -f"
  return 1
}

# Run health check in background — doesn't block the watch loop
docker_health_check_async() {
  local target="${1:-all}"
  docker_health_check "$target" &
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
  sleep 10
  docker_health_check
  log "Rollback complete."
}

# ── Ensure .env ───────────────────────────────────────────────────────────────

ensure_env() {
  if [ ! -f "$APP_DIR/.env" ]; then
    log "Creating .env..."
    touch "$APP_DIR/.env"
  fi
  # Ensure JWT_SECRET_KEY exists in .env (append if missing)
  if ! grep -q '^JWT_SECRET_KEY=' "$APP_DIR/.env"; then
    log "Adding JWT_SECRET_KEY to .env..."
    local jwt_secret
    jwt_secret=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")
    echo "JWT_SECRET_KEY=${jwt_secret}" >> "$APP_DIR/.env"
  fi
  # Ensure POSTGRES_PASSWORD exists
  if ! grep -q '^POSTGRES_PASSWORD=' "$APP_DIR/.env"; then
    log "Adding POSTGRES_PASSWORD to .env..."
    local pg_pass
    pg_pass=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    echo "POSTGRES_PASSWORD=${pg_pass}" >> "$APP_DIR/.env"
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

  local ts; ts=$(fresh_timestamp)
  log "Starting legacy deployment at $ts"
  mkdir -p "$BACKUP_DIR" "$APP_DIR/logs"

  local current_ref
  current_ref=$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || echo "none")

  if [ -f "$APP_DIR/homegym.db" ]; then
    cp "$APP_DIR/homegym.db" "$BACKUP_DIR/homegym_${ts}.db"
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

# ── Watch mode ─────────────────────────────────────────────────────────────────

watch_and_reload() {
  local interval="${1:-60}"

  if ! is_docker_mode; then
    err "Watch mode requires Docker. Run ./deploy.sh first to migrate."
    exit 1
  fi

  log "Watching for changes every ${interval}s ..."

  # Heal any dirty state from a previous crash
  git_heal

  # Use the SHA that was last *deployed* as the baseline, not the current
  # remote HEAD.  This means if --watch is restarted after pushes happened
  # while it was stopped, those commits will be picked up and deployed on
  # the very first poll — rather than silently skipped because the remote
  # already shows those SHAs when the script opens.
  git fetch origin --quiet 2>/dev/null || true
  local last_main last_dev
  if [ -f "$LAST_DEPLOYED_MAIN" ]; then
    last_main=$(cat "$LAST_DEPLOYED_MAIN")
  else
    last_main=$(git rev-parse origin/main 2>/dev/null || echo "none")
  fi
  if [ -f "$LAST_DEPLOYED_DEV" ]; then
    last_dev=$(cat "$LAST_DEPLOYED_DEV")
  else
    last_dev=$(git rev-parse origin/dev 2>/dev/null || echo "none")
  fi

  log "Baseline — main: ${last_main:0:7}  dev: ${last_dev:0:7}"

  while true; do
    sleep "$interval"
    git_heal
    git fetch origin --quiet 2>/dev/null || { warn "git fetch failed, retrying next cycle..."; continue; }

    local cur_main cur_dev
    cur_main=$(git rev-parse origin/main 2>/dev/null || echo "none")
    cur_dev=$(git rev-parse origin/dev 2>/dev/null || echo "none")

    local changed_main=false changed_dev=false

    if [ "$cur_main" != "$last_main" ]; then
      if is_failed_sha "$cur_main"; then
        warn "Skipping main ${cur_main:0:7} — previously failed health check"
      else
        changed_main=true
        log "main branch changed: ${last_main:0:7} → ${cur_main:0:7}"
      fi
    fi

    if [ "$cur_dev" != "$last_dev" ]; then
      if is_failed_sha "$cur_dev"; then
        warn "Skipping dev ${cur_dev:0:7} — previously failed health check"
      else
        changed_dev=true
        log "dev branch changed: ${last_dev:0:7} → ${cur_dev:0:7}"
      fi
    fi

    # Rebuild only what changed
    if $changed_main && $changed_dev; then
      log "Both branches changed — rebuilding all..."
      docker_deploy all
    elif $changed_main; then
      log "Rebuilding main only..."
      docker_deploy main
    elif $changed_dev; then
      log "Rebuilding dev only..."
      docker_deploy dev
    fi

    last_main="$cur_main"
    last_dev="$cur_dev"
  done
}

# ── Service install / uninstall ───────────────────────────────────────────────

SERVICE_NAME="fitness-app-watch"
SERVICE_FILE="$APP_DIR/fitness-app-watch.service"

install_service() {
  if [ ! -f "$SERVICE_FILE" ]; then
    err "Service file not found: $SERVICE_FILE"
    exit 1
  fi

  log "Installing $SERVICE_NAME systemd service..."
  cp "$SERVICE_FILE" "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl start "$SERVICE_NAME"
  log "Service installed and started."
  log "  Status:  systemctl status $SERVICE_NAME"
  log "  Logs:    journalctl -u $SERVICE_NAME -f"
  log "  Stop:    systemctl stop $SERVICE_NAME"
}

uninstall_service() {
  log "Uninstalling $SERVICE_NAME systemd service..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  log "Service uninstalled."
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    --watch)
      watch_and_reload "${2:-60}"
      ;;
    --install)
      install_service
      ;;
    --uninstall)
      uninstall_service
      ;;
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
