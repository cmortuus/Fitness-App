"""add_indexes

Add indexes on frequently-queried columns for exercise_sets and
workout_sessions to avoid full-table scans as data grows.

Revision ID: d4f7a1b2c3e8
Revises: c5e8f3a91d2b
Create Date: 2026-03-20 14:00:00.000000

"""
from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'd4f7a1b2c3e8'
down_revision: Union[str, Sequence[str], None] = 'c5e8f3a91d2b'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Add missing indexes for performance-critical foreign keys and filter columns."""
    op.create_index("ix_exercise_sets_session",  "exercise_sets",     ["workout_session_id"])
    op.create_index("ix_exercise_sets_exercise", "exercise_sets",     ["exercise_id"])
    op.create_index("ix_workout_sessions_date",  "workout_sessions",  ["date"])
    op.create_index("ix_workout_sessions_status","workout_sessions",  ["status"])
    op.create_index("ix_workout_sessions_plan",  "workout_sessions",  ["workout_plan_id"])


def downgrade() -> None:
    """Drop indexes."""
    op.drop_index("ix_exercise_sets_session",  table_name="exercise_sets")
    op.drop_index("ix_exercise_sets_exercise", table_name="exercise_sets")
    op.drop_index("ix_workout_sessions_date",  table_name="workout_sessions")
    op.drop_index("ix_workout_sessions_status",table_name="workout_sessions")
    op.drop_index("ix_workout_sessions_plan",  table_name="workout_sessions")
