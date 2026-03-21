"""add_planned_reps_left_right_to_exercise_set

Revision ID: 826341152d35
Revises: 86f35b8cc8b6
Create Date: 2026-03-20

"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = '826341152d35'
down_revision: Union[str, Sequence[str], None] = '86f35b8cc8b6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.add_column(sa.Column('planned_reps_left', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('planned_reps_right', sa.Integer(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.drop_column('planned_reps_right')
        batch_op.drop_column('planned_reps_left')
