"""Pydantic schemas for API request/response validation."""

from datetime import date, datetime
from enum import Enum

from pydantic import BaseModel, Field, model_validator


# Enums (mirroring model enums)
class MovementType(str, Enum):
    COMPOUND = "compound"
    ISOLATION = "isolation"
    PUSH = "push"
    PULL = "pull"
    HINGE = "hinge"
    SQUAT = "squat"
    LUNGE = "lunge"
    CARRY = "carry"
    ROTATION = "rotation"


class BodyRegion(str, Enum):
    UPPER = "upper"
    LOWER = "lower"
    FULL_BODY = "full_body"


class WorkoutStatusSchema(str, Enum):
    PLANNED = "planned"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    SKIPPED = "skipped"


# User schemas
class UserCreate(BaseModel):
    username: str = Field(..., min_length=3, max_length=50)
    email: str
    password: str = Field(..., min_length=8)
    height_cm: float | None = None
    weight_kg: float | None = None


class UserResponse(BaseModel):
    id: int
    username: str
    email: str
    height_cm: float | None
    weight_kg: float | None
    created_at: datetime

    model_config = {"from_attributes": True}


# Exercise schemas
class ExerciseCreate(BaseModel):
    name: str
    display_name: str
    movement_type: MovementType = MovementType.COMPOUND
    body_region: BodyRegion = BodyRegion.UPPER
    equipment_type: str = "other"
    is_unilateral: bool = False
    is_assisted: bool = False
    description: str | None = None
    primary_muscles: list[str] = []
    secondary_muscles: list[str] = []

    @model_validator(mode="after")
    def no_overlap_between_primary_and_secondary(self) -> "ExerciseCreate":
        overlap = set(self.primary_muscles) & set(self.secondary_muscles)
        if overlap:
            raise ValueError(
                f"A muscle cannot be both primary and secondary: {sorted(overlap)}"
            )
        return self


class ExerciseResponse(BaseModel):
    id: int
    name: str
    display_name: str
    movement_type: str
    body_region: str
    equipment_type: str = "other"
    is_unilateral: bool = False
    is_assisted:   bool = False
    description: str | None
    primary_muscles: list[str]
    secondary_muscles: list[str]

    model_config = {"from_attributes": True}


# Set schemas
class SetCreate(BaseModel):
    exercise_id: int
    set_number: int
    planned_reps: int | None = None
    planned_weight_kg: float | None = None
    set_type: str = "standard"


class SetUpdate(BaseModel):
    actual_reps: int | None = None
    actual_weight_kg: float | None = None
    reps_left: int | None = None
    reps_right: int | None = None
    set_type: str | None = None
    sub_sets: list | str | None = None
    notes: str | None = None
    completed_at: datetime | None = None
    started_at: datetime | None = None
    draft_weight_kg: float | None = None
    draft_reps: int | None = None
    draft_reps_left: int | None = None
    draft_reps_right: int | None = None
    skipped_at: datetime | None = None


class SetResponse(BaseModel):
    id: int
    exercise_id: int
    set_number: int
    planned_reps: int | None = None
    planned_reps_left: int | None = None
    planned_reps_right: int | None = None
    planned_weight_kg: float | None = None
    actual_reps: int | None = None
    actual_weight_kg: float | None = None
    reps_left: int | None = None
    reps_right: int | None = None
    set_type: str = "standard"
    sub_sets: list | str | None = None
    notes: str | None = None
    started_at: datetime | None = None
    completed_at: datetime | None = None
    draft_weight_kg: float | None = None
    draft_reps: int | None = None
    draft_reps_left: int | None = None
    draft_reps_right: int | None = None
    skipped_at: str | None = None

    model_config = {"from_attributes": True}


# Workout session schemas
class WorkoutSessionCreate(BaseModel):
    name: str | None = None
    workout_plan_id: int | None = None
    date: date


class WorkoutSessionStart(BaseModel):
    session_id: int


class WorkoutSessionResponse(BaseModel):
    id: int
    name: str | None
    date: date
    status: WorkoutStatusSchema
    workout_plan_id: int | None = None
    total_volume_kg: float
    total_sets: int
    total_reps: int
    started_at: datetime | None
    completed_at: datetime | None
    notes: str | None = None
    sets: list[SetResponse] = []

    model_config = {"from_attributes": True}


class WorkoutSessionAuditResponse(BaseModel):
    id: int
    workout_session_id: int
    from_status: str | None
    to_status: str | None
    reason: str
    endpoint: str
    actor_username: str | None
    source_device: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


# Workout plan schemas
class PlannedExercise(BaseModel):
    exercise_id: int
    sets: int
    reps: int
    starting_weight_kg: float
    progression_type: str = "linear"
    set_type: str = "standard"
    drops: int | None = None  # number of drops for drop sets
    rest_seconds: int | None = 90
    notes: str | None = None


