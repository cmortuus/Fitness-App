"""add_nutrition_tables

Revision ID: 3c47c344335e
Revises: 826341152d35
Create Date: 2026-03-20 21:36:08.128435

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '3c47c344335e'
down_revision: Union[str, Sequence[str], None] = '826341152d35'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'food_items',
        sa.Column('id', sa.Integer, primary_key=True, autoincrement=True),
        sa.Column('name', sa.String(200), nullable=False),
        sa.Column('brand', sa.String(200), nullable=True),
        sa.Column('barcode', sa.String(50), nullable=True),
        sa.Column('source', sa.String(20), nullable=False, server_default='custom'),
        sa.Column('source_id', sa.String(100), nullable=True),
        sa.Column('calories_per_100g', sa.Float, nullable=True),
        sa.Column('protein_per_100g', sa.Float, nullable=True),
        sa.Column('carbs_per_100g', sa.Float, nullable=True),
        sa.Column('fat_per_100g', sa.Float, nullable=True),
        sa.Column('serving_size_g', sa.Float, nullable=False, server_default='100'),
        sa.Column('serving_label', sa.String(100), nullable=True),
        sa.Column('is_custom', sa.Boolean, nullable=False, server_default='0'),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index('ix_food_items_barcode', 'food_items', ['barcode'])

    op.create_table(
        'nutrition_entries',
        sa.Column('id', sa.Integer, primary_key=True, autoincrement=True),
        sa.Column('food_item_id', sa.Integer, sa.ForeignKey('food_items.id', ondelete='SET NULL'), nullable=True),
        sa.Column('name', sa.String(200), nullable=False),
        sa.Column('date', sa.Date, nullable=False),
        sa.Column('meal', sa.String(20), nullable=False, server_default='snack'),
        sa.Column('quantity_g', sa.Float, nullable=False),
        sa.Column('calories', sa.Float, nullable=False),
        sa.Column('protein', sa.Float, nullable=False),
        sa.Column('carbs', sa.Float, nullable=False),
        sa.Column('fat', sa.Float, nullable=False),
        sa.Column('logged_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index('ix_nutrition_entries_date', 'nutrition_entries', ['date'])

    op.create_table(
        'macro_goals',
        sa.Column('id', sa.Integer, primary_key=True, autoincrement=True),
        sa.Column('calories', sa.Float, nullable=False),
        sa.Column('protein', sa.Float, nullable=False),
        sa.Column('carbs', sa.Float, nullable=False),
        sa.Column('fat', sa.Float, nullable=False),
        sa.Column('effective_from', sa.Date, nullable=False, unique=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('macro_goals')
    op.drop_table('nutrition_entries')
    op.drop_table('food_items')
