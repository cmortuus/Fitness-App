"""Workout session and plan models."""

from datetime import date, datetime
from enum import Enum
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base

if TYPE_CHECKING:
    from app.models.exercise import Exercise
    from app.models.user import User


class WorkoutStatus(str, Enum):
    """Status of a workout session."""

    PLANNED = "planned"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    SKIPPED = "skipped"


class ExerciseSet(Base):
    """A single set of an exercise during a workout session."""

    __tablename__ = "exercise_sets"
    __table_args__ = (
        # History and progress queries filter by session and exercise frequently
        Index("ix_exercise_sets_session", "workout_session_id"),
        Index("ix_exercise_sets_exercise", "exercise_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    workout_session_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("workout_sessions.id"), nullable=False
    )
    exercise_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("exercises.id"), nullable=False
    )
    set_number: Mapped[int] = mapped_column(Integer, nullable=False)

    # Planned values
    planned_reps: Mapped[int | None] = mapped_column(Integer, nullable=True)
    planned_weight_kg: Mapped[float | None] = mapped_column(Float, nullable=True)

    # Actual values (manual entry)
    actual_reps: Mapped[int | None] = mapped_column(Integer, nullable=True)
    actual_weight_kg: Mapped[float | None] = mapped_column(Float, nullable=True)

    # Unilateral planned targets (left/right independently)
    planned_reps_left: Mapped[int | None] = mapped_column(Integer, nullable=True)
    planned_reps_right: Mapped[int | None] = mapped_column(Integer, nullable=True)

    # Unilateral actual rep tracking (left/right independently)
    reps_left: Mapped[int | None] = mapped_column(Integer, nullable=True)
    reps_right: Mapped[int | None] = mapped_column(Integer, nullable=True)

    # Set type and sub-sets (for drop sets)
    set_type: Mapped[str] = mapped_column(String(20), nullable=False, default="standard")
    sub_sets: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON for drop set entries
    peg_weights: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON: {"peg1":kg,"peg2":kg,"peg3":kg} per side

    # Draft values — in-progress inputs not yet completed (for cross-device sync)
    draft_weight_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    draft_reps: Mapped[int | None] = mapped_column(Integer, nullable=True)
    draft_reps_left: Mapped[int | None] = mapped_column(Integer, nullable=True)
    draft_reps_right: Mapped[int | None] = mapped_column(Integer, nullable=True)

    # Notes and timestamps
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    started_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    skipped_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    # Relationships
    workout_session: Mapped["WorkoutSession"] = relationship(
        "WorkoutSession", back_populates="sets"
    )
    exercise: Mapped["Exercise"] = relationship("Exercise", back_populates="sets")


class WorkoutSession(Base):
    """An actual workout session (performed workout)."""

    __tablename__ = "workout_sessions"
    __table_args__ = (
        # Dashboard and progress queries filter by date and status
        Index("ix_workout_sessions_date", "date"),
        Index("ix_workout_sessions_status", "status"),
        Index("ix_workout_sessions_plan", "workout_plan_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("users.id"), nullable=True)
    workout_plan_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("workout_plans.id"), nullable=True
    )
    plan_day_number: Mapped[int | None] = mapped_column(Integer, nullable=True)

    name: Mapped[str | None] = mapped_column(String(100), nullable=True)
    date: Mapped[date] = mapped_column(Date, nullable=False)
    status: Mapped[WorkoutStatus] = mapped_column(
        String(20), default=WorkoutStatus.PLANNED, nullable=False
    )

    # Session metrics
    total_volume_kg: Mapped[float] = mapped_column(Float, default=0.0)
    total_sets: Mapped[int] = mapped_column(Integer, default=0)
    total_reps: Mapped[int] = mapped_column(Integer, default=0)
    duration_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)

    # User notes
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    # Timestamps
    started_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), onupdate=lambda: datetime.utcnow(), nullable=False
    )

    # Relationships
    user: Mapped["User"] = relationship("User", back_populates="workout_sessions")
    workout_plan: Mapped["WorkoutPlan | None"] = relationship(
        "WorkoutPlan", back_populates="workout_sessions"
    )
    sets: Mapped[list["ExerciseSet"]] = relationship(
        "ExerciseSet", back_populates="workout_session", cascade="all, delete-orphan"
    )
    audit_entries: Mapped[list["WorkoutSessionAudit"]] = relationship(
        "WorkoutSessionAudit", back_populates="workout_session", cascade="all, delete-orphan"
    )


