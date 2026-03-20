#!/usr/bin/env python3
"""Standalone seed script — populates the exercise library without starting the server.

Usage (from the project root with venv active):
    python scripts/seed_exercises.py

This is safe to run on a DB that already has exercises; duplicates are
skipped automatically.  The Alembic migrations must have been applied first:
    alembic upgrade head
"""

import asyncio
import sys
from pathlib import Path

# Ensure the project root is on sys.path so app.* imports work.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.database import seed_exercises  # noqa: E402


async def main() -> None:
    print("Seeding exercise library…")
    await seed_exercises()


if __name__ == "__main__":
    asyncio.run(main())
