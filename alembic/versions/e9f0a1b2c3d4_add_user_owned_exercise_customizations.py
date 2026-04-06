"""add user-owned exercise customizations

Revision ID: e9f0a1b2c3d4
Revises: b1c2d3e4f5g6
Create Date: 2026-03-31
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'e9f0a1b2c3d4'
down_revision: Union[str, Sequence[str], None] = 'b1c2d3e4f5g6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _pg_has_column(conn, table: str, column: str) -> bool:
    row = conn.execute(sa.text(
        "SELECT 1 FROM information_schema.columns "
        "WHERE table_name=:t AND column_name=:c"
    ), {"t": table, "c": column}).fetchone()
    return row is not None


def _pg_has_constraint(conn, table: str, constraint: str) -> bool:
    row = conn.execute(sa.text(
        "SELECT 1 FROM information_schema.table_constraints "
        "WHERE table_name=:t AND constraint_name=:c"
    ), {"t": table, "c": constraint}).fetchone()
    return row is not None


def upgrade() -> None:
    conn = op.get_bind()
    dialect = conn.dialect.name

    if dialect == 'sqlite':
        cols = [c[1] for c in conn.execute(sa.text("PRAGMA table_info(exercises)")).fetchall()]
        with op.batch_alter_table('exercises', schema=None) as batch_op:
            if 'user_id' not in cols:
                batch_op.add_column(sa.Column('user_id', sa.Integer(), nullable=True))
            if 'source_exercise_id' not in cols:
                batch_op.add_column(sa.Column('source_exercise_id', sa.Integer(), nullable=True))
        # Foreign keys are handled by batch_alter_table recreate in SQLite — skip explicit FK creation
    else:
        # PostgreSQL — check columns and constraints before adding
        with op.batch_alter_table('exercises', schema=None) as batch_op:
            if not _pg_has_column(conn, 'exercises', 'user_id'):
                batch_op.add_column(sa.Column('user_id', sa.Integer(), nullable=True))
            if not _pg_has_column(conn, 'exercises', 'source_exercise_id'):
                batch_op.add_column(sa.Column('source_exercise_id', sa.Integer(), nullable=True))

        if not _pg_has_constraint(conn, 'exercises', 'fk_exercises_user_id_users'):
            with op.batch_alter_table('exercises', schema=None) as batch_op:
                batch_op.create_foreign_key('fk_exercises_user_id_users', 'users', ['user_id'], ['id'])

        if not _pg_has_constraint(conn, 'exercises', 'fk_exercises_source_exercise_id'):
            with op.batch_alter_table('exercises', schema=None) as batch_op:
                batch_op.create_foreign_key('fk_exercises_source_exercise_id', 'exercises', ['source_exercise_id'], ['id'])


def downgrade() -> None:
    with op.batch_alter_table('exercises', schema=None) as batch_op:
        batch_op.drop_constraint('fk_exercises_source_exercise_id', type_='foreignkey')
        batch_op.drop_constraint('fk_exercises_user_id_users', type_='foreignkey')
        batch_op.drop_column('source_exercise_id')
        batch_op.drop_column('user_id')
