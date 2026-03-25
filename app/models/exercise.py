"""Exercise definitions model."""

from datetime import datetime, timezone
from enum import Enum
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, DateTime, Integer, JSON, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base

if TYPE_CHECKING:
    from app.models.workout import ExerciseSet


class MovementType(str, Enum):
    """Compound vs isolation movement."""

    COMPOUND = "compound"
    ISOLATION = "isolation"


class BodyRegion(str, Enum):
    """Body region targeted."""

    UPPER = "upper"
    LOWER = "lower"
    FULL_BODY = "full_body"


class EquipmentType(str, Enum):
    """Type of equipment used for an exercise."""

    BARBELL = "barbell"
    DUMBBELL = "dumbbell"
    CABLE = "cable"
    MACHINE = "machine"             # selectorized / pin-loaded stack
    PLATE_LOADED = "plate_loaded"   # smith, hack squat, leg press, etc.
    BODYWEIGHT = "bodyweight"
    BAND = "band"
    KETTLEBELL = "kettlebell"
    OTHER = "other"


class Exercise(Base):
    """Exercise definition model."""

    __tablename__ = "exercises"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(100), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(100), nullable=False)
    movement_type: Mapped[str] = mapped_column(String(50), default="compound")
    body_region: Mapped[str] = mapped_column(String(50), default="upper")
    equipment_type: Mapped[str] = mapped_column(String(30), default="other", nullable=False, server_default="other")
    is_unilateral: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_assisted:   Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # Description and technique cues
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    technique_cues: Mapped[str | None] = mapped_column(Text, nullable=True)

    # Primary and secondary muscle groups (stored as JSON array)
    primary_muscles: Mapped[list | None] = mapped_column(JSON, nullable=True)
    secondary_muscles: Mapped[list | None] = mapped_column(JSON, nullable=True)

    # Timestamps
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc), nullable=False
    )

    # Relationships
    sets: Mapped[list["ExerciseSet"]] = relationship(
        "ExerciseSet", back_populates="exercise", cascade="all, delete-orphan"
    )

    def __repr__(self) -> str:
        return f"<Exercise {self.name}>"
