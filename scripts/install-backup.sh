#!/bin/bash
#
# install-backup.sh — install & enable the nightly DB backup.
#
# Prerequisites (ensure these are installed on the host first):
#   - b2 CLI (pipx install b2 OR apt install backblaze-b2)
#   - jq
#   - curl
#   - docker compose (already present)
#
# Before running, create /etc/Fitness-App/.backup-env with:
#   B2_APPLICATION_KEY_ID=...
#   B2_APPLICATION_KEY=...
#   B2_BUCKET=onyx-db-backups
#   HEALTHCHECKS_URL=https://hc-ping.com/<uuid>
#
# Then: sudo bash scripts/install-backup.sh

set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0"
  exit 1
fi

APP_DIR="${APP_DIR:-/etc/Fitness-App}"
SCRIPTS_DIR="${APP_DIR}/scripts"

# ── Sanity checks ────────────────────────────────────────────────────────────
command -v b2   >/dev/null 2>&1 || { echo "b2 CLI not installed. pipx install b2"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "jq not installed. apt install jq"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not installed"; exit 1; }

if [ ! -f "${APP_DIR}/.backup-env" ]; then
  cat <<HINT
Missing ${APP_DIR}/.backup-env

Create it (mode 600) with:
  B2_APPLICATION_KEY_ID=...
  B2_APPLICATION_KEY=...
  B2_BUCKET=onyx-db-backups
  HEALTHCHECKS_URL=https://hc-ping.com/<uuid>

Then re-run this script.
HINT
  exit 1
fi

# Lock down the env file
chmod 600 "${APP_DIR}/.backup-env"

# ── Sanity-check the backup env ──────────────────────────────────────────────
# shellcheck source=/dev/null
source "${APP_DIR}/.backup-env"
: "${B2_APPLICATION_KEY_ID:?missing in .backup-env}"
: "${B2_APPLICATION_KEY:?missing in .backup-env}"
: "${B2_BUCKET:?missing in .backup-env}"
: "${HEALTHCHECKS_URL:?missing in .backup-env}"

# ── Install systemd units ────────────────────────────────────────────────────
echo "Installing systemd units..."
install -m 644 "${SCRIPTS_DIR}/onyx-backup.service" /etc/systemd/system/onyx-backup.service
install -m 644 "${SCRIPTS_DIR}/onyx-backup.timer"   /etc/systemd/system/onyx-backup.timer

# Make sure the script is executable
chmod +x "${SCRIPTS_DIR}/backup-db.sh"

systemctl daemon-reload
systemctl enable --now onyx-backup.timer

echo
echo "Backup timer installed."
echo "  Next run:     systemctl list-timers onyx-backup.timer"
echo "  Trigger now:  sudo systemctl start onyx-backup.service"
echo "  Logs:         journalctl -u onyx-backup.service -e"
