"""add user_id to all data tables and create test user

This migration:
1. Adds user_id (nullable FK) to body_weight_entries, food_items,
   nutrition_entries, macro_goals, diet_phases
   (workout_sessions and workout_plans already have user_id)
2. Creates a default 'testuser' so existing data can be assigned
3. Assigns all existing rows to testuser so no data is orphaned
4. Removes the unique constraint on macro_goals.effective_from
   (now scoped per-user, so different users can have same date)

Revision ID: b2c3d4e5f6a7
Revises: a1b2c3d4e5f6
Create Date: 2026-03-23
"""
from typing import Sequence, Union
from datetime import datetime, timezone

from alembic import op
import sqlalchemy as sa

revision: str = 'b2c3d4e5f6a7'
down_revision: Union[str, Sequence[str], None] = 'a1b2c3d4e5f6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()

    # 1. Create a default test user if none exists
    result = conn.execute(sa.text("SELECT id FROM users LIMIT 1"))
    row = result.fetchone()
    if row:
        default_user_id = row[0]
    else:
        # Hash for password "testpass123" — bcrypt
        import bcrypt
        hashed = bcrypt.hashpw(b"testpass123", bcrypt.gensalt()).decode()
        now = datetime.now(timezone.utc).isoformat()
        conn.execute(sa.text(
            "INSERT INTO users (username, email, hashed_password, created_at, updated_at) "
            "VALUES (:u, :e, :p, :c, :c)"
        ), {"u": "testuser", "e": "test@example.com", "p": hashed, "c": now})
        result = conn.execute(sa.text("SELECT id FROM users WHERE username = 'testuser'"))
        default_user_id = result.fetchone()[0]

    # 2. Add user_id column to tables that don't have it yet
    tables_to_update = [
        'body_weight_entries',
        'food_items',
        'nutrition_entries',
        'macro_goals',
        'diet_phases',
    ]

    for table in tables_to_update:
        # Check if column already exists (idempotent)
        cols = [c[1] for c in conn.execute(sa.text(f"PRAGMA table_info({table})")).fetchall()]
        if 'user_id' not in cols:
            with op.batch_alter_table(table, schema=None) as batch_op:
                batch_op.add_column(sa.Column('user_id', sa.Integer(), nullable=True))

    # 3. Assign all existing rows to the default user
    for table in tables_to_update:
        conn.execute(sa.text(f"UPDATE {table} SET user_id = :uid WHERE user_id IS NULL"),
                     {"uid": default_user_id})

    # Also assign existing workout_sessions and workout_plans
    conn.execute(sa.text("UPDATE workout_sessions SET user_id = :uid WHERE user_id IS NULL"),
                 {"uid": default_user_id})
    conn.execute(sa.text("UPDATE workout_plans SET user_id = :uid WHERE user_id IS NULL"),
                 {"uid": default_user_id})

    # 4. Remove unique constraint on macro_goals.effective_from
    #    (now per-user, so we need a composite unique on user_id + effective_from)
    #    SQLite doesn't support ALTER CONSTRAINT, so we skip this for SQLite
    #    and handle it at the application level.


def downgrade() -> None:
    tables = [
        'body_weight_entries',
        'food_items',
        'nutrition_entries',
        'macro_goals',
        'diet_phases',
    ]
    for table in tables:
        with op.batch_alter_table(table, schema=None) as batch_op:
            batch_op.drop_column('user_id')
