"""Delete orphaned PLANNED sessions that were never started and have no completed sets.

Run on server:
    docker compose exec app python scripts/cleanup_orphaned_sessions.py
    docker compose exec app python scripts/cleanup_orphaned_sessions.py --dry-run
"""

import argparse
import os
import sys

from sqlalchemy import create_engine, text

DB_URL = os.environ.get(
    "DATABASE_SYNC_URL",
    "postgresql://homegym:homegym_secret@db:5432/homegym",
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Show what would be deleted without deleting")
    args = parser.parse_args()

    engine = create_engine(DB_URL)

    with engine.connect() as conn:
        # Find PLANNED sessions with no started_at and zero completed sets
        rows = conn.execute(text("""
            SELECT ws.id, ws.name, ws.date, ws.status, ws.started_at,
                   COUNT(es.id) AS total_sets,
                   COUNT(es.completed_at) AS completed_sets
            FROM workout_sessions ws
            LEFT JOIN exercise_sets es ON es.workout_session_id = ws.id
            WHERE ws.status = 'planned' AND ws.started_at IS NULL
            GROUP BY ws.id
            HAVING COUNT(es.completed_at) = 0
            ORDER BY ws.id
        """)).fetchall()

        if not rows:
            print("No orphaned sessions found.")
            return

        print(f"Found {len(rows)} orphaned session(s):\n")
        for r in rows:
            print(f"  id={r.id}  name={r.name}  date={r.date}  sets={r.total_sets}")

        if args.dry_run:
            print(f"\nDry run — nothing deleted.")
            return

        ids = [r.id for r in rows]

        # Delete sets first (FK constraint), then sessions
        conn.execute(text(
            "DELETE FROM exercise_sets WHERE workout_session_id = ANY(:ids)"
        ), {"ids": ids})
        result = conn.execute(text(
            "DELETE FROM workout_sessions WHERE id = ANY(:ids)"
        ), {"ids": ids})
        conn.commit()

        print(f"\nDeleted {result.rowcount} orphaned session(s).")


if __name__ == "__main__":
    main()
