"""add_recipes_tables

Revision ID: ff3a81b4c9d7
Revises: c991b6be013a
Create Date: 2026-03-27
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'ff3a81b4c9d7'
down_revision: Union[str, Sequence[str], None] = 'c991b6be013a'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'recipes',
        sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('name', sa.String(length=200), nullable=False),
        sa.Column('description', sa.String(length=500), nullable=True),
        sa.Column('servings', sa.Float(), nullable=False, server_default='1.0'),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('total_calories', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('total_protein', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('total_carbs', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('total_fat', sa.Float(), nullable=False, server_default='0.0'),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_recipes_user_id', 'recipes', ['user_id'], unique=False)

    op.create_table(
        'recipe_ingredients',
        sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
        sa.Column('recipe_id', sa.Integer(), nullable=False),
        sa.Column('name', sa.String(length=200), nullable=False),
        sa.Column('quantity', sa.Float(), nullable=False, server_default='1.0'),
        sa.Column('unit', sa.String(length=50), nullable=False, server_default='serving'),
        sa.Column('calories', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('protein', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('carbs', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('fat', sa.Float(), nullable=False, server_default='0.0'),
        sa.ForeignKeyConstraint(['recipe_id'], ['recipes.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_recipe_ingredients_recipe_id', 'recipe_ingredients', ['recipe_id'], unique=False)


def downgrade() -> None:
    op.drop_index('ix_recipe_ingredients_recipe_id', table_name='recipe_ingredients')
    op.drop_table('recipe_ingredients')
    op.drop_index('ix_recipes_user_id', table_name='recipes')
    op.drop_table('recipes')
