"""add workout session audit table

Revision ID: 1f2e3d4c5b6a
Revises: f70bebb5a18c
Create Date: 2026-03-30 11:48:00.000000
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "1f2e3d4c5b6a"
down_revision: str | None = "f70bebb5a18c"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "workout_session_audit",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("workout_session_id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("from_status", sa.String(length=20), nullable=True),
        sa.Column("to_status", sa.String(length=20), nullable=True),
        sa.Column("reason", sa.String(length=100), nullable=False),
        sa.Column("endpoint", sa.String(length=100), nullable=False),
        sa.Column("actor_username", sa.String(length=50), nullable=True),
        sa.Column("source_device", sa.String(length=50), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["workout_session_id"], ["workout_sessions.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_workout_session_audit_created_at", "workout_session_audit", ["created_at"], unique=False)
    op.create_index("ix_workout_session_audit_session", "workout_session_audit", ["workout_session_id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_workout_session_audit_session", table_name="workout_session_audit")
    op.drop_index("ix_workout_session_audit_created_at", table_name="workout_session_audit")
    op.drop_table("workout_session_audit")
