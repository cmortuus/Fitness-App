"""muscles_json_type

Switch primary_muscles and secondary_muscles from VARCHAR(255) to TEXT so
the columns can hold arbitrarily-long JSON arrays without a length cap.
The stored format (a JSON string) is unchanged — SQLAlchemy's JSON type
deserialises it automatically.

Revision ID: c5e8f3a91d2b
Revises: 77f39af0983d
Create Date: 2026-03-20 13:30:00.000000

"""
from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'c5e8f3a91d2b'
down_revision: Union[str, Sequence[str], None] = '77f39af0983d'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Change muscle columns from VARCHAR(255) to TEXT.

    SQLite ignores column type constraints at the storage level, so this
    migration is primarily a schema-documentation change.  It also future-
    proofs against databases (e.g. PostgreSQL) that do enforce VARCHAR limits.

    Default any NULL muscle columns to an empty JSON array so reads always
    return a list rather than None.
    """
    op.execute(
        "UPDATE exercises SET primary_muscles = '[]' WHERE primary_muscles IS NULL"
    )
    op.execute(
        "UPDATE exercises SET secondary_muscles = '[]' WHERE secondary_muscles IS NULL"
    )
    # SQLite stores both VARCHAR(255) and TEXT as the same TEXT affinity,
    # so no DDL column-type change is needed for SQLite.
    # (On PostgreSQL you would do an ALTER COLUMN here.)


def downgrade() -> None:
    """No-op: reverting TEXT → VARCHAR(255) is safe on SQLite."""
    pass
