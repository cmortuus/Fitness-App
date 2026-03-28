"""add tdee_history, weekly_checkins, macro_cycles tables

Revision ID: f70bebb5a18c
Revises: 7dc59e708258
Create Date: 2026-03-28 18:14:25.602027

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'f70bebb5a18c'
down_revision: Union[str, Sequence[str], None] = '7dc59e708258'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'tdee_history',
        sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('date', sa.Date(), nullable=False),
        sa.Column('estimated_tdee', sa.Float(), nullable=False),
        sa.Column('intake_calories', sa.Float(), nullable=True),
        sa.Column('weight_trend_kg', sa.Float(), nullable=True),
        sa.Column('confidence', sa.Float(), nullable=False, server_default='0'),
        sa.Column('method', sa.String(20), nullable=False, server_default='adaptive'),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_tdee_history_user_date', 'tdee_history', ['user_id', 'date'], unique=True)

    op.create_table(
        'weekly_checkins',
        sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('week_start', sa.Date(), nullable=False),
        sa.Column('weight_trend_kg', sa.Float(), nullable=True),
        sa.Column('avg_intake', sa.Float(), nullable=True),
        sa.Column('tdee_estimate', sa.Float(), nullable=True),
        sa.Column('recommended_calories', sa.Float(), nullable=True),
        sa.Column('recommended_protein', sa.Float(), nullable=True),
        sa.Column('recommended_carbs', sa.Float(), nullable=True),
        sa.Column('recommended_fat', sa.Float(), nullable=True),
        sa.Column('status', sa.String(20), nullable=False, server_default='pending'),
        sa.Column('stall_detected', sa.Boolean(), nullable=False, server_default='false'),
        sa.Column('rate_too_fast', sa.Boolean(), nullable=False, server_default='false'),
        sa.Column('notes', sa.Text(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_weekly_checkins_user_week', 'weekly_checkins', ['user_id', 'week_start'], unique=True)

    op.create_table(
        'macro_cycles',
        sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('is_active', sa.Boolean(), nullable=False, server_default='true'),
        sa.Column('training_calories', sa.Float(), nullable=False),
        sa.Column('training_protein', sa.Float(), nullable=False),
        sa.Column('training_carbs', sa.Float(), nullable=False),
        sa.Column('training_fat', sa.Float(), nullable=False),
        sa.Column('rest_calories', sa.Float(), nullable=False),
        sa.Column('rest_protein', sa.Float(), nullable=False),
        sa.Column('rest_carbs', sa.Float(), nullable=False),
        sa.Column('rest_fat', sa.Float(), nullable=False),
        sa.Column('effective_from', sa.Date(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_macro_cycles_user_active', 'macro_cycles', ['user_id', 'is_active'])


def downgrade() -> None:
    op.drop_index('ix_macro_cycles_user_active')
    op.drop_table('macro_cycles')
    op.drop_index('ix_weekly_checkins_user_week')
    op.drop_table('weekly_checkins')
    op.drop_index('ix_tdee_history_user_date')
    op.drop_table('tdee_history')
