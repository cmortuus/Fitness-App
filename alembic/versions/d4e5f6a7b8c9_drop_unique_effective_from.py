"""drop unique constraint on macro_goals.effective_from

Now scoped per-user, so different users can have the same effective_from date.
SQLite inline UNIQUE constraints require table recreation.

Revision ID: d4e5f6a7b8c9
Revises: c3d4e5f6a7b8
Create Date: 2026-03-23
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'd4e5f6a7b8c9'
down_revision: Union[str, Sequence[str], None] = 'c3d4e5f6a7b8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()

    # Recreate macro_goals without the UNIQUE constraint on effective_from
    conn.execute(sa.text("""
        CREATE TABLE macro_goals_new (
            id INTEGER NOT NULL PRIMARY KEY,
            user_id INTEGER,
            calories FLOAT NOT NULL,
            protein FLOAT NOT NULL,
            carbs FLOAT NOT NULL,
            fat FLOAT NOT NULL,
            effective_from DATE NOT NULL,
            created_at DATETIME NOT NULL,
            FOREIGN KEY (user_id) REFERENCES users(id)
        )
    """))
    conn.execute(sa.text(
        "INSERT INTO macro_goals_new SELECT id, user_id, calories, protein, carbs, fat, effective_from, created_at FROM macro_goals"
    ))
    conn.execute(sa.text("DROP TABLE macro_goals"))
    conn.execute(sa.text("ALTER TABLE macro_goals_new RENAME TO macro_goals"))


def downgrade() -> None:
    with op.batch_alter_table('macro_goals', schema=None) as batch_op:
        batch_op.create_unique_constraint('uq_macro_goals_effective_from', ['effective_from'])
