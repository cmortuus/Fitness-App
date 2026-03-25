"""add_equipment_type_to_exercises

Revision ID: a7b8c9d0e1f2
Revises: dda8cf8a74dd
Create Date: 2026-03-25
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'a7b8c9d0e1f2'
down_revision: Union[str, Sequence[str], None] = 'dda8cf8a74dd'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('exercises', schema=None) as batch_op:
        batch_op.add_column(
            sa.Column('equipment_type', sa.String(30), nullable=False, server_default='other')
        )

    # Data migration: categorize existing exercises by name prefix
    conn = op.get_bind()
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'barbell' WHERE name LIKE 'barbell_%'"))
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'dumbbell' WHERE name LIKE 'db_%'"))
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'cable' WHERE name LIKE 'cable_%'"))
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'plate_loaded' WHERE name LIKE 'smith_%'"))
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'machine' WHERE name LIKE 'machine_%'"))
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'bodyweight' WHERE name LIKE 'bodyweight_%'"))
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'band' WHERE name LIKE 'band_%'"))
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'kettlebell' WHERE name LIKE 'kb_%'"))
    # T-bar rows are plate loaded
    conn.execute(sa.text("UPDATE exercises SET equipment_type = 'plate_loaded' WHERE name LIKE 'tbar_%'"))


def downgrade() -> None:
    with op.batch_alter_table('exercises', schema=None) as batch_op:
        batch_op.drop_column('equipment_type')
