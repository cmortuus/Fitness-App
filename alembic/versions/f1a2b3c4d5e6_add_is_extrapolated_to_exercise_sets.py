"""add is_extrapolated to exercise_sets

Revision ID: f1a2b3c4d5e6
Revises: 2b4c6d8e0f1a
Create Date: 2026-04-02
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'f1a2b3c4d5e6'
down_revision: Union[str, Sequence[str], None] = '2b4c6d8e0f1a'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()
    dialect = conn.dialect.name

    if dialect == 'sqlite':
        cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(exercise_sets)")).fetchall()]
        if 'is_extrapolated' not in cols:
            with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
                batch_op.add_column(sa.Column('is_extrapolated', sa.Boolean(), nullable=True))
    else:
        row = conn.execute(sa.text(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name='exercise_sets' AND column_name='is_extrapolated'"
        )).fetchone()
        if not row:
            with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
                batch_op.add_column(sa.Column('is_extrapolated', sa.Boolean(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('exercise_sets', schema=None) as batch_op:
        batch_op.drop_column('is_extrapolated')
