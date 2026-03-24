"""add_draft_columns_to_exercise_sets

Revision ID: 27ac2eea39cc
Revises: 10ada4009d15
Create Date: 2026-03-24
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = '27ac2eea39cc'
down_revision: Union[str, Sequence[str], None] = '10ada4009d15'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.add_column(sa.Column('draft_weight_kg', sa.Float(), nullable=True))
        batch_op.add_column(sa.Column('draft_reps', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('draft_reps_left', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('draft_reps_right', sa.Integer(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.drop_column('draft_reps_right')
        batch_op.drop_column('draft_reps_left')
        batch_op.drop_column('draft_reps')
        batch_op.drop_column('draft_weight_kg')
