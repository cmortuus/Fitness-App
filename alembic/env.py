"""Alembic migration environment for home-gym-tracker.

Uses a synchronous PostgreSQL connection for migration execution (Alembic does
not support async natively) while still reading the DATABASE_URL from app config.
"""
import re
from logging.config import fileConfig

from sqlalchemy import engine_from_config, pool

from alembic import context

# ── App imports ──────────────────────────────────────────────────────────────
# Import all models so that Base.metadata includes every table.
import app.models.body_weight  # noqa: F401
import app.models.exercise  # noqa: F401
import app.models.nutrition  # noqa: F401
import app.models.user  # noqa: F401
import app.models.workout  # noqa: F401
from app.database import Base

# ── Alembic config ────────────────────────────────────────────────────────────
config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def _sync_url(url: str) -> str:
    """Convert an async SQLAlchemy URL to a synchronous one.

    asyncpg → psycopg2  (postgresql+asyncpg://... → postgresql://...)
    """
    url = re.sub(r"^postgresql\+asyncpg", "postgresql", url)
    return url


def _get_url() -> str:
    """Read DATABASE_URL from env / app config."""
    from app.config import get_settings
    return _sync_url(get_settings().database_url)


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode (SQL script output, no DB connection)."""
    url = _get_url()
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode (direct DB connection)."""
    configuration = config.get_section(config.config_ini_section, {})
    configuration["sqlalchemy.url"] = _get_url()

    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=True,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
