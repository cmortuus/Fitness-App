#!/bin/bash
#
# backup-db.sh — Nightly Postgres backup to Backblaze B2
#
# Runs `pg_dump` inside the db container, compresses with gzip, uploads
# to B2, and pings healthchecks.io.  Exits nonzero on any failure so
# systemd + healthchecks can alert.
#
# Required env (from /etc/Fitness-App/.backup-env or service EnvironmentFile):
#   B2_APPLICATION_KEY_ID       — Backblaze B2 key ID
#   B2_APPLICATION_KEY          — Backblaze B2 application key
#   B2_BUCKET                   — e.g. "onyx-db-backups"
#   HEALTHCHECKS_URL            — https://hc-ping.com/<uuid>
#
# Optional:
#   COMPOSE_DIR                 — directory with docker-compose.yml (default /etc/Fitness-App)
#   DB_SERVICE                  — compose service name of Postgres (default db)
#   DB_NAME                     — Postgres database name (default homegym)
#   DB_USER                     — Postgres user (default homegym)
#   RETENTION_DAYS              — delete remote backups older than N days (default 30)
#
# Retention uses b2's lifecycle rules when possible; this script also
# prunes as a belt-and-suspenders check.

set -euo pipefail

# ── Required env ─────────────────────────────────────────────────────────────
: "${B2_APPLICATION_KEY_ID:?B2_APPLICATION_KEY_ID must be set}"
: "${B2_APPLICATION_KEY:?B2_APPLICATION_KEY must be set}"
: "${B2_BUCKET:?B2_BUCKET must be set}"
: "${HEALTHCHECKS_URL:?HEALTHCHECKS_URL must be set}"

# ── Defaults ─────────────────────────────────────────────────────────────────
COMPOSE_DIR="${COMPOSE_DIR:-/etc/Fitness-App}"
DB_SERVICE="${DB_SERVICE:-db}"
DB_NAME="${DB_NAME:-homegym}"
DB_USER="${DB_USER:-homegym}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_NAME="onyx-${DB_NAME}-${TIMESTAMP}.sql.gz"
TMP_DIR="$(mktemp -d)"
BACKUP_PATH="${TMP_DIR}/${BACKUP_NAME}"
trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "[backup $(date -u +%H:%M:%S)] $*"; }

# ── Ping healthchecks: start ─────────────────────────────────────────────────
curl -fsS --retry 3 -m 10 -o /dev/null "${HEALTHCHECKS_URL}/start" || true

# ── Dump ─────────────────────────────────────────────────────────────────────
log "Dumping database ${DB_NAME} from service ${DB_SERVICE}..."
cd "$COMPOSE_DIR"
docker compose exec -T "$DB_SERVICE" pg_dump -U "$DB_USER" -d "$DB_NAME" \
  --no-owner --no-privileges --format=plain \
  | gzip -9 > "$BACKUP_PATH"

SIZE_BYTES=$(stat -c %s "$BACKUP_PATH" 2>/dev/null || stat -f %z "$BACKUP_PATH")
log "Dump complete: ${SIZE_BYTES} bytes"

# Sanity: an empty dump is a failure (smallest sane dump is ~1KB)
if [ "$SIZE_BYTES" -lt 1024 ]; then
  log "ERROR: dump is suspiciously small (${SIZE_BYTES} bytes)"
  curl -fsS --retry 3 -m 10 -o /dev/null "${HEALTHCHECKS_URL}/fail" || true
  exit 1
fi

# ── Upload ───────────────────────────────────────────────────────────────────
log "Authorizing with B2..."
export B2_APPLICATION_KEY_ID B2_APPLICATION_KEY
# `b2` is the Backblaze B2 CLI; install via pipx install b2 or apt
b2 account authorize "$B2_APPLICATION_KEY_ID" "$B2_APPLICATION_KEY" >/dev/null

log "Uploading to b2://${B2_BUCKET}/${BACKUP_NAME}..."
b2 file upload --no-progress --quiet "$B2_BUCKET" "$BACKUP_PATH" "$BACKUP_NAME"

log "Upload complete."

# ── Retention prune ──────────────────────────────────────────────────────────
# Delete remote files older than RETENTION_DAYS.  Uses JSON listing + jq.
if command -v jq >/dev/null 2>&1; then
  log "Pruning backups older than ${RETENTION_DAYS} days..."
  CUTOFF_EPOCH_MS=$(( ( $(date -u +%s) - RETENTION_DAYS * 86400 ) * 1000 ))
  # b2 ls returns JSON with --json flag
  b2 ls --json "$B2_BUCKET" \
    | jq -r --argjson cutoff "$CUTOFF_EPOCH_MS" \
        '.[] | select(.uploadTimestamp < $cutoff) | "\(.fileId) \(.fileName)"' \
    | while read -r file_id file_name; do
        [ -z "$file_id" ] && continue
        log "  deleting ${file_name}"
        b2 file delete "$file_id" >/dev/null || true
      done
else
  log "jq not installed; skipping retention prune (configure B2 lifecycle rules instead)"
fi

# ── Ping healthchecks: success ───────────────────────────────────────────────
curl -fsS --retry 3 -m 10 -o /dev/null "$HEALTHCHECKS_URL" || true
log "Done."
