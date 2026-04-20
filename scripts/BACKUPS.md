# Nightly Postgres backups → Backblaze B2

Server-side setup only; runs outside Docker on the host.

## One-time setup

1. **Create the B2 bucket**
   - Log in to [Backblaze](https://secure.backblaze.com/user_signin.htm)
   - Buckets → Create Bucket → private → e.g. `onyx-db-backups`
   - App Keys → Add a New Application Key → scope to this bucket, permissions: read + write + delete
   - Copy the `keyID` and `applicationKey` (shown once).

2. **Create a healthchecks.io check**
   - https://healthchecks.io → Add Check → "Onyx DB backup"
   - Schedule: cron `30 3 * * *`, grace 2h
   - Copy the ping URL (looks like `https://hc-ping.com/<uuid>`)

3. **Install the host deps**

    ```bash
    ssh c@your-server
    sudo apt install -y jq curl python3-venv pipx
    pipx install b2
    pipx ensurepath
    ```

4. **Create `/etc/Fitness-App/.backup-env`** (mode 600):

    ```
    B2_APPLICATION_KEY_ID=<keyID>
    B2_APPLICATION_KEY=<applicationKey>
    B2_BUCKET=onyx-db-backups
    HEALTHCHECKS_URL=https://hc-ping.com/<uuid>
    ```

5. **Install the service + timer**

    ```bash
    cd /etc/Fitness-App
    sudo bash scripts/install-backup.sh
    ```

6. **Smoke test** — force one run immediately:

    ```bash
    sudo systemctl start onyx-backup.service
    journalctl -u onyx-backup.service -n 50 --no-pager
    ```

   Confirm the file appears on B2 and healthchecks.io shows green.

## Ongoing

- Logs: `journalctl -u onyx-backup.service -e`
- Timer status: `systemctl list-timers onyx-backup.timer`
- Manual run: `sudo systemctl start onyx-backup.service`
- Weekly sanity: `sudo -E bash scripts/restore-db.sh` (loads latest backup into a scratch DB, compares row counts, drops it)

## Retention

The script deletes remote backups older than 30 days (configurable via `RETENTION_DAYS` in `.backup-env`). You can also set a B2 lifecycle rule for belt + suspenders.

## Files

| File | Purpose |
|---|---|
| `backup-db.sh` | Runs the dump, compresses, uploads to B2, pings healthchecks |
| `restore-db.sh` | Downloads latest backup, restores to scratch DB, verifies row counts |
| `onyx-backup.service` | Systemd oneshot unit running `backup-db.sh` |
| `onyx-backup.timer` | Systemd timer firing `onyx-backup.service` nightly at 03:30 |
| `install-backup.sh` | One-time installer — copies units, enables timer |
