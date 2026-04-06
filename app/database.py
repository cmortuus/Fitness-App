"""Database connection and session management."""

from typing import AsyncGenerator

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.config import get_settings

settings = get_settings()

engine_kwargs = {
    "echo": settings.debug,
    "pool_pre_ping": True,
    "pool_size": 5,
    "max_overflow": 10,
}

engine = create_async_engine(settings.database_url, **engine_kwargs)

async_session_factory = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autocommit=False,
    autoflush=False,
)


class Base(DeclarativeBase):
    """Base class for all SQLAlchemy models."""

    pass


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """Dependency for getting async database sessions."""
    async with async_session_factory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
        finally:
            await session.close()


async def init_db() -> None:
    """Initialize database tables."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    # Seed with default exercises — never let this crash startup
    try:
        await seed_exercises()
    except Exception as e:
        print(f"⚠️ Exercise seeding failed (non-fatal): {e}")

    # Seed workout templates
    try:
        await seed_templates()
    except Exception as e:
        print(f"⚠️ Template seeding failed (non-fatal): {e}")


async def seed_exercises() -> None:
    """Seed database with default exercises if empty."""
    from app.models.exercise import Exercise

    async with async_session_factory() as session:
        default_exercises = [
            # ========== CHEST ==========
            # Compound
            {"name": "barbell_bench_press", "display_name": "Barbell Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "incline_barbell_press", "display_name": "Incline Barbell Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "decline_barbell_press", "display_name": "Decline Barbell Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "dumbbell_bench_press", "display_name": "Dumbbell Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "incline_dumbbell_press", "display_name": "Incline Dumbbell Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "decline_dumbbell_press", "display_name": "Decline Dumbbell Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "weighted_dip", "display_name": "Weighted Dip", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "triceps"], "secondary_muscles": ["front_delts"]},
            {"name": "machine_chest_press", "display_name": "Machine Chest Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "smith_machine_press", "display_name": "Smith Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "incline_smith_machine_press", "display_name": "Incline Smith Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "decline_smith_machine_press", "display_name": "Decline Smith Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "incline_machine_chest_press", "display_name": "Incline Machine Chest Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "hammer_strength_chest_press", "display_name": "Hammer Strength Chest Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "hammer_strength_incline_press", "display_name": "Hammer Strength Incline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "push_up", "display_name": "Push Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "incline_push_up", "display_name": "Incline Push Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "decline_push_up", "display_name": "Decline Push Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "ring_push_up", "display_name": "Ring Push Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "core"]},
            {"name": "neutral_grip_dumbbell_press", "display_name": "Neutral Grip Dumbbell Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            # Isolation
            {"name": "dumbbell_flye", "display_name": "Dumbbell Flye", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "incline_dumbbell_flye", "display_name": "Incline Dumbbell Flye", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "cable_crossover", "display_name": "Cable Crossover", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "low_cable_crossover", "display_name": "Low Cable Crossover", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "high_cable_crossover", "display_name": "High Cable Crossover", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "pec_deck", "display_name": "Pec Deck", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "svend_press", "display_name": "Svend Press", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "floor_press", "display_name": "Floor Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps"]},
            {"name": "landmine_press", "display_name": "Landmine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "front_delts"], "secondary_muscles": ["triceps"]},
            {"name": "cable_chest_fly", "display_name": "Cable Chest Fly", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "low_to_high_cable_fly", "display_name": "Low to High Cable Fly", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "high_to_low_cable_fly", "display_name": "High to Low Cable Fly", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "decline_cable_fly", "display_name": "Decline Cable Fly", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "spoto_press", "display_name": "Spoto Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps"]},
            {"name": "pin_press", "display_name": "Pin Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps"]},
            {"name": "board_press", "display_name": "Board Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps"]},

            # ========== BACK ==========
            # Lats (Vertical Pull)
            {"name": "pull_up", "display_name": "Pull Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "chin_up", "display_name": "Chin Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "lat_pulldown", "display_name": "Lat Pulldown", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "close_grip_lat_pulldown", "display_name": "Close Grip Lat Pulldown", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "single_arm_lat_pulldown", "display_name": "Single Arm Lat Pulldown", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"], "is_unilateral": True},
            {"name": "straight_arm_pulldown", "display_name": "Straight Arm Pulldown", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": []},
            {"name": "machine_pullover", "display_name": "Machine Pullover", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": []},
            {"name": "weighted_pull_up", "display_name": "Weighted Pull Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "neutral_grip_pull_up", "display_name": "Neutral Grip Pull Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "wide_grip_pull_up", "display_name": "Wide Grip Pull Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "neutral_grip_lat_pulldown", "display_name": "Neutral Grip Lat Pulldown", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "wide_grip_lat_pulldown", "display_name": "Wide Grip Lat Pulldown", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "cable_pullover", "display_name": "Cable Pullover", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": []},
            {"name": "dumbbell_pullover", "display_name": "Dumbbell Pullover", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["chest"]},
            # Rhomboids/Mid-Back (Horizontal Pull)
            {"name": "barbell_row", "display_name": "Barbell Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps", "hamstrings", "lower_back"]},
            {"name": "pendlay_row", "display_name": "Pendlay Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps", "lower_back"]},
            {"name": "dumbbell_row", "display_name": "Dumbbell Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"], "is_unilateral": True},
            {"name": "cable_row", "display_name": "Cable Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "seated_cable_row", "display_name": "Seated Cable Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "chest_supported_row", "display_name": "Chest Supported Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "machine_row", "display_name": "Machine Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "t_bar_row", "display_name": "T-Bar Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "meadows_row", "display_name": "Meadows Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"], "is_unilateral": True},
            {"name": "inverted_row", "display_name": "Inverted Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "seal_row", "display_name": "Seal Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "smith_machine_row", "display_name": "Smith Machine Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "trap_bar_row", "display_name": "Trap Bar Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "one_arm_cable_row", "display_name": "One Arm Cable Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"], "is_unilateral": True},
            {"name": "hammer_strength_row", "display_name": "Hammer Strength Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "iso_lateral_row", "display_name": "ISO Lateral Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "ring_row", "display_name": "Ring Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "yates_row", "display_name": "Yates Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            # Lower Back
            {"name": "back_extension", "display_name": "Back Extension", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["lower_back"], "secondary_muscles": ["hamstrings", "glutes"]},
            {"name": "reverse_hyperextension", "display_name": "Reverse Hyperextension", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["lower_back"], "secondary_muscles": ["hamstrings", "glutes"]},

            # ========== SHOULDERS ==========
            # Front Delts
            {"name": "overhead_press", "display_name": "Overhead Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "dumbbell_overhead_press", "display_name": "Dumbbell Overhead Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "arnold_press", "display_name": "Arnold Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "machine_shoulder_press", "display_name": "Machine Shoulder Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "viking_press", "display_name": "Viking Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "smith_machine_overhead_press", "display_name": "Smith Machine Overhead Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "seated_barbell_ohp", "display_name": "Seated Barbell OHP", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "push_press", "display_name": "Push Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps", "quadriceps"]},
            {"name": "z_press", "display_name": "Z Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps", "core"]},
            {"name": "landmine_press_shoulder", "display_name": "Landmine Press (Shoulder)", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            # Side Delts
            {"name": "dumbbell_lateral_raise", "display_name": "Dumbbell Lateral Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": []},
            {"name": "cable_lateral_raise", "display_name": "Cable Lateral Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "machine_lateral_raise", "display_name": "Machine Lateral Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": []},
            {"name": "leaning_cable_lateral_raise", "display_name": "Leaning Cable Lateral Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "cable_y_raise", "display_name": "Cable Y-Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": []},
            {"name": "upright_row", "display_name": "Upright Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": ["traps", "biceps"]},
            {"name": "cable_upright_row", "display_name": "Cable Upright Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": ["traps", "biceps"]},
            # Rear Delts
            {"name": "rear_delt_flye", "display_name": "Rear Delt Flye", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},
            {"name": "cable_rear_delt_flye", "display_name": "Cable Rear Delt Flye", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},
            {"name": "machine_reverse_flye", "display_name": "Machine Reverse Flye", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},
            {"name": "face_pull", "display_name": "Face Pull", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},
            {"name": "cable_face_pull", "display_name": "Cable Face Pull", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},
            {"name": "reverse_pec_deck", "display_name": "Reverse Pec Deck", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},
            {"name": "dumbbell_front_raise", "display_name": "Dumbbell Front Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": []},
            {"name": "cable_front_raise", "display_name": "Cable Front Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": []},
            {"name": "plate_front_raise", "display_name": "Plate Front Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": []},
            {"name": "band_pull_apart", "display_name": "Band Pull Apart", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},
            {"name": "prone_y_raise", "display_name": "Prone Y Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},
            {"name": "landmine_lateral_raise", "display_name": "Landmine Lateral Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "w_raise", "display_name": "W Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["rear_delts"], "secondary_muscles": []},

            # ========== TRAPS ==========
            {"name": "barbell_shrug", "display_name": "Barbell Shrug", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["traps"], "secondary_muscles": []},
            {"name": "dumbbell_shrug", "display_name": "Dumbbell Shrug", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["traps"], "secondary_muscles": []},
            {"name": "rack_pull", "display_name": "Rack Pull", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["traps", "upper_back"], "secondary_muscles": ["hamstrings", "glutes"]},
            {"name": "snatch_grip_shrug", "display_name": "Snatch Grip Shrug", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["traps"], "secondary_muscles": []},

            # ========== QUADRICEPS ==========
            {"name": "squat", "display_name": "Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings", "calves", "lower_back"]},
            {"name": "front_squat", "display_name": "Front Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings", "lower_back"]},
            {"name": "high_bar_squat", "display_name": "High Bar Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings", "lower_back"]},
            {"name": "low_bar_squat", "display_name": "Low Bar Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings", "lower_back"]},
            {"name": "safety_bar_squat", "display_name": "Safety Bar Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings", "lower_back"]},
            {"name": "leg_press", "display_name": "Leg Press", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "hack_squat", "display_name": "Hack Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "pendulum_squat", "display_name": "Pendulum Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "leg_extension", "display_name": "Leg Extension", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": []},
            {"name": "sissy_squat", "display_name": "Sissy Squat", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": []},
            {"name": "goblet_squat", "display_name": "Goblet Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "cyclist_squat", "display_name": "Cyclist Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes"]},
            {"name": "bulgarian_split_squat", "display_name": "Bulgarian Split Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings"], "is_unilateral": True},
            {"name": "walking_lunge", "display_name": "Walking Lunge", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings"], "is_unilateral": True},
            {"name": "reverse_lunge", "display_name": "Reverse Lunge", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings"], "is_unilateral": True},
            {"name": "step_up", "display_name": "Step Up", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings"], "is_unilateral": True},
            {"name": "leg_press_calf_raise", "display_name": "Leg Press Calf Raise", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["calves"], "secondary_muscles": []},
            {"name": "box_squat", "display_name": "Box Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings", "lower_back"]},
            {"name": "pause_squat", "display_name": "Pause Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings", "lower_back"]},
            {"name": "smith_machine_squat", "display_name": "Smith Machine Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "zercher_squat", "display_name": "Zercher Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings", "lower_back"]},
            {"name": "belt_squat", "display_name": "Belt Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "heel_elevated_squat", "display_name": "Heel Elevated Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes"]},
            {"name": "single_leg_press", "display_name": "Single Leg Press", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"], "is_unilateral": True},
            {"name": "landmine_squat", "display_name": "Landmine Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes"]},
            {"name": "terminal_knee_extension", "display_name": "Terminal Knee Extension", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": []},
            {"name": "single_leg_extension", "display_name": "Single Leg Extension", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": [], "is_unilateral": True},

            # ========== HAMSTRINGS ==========
            {"name": "deadlift", "display_name": "Deadlift", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "glutes", "lower_back"], "secondary_muscles": ["traps", "quadriceps"]},
            {"name": "sumo_deadlift", "display_name": "Sumo Deadlift", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "glutes", "quadriceps", "adductors"], "secondary_muscles": ["lower_back", "traps"]},
            {"name": "romanian_deadlift", "display_name": "Romanian Deadlift", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": ["glutes", "lower_back"]},
            {"name": "stiff_leg_deadlift", "display_name": "Stiff Leg Deadlift", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": ["glutes", "lower_back"]},
            {"name": "leg_curl", "display_name": "Leg Curl", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": []},
            {"name": "seated_leg_curl", "display_name": "Seated Leg Curl", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": []},
            {"name": "lying_leg_curl", "display_name": "Lying Leg Curl", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": []},
            {"name": "nordic_curl", "display_name": "Nordic Curl", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": []},
            {"name": "good_morning", "display_name": "Good Morning", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": ["lower_back", "glutes"]},
            {"name": "single_leg_rdl", "display_name": "Single Leg RDL", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": ["glutes", "lower_back"], "is_unilateral": True},
            {"name": "trap_bar_deadlift", "display_name": "Trap Bar Deadlift", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "quadriceps", "glutes"], "secondary_muscles": ["lower_back", "traps"]},
            {"name": "pause_deadlift", "display_name": "Pause Deadlift", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "glutes"], "secondary_muscles": ["lower_back", "traps", "quadriceps"]},
            {"name": "deficit_deadlift", "display_name": "Deficit Deadlift", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "glutes"], "secondary_muscles": ["lower_back", "traps", "quadriceps"]},
            {"name": "glute_ham_raise", "display_name": "Glute Ham Raise", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": ["glutes"]},
            {"name": "natural_leg_curl", "display_name": "Natural Leg Curl", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": []},
            {"name": "single_leg_curl", "display_name": "Single Leg Curl", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "dumbbell_leg_curl", "display_name": "Dumbbell Leg Curl", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": []},
            {"name": "cable_pull_through", "display_name": "Cable Pull Through", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings", "glutes"], "secondary_muscles": []},

            # ========== GLUTES ==========
            {"name": "hip_thrust", "display_name": "Hip Thrust", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": ["hamstrings"]},
            {"name": "barbell_hip_thrust", "display_name": "Barbell Hip Thrust", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": ["hamstrings"]},
            {"name": "single_leg_hip_thrust", "display_name": "Single Leg Hip Thrust", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": ["hamstrings"], "is_unilateral": True},
            {"name": "glute_bridge", "display_name": "Glute Bridge", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": ["hamstrings"]},
            {"name": "cable_pull_through", "display_name": "Cable Pull Through", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["glutes", "hamstrings"], "secondary_muscles": []},
            {"name": "frog_pump", "display_name": "Frog Pump", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": []},
            {"name": "glute_kickback", "display_name": "Glute Kickback", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "cable_glute_kickback", "display_name": "Cable Glute Kickback", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "reverse_hyper", "display_name": "Reverse Hyper", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes", "hamstrings"], "secondary_muscles": []},
            {"name": "kettlebell_swing", "display_name": "Kettlebell Swing", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["glutes", "hamstrings"], "secondary_muscles": ["lower_back", "front_delts"]},
            {"name": "smith_machine_hip_thrust", "display_name": "Smith Machine Hip Thrust", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": ["hamstrings"]},
            {"name": "hip_abduction_machine", "display_name": "Hip Abduction Machine", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": []},
            {"name": "hip_adduction_machine", "display_name": "Hip Adduction Machine", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["adductors"], "secondary_muscles": []},
            {"name": "cable_hip_abduction", "display_name": "Cable Hip Abduction", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "cable_glute_kickback", "display_name": "Cable Glute Kickback", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "donkey_kick", "display_name": "Donkey Kick", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "clamshell", "display_name": "Clamshell", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": []},
            {"name": "sumo_squat", "display_name": "Sumo Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["glutes", "quadriceps", "adductors"], "secondary_muscles": ["hamstrings"]},

            # ========== CALVES ==========
            {"name": "standing_calf_raise", "display_name": "Standing Calf Raise", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["calves"], "secondary_muscles": []},
            {"name": "seated_calf_raise", "display_name": "Seated Calf Raise", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["calves"], "secondary_muscles": []},
            {"name": "donkey_calf_raise", "display_name": "Donkey Calf Raise", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["calves"], "secondary_muscles": []},
            {"name": "single_leg_calf_raise", "display_name": "Single Leg Calf Raise", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["calves"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "tibialis_raise", "display_name": "Tibialis Raise", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["calves"], "secondary_muscles": []},
            {"name": "smith_machine_calf_raise", "display_name": "Smith Machine Calf Raise", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["calves"], "secondary_muscles": []},

            # ========== BICEPS ==========
            {"name": "barbell_curl", "display_name": "Barbell Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "ez_bar_curl", "display_name": "EZ Bar Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "dumbbell_curl", "display_name": "Dumbbell Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "hammer_curl", "display_name": "Hammer Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "preacher_curl", "display_name": "Preacher Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "incline_curl", "display_name": "Incline Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "spider_curl", "display_name": "Spider Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "concentration_curl", "display_name": "Concentration Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "cable_curl", "display_name": "Cable Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "bayesian_curl", "display_name": "Bayesian Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "drag_curl", "display_name": "Drag Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "machine_curl", "display_name": "Machine Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "reverse_curl", "display_name": "Reverse Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps", "forearms"], "secondary_muscles": []},
            {"name": "zottman_curl", "display_name": "Zottman Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps", "forearms"], "secondary_muscles": []},
            {"name": "cross_body_hammer_curl", "display_name": "Cross Body Hammer Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "cable_hammer_curl", "display_name": "Cable Hammer Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "machine_preacher_curl", "display_name": "Machine Preacher Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "single_arm_preacher_curl", "display_name": "Single Arm Preacher Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "ez_bar_preacher_curl", "display_name": "EZ Bar Preacher Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "high_cable_curl", "display_name": "High Cable Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},

            # ========== TRICEPS ==========
            {"name": "tricep_pushdown", "display_name": "Tricep Pushdown", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "rope_pushdown", "display_name": "Rope Pushdown", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "overhead_tricep_extension", "display_name": "Overhead Tricep Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "cable_overhead_extension", "display_name": "Cable Overhead Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "skull_crusher", "display_name": "Skull Crusher", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "cable_skull_crusher", "display_name": "Cable Skull Crusher", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "close_grip_bench", "display_name": "Close Grip Bench", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": ["chest"]},
            {"name": "jm_press", "display_name": "JM Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": ["chest"]},
            {"name": "dip", "display_name": "Dip", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "triceps"], "secondary_muscles": ["front_delts"]},
            {"name": "bench_dip", "display_name": "Bench Dip", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": ["chest"]},
            {"name": "kickback", "display_name": "Kickback", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "cable_kickback", "display_name": "Cable Kickback", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "machine_dip", "display_name": "Machine Dip", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "triceps"], "secondary_muscles": []},
            {"name": "single_arm_pushdown", "display_name": "Single Arm Pushdown", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "single_arm_overhead_extension", "display_name": "Single Arm Overhead Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": [], "is_unilateral": True},
            {"name": "tate_press", "display_name": "Tate Press", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "rolling_tricep_extension", "display_name": "Rolling Tricep Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "lying_tricep_extension", "display_name": "Lying Tricep Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "french_press", "display_name": "French Press", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "ez_bar_overhead_extension", "display_name": "EZ Bar Overhead Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "bar_pushdown", "display_name": "Bar Pushdown", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},

            # ========== FOREARMS ==========
            {"name": "wrist_curl", "display_name": "Wrist Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["forearms"], "secondary_muscles": []},
            {"name": "reverse_wrist_curl", "display_name": "Reverse Wrist Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["forearms"], "secondary_muscles": []},
            {"name": "farmer_carry", "display_name": "Farmer Carry", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["forearms"], "secondary_muscles": ["traps", "core"]},
            {"name": "dead_hang", "display_name": "Dead Hang", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["forearms"], "secondary_muscles": []},
            {"name": "plate_pinch", "display_name": "Plate Pinch", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["forearms"], "secondary_muscles": []},
            {"name": "wrist_roller", "display_name": "Wrist Roller", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["forearms"], "secondary_muscles": []},
            {"name": "towel_pull_up", "display_name": "Towel Pull Up", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["forearms", "lats"], "secondary_muscles": ["biceps"]},

            # ========== ABS / CORE ==========
            {"name": "plank", "display_name": "Plank", "movement_type": "isolation", "body_region": "full_body", "primary_muscles": ["abs", "core"], "secondary_muscles": []},
            {"name": "side_plank", "display_name": "Side Plank", "movement_type": "isolation", "body_region": "full_body", "primary_muscles": ["obliques", "core"], "secondary_muscles": []},
            {"name": "hanging_leg_raise", "display_name": "Hanging Leg Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["abs"], "secondary_muscles": []},
            {"name": "lying_leg_raise", "display_name": "Lying Leg Raise", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["abs"], "secondary_muscles": []},
            {"name": "cable_crunch", "display_name": "Cable Crunch", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["abs"], "secondary_muscles": []},
            {"name": "machine_crunch", "display_name": "Machine Crunch", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["abs"], "secondary_muscles": []},
            {"name": "ab_wheel", "display_name": "Ab Wheel", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["abs", "core"], "secondary_muscles": []},
            {"name": "russian_twist", "display_name": "Russian Twist", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["obliques", "abs"], "secondary_muscles": []},
            {"name": "pallof_press", "display_name": "Pallof Press", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["core", "obliques"], "secondary_muscles": []},
            {"name": "woodchop", "display_name": "Woodchop", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["obliques", "core"], "secondary_muscles": ["front_delts"]},
            {"name": "reverse_crunch", "display_name": "Reverse Crunch", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["abs"], "secondary_muscles": []},
            {"name": "v_up", "display_name": "V-Up", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["abs"], "secondary_muscles": []},
            {"name": "toes_to_bar", "display_name": "Toes to Bar", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["abs"], "secondary_muscles": []},
            {"name": "dragon_flag", "display_name": "Dragon Flag", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["abs", "core"], "secondary_muscles": []},
            {"name": "vacuum", "display_name": "Stomach Vacuum", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["core"], "secondary_muscles": []},
            {"name": "dead_bug", "display_name": "Dead Bug", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["core", "abs"], "secondary_muscles": []},
            {"name": "bird_dog", "display_name": "Bird Dog", "movement_type": "isolation", "body_region": "full_body", "primary_muscles": ["core", "lower_back"], "secondary_muscles": []},

            # ========== NECK ==========
            {"name": "neck_extension", "display_name": "Neck Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["neck"], "secondary_muscles": []},
            {"name": "neck_flexion", "display_name": "Neck Flexion", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["neck"], "secondary_muscles": []},
            {"name": "neck_harness", "display_name": "Neck Harness", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["neck"], "secondary_muscles": []},
            {"name": "neck_lateral_flexion", "display_name": "Neck Lateral Flexion", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["neck"], "secondary_muscles": []},

            # ========== POWER / ATHLETIC ==========
            {"name": "power_clean", "display_name": "Power Clean", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["lower_back", "traps", "front_delts"]},
            {"name": "hang_clean", "display_name": "Hang Clean", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["lower_back", "traps", "front_delts"]},
            {"name": "clean_and_jerk", "display_name": "Clean and Jerk", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["quadriceps", "glutes", "front_delts"], "secondary_muscles": ["lower_back", "traps"]},
            {"name": "snatch", "display_name": "Snatch", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["quadriceps", "glutes", "front_delts"], "secondary_muscles": ["lower_back", "traps"]},
            {"name": "hang_snatch", "display_name": "Hang Snatch", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["quadriceps", "glutes", "front_delts"], "secondary_muscles": ["lower_back", "traps"]},
            {"name": "box_jump", "display_name": "Box Jump", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings", "calves"]},
            {"name": "broad_jump", "display_name": "Broad Jump", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings", "calves"]},
            {"name": "sled_push", "display_name": "Sled Push", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings", "calves", "front_delts"]},
            {"name": "sled_pull", "display_name": "Sled Pull", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "glutes"], "secondary_muscles": ["upper_back", "biceps"]},
            {"name": "battle_ropes", "display_name": "Battle Ropes", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["side_delts", "core"], "secondary_muscles": ["upper_back", "biceps"]},
            {"name": "medicine_ball_slam", "display_name": "Medicine Ball Slam", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["core", "lats"], "secondary_muscles": ["lats", "quadriceps"]},

            # ========== TRAPS (additional) ==========
            {"name": "cable_shrug", "display_name": "Cable Shrug", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["traps"], "secondary_muscles": []},
            {"name": "smith_machine_shrug", "display_name": "Smith Machine Shrug", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["traps"], "secondary_muscles": []},
            {"name": "behind_back_shrug", "display_name": "Behind Back Shrug", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["traps"], "secondary_muscles": []},

            # ========== SPECIALTY BAR VARIATIONS ==========
            # --- Cambered / Rackable Cambered Bar ---
            {"name": "cambered_bar_bench_press", "display_name": "Cambered Bar Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "cambered_bar_row", "display_name": "Cambered Bar Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "cambered_bar_squat", "display_name": "Cambered Bar Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "cambered_bar_deadlift", "display_name": "Cambered Bar Deadlift", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "glutes"], "secondary_muscles": ["lower_back", "traps"]},
            {"name": "cambered_bar_overhead_press", "display_name": "Cambered Bar Overhead Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "cambered_bar_good_morning", "display_name": "Cambered Bar Good Morning", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": ["lower_back", "glutes"]},

            # --- SSB (Safety Squat Bar) ---
            {"name": "ssb_squat", "display_name": "SSB Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "ssb_good_morning", "display_name": "SSB Good Morning", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": ["lower_back", "glutes"]},
            {"name": "ssb_box_squat", "display_name": "SSB Box Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "ssb_pause_squat", "display_name": "SSB Pause Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "ssb_front_squat", "display_name": "SSB Front Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes"]},
            {"name": "ssb_lunge", "display_name": "SSB Lunge", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings"], "is_unilateral": True},

            # --- EZ Bar (additional variations) ---
            {"name": "ez_bar_bench_press", "display_name": "EZ Bar Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "ez_bar_incline_press", "display_name": "EZ Bar Incline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "ez_bar_row", "display_name": "EZ Bar Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "ez_bar_skull_crusher", "display_name": "EZ Bar Skull Crusher", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "ez_bar_reverse_curl", "display_name": "EZ Bar Reverse Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps", "forearms"], "secondary_muscles": []},
            {"name": "ez_bar_upright_row", "display_name": "EZ Bar Upright Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["side_delts"], "secondary_muscles": ["traps", "biceps"]},
            {"name": "ez_bar_good_morning", "display_name": "EZ Bar Good Morning", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["hamstrings"], "secondary_muscles": ["lower_back", "glutes"]},
            {"name": "rackable_ez_bar_curl", "display_name": "Rackable EZ Bar Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "rackable_ez_bar_bench", "display_name": "Rackable EZ Bar Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},

            # --- Swiss Bar / Football Bar / Multi-Grip Bar ---
            {"name": "swiss_bar_bench_press", "display_name": "Swiss Bar Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "swiss_bar_incline_press", "display_name": "Swiss Bar Incline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "swiss_bar_overhead_press", "display_name": "Swiss Bar Overhead Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "swiss_bar_row", "display_name": "Swiss Bar Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "swiss_bar_skull_crusher", "display_name": "Swiss Bar Skull Crusher", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "swiss_bar_curl", "display_name": "Swiss Bar Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "multi_grip_pulldown", "display_name": "Multi-Grip Pulldown", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},

            # --- Buffalo Bar ---
            {"name": "buffalo_bar_squat", "display_name": "Buffalo Bar Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "buffalo_bar_bench_press", "display_name": "Buffalo Bar Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},

            # --- Trap Bar / Hex Bar ---
            {"name": "trap_bar_overhead_press", "display_name": "Trap Bar Overhead Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "trap_bar_farmers_carry", "display_name": "Trap Bar Farmer's Carry", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["forearms", "traps"], "secondary_muscles": ["core", "quadriceps"]},
            {"name": "trap_bar_shrug", "display_name": "Trap Bar Shrug", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["traps"], "secondary_muscles": []},
            {"name": "trap_bar_jump", "display_name": "Trap Bar Jump", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings", "calves"]},

            # --- Axle Bar ---
            {"name": "axle_bar_deadlift", "display_name": "Axle Bar Deadlift", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "glutes"], "secondary_muscles": ["lower_back", "traps", "forearms"]},
            {"name": "axle_bar_bench_press", "display_name": "Axle Bar Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "axle_bar_overhead_press", "display_name": "Axle Bar Overhead Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "axle_bar_curl", "display_name": "Axle Bar Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps", "forearms"], "secondary_muscles": []},
            {"name": "axle_bar_row", "display_name": "Axle Bar Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps", "forearms"]},

            # --- Log Bar (Strongman) ---
            {"name": "log_press", "display_name": "Log Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["front_delts"], "secondary_muscles": ["side_delts", "triceps"]},
            {"name": "log_clean_and_press", "display_name": "Log Clean and Press", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["front_delts", "quadriceps"], "secondary_muscles": ["triceps", "lower_back"]},

            # --- Duffalo Bar ---
            {"name": "duffalo_bar_squat", "display_name": "Duffalo Bar Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "duffalo_bar_bench_press", "display_name": "Duffalo Bar Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "duffalo_bar_deadlift", "display_name": "Duffalo Bar Deadlift", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["hamstrings", "glutes"], "secondary_muscles": ["lower_back", "traps"]},

            # --- Curl Bar / Preacher Curl Bar variations ---
            {"name": "reverse_ez_bar_curl", "display_name": "Reverse EZ Bar Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps", "forearms"], "secondary_muscles": []},
            {"name": "ez_bar_spider_curl", "display_name": "EZ Bar Spider Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},

            # ========== GRIP WIDTH VARIATIONS ==========
            {"name": "wide_grip_bench_press", "display_name": "Wide Grip Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "neutral_grip_bench_press", "display_name": "Neutral Grip Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "close_grip_incline_press", "display_name": "Close Grip Incline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "triceps"], "secondary_muscles": ["front_delts"]},
            {"name": "wide_grip_incline_press", "display_name": "Wide Grip Incline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "neutral_grip_incline_press", "display_name": "Neutral Grip Incline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "close_grip_decline_press", "display_name": "Close Grip Decline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "triceps"], "secondary_muscles": ["front_delts"]},
            {"name": "wide_grip_decline_press", "display_name": "Wide Grip Decline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "neutral_grip_decline_press", "display_name": "Neutral Grip Decline Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "close_grip_machine_chest_press", "display_name": "Close Grip Machine Chest Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "triceps"], "secondary_muscles": ["front_delts"]},
            {"name": "wide_grip_machine_chest_press", "display_name": "Wide Grip Machine Chest Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "neutral_grip_machine_chest_press", "display_name": "Neutral Grip Machine Chest Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "close_grip_barbell_row", "display_name": "Close Grip Barbell Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "wide_grip_barbell_row", "display_name": "Wide Grip Barbell Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["upper_back"], "secondary_muscles": ["lats", "mid_back", "biceps"]},
            {"name": "neutral_grip_barbell_row", "display_name": "Neutral Grip Barbell Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "close_grip_cable_row", "display_name": "Close Grip Cable Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "wide_grip_cable_row", "display_name": "Wide Grip Cable Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["upper_back"], "secondary_muscles": ["lats", "mid_back", "biceps"]},
            {"name": "neutral_grip_cable_row", "display_name": "Neutral Grip Cable Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},

            # ========== INCLINE ANGLE VARIATIONS ==========
            {"name": "15_degree_incline_dumbbell_press", "display_name": "15\u00b0 Incline Dumbbell Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "30_degree_incline_dumbbell_press", "display_name": "30\u00b0 Incline Dumbbell Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "45_degree_incline_dumbbell_press", "display_name": "45\u00b0 Incline Dumbbell Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "front_delts"], "secondary_muscles": ["triceps"]},
            {"name": "15_degree_smith_machine_press", "display_name": "15\u00b0 Smith Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "30_degree_smith_machine_press", "display_name": "30\u00b0 Smith Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "45_degree_smith_machine_press", "display_name": "45\u00b0 Smith Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "front_delts"], "secondary_muscles": ["triceps"]},
            {"name": "15_degree_incline_cable_fly", "display_name": "15\u00b0 Incline Cable Fly", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "30_degree_incline_cable_fly", "display_name": "30\u00b0 Incline Cable Fly", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "45_degree_incline_cable_fly", "display_name": "45\u00b0 Incline Cable Fly", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},
            {"name": "15_degree_machine_press", "display_name": "15\u00b0 Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "30_degree_machine_press", "display_name": "30\u00b0 Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "45_degree_machine_press", "display_name": "45\u00b0 Machine Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest", "front_delts"], "secondary_muscles": ["triceps"]},

            # ========== ADDITIONAL MISSING EXERCISES ==========
            {"name": "kroc_row", "display_name": "Kroc Row", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps", "forearms"], "is_unilateral": True},
            {"name": "larsen_press", "display_name": "Larsen Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "spanish_squat", "display_name": "Spanish Squat", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": []},
            {"name": "reverse_grip_bench_press", "display_name": "Reverse Grip Bench Press", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "biceps"]},
            {"name": "reverse_grip_lat_pulldown", "display_name": "Reverse Grip Lat Pulldown", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "jefferson_squat", "display_name": "Jefferson Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["hamstrings", "lower_back"]},
            {"name": "standing_calf_raise_machine", "display_name": "Standing Calf Raise Machine", "movement_type": "isolation", "body_region": "lower", "primary_muscles": ["calves"], "secondary_muscles": []},
            {"name": "dumbbell_overhead_tricep_extension", "display_name": "Dumbbell Overhead Tricep Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "cable_woodchop", "display_name": "Cable Woodchop", "movement_type": "compound", "body_region": "full_body", "primary_muscles": ["obliques", "core"], "secondary_muscles": ["front_delts"]},
            {"name": "v_squat", "display_name": "V-Squat", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["quadriceps"], "secondary_muscles": ["glutes", "hamstrings"]},
            {"name": "glute_drive_machine", "display_name": "Glute Drive Machine", "movement_type": "compound", "body_region": "lower", "primary_muscles": ["glutes"], "secondary_muscles": ["hamstrings"]},
            {"name": "chest_supported_row_machine", "display_name": "Chest Supported Row Machine", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "low_row_machine", "display_name": "Low Row Machine", "movement_type": "compound", "body_region": "upper", "primary_muscles": ["mid_back"], "secondary_muscles": ["lats", "upper_back", "biceps"]},
            {"name": "machine_bicep_curl", "display_name": "Machine Bicep Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "machine_tricep_extension", "display_name": "Machine Tricep Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "cable_bicep_curl", "display_name": "Cable Bicep Curl", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["biceps"], "secondary_muscles": []},
            {"name": "cable_tricep_extension", "display_name": "Cable Tricep Extension", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["triceps"], "secondary_muscles": []},
            {"name": "cable_flye", "display_name": "Cable Flye", "movement_type": "isolation", "body_region": "upper", "primary_muscles": ["chest"], "secondary_muscles": []},

            # ========== ASSISTED EXERCISES ==========
            {"name": "assisted_pull_up_machine", "display_name": "Assisted Pull-Up Machine", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "assisted_pull_up_machine_wide_grip", "display_name": "Assisted Pull-Up Machine Wide Grip", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "assisted_pull_up_machine_neutral_grip", "display_name": "Assisted Pull-Up Machine Neutral Grip", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "assisted_pull_up_machine_close_grip", "display_name": "Assisted Pull-Up Machine Close Grip", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "assisted_chin_up_machine", "display_name": "Assisted Chin-Up Machine", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["lats", "biceps"], "secondary_muscles": []},
            {"name": "assisted_dip_machine", "display_name": "Assisted Dip Machine", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["chest", "triceps"], "secondary_muscles": ["front_delts"]},
            {"name": "assisted_dip_machine_wide_grip", "display_name": "Assisted Dip Machine Wide Grip (Chest)", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "front_delts"]},
            {"name": "assisted_dip_machine_close_grip", "display_name": "Assisted Dip Machine Close Grip (Tricep)", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["triceps"], "secondary_muscles": ["chest", "front_delts"]},
            {"name": "band_assisted_pull_up", "display_name": "Band Assisted Pull-Up", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["lats"], "secondary_muscles": ["biceps"]},
            {"name": "band_assisted_chin_up", "display_name": "Band Assisted Chin-Up", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["lats", "biceps"], "secondary_muscles": []},
            {"name": "band_assisted_dip", "display_name": "Band Assisted Dip", "movement_type": "compound", "body_region": "upper", "is_assisted": True, "primary_muscles": ["chest", "triceps"], "secondary_muscles": ["front_delts"]},
            {"name": "pistol_squat", "display_name": "Pistol Squat", "movement_type": "compound", "body_region": "lower", "is_unilateral": True, "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["core"]},
            {"name": "assisted_pistol_squat", "display_name": "Assisted Pistol Squat (Band / TRX)", "movement_type": "compound", "body_region": "lower", "is_assisted": True, "is_unilateral": True, "primary_muscles": ["quadriceps", "glutes"], "secondary_muscles": ["core"]},
        ]

        seeded_count = 0
        skipped_count = 0

        updated_count = 0
        for ex_data in default_exercises:
            # Check if exercise already exists
            existing = await session.execute(
                select(Exercise).where(Exercise.name == ex_data["name"])
            )
            ex = existing.scalar_one_or_none()
            if ex:
                # Update fields that may have changed or been added after initial seed
                changed = False
                want_uni = ex_data.get("is_unilateral", False)
                want_ast = ex_data.get("is_assisted", False)
                want_primary = ex_data.get("primary_muscles", [])
                want_secondary = ex_data.get("secondary_muscles", [])
                if ex.is_unilateral != want_uni:
                    ex.is_unilateral = want_uni
                    changed = True
                if ex.is_assisted != want_ast:
                    ex.is_assisted = want_ast
                    changed = True
                if sorted(ex.primary_muscles or []) != sorted(want_primary):
                    ex.primary_muscles = want_primary
                    changed = True
                if sorted(ex.secondary_muscles or []) != sorted(want_secondary):
                    ex.secondary_muscles = want_secondary
                    changed = True
                if changed:
                    updated_count += 1
                skipped_count += 1
                continue

            exercise = Exercise(
                name=ex_data["name"],
                display_name=ex_data["display_name"],
                movement_type=ex_data["movement_type"],
                body_region=ex_data["body_region"],
                primary_muscles=ex_data["primary_muscles"],
                secondary_muscles=ex_data["secondary_muscles"],
                is_unilateral=ex_data.get("is_unilateral", False),
                is_assisted=ex_data.get("is_assisted", False),
            )
            session.add(exercise)
            seeded_count += 1

        try:
            await session.commit()
            print(f"✅ Seeded {seeded_count} new exercises, updated {updated_count} flags (skipped {skipped_count} unchanged)")
        except Exception:
            await session.rollback()
            # Duplicates in DB — seed one-by-one to skip conflicts
            seeded_count = 0
            for ex_data in default_exercises:
                try:
                    async with async_session_factory() as s2:
                        existing = await s2.execute(
                            select(Exercise).where(Exercise.name == ex_data["name"])
                        )
                        if existing.scalar_one_or_none():
                            continue
                        s2.add(Exercise(
                            name=ex_data["name"],
                            display_name=ex_data["display_name"],
                            movement_type=ex_data["movement_type"],
                            body_region=ex_data["body_region"],
                            primary_muscles=ex_data["primary_muscles"],
                            secondary_muscles=ex_data["secondary_muscles"],
                            is_unilateral=ex_data.get("is_unilateral", False),
                            is_assisted=ex_data.get("is_assisted", False),
                        ))
                        await s2.commit()
                        seeded_count += 1
                except Exception:
                    pass
            print(f"✅ Seeded {seeded_count} exercises (conflict-safe fallback)")


async def seed_templates() -> None:
    """Seed workout templates if the table is empty."""
    import json
    from app.models.template import WorkoutTemplate
    from app.models.exercise import Exercise
    from app.data.templates import TEMPLATES

    async with async_session_factory() as session:
        result = await session.execute(select(WorkoutTemplate).limit(1))
        if result.scalar_one_or_none():
            return  # Already seeded

        # Build exercise name → id lookup
        ex_result = await session.execute(select(Exercise))
        exercises = {e.name: e.id for e in ex_result.scalars().all()}

        seeded = 0
        for tmpl in TEMPLATES:
            # Resolve exercise names to IDs
            days = []
            valid = True
            for day in tmpl["days"]:
                resolved = []
                for ex in day["exercises"]:
                    ex_id = exercises.get(ex["exercise"])
                    if not ex_id:
                        print(f"  ⚠️ Template '{tmpl['name']}': exercise '{ex['exercise']}' not found, skipping template")
                        valid = False
                        break
                    resolved.append({
                        "exercise_id": ex_id,
                        "sets": ex["sets"],
                        "reps": ex["reps"],
                        "starting_weight_kg": 0,
                        "progression_type": "linear",
                    })
                if not valid:
                    break
                days.append({
                    "day_number": day["day_number"],
                    "day_name": day["day_name"],
                    "exercises": resolved,
                })

            if not valid:
                continue

            planned = json.dumps({"number_of_days": tmpl["days_per_week"], "days": days})
            session.add(WorkoutTemplate(
                name=tmpl["name"],
                split_type=tmpl["split_type"],
                days_per_week=tmpl["days_per_week"],
                equipment_tier=tmpl["equipment_tier"],
                description=tmpl.get("description", ""),
                planned_exercises=planned,
                block_type=tmpl.get("block_type", "hypertrophy"),
            ))
            seeded += 1

        await session.commit()
        print(f"✅ Seeded {seeded} workout templates")