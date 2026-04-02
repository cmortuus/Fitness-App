"""add plan_day_number to workout sessions

Revision ID: 2b4c6d8e0f1a
Revises: 1f2e3d4c5b6a
Create Date: 2026-04-02
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2b4c6d8e0f1a"
down_revision: str | None = "1f2e3d4c5b6a"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("workout_sessions", schema=None) as batch_op:
        batch_op.add_column(sa.Column("plan_day_number", sa.Integer(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("workout_sessions", schema=None) as batch_op:
        batch_op.drop_column("plan_day_number")
