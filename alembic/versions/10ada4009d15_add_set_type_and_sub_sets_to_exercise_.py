"""add_set_type_and_sub_sets_to_exercise_sets

Revision ID: 10ada4009d15
Revises: f0b873e7c9f3
Create Date: 2026-03-24
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = '10ada4009d15'
down_revision: Union[str, Sequence[str], None] = 'f0b873e7c9f3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.add_column(sa.Column('set_type', sa.String(20), nullable=False, server_default='standard'))
        batch_op.add_column(sa.Column('sub_sets', sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.drop_column('sub_sets')
        batch_op.drop_column('set_type')
