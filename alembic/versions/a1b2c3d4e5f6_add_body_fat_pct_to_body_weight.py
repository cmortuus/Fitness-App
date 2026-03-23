"""add body_fat_pct to body_weight_entries

Revision ID: a1b2c3d4e5f6
Revises: 3fa836442cfd
Create Date: 2026-03-23
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'a1b2c3d4e5f6'
down_revision: Union[str, Sequence[str], None] = '3fa836442cfd'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('body_weight_entries', schema=None) as batch_op:
        batch_op.add_column(sa.Column('body_fat_pct', sa.Float(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('body_weight_entries', schema=None) as batch_op:
        batch_op.drop_column('body_fat_pct')
