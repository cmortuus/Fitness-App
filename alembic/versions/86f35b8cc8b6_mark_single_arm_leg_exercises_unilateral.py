"""mark_single_arm_leg_exercises_unilateral

Data migration: set is_unilateral=1 for all exercises whose display_name
starts with 'Single Arm' or 'Single Leg'.  The seed data previously left
these as bilateral (is_unilateral=0) by omission.

Revision ID: 86f35b8cc8b6
Revises: d4f7a1b2c3e8
Create Date: 2026-03-20 13:48:11.139822

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '86f35b8cc8b6'
down_revision: Union[str, Sequence[str], None] = 'd4f7a1b2c3e8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Exercises that are genuinely unilateral (one limb at a time) and should
# have is_unilateral=True.  Matched by their canonical `name` field so the
# update is idempotent and safe to run on any DB state.
UNILATERAL_NAMES = [
    "single_arm_lat_pulldown",
    "single_leg_press",
    "single_leg_extension",
    "single_leg_rdl",
    "single_leg_curl",
    "single_leg_hip_thrust",
    "single_leg_calf_raise",
    "single_arm_preacher_curl",
    "single_arm_pushdown",
    "single_arm_overhead_extension",
]


def upgrade() -> None:
    """Mark unilateral exercises correctly."""
    exercises = sa.table(
        "exercises",
        sa.column("name", sa.String),
        sa.column("is_unilateral", sa.Boolean),
    )
    for name in UNILATERAL_NAMES:
        op.execute(
            exercises.update()
            .where(exercises.c.name == name)
            .values(is_unilateral=True)
        )


def downgrade() -> None:
    """Revert to bilateral (is_unilateral=False) for these exercises."""
    exercises = sa.table(
        "exercises",
        sa.column("name", sa.String),
        sa.column("is_unilateral", sa.Boolean),
    )
    for name in UNILATERAL_NAMES:
        op.execute(
            exercises.update()
            .where(exercises.c.name == name)
            .values(is_unilateral=False)
        )
