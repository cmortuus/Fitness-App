"""add_diet_phases_table

Revision ID: 3fa836442cfd
Revises: 3c47c344335e
Create Date: 2026-03-20
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = '3fa836442cfd'
down_revision: Union[str, Sequence[str], None] = '3c47c344335e'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'diet_phases',
        sa.Column('id', sa.Integer, primary_key=True, autoincrement=True),
        sa.Column('phase_type', sa.String(20), nullable=False),
        sa.Column('started_on', sa.Date, nullable=False),
        sa.Column('duration_weeks', sa.Integer, nullable=False),
        sa.Column('starting_weight_kg', sa.Float, nullable=False),
        sa.Column('target_rate_pct', sa.Float, nullable=False),
        sa.Column('activity_multiplier', sa.Float, nullable=False, server_default='1.4'),
        sa.Column('tdee_override', sa.Float, nullable=True),
        sa.Column('carb_preset', sa.String(20), nullable=False, server_default='moderate'),
        sa.Column('body_fat_pct', sa.Float, nullable=True),
        sa.Column('protein_per_lb', sa.Float, nullable=True),
        sa.Column('is_active', sa.Boolean, nullable=False, server_default='1'),
        sa.Column('ended_on', sa.Date, nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('diet_phases')
