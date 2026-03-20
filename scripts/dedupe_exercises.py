"""Deduplicate exercises in the database."""

import os
from pathlib import Path
from sqlalchemy import create_engine, select, func, delete, update
from sqlalchemy.orm import Session

# Use sync engine and absolute path
PROJECT_ROOT = Path(__file__).parent.parent
DB_PATH = PROJECT_ROOT / "homegym.db"
engine = create_engine(f"sqlite:///{DB_PATH}")

# Import models after engine is defined
import sys
sys.path.insert(0, str(PROJECT_ROOT))
from app.models.exercise import Exercise
from app.models.workout import ExerciseSet


def dedupe_exercises():
    """Remove duplicate exercises, keeping the most meaningful variant."""

    with Session(engine) as session:
        # Get all exercises
        result = session.execute(select(Exercise).order_by(Exercise.id))
        exercises = result.scalars().all()

        # Group by normalized name
        from collections import defaultdict
        groups = defaultdict(list)
        for ex in exercises:
            # Normalize: lowercase, replace spaces/hyphens with underscores
            normalized = ex.display_name.lower().replace(' ', '_').replace('-', '_')
            groups[normalized].append(ex)

        # Find duplicates
        duplicates = {k: v for k, v in groups.items() if len(v) > 1}

        print(f'Total exercises: {len(exercises)}')
        print(f'Duplicate groups: {len(duplicates)}')
        print(f'Exercises to remove: {sum(len(v) - 1 for v in duplicates.values())}')

        removed_count = 0

        for name, exs in duplicates.items():
            # Sort by ID (keep oldest entry as primary)
            exs_sorted = sorted(exs, key=lambda x: x.id)

            # Keep the first one (lowest ID - original import)
            keeper = exs_sorted[0]

            for ex in exs_sorted[1:]:
                print(f'Removing: {ex.display_name} (id={ex.id}) - keeping {keeper.display_name} (id={keeper.id})')
                removed_count += 1

                # Update any sets referencing this exercise to point to keeper
                session.execute(
                    update(ExerciseSet)
                    .where(ExerciseSet.exercise_id == ex.id)
                    .values(exercise_id=keeper.id)
                )

                # Delete the duplicate exercise
                session.execute(delete(Exercise).where(Exercise.id == ex.id))

        session.commit()

        print(f'\n✅ Removed {removed_count} duplicate exercises')

        # Verify
        result = session.execute(select(func.count(Exercise.id)))
        new_count = result.scalar()
        print(f'Remaining exercises: {new_count}')


if __name__ == '__main__':
    dedupe_exercises()