class WorkoutSessionAudit(Base):
    """Audit trail for workout session lifecycle transitions."""

    __tablename__ = "workout_session_audit"
    __table_args__ = (
        Index("ix_workout_session_audit_session", "workout_session_id"),
        Index("ix_workout_session_audit_created_at", "created_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    workout_session_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("workout_sessions.id"), nullable=False
    )
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id"), nullable=False)
    from_status: Mapped[str | None] = mapped_column(String(20), nullable=True)
    to_status: Mapped[str | None] = mapped_column(String(20), nullable=True)
    reason: Mapped[str] = mapped_column(String(100), nullable=False)
    endpoint: Mapped[str] = mapped_column(String(100), nullable=False)
    actor_username: Mapped[str | None] = mapped_column(String(50), nullable=True)
    source_device: Mapped[str | None] = mapped_column(String(50), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )

    workout_session: Mapped["WorkoutSession"] = relationship(
        "WorkoutSession", back_populates="audit_entries"
    )


class ExerciseFeedback(Base):
    """Per-exercise recovery and effort feedback for autoregulation."""

    __tablename__ = "exercise_feedback"
    __table_args__ = (
        Index("ix_exercise_feedback_session", "session_id"),
        Index("ix_exercise_feedback_exercise", "exercise_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    session_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("workout_sessions.id"), nullable=False
    )
    exercise_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("exercises.id"), nullable=False
    )
    user_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("users.id"), nullable=False
    )

    # Recovery check (after first set) — "poor", "ok", "good", "fresh"
    recovery_rating: Mapped[str | None] = mapped_column(String(10), nullable=True)

    # Effort check (after last set) — RIR 0-5
    rir: Mapped[int | None] = mapped_column(Integer, nullable=True)

    # Pump rating — "none", "mild", "good", "great"
    pump_rating: Mapped[str | None] = mapped_column(String(10), nullable=True)

    # What the system suggested — "aggressive", "normal", "conservative", "hold", "repeat", "ease", "deload"
    suggestion: Mapped[str | None] = mapped_column(String(20), nullable=True)
    suggestion_detail: Mapped[str | None] = mapped_column(Text, nullable=True)
    suggestion_accepted: Mapped[bool] = mapped_column(Boolean, default=False)

    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


class WorkoutPlan(Base):
    """A planned workout template."""

    __tablename__ = "workout_plans"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("users.id"), nullable=True)

    name: Mapped[str] = mapped_column(String(100), nullable=False)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)

    # Block periodization info
    block_type: Mapped[str] = mapped_column(String(50), default="other")
    duration_weeks: Mapped[int] = mapped_column(Integer, default=4)
    current_week: Mapped[int] = mapped_column(Integer, default=1)
    # Planned exercises as JSON
    planned_exercises: Mapped[str] = mapped_column(Text, nullable=False)

    # Progressive overload settings
    auto_progression: Mapped[bool] = mapped_column(default=True)
    min_technique_score: Mapped[float | None] = mapped_column(Float, nullable=True, default=0.0)

    # Lifecycle
    is_draft: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_archived: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # Timestamps
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), onupdate=lambda: datetime.utcnow(), nullable=False
    )

    # Relationships
    user: Mapped["User"] = relationship("User", back_populates="workout_plans")
    workout_sessions: Mapped[list["WorkoutSession"]] = relationship(
        "WorkoutSession", back_populates="workout_plan"
    )
