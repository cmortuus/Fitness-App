"""add water_entries table and water_goal_ml to macro_goals

Revision ID: 7dc59e708258
Revises: 1ee0785d6870
Create Date: 2026-03-27 19:41:12.341147

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '7dc59e708258'
down_revision: Union[str, Sequence[str], None] = '1ee0785d6870'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'water_entries',
        sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('date', sa.Date(), nullable=False),
        sa.Column('amount_ml', sa.Float(), nullable=False),
        sa.Column('logged_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    with op.batch_alter_table('water_entries') as batch_op:
        batch_op.create_index('ix_water_entries_date', ['date'], unique=False)

    with op.batch_alter_table('macro_goals') as batch_op:
        batch_op.add_column(sa.Column('water_goal_ml', sa.Float(), nullable=False, server_default='2500'))


def downgrade() -> None:
    with op.batch_alter_table('macro_goals') as batch_op:
        batch_op.drop_column('water_goal_ml')

    with op.batch_alter_table('water_entries') as batch_op:
        batch_op.drop_index('ix_water_entries_date')

    op.drop_table('water_entries')
