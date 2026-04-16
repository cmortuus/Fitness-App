"""email required on users + email_verified_at column

Revision ID: h2i3j4k5l6m7
Revises: g1h2i3j4k5l6
Create Date: 2026-04-16
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'h2i3j4k5l6m7'
down_revision: Union[str, Sequence[str], None] = 'g1h2i3j4k5l6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()
    dialect = conn.dialect.name

    # ── 1. Add email_verified_at column ────────────────────────────────────
    if dialect == 'sqlite':
        cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(users)")).fetchall()]
        if 'email_verified_at' not in cols:
            with op.batch_alter_table('users', schema=None) as batch_op:
                batch_op.add_column(sa.Column('email_verified_at', sa.DateTime(), nullable=True))
    else:
        conn.execute(sa.text(
            "ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMP NULL"
        ))

    # ── 2. Backfill missing emails with a deterministic placeholder ────────
    # Existing users without an email get "{username}@local.invalid" — a
    # non-deliverable placeholder they'll be prompted to replace in UI.
    conn.execute(sa.text(
        "UPDATE users SET email = username || '@local.invalid' WHERE email IS NULL OR email = ''"
    ))

    # ── 3. Make email NOT NULL ─────────────────────────────────────────────
    if dialect == 'sqlite':
        # SQLite requires a batch operation to alter column nullability
        with op.batch_alter_table('users', schema=None) as batch_op:
            batch_op.alter_column('email', existing_type=sa.String(255), nullable=False)
    else:
        conn.execute(sa.text("ALTER TABLE users ALTER COLUMN email SET NOT NULL"))


def downgrade() -> None:
    conn = op.get_bind()
    dialect = conn.dialect.name

    if dialect == 'sqlite':
        with op.batch_alter_table('users', schema=None) as batch_op:
            batch_op.alter_column('email', existing_type=sa.String(255), nullable=True)
            batch_op.drop_column('email_verified_at')
    else:
        conn.execute(sa.text("ALTER TABLE users ALTER COLUMN email DROP NOT NULL"))
        conn.execute(sa.text("ALTER TABLE users DROP COLUMN IF EXISTS email_verified_at"))
