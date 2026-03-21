"""Nutrition tracking models — food items, daily entries, and macro goals."""

from datetime import date as date_type, datetime, timezone

from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class FoodItem(Base):
    """A food in the user's library (custom or cached from search)."""

    __tablename__ = "food_items"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    brand: Mapped[str | None] = mapped_column(String(200), nullable=True)
    barcode: Mapped[str | None] = mapped_column(String(50), nullable=True, index=True)
    source: Mapped[str] = mapped_column(String(20), nullable=False, default="custom")
    source_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    calories_per_100g: Mapped[float | None] = mapped_column(Float, nullable=True)
    protein_per_100g: Mapped[float | None] = mapped_column(Float, nullable=True)
    carbs_per_100g: Mapped[float | None] = mapped_column(Float, nullable=True)
    fat_per_100g: Mapped[float | None] = mapped_column(Float, nullable=True)
    serving_size_g: Mapped[float] = mapped_column(Float, nullable=False, default=100.0)
    serving_label: Mapped[str | None] = mapped_column(String(100), nullable=True)
    is_custom: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False
    )


class NutritionEntry(Base):
    """A single logged food entry for a given day and meal."""

    __tablename__ = "nutrition_entries"
    __table_args__ = (Index("ix_nutrition_entries_date", "date"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    food_item_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("food_items.id", ondelete="SET NULL"), nullable=True
    )
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    date: Mapped[date_type] = mapped_column(Date, nullable=False)
    meal: Mapped[str] = mapped_column(String(20), nullable=False, default="snack")
    quantity_g: Mapped[float] = mapped_column(Float, nullable=False)
    calories: Mapped[float] = mapped_column(Float, nullable=False)
    protein: Mapped[float] = mapped_column(Float, nullable=False)
    carbs: Mapped[float] = mapped_column(Float, nullable=False)
    fat: Mapped[float] = mapped_column(Float, nullable=False)
    logged_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False
    )


class MacroGoal(Base):
    """Daily macro targets, versioned by effective_from date."""

    __tablename__ = "macro_goals"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    calories: Mapped[float] = mapped_column(Float, nullable=False)
    protein: Mapped[float] = mapped_column(Float, nullable=False)
    carbs: Mapped[float] = mapped_column(Float, nullable=False)
    fat: Mapped[float] = mapped_column(Float, nullable=False)
    effective_from: Mapped[date_type] = mapped_column(Date, nullable=False, unique=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False
    )


class DietPhase(Base):
    """A diet phase (cut/bulk/maintenance) with auto-calculated periodized macros."""

    __tablename__ = "diet_phases"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    phase_type: Mapped[str] = mapped_column(String(20), nullable=False)
    started_on: Mapped[date_type] = mapped_column(Date, nullable=False)
    duration_weeks: Mapped[int] = mapped_column(Integer, nullable=False)
    starting_weight_kg: Mapped[float] = mapped_column(Float, nullable=False)
    target_rate_pct: Mapped[float] = mapped_column(Float, nullable=False)
    activity_multiplier: Mapped[float] = mapped_column(Float, nullable=False, default=1.4)
    tdee_override: Mapped[float | None] = mapped_column(Float, nullable=True)
    carb_preset: Mapped[str] = mapped_column(String(20), nullable=False, default="moderate")
    body_fat_pct: Mapped[float | None] = mapped_column(Float, nullable=True)
    protein_per_lb: Mapped[float | None] = mapped_column(Float, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    ended_on: Mapped[date_type | None] = mapped_column(Date, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False
    )
