"""add subscription fields to users + stripe_events table

Revision ID: i3j4k5l6m7n8
Revises: h2i3j4k5l6m7
Create Date: 2026-04-16
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'i3j4k5l6m7n8'
down_revision: Union[str, Sequence[str], None] = 'h2i3j4k5l6m7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()
    dialect = conn.dialect.name

    # ── 1. Add subscription columns to users ───────────────────────────────
    if dialect == 'sqlite':
        cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(users)")).fetchall()]
        with op.batch_alter_table('users', schema=None) as batch_op:
            if 'stripe_customer_id' not in cols:
                batch_op.add_column(sa.Column('stripe_customer_id', sa.String(255), nullable=True))
                batch_op.create_unique_constraint('uq_users_stripe_customer_id', ['stripe_customer_id'])
            if 'subscription_status' not in cols:
                batch_op.add_column(sa.Column('subscription_status', sa.String(32), nullable=True))
            if 'subscription_current_period_end' not in cols:
                batch_op.add_column(sa.Column('subscription_current_period_end', sa.DateTime(), nullable=True))
            if 'trial_ends_at' not in cols:
                batch_op.add_column(sa.Column('trial_ends_at', sa.DateTime(), nullable=True))
    else:
        conn.execute(sa.text("""
            ALTER TABLE users
              ADD COLUMN IF NOT EXISTS stripe_customer_id VARCHAR(255) UNIQUE,
              ADD COLUMN IF NOT EXISTS subscription_status VARCHAR(32),
              ADD COLUMN IF NOT EXISTS subscription_current_period_end TIMESTAMP,
              ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMP
        """))

    # ── 2. Backfill trial_ends_at — give every existing user a 30-day trial ─
    # starting from now.  Using created_at could be retroactively stingy for
    # old accounts.  Newly-registered users get their trial set in register().
    if dialect == 'sqlite':
        conn.execute(sa.text(
            "UPDATE users SET trial_ends_at = datetime('now', '+30 days') "
            "WHERE trial_ends_at IS NULL"
        ))
    else:
        conn.execute(sa.text(
            "UPDATE users SET trial_ends_at = NOW() + INTERVAL '30 days' "
            "WHERE trial_ends_at IS NULL"
        ))

    # ── 3. Create stripe_events table ──────────────────────────────────────
    if dialect == 'sqlite':
        existing = [r[0] for r in conn.execute(sa.text(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='stripe_events'"
        )).fetchall()]
        if 'stripe_events' not in existing:
            op.create_table(
                'stripe_events',
                sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
                sa.Column('event_id', sa.String(255), nullable=False, unique=True),
                sa.Column('event_type', sa.String(128), nullable=False),
                sa.Column('payload_json', sa.Text(), nullable=False),
                sa.Column('received_at', sa.DateTime(), nullable=False,
                          server_default=sa.text('CURRENT_TIMESTAMP')),
                sa.Column('processed_at', sa.DateTime(), nullable=True),
            )
    else:
        conn.execute(sa.text("""
            CREATE TABLE IF NOT EXISTS stripe_events (
                id SERIAL PRIMARY KEY,
                event_id VARCHAR(255) NOT NULL UNIQUE,
                event_type VARCHAR(128) NOT NULL,
                payload_json TEXT NOT NULL,
                received_at TIMESTAMP NOT NULL DEFAULT NOW(),
                processed_at TIMESTAMP NULL
            )
        """))


def downgrade() -> None:
    conn = op.get_bind()
    dialect = conn.dialect.name

    if dialect == 'sqlite':
        with op.batch_alter_table('users', schema=None) as batch_op:
            batch_op.drop_constraint('uq_users_stripe_customer_id', type_='unique')
            batch_op.drop_column('trial_ends_at')
            batch_op.drop_column('subscription_current_period_end')
            batch_op.drop_column('subscription_status')
            batch_op.drop_column('stripe_customer_id')
        op.drop_table('stripe_events')
    else:
        conn.execute(sa.text("""
            ALTER TABLE users
              DROP COLUMN IF EXISTS trial_ends_at,
              DROP COLUMN IF EXISTS subscription_current_period_end,
              DROP COLUMN IF EXISTS subscription_status,
              DROP COLUMN IF EXISTS stripe_customer_id
        """))
        conn.execute(sa.text("DROP TABLE IF EXISTS stripe_events"))
