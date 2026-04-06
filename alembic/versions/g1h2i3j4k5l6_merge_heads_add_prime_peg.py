"""merge migration heads and ensure prime/peg columns

Revision ID: g1h2i3j4k5l6
Revises: f1a2b3c4d5e6, e9f0a1b2c3d4
Create Date: 2026-04-02

Merges the two diverging heads (is_extrapolated branch and
user-customizations branch) into a single linear chain.

Also ensures the is_prime (exercises) and peg_weights (exercise_sets)
columns exist — these were previously in a standalone migration with a
duplicate revision ID that caused Alembic to fail. Using IF NOT EXISTS /
PRAGMA guards so running this on a DB that already has the columns is safe.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'g1h2i3j4k5l6'
down_revision: Union[str, Sequence[str], None] = ('f1a2b3c4d5e6', 'e9f0a1b2c3d4')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()
    dialect = conn.dialect.name

    if dialect == 'sqlite':
        ex_cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(exercises)")).fetchall()]
        set_cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(exercise_sets)")).fetchall()]

        if 'is_prime' not in ex_cols:
            with op.batch_alter_table('exercises', schema=None) as batch_op:
                batch_op.add_column(sa.Column('is_prime', sa.Boolean(), nullable=False, server_default='0'))
            conn.execute(sa.text(
                "UPDATE exercises SET is_prime = 1 "
                "WHERE name LIKE '%prime%' AND equipment_type = 'plate_loaded'"
            ))

        if 'peg_weights' not in set_cols:
            with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
                batch_op.add_column(sa.Column('peg_weights', sa.Text(), nullable=True))

    else:
        # PostgreSQL
        ex_cols_q = conn.execute(sa.text(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name='exercises' AND column_name='is_prime'"
        ))
        if not ex_cols_q.fetchone():
            with op.batch_alter_table('exercises', schema=None) as batch_op:
                batch_op.add_column(sa.Column('is_prime', sa.Boolean(), nullable=False, server_default='false'))
            conn.execute(sa.text(
                "UPDATE exercises SET is_prime = true "
                "WHERE name LIKE '%prime%' AND equipment_type = 'plate_loaded'"
            ))

        set_cols_q = conn.execute(sa.text(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name='exercise_sets' AND column_name='peg_weights'"
        ))
        if not set_cols_q.fetchone():
            with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
                batch_op.add_column(sa.Column('peg_weights', sa.Text(), nullable=True))


def downgrade() -> None:
    # Only drop if this migration added them (best-effort; skip if not present)
    conn = op.get_bind()
    dialect = conn.dialect.name

    if dialect == 'sqlite':
        ex_cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(exercises)")).fetchall()]
        set_cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(exercise_sets)")).fetchall()]
        if 'is_prime' in ex_cols:
            with op.batch_alter_table('exercises', schema=None) as batch_op:
                batch_op.drop_column('is_prime')
        if 'peg_weights' in set_cols:
            with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
                batch_op.drop_column('peg_weights')
    else:
        with op.batch_alter_table('exercises', schema=None) as batch_op:
            batch_op.drop_column('is_prime')
        with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
            batch_op.drop_column('peg_weights')
