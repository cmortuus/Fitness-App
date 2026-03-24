"""add_workout_templates_table

Revision ID: 684a8290de3b
Revises: e5f6a7b8c9d0
Create Date: 2026-03-23
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = '684a8290de3b'
down_revision: Union[str, Sequence[str], None] = 'e5f6a7b8c9d0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'workout_templates',
        sa.Column('id', sa.Integer, primary_key=True, autoincrement=True),
        sa.Column('name', sa.String(200), nullable=False),
        sa.Column('split_type', sa.String(20), nullable=False),
        sa.Column('days_per_week', sa.Integer, nullable=False),
        sa.Column('equipment_tier', sa.String(20), nullable=False),
        sa.Column('description', sa.Text, nullable=False, server_default=''),
        sa.Column('planned_exercises', sa.Text, nullable=False),
        sa.Column('block_type', sa.String(20), nullable=False, server_default='hypertrophy'),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('workout_templates')
