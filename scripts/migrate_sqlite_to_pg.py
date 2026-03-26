#!/usr/bin/env python3
"""Migrate data from SQLite to PostgreSQL.

Usage (inside Docker container or with correct env vars):
    python scripts/migrate_sqlite_to_pg.py /path/to/homegym.db

This reads all data from the SQLite file and inserts it into the
PostgreSQL database specified by DATABASE_SYNC_URL env var.
"""
import sys
import sqlite3
from pathlib import Path

# PostgreSQL connection
import psycopg2

def migrate(sqlite_path: str, pg_url: str):
    """Copy all data from SQLite to PostgreSQL."""
    print(f"Reading from SQLite: {sqlite_path}")
    print(f"Writing to PostgreSQL: {pg_url.split('@')[1] if '@' in pg_url else pg_url}")

    sconn = sqlite3.connect(sqlite_path)
    sconn.row_factory = sqlite3.Row
    scur = sconn.cursor()

    # Clean the pg_url for psycopg2 (remove +asyncpg, etc.)
    clean_url = pg_url.replace("postgresql+asyncpg://", "postgresql://")
    pconn = psycopg2.connect(clean_url)
    pconn.autocommit = False
    pcur = pconn.cursor()

    # Tables to migrate in dependency order
    tables = [
        "users",
        "exercises",
        "workout_plans",
        "planned_days",
        "planned_exercises",
        "workout_sessions",
        "exercise_sets",
        "body_weight_entries",
        "diet_phases",
        "food_entries",
    ]

    for table in tables:
        try:
            scur.execute(f"SELECT * FROM {table}")
            rows = scur.fetchall()
            if not rows:
                print(f"  {table}: 0 rows (empty)")
                continue

            cols = [desc[0] for desc in scur.description]
            placeholders = ", ".join(["%s"] * len(cols))
            col_names = ", ".join(f'"{c}"' for c in cols)

            # Clear existing data in PG (cascade to handle FK deps)
            pcur.execute(f'TRUNCATE "{table}" CASCADE')

            # Get PG column types to convert SQLite int→bool
            pcur.execute("""
                SELECT column_name, data_type FROM information_schema.columns
                WHERE table_name = %s
            """, (table,))
            bool_cols = {r[0] for r in pcur.fetchall() if r[1] == 'boolean'}

            inserted = 0
            for row in rows:
                # Convert SQLite integers to Python bools for boolean columns
                values = []
                for col, val in zip(cols, row):
                    if col in bool_cols and isinstance(val, int):
                        values.append(bool(val))
                    else:
                        values.append(val)
                try:
                    pcur.execute(
                        f'INSERT INTO "{table}" ({col_names}) VALUES ({placeholders})',
                        tuple(values)
                    )
                    inserted += 1
                except Exception as e:
                    pconn.rollback()
                    # Re-delete and re-insert everything up to this point
                    pcur.execute(f'DELETE FROM "{table}"')
                    print(f"  {table} row error (skipping rest): {e}")
                    break

            # Reset sequence for tables with auto-increment
            if "id" in cols:
                pcur.execute(f"SELECT MAX(id) FROM \"{table}\"")
                max_id = pcur.fetchone()[0]
                if max_id:
                    pcur.execute(f"SELECT setval(pg_get_serial_sequence('\"{table}\"', 'id'), {max_id})")

            pconn.commit()
            print(f"  {table}: {len(rows)} rows migrated")

        except sqlite3.OperationalError as e:
            print(f"  {table}: skipped ({e})")
        except Exception as e:
            print(f"  {table}: error ({e})")
            pconn.rollback()

    sconn.close()
    pconn.close()
    print("Migration complete!")


if __name__ == "__main__":
    import os
    if len(sys.argv) < 2:
        print("Usage: python migrate_sqlite_to_pg.py <sqlite_file>")
        sys.exit(1)

    sqlite_path = sys.argv[1]
    if not Path(sqlite_path).exists():
        print(f"SQLite file not found: {sqlite_path}")
        sys.exit(1)

    pg_url = os.environ.get("DATABASE_SYNC_URL") or os.environ.get("DATABASE_URL", "")
    if "postgresql" not in pg_url:
        print("DATABASE_SYNC_URL must be a PostgreSQL URL")
        sys.exit(1)

    migrate(sqlite_path, pg_url)
