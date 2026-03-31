#!/usr/bin/env python3
"""
Fix workout plan exercise IDs after SQLite→PG migration + re-seed caused ID mismatch.

Plans stored SQLite exercise IDs. After the exercises table was re-seeded in PG,
those IDs now point to different exercises. This script remaps them using name lookup:
  SQLite ID → SQLite exercise name → PostgreSQL ID (by name)

Run on the server:
  DATABASE_SYNC_URL=<pg_url> python scripts/fix_plan_exercise_ids.py /path/to/homegym.db
"""
import json
import os
import sqlite3
import sys
import psycopg2


def fix(sqlite_path: str, pg_url: str, dry_run: bool = False):
    sconn = sqlite3.connect(sqlite_path)
    sconn.row_factory = sqlite3.Row
    scur = sconn.cursor()

    clean_url = pg_url.replace("postgresql+asyncpg://", "postgresql://")
    pconn = psycopg2.connect(clean_url)
    pcur = pconn.cursor()

    # Build lookup: sqlite_id → name
    scur.execute("SELECT id, name FROM exercises")
    sqlite_id_to_name = {row["id"]: row["name"] for row in scur.fetchall()}

    # Build lookup: name → pg_id
    pcur.execute("SELECT id, name FROM exercises")
    pg_name_to_id = {row[1]: row[0] for row in pcur.fetchall()}

    print(f"SQLite exercises: {len(sqlite_id_to_name)}")
    print(f"PG exercises:     {len(pg_name_to_id)}")

    # Fetch all plans
    pcur.execute("SELECT id, name, planned_exercises FROM workout_plans")
    plans = pcur.fetchall()
    print(f"\nPlans to check: {len(plans)}\n")

    total_remapped = 0
    total_missing = 0

    for plan_id, plan_name, planned_json in plans:
        if not planned_json:
            continue

        try:
            data = json.loads(planned_json) if isinstance(planned_json, str) else planned_json
        except Exception:
            print(f"  Plan {plan_id} '{plan_name}': invalid JSON, skipping")
            continue

        days = data.get("days", [])
        if not days:
            continue

        changed = False
        remapped = []
        missing = []

        for day in days:
            if not day:
                continue
            for ex in day.get("exercises", []):
                old_id = ex.get("exercise_id")
                if old_id is None:
                    continue

                # What name does PG currently have at this ID?
                pcur.execute("SELECT name FROM exercises WHERE id = %s", (old_id,))
                row = pcur.fetchone()
                pg_current_name = row[0] if row else None

                # What name did SQLite have at this ID?
                sqlite_name = sqlite_id_to_name.get(old_id)

                if sqlite_name is None:
                    # ID doesn't exist in SQLite — was a PG-native exercise
                    if pg_current_name is None:
                        missing.append(old_id)
                        total_missing += 1
                    # else: ID exists in PG, keep it
                    continue

                if pg_current_name == sqlite_name:
                    # Same name in both — no remap needed
                    continue

                # Different name — remap to correct PG ID
                new_id = pg_name_to_id.get(sqlite_name)
                if new_id is None:
                    print(f"    ⚠ '{sqlite_name}' (sqlite id {old_id}) not found in PG — skipping")
                    missing.append(old_id)
                    total_missing += 1
                    continue

                ex["exercise_id"] = new_id
                changed = True
                remapped.append(f"{old_id}({pg_current_name or '?'}) → {new_id}({sqlite_name})")
                total_remapped += 1

        if remapped:
            print(f"Plan {plan_id} '{plan_name}': {len(remapped)} remapped")
            for r in remapped:
                print(f"    {r}")

        if missing:
            print(f"Plan {plan_id} '{plan_name}': {len(missing)} IDs not resolvable: {missing}")

        if changed and not dry_run:
            pcur.execute(
                "UPDATE workout_plans SET planned_exercises = %s WHERE id = %s",
                (json.dumps(data), plan_id)
            )

    # Also fix workout_templates
    pcur.execute("SELECT id, name, exercises FROM workout_templates")
    templates = pcur.fetchall()
    print(f"\nTemplates to check: {len(templates)}")

    template_remapped = 0
    for tmpl_id, tmpl_name, tmpl_json in templates:
        if not tmpl_json:
            continue
        try:
            exercises = json.loads(tmpl_json) if isinstance(tmpl_json, str) else tmpl_json
        except Exception:
            continue

        if not isinstance(exercises, list):
            continue

        changed = False
        for ex in exercises:
            old_id = ex.get("exercise_id") or ex.get("id")
            if old_id is None:
                continue
            sqlite_name = sqlite_id_to_name.get(old_id)
            if sqlite_name is None:
                continue
            pcur.execute("SELECT name FROM exercises WHERE id = %s", (old_id,))
            row = pcur.fetchone()
            if row and row[0] == sqlite_name:
                continue
            new_id = pg_name_to_id.get(sqlite_name)
            if new_id:
                ex["exercise_id"] = new_id
                changed = True
                template_remapped += 1

        if changed and not dry_run:
            pcur.execute(
                "UPDATE workout_templates SET exercises = %s WHERE id = %s",
                (json.dumps(exercises), tmpl_id)
            )

    if not dry_run:
        pconn.commit()
        print(f"\n✓ Committed. Plans: {total_remapped} IDs remapped. Templates: {template_remapped} IDs remapped.")
        print(f"  {total_missing} IDs could not be resolved (exercise not in PG).")
    else:
        print(f"\n[DRY RUN] Would remap {total_remapped} plan IDs, {template_remapped} template IDs.")
        print(f"  {total_missing} IDs unresolvable.")

    sconn.close()
    pconn.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python fix_plan_exercise_ids.py <sqlite_file> [--dry-run]")
        sys.exit(1)

    sqlite_path = sys.argv[1]
    dry_run = "--dry-run" in sys.argv

    pg_url = os.environ.get("DATABASE_SYNC_URL") or os.environ.get("DATABASE_URL", "")
    if "postgresql" not in pg_url:
        print("Set DATABASE_SYNC_URL or DATABASE_URL to a PostgreSQL URL")
        sys.exit(1)

    fix(sqlite_path, pg_url, dry_run=dry_run)
