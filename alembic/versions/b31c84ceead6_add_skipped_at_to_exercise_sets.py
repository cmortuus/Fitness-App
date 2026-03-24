"""add_skipped_at_to_exercise_sets

Revision ID: b31c84ceead6
Revises: 27ac2eea39cc
Create Date: 2026-03-24
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'b31c84ceead6'
down_revision: Union[str, Sequence[str], None] = '27ac2eea39cc'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.add_column(sa.Column('skipped_at', sa.DateTime(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.drop_column('skipped_at')
