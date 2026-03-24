"""add_micronutrient_json_columns

Revision ID: f0b873e7c9f3
Revises: 684a8290de3b
Create Date: 2026-03-23
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'f0b873e7c9f3'
down_revision: Union[str, Sequence[str], None] = '684a8290de3b'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('food_items', schema=None) as batch_op:
        batch_op.add_column(sa.Column('micronutrients', sa.Text(), nullable=True))

    with op.batch_alter_table('nutrition_entries', schema=None) as batch_op:
        batch_op.add_column(sa.Column('micronutrients', sa.Text(), nullable=True))

    with op.batch_alter_table('macro_goals', schema=None) as batch_op:
        batch_op.add_column(sa.Column('micronutrient_goals', sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('macro_goals', schema=None) as batch_op:
        batch_op.drop_column('micronutrient_goals')

    with op.batch_alter_table('nutrition_entries', schema=None) as batch_op:
        batch_op.drop_column('micronutrients')

    with op.batch_alter_table('food_items', schema=None) as batch_op:
        batch_op.drop_column('micronutrients')
