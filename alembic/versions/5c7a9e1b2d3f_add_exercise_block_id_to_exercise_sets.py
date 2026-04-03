"""add exercise_block_id to exercise sets

Revision ID: 5c7a9e1b2d3f
Revises: 2b4c6d8e0f1a
Create Date: 2026-04-03
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "5c7a9e1b2d3f"
down_revision: str | None = "g1h2i3j4k5l6"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Use IF NOT EXISTS so the migration is safe to run even if the column
    # was added manually during an emergency hotfix.
    op.execute(
        "ALTER TABLE exercise_sets ADD COLUMN IF NOT EXISTS exercise_block_id VARCHAR(36)"
    )


def downgrade() -> None:
    with op.batch_alter_table("exercise_sets", schema=None) as batch_op:
        batch_op.drop_column("exercise_block_id")
