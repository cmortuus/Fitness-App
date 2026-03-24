"""add is_draft to workout_plans

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-03-24
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'e5f6a7b8c9d0'
down_revision: Union[str, Sequence[str], None] = 'd4e5f6a7b8c9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()
    cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(workout_plans)")).fetchall()]
    if 'is_draft' not in cols:
        with op.batch_alter_table('workout_plans', schema=None) as batch_op:
            batch_op.add_column(sa.Column('is_draft', sa.Boolean(), nullable=True, server_default='0'))
        # Set all existing plans to not-draft
        conn.execute(sa.text("UPDATE workout_plans SET is_draft = 0 WHERE is_draft IS NULL"))


def downgrade() -> None:
    with op.batch_alter_table('workout_plans', schema=None) as batch_op:
        batch_op.drop_column('is_draft')
