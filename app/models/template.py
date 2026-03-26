"""Workout template model — pre-built programs users can clone."""

from datetime import datetime

from sqlalchemy import DateTime, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class WorkoutTemplate(Base):
    """A pre-built workout program template. Global (no user_id), read-only."""

    __tablename__ = "workout_templates"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    split_type: Mapped[str] = mapped_column(String(20), nullable=False)
    days_per_week: Mapped[int] = mapped_column(Integer, nullable=False)
    equipment_tier: Mapped[str] = mapped_column(String(20), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    planned_exercises: Mapped[str] = mapped_column(Text, nullable=False)
    block_type: Mapped[str] = mapped_column(String(20), nullable=False, default="hypertrophy")
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )
