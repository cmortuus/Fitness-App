"""Add exercise_feedback table for autoregulation

Revision ID: c991b6be013a
Revises: f0b873e7c9f3
Create Date: 2026-03-26
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'c991b6be013a'
down_revision: Union[str, Sequence[str], None] = 'b1c2d3e4f5g6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'exercise_feedback',
        sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
        sa.Column('session_id', sa.Integer(), sa.ForeignKey('workout_sessions.id'), nullable=False),
        sa.Column('exercise_id', sa.Integer(), sa.ForeignKey('exercises.id'), nullable=False),
        sa.Column('user_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('recovery_rating', sa.String(10), nullable=True),
        sa.Column('rir', sa.Integer(), nullable=True),
        sa.Column('pump_rating', sa.String(10), nullable=True),
        sa.Column('suggestion', sa.String(20), nullable=True),
        sa.Column('suggestion_detail', sa.Text(), nullable=True),
        sa.Column('suggestion_accepted', sa.Boolean(), server_default='false', nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_exercise_feedback_session', 'exercise_feedback', ['session_id'])
    op.create_index('ix_exercise_feedback_exercise', 'exercise_feedback', ['exercise_id'])


def downgrade() -> None:
    op.drop_index('ix_exercise_feedback_exercise', 'exercise_feedback')
    op.drop_index('ix_exercise_feedback_session', 'exercise_feedback')
    op.drop_table('exercise_feedback')
