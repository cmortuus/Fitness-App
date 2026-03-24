"""add_exercise_notes_table

Revision ID: dda8cf8a74dd
Revises: b31c84ceead6
Create Date: 2026-03-24
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'dda8cf8a74dd'
down_revision: Union[str, Sequence[str], None] = 'b31c84ceead6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'exercise_notes',
        sa.Column('id', sa.Integer, primary_key=True, autoincrement=True),
        sa.Column('user_id', sa.Integer, sa.ForeignKey('users.id'), nullable=False),
        sa.Column('exercise_id', sa.Integer, sa.ForeignKey('exercises.id'), nullable=False),
        sa.Column('note', sa.Text, nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('exercise_notes')
