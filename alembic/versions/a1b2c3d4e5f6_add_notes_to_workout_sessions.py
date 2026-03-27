"""add notes to workout_sessions

Revision ID: a1b2c3d4e5f6
Revises: ff3a81b4c9d7
Create Date: 2026-03-27

"""
from alembic import op
import sqlalchemy as sa

revision = 'a1b2c3d4e5f6'
down_revision = 'ff3a81b4c9d7'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column('workout_sessions', sa.Column('notes', sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column('workout_sessions', 'notes')
