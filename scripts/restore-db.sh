#!/bin/bash
#
# restore-db.sh — dry-run restore of the most recent B2 backup to a
# scratch database, verify row counts, drop the scratch DB.
#
# Use this as a recurring sanity check (weekly?) AND during the 48h
# burn-in to prove the backups are actually loadable.
#
# Usage: sudo bash scripts/restore-db.sh
#
# Required env (same as backup-db.sh, from /etc/Fitness-App/.backup-env):
#   B2_APPLICATION_KEY_ID, B2_APPLICATION_KEY, B2_BUCKET
# Optional:
#   COMPOSE_DIR (default /etc/Fitness-App)
#   DB_SERVICE (default db)
#   DB_USER (default homegym)
#   SOURCE_DB (default homegym) — DB we compare against
#   SCRATCH_DB (default homegym_restore_check)

set -euo pipefail

: "${B2_APPLICATION_KEY_ID:?}"
: "${B2_APPLICATION_KEY:?}"
: "${B2_BUCKET:?}"

COMPOSE_DIR="${COMPOSE_DIR:-/etc/Fitness-App}"
DB_SERVICE="${DB_SERVICE:-db}"
DB_USER="${DB_USER:-homegym}"
SOURCE_DB="${SOURCE_DB:-homegym}"
SCRATCH_DB="${SCRATCH_DB:-homegym_restore_check}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "[restore $(date -u +%H:%M:%S)] $*"; }

# ── Find the most recent backup on B2 ───────────────────────────────────────
log "Locating most recent backup in b2://${B2_BUCKET}..."
b2 account authorize "$B2_APPLICATION_KEY_ID" "$B2_APPLICATION_KEY" >/dev/null

LATEST_FILE=$(b2 ls --json "$B2_BUCKET" \
  | jq -r 'sort_by(.uploadTimestamp) | reverse | .[0].fileName')
if [ -z "$LATEST_FILE" ] || [ "$LATEST_FILE" = "null" ]; then
  log "ERROR: no backups found in bucket"
  exit 1
fi

log "Latest backup: $LATEST_FILE"

# ── Download and decompress ─────────────────────────────────────────────────
LOCAL_GZ="${TMP_DIR}/${LATEST_FILE}"
LOCAL_SQL="${LOCAL_GZ%.gz}"
b2 file download --no-progress "b2://${B2_BUCKET}/${LATEST_FILE}" "$LOCAL_GZ"
gunzip -f "$LOCAL_GZ"
log "Decompressed to ${LOCAL_SQL}"

# ── Restore into scratch DB ─────────────────────────────────────────────────
cd "$COMPOSE_DIR"
log "Creating scratch DB ${SCRATCH_DB}..."
docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS ${SCRATCH_DB};" >/dev/null
docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -c "CREATE DATABASE ${SCRATCH_DB};" >/dev/null

log "Restoring dump..."
docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d "$SCRATCH_DB" < "$LOCAL_SQL" >/dev/null

# ── Compare row counts ──────────────────────────────────────────────────────
TABLES=(users workout_sessions exercise_sets workout_plans exercises)
all_ok=1
for t in "${TABLES[@]}"; do
  src=$(docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d "$SOURCE_DB" -tAc "SELECT COUNT(*) FROM ${t};" 2>/dev/null || echo "?")
  dst=$(docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d "$SCRATCH_DB" -tAc "SELECT COUNT(*) FROM ${t};" 2>/dev/null || echo "?")
  printf "  %-20s source=%s  restored=%s" "$t" "$src" "$dst"
  # Allow restored to be <= source (source may have newer rows than the backup)
  if [ "$src" = "?" ] || [ "$dst" = "?" ] || [ "$dst" -gt "$src" ]; then
    echo "  ✗"
    all_ok=0
  else
    echo "  ✓"
  fi
done

# ── Cleanup scratch DB ──────────────────────────────────────────────────────
log "Dropping scratch DB..."
docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -c "DROP DATABASE ${SCRATCH_DB};" >/dev/null

if [ "$all_ok" = "1" ]; then
  log "Restore dry-run SUCCESS"
  exit 0
else
  log "Restore dry-run FAILED — row counts mismatched or tables missing"
  exit 1
fi
