#!/usr/bin/env bash
# Build Docker images locally (faster than building on the VPS) and deploy.
#
# Usage:
#   ./deploy-local.sh              # Build and deploy both main and dev
#   ./deploy-local.sh main         # Build and deploy main only
#   ./deploy-local.sh dev          # Build and deploy dev only
#
# Prerequisites:
#   - Docker Desktop with buildx (comes by default)
#   - SSH access to the server: ssh root@lethal.dev
#   - Server has Docker + docker compose installed

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SERVER="root@lethal.dev"
SERVER_DIR="/etc/Fitness-App"
REGISTRY_TAG="gymtracker"
PLATFORM="linux/amd64"     # Vultr VPS is x86_64

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[local-deploy] $*"; }
err()  { echo "[error] $*" >&2; }
elapsed() {
  local t=$1
  printf "%dm%02ds" $((t / 60)) $((t % 60))
}

# ── Parse args ────────────────────────────────────────────────────────────────
TARGET="${1:-all}"
if [[ "$TARGET" != "all" && "$TARGET" != "main" && "$TARGET" != "dev" ]]; then
  err "Usage: $0 [all|main|dev]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Verify SSH ────────────────────────────────────────────────────────────────
log "Verifying SSH access..."
if ! ssh -o ConnectTimeout=5 "$SERVER" "echo ok" &>/dev/null; then
  err "Cannot SSH to $SERVER. Check your SSH config."
  exit 1
fi

# ── Build images locally ──────────────────────────────────────────────────────
build_image() {
  local branch="$1"
  local tag="${REGISTRY_TAG}-${branch}"
  local start_time=$SECONDS

  log "Building $tag for $PLATFORM..."

  # Checkout the right branch code into a temp dir
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  git archive "origin/$branch" | tar -x -C "$tmpdir"

  docker buildx build \
    --platform "$PLATFORM" \
    --tag "$tag:latest" \
    --load \
    "$tmpdir"

  local duration=$((SECONDS - start_time))
  log "Built $tag in $(elapsed $duration)"
}

# ── Transfer image to server ─────────────────────────────────────────────────
transfer_image() {
  local branch="$1"
  local tag="${REGISTRY_TAG}-${branch}"
  local start_time=$SECONDS

  log "Saving and transferring $tag to server..."

  # Save image, compress, pipe over SSH, load on server
  docker save "$tag:latest" | gzip | \
    ssh "$SERVER" "docker load"

  local duration=$((SECONDS - start_time))
  log "Transferred $tag in $(elapsed $duration)"
}

# ── Update server ────────────────────────────────────────────────────────────
update_server() {
  local branch="$1"
  local tag="${REGISTRY_TAG}-${branch}"

  log "Updating $branch container on server..."

  ssh "$SERVER" bash -s "$branch" "$tag" <<'REMOTE_SCRIPT'
    branch="$1"
    tag="$2"
    cd /etc/Fitness-App

    # Update docker-compose to use our pre-built image
    # Tag the loaded image to match what compose expects
    docker tag "$tag:latest" "fitness-app-${branch}:latest"

    # Restart just this service
    docker compose up -d --no-build "$branch"

    echo "[server] $branch container updated and running"
REMOTE_SCRIPT
}

# ── Main ──────────────────────────────────────────────────────────────────────
total_start=$SECONDS

if [[ "$TARGET" == "all" || "$TARGET" == "main" ]]; then
  build_image main
  transfer_image main
  update_server main
fi

if [[ "$TARGET" == "all" || "$TARGET" == "dev" ]]; then
  build_image dev
  transfer_image dev
  update_server dev
fi

# Health check
log "Running health check..."
sleep 3
if ssh "$SERVER" "curl -sf http://localhost/ > /dev/null 2>&1"; then
  log "Health check passed"
else
  log "Health check failed — check server logs: ssh $SERVER 'docker compose -C $SERVER_DIR logs'"
fi

total_duration=$((SECONDS - total_start))
log "Deploy complete in $(elapsed $total_duration)"
