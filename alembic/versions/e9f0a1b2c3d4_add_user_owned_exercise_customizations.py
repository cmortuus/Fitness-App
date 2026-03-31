"""add user-owned exercise customizations

Revision ID: e9f0a1b2c3d4
Revises: b1c2d3e4f5g6
Create Date: 2026-03-31
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'e9f0a1b2c3d4'
down_revision: Union[str, Sequence[str], None] = 'b1c2d3e4f5g6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('exercises', schema=None) as batch_op:
        batch_op.add_column(sa.Column('user_id', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('source_exercise_id', sa.Integer(), nullable=True))
        batch_op.create_foreign_key('fk_exercises_user_id_users', 'users', ['user_id'], ['id'])
        batch_op.create_foreign_key('fk_exercises_source_exercise_id', 'exercises', ['source_exercise_id'], ['id'])


def downgrade() -> None:
    with op.batch_alter_table('exercises', schema=None) as batch_op:
        batch_op.drop_constraint('fk_exercises_source_exercise_id', type_='foreignkey')
        batch_op.drop_constraint('fk_exercises_user_id_users', type_='foreignkey')
        batch_op.drop_column('source_exercise_id')
        batch_op.drop_column('user_id')
