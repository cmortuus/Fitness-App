"""Nutrition tracking models — food items, daily entries, and macro goals."""

import os
from datetime import date as date_type, datetime

from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class FoodItem(Base):
    """A food in the user's library (custom or cached from search)."""

    __tablename__ = "food_items"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("users.id"), nullable=True)
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
    micronutrients: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON: per-100g values
    is_custom: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


class NutritionEntry(Base):
    """A single logged food entry for a given day and meal."""

    __tablename__ = "nutrition_entries"
    __table_args__ = (Index("ix_nutrition_entries_date", "date"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("users.id"), nullable=True)
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
    micronutrients: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON: actual intake values
    logged_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


class MacroGoal(Base):
    """Daily macro targets, versioned by effective_from date."""

    __tablename__ = "macro_goals"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("users.id"), nullable=True)
    calories: Mapped[float] = mapped_column(Float, nullable=False)
    protein: Mapped[float] = mapped_column(Float, nullable=False)
    carbs: Mapped[float] = mapped_column(Float, nullable=False)
    fat: Mapped[float] = mapped_column(Float, nullable=False)
    water_goal_ml: Mapped[float] = mapped_column(Float, nullable=False, default=2500.0)
    effective_from: Mapped[date_type] = mapped_column(Date, nullable=False)
    micronutrient_goals: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON: RDA targets
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


class WaterEntry(Base):
    """A single water intake log entry."""

    __tablename__ = "water_entries"
    __table_args__ = (Index("ix_water_entries_date", "date"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id"), nullable=False)
    date: Mapped[date_type] = mapped_column(Date, nullable=False)
    amount_ml: Mapped[float] = mapped_column(Float, nullable=False)
    logged_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


class DietPhase(Base):
    """A diet phase (cut/bulk/maintenance) with auto-calculated periodized macros."""

    __tablename__ = "diet_phases"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("users.id"), nullable=True)
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
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


class FoodSubmission(Base):
    """Tracks which users have submitted a pending community food, enabling vote-based promotion."""

    __tablename__ = "food_submissions"
    __table_args__ = (UniqueConstraint("food_item_id", "user_id", name="uq_food_submission"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    food_item_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("food_items.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id"), nullable=False)
    # Snapshot of the submitter's values — averaged when promoting to community
    calories_per_100g: Mapped[float | None] = mapped_column(Float, nullable=True)
    protein_per_100g: Mapped[float | None] = mapped_column(Float, nullable=True)
    carbs_per_100g: Mapped[float | None] = mapped_column(Float, nullable=True)
    fat_per_100g: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


# Number of distinct user submissions required to promote a pending food to community.
# Configurable via COMMUNITY_FOOD_THRESHOLD env var (default 1 — single user promotes immediately).
COMMUNITY_THRESHOLD: int = int(os.environ.get("COMMUNITY_FOOD_THRESHOLD", "1"))


class Recipe(Base):
    """A user-defined recipe composed of individual ingredients."""

    __tablename__ = "recipes"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str | None] = mapped_column(String(500), nullable=True)
    servings: Mapped[float] = mapped_column(Float, nullable=False, default=1.0)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )
    # Denormalized totals — recomputed whenever ingredients change
    total_calories: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    total_protein: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    total_carbs: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    total_fat: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)

    ingredients: Mapped[list["RecipeIngredient"]] = relationship(
        back_populates="recipe", cascade="all, delete-orphan"
    )


class RecipeIngredient(Base):
    """A single ingredient line within a recipe."""

    __tablename__ = "recipe_ingredients"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    recipe_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("recipes.id"), nullable=False, index=True
    )
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    quantity: Mapped[float] = mapped_column(Float, nullable=False, default=1.0)
    unit: Mapped[str] = mapped_column(String(50), nullable=False, default="serving")
    calories: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    protein: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    carbs: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    fat: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)

    recipe: Mapped["Recipe"] = relationship(back_populates="ingredients")


class TDEEHistory(Base):
    """Daily adaptive TDEE estimate derived from intake + weight trend data."""

    __tablename__ = "tdee_history"
    __table_args__ = (Index("ix_tdee_history_user_date", "user_id", "date", unique=True),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id"), nullable=False)
    date: Mapped[date_type] = mapped_column(Date, nullable=False)
    estimated_tdee: Mapped[float] = mapped_column(Float, nullable=False)
    intake_calories: Mapped[float | None] = mapped_column(Float, nullable=True)
    weight_trend_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    confidence: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    method: Mapped[str] = mapped_column(String(20), nullable=False, default="adaptive")
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


class WeeklyCheckIn(Base):
    """Automated weekly nutrition review with macro adjustment recommendations."""

    __tablename__ = "weekly_checkins"
    __table_args__ = (Index("ix_weekly_checkins_user_week", "user_id", "week_start", unique=True),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id"), nullable=False)
    week_start: Mapped[date_type] = mapped_column(Date, nullable=False)
    weight_trend_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    avg_intake: Mapped[float | None] = mapped_column(Float, nullable=True)
    tdee_estimate: Mapped[float | None] = mapped_column(Float, nullable=True)
    recommended_calories: Mapped[float | None] = mapped_column(Float, nullable=True)
    recommended_protein: Mapped[float | None] = mapped_column(Float, nullable=True)
    recommended_carbs: Mapped[float | None] = mapped_column(Float, nullable=True)
    recommended_fat: Mapped[float | None] = mapped_column(Float, nullable=True)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="pending")
    stall_detected: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    rate_too_fast: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )


class MacroCycle(Base):
    """Per-day macro targets for training vs rest day cycling."""

    __tablename__ = "macro_cycles"
    __table_args__ = (Index("ix_macro_cycles_user_active", "user_id", "is_active"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id"), nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    training_calories: Mapped[float] = mapped_column(Float, nullable=False)
    training_protein: Mapped[float] = mapped_column(Float, nullable=False)
    training_carbs: Mapped[float] = mapped_column(Float, nullable=False)
    training_fat: Mapped[float] = mapped_column(Float, nullable=False)
    rest_calories: Mapped[float] = mapped_column(Float, nullable=False)
    rest_protein: Mapped[float] = mapped_column(Float, nullable=False)
    rest_carbs: Mapped[float] = mapped_column(Float, nullable=False)
    rest_fat: Mapped[float] = mapped_column(Float, nullable=False)
    effective_from: Mapped[date_type] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow(), nullable=False
    )
