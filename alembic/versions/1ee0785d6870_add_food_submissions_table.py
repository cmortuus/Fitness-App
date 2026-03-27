"""add_food_submissions_table

Revision ID: 1ee0785d6870
Revises: c4d5e6f7a8b9
Create Date: 2026-03-27 13:30:36.124055

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '1ee0785d6870'
down_revision: Union[str, Sequence[str], None] = 'c4d5e6f7a8b9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        'food_submissions',
        sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
        sa.Column('food_item_id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('calories_per_100g', sa.Float(), nullable=True),
        sa.Column('protein_per_100g', sa.Float(), nullable=True),
        sa.Column('carbs_per_100g', sa.Float(), nullable=True),
        sa.Column('fat_per_100g', sa.Float(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['food_item_id'], ['food_items.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('food_item_id', 'user_id', name='uq_food_submission'),
    )
    with op.batch_alter_table('food_submissions', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_food_submissions_food_item_id'), ['food_item_id'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    with op.batch_alter_table('food_submissions', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_food_submissions_food_item_id'))
    op.drop_table('food_submissions')