class PlannedDay(BaseModel):
    day_number: int
    day_name: str
    exercises: list[PlannedExercise]


class BlockType(str, Enum):
    HYPERTROPHY = "hypertrophy"
    STRENGTH = "strength"
    POWERLIFTING = "powerlifting"
    MAINTENANCE = "maintenance"
    CUTTING = "cutting"
    PEAKING = "peaking"
    DELOAD = "deload"
    OTHER = "other"


class WorkoutPlanCreate(BaseModel):
    name: str
    description: str | None = None
    block_type: BlockType = BlockType.OTHER
    duration_weeks: int = Field(default=4, ge=1, le=12)
    number_of_days: int = Field(default=1, ge=1, le=7)
    days: list[PlannedDay] = []
    auto_progression: bool = True
    is_draft: bool = False


class WorkoutPlanResponse(BaseModel):
    id: int
    name: str
    description: str | None
    block_type: str
    duration_weeks: int
    current_week: int
    number_of_days: int
    days: list[PlannedDay]
    auto_progression: bool
    is_draft: bool = False
    is_archived: bool = False
    created_at: datetime

    model_config = {"from_attributes": True}


# Progress schemas
class ProgressResponse(BaseModel):
    exercise_id: int
    exercise_name: str
    date: date
    estimated_1rm: float | None
    volume_load: float
    recommended_weight: float | None
    progression_notes: str | None


class ProgressionRecommendation(BaseModel):
    exercise_id: int
    exercise_name: str
    current_weight: float
    recommended_weight: float
    reason: str
    confidence: float


# Body weight schemas
class BodyWeightCreate(BaseModel):
    weight_kg: float = Field(gt=0, description="Body weight in kg — must be greater than zero")
    body_fat_pct: float | None = Field(default=None, ge=3, le=60)
    recorded_at: str | None = None  # ISO datetime string, optional
    notes: str | None = None


class BodyWeightUpdate(BaseModel):
    weight_kg: float | None = None
    notes: str | None = None


# ── Nutrition schemas ─────────────────────────────────────────────────────────

class MealType(str, Enum):
    BREAKFAST = "breakfast"
    LUNCH = "lunch"
    DINNER = "dinner"
    SNACK = "snack"


class FoodItemCreate(BaseModel):
    name: str
    brand: str | None = None
    barcode: str | None = None
    calories_per_100g: float = Field(ge=0)
    protein_per_100g: float = Field(ge=0)
    carbs_per_100g: float = Field(ge=0)
    fat_per_100g: float = Field(ge=0)
    serving_size_g: float = Field(default=100, gt=0)
    serving_label: str | None = None
    micronutrients: dict | None = None


class NutritionEntryCreate(BaseModel):
    food_item_id: int | None = None
    name: str
    date: date
    meal: MealType = MealType.SNACK
    quantity_g: float = Field(ge=0)  # ge=0 to allow alcohol/quick-add entries with 0g
    calories: float = Field(ge=0)
    protein: float = Field(ge=0)
    carbs: float = Field(ge=0)
    fat: float = Field(ge=0)
    micronutrients: dict | None = None


class NutritionEntryUpdate(BaseModel):
    quantity_g: float | None = Field(default=None, ge=0)
    calories: float | None = Field(default=None, ge=0)
    protein: float | None = Field(default=None, ge=0)
    carbs: float | None = Field(default=None, ge=0)
    fat: float | None = Field(default=None, ge=0)
    meal: MealType | None = None


class WaterEntryCreate(BaseModel):
    date: date
    amount_ml: float = Field(gt=0)


class MacroGoalsUpdate(BaseModel):
    calories: float = Field(gt=0)
    protein: float = Field(ge=0)
    carbs: float = Field(ge=0)
    fat: float = Field(ge=0)
    effective_from: date | None = None
    micronutrient_goals: dict | None = None
    water_goal_ml: float | None = Field(default=None, gt=0)


class PhaseType(str, Enum):
    CUT = "cut"
    BULK = "bulk"
    MAINTENANCE = "maintenance"


class CarbPreset(str, Enum):
    HIGH = "high"
    MODERATE = "moderate"
    LOW = "low"


class DietPhaseCreate(BaseModel):
    phase_type: PhaseType
    duration_weeks: int = Field(ge=4, le=24, default=8)
    target_rate_pct: float = Field(ge=0, le=1.5, default=0.7)
    activity_multiplier: float = Field(ge=1.0, le=2.0, default=1.4)
    tdee_override: float | None = None
    carb_preset: CarbPreset = CarbPreset.MODERATE
    body_fat_pct: float | None = Field(default=None, ge=5, le=60)
    protein_per_lb: float | None = Field(default=None, ge=0.5, le=1.5)
