"""Add settings_json to users table

Revision ID: b1c2d3e4f5g6
Revises: a7b8c9d0e1f2
Create Date: 2026-03-25
"""
from alembic import op
import sqlalchemy as sa

revision = "b1c2d3e4f5g6"
down_revision = "a7b8c9d0e1f2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("users", sa.Column("settings_json", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "settings_json")
