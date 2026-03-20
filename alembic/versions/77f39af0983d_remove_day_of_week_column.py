"""remove_day_of_week_column

Revision ID: 77f39af0983d
Revises: ba352aa05e2d
Create Date: 2026-03-20 12:53:53.861107

"""
from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = '77f39af0983d'
down_revision: Union[str, Sequence[str], None] = 'ba352aa05e2d'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Drop the deprecated day_of_week column from workout_plans.

    Uses raw DDL instead of batch_alter_table to avoid SQLite's restriction
    on non-constant DEFAULT expressions when the table is recreated.
    SQLite 3.35.0+ supports DROP COLUMN directly.
    """
    op.execute("ALTER TABLE workout_plans DROP COLUMN day_of_week")


def downgrade() -> None:
    """Re-add day_of_week column (nullable so existing rows are unaffected)."""
    op.execute("ALTER TABLE workout_plans ADD COLUMN day_of_week VARCHAR(10)")
