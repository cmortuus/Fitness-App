"""add prime machine peg support

Revision ID: a1b2c3d4e5f6
Revises: ff3a81b4c9d7
Create Date: 2026-03-31
"""
from alembic import op
import sqlalchemy as sa

revision = "a1b2c3d4e5f6"
down_revision = None  # standalone; handled by ensure_columns pattern
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("exercises",
        sa.Column("is_prime", sa.Boolean(), nullable=False, server_default="false"))
    op.add_column("exercise_sets",
        sa.Column("peg_weights", sa.Text(), nullable=True))

    # Mark existing Prime exercises
    op.execute(
        "UPDATE exercises SET is_prime = true "
        "WHERE (name LIKE '%prime%') AND equipment_type = 'plate_loaded'"
    )


def downgrade() -> None:
    op.drop_column("exercise_sets", "peg_weights")
    op.drop_column("exercises", "is_prime")
