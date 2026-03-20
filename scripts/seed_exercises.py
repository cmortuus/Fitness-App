"""Script to seed the database with default exercises."""

import asyncio
import json

from app.database import async_session_factory, init_db
from app.models.exercise import Exercise, ExerciseType, MuscleGroup


DEFAULT_EXERCISES = [
    # Squat variations
    {
        "name": "back_squat",
        "display_name": "Back Squat",
        "exercise_type": ExerciseType.SQUAT,
        "description": "Barbell back squat targeting quads, glutes, and hamstrings.",
        "technique_cues": {
            "stance": "Shoulder-width stance with toes slightly pointed out",
            "depth": "Squat until hip crease is below knee",
            "back": "Keep back neutral, chest up",
            "knees": "Push knees out in line with toes",
        },
        "primary_muscles": [MuscleGroup.QUADRICEPS.value, MuscleGroup.GLUTES.value],
        "secondary_muscles": [MuscleGroup.HAMSTRINGS.value, MuscleGroup.CORE.value],
        "expected_rom_min": 70.0,
        "expected_rom_max": 90.0,
    },
    {
        "name": "front_squat",
        "display_name": "Front Squat",
        "exercise_type": ExerciseType.SQUAT,
        "description": "Barbell front squat with more quad emphasis.",
        "technique_cues": {
            "rack": "Bar rests on front shoulders with high elbow position",
            "stance": "Shoulder-width stance",
            "depth": "Full depth, hip crease below knee",
            "torso": "Keep torso more upright than back squat",
        },
        "primary_muscles": [MuscleGroup.QUADRICEPS.value],
        "secondary_muscles": [MuscleGroup.GLUTES.value, MuscleGroup.CORE.value],
        "expected_rom_min": 70.0,
        "expected_rom_max": 90.0,
    },
    {
        "name": "goblet_squat",
        "display_name": "Goblet Squat",
        "exercise_type": ExerciseType.SQUAT,
        "description": "Dumbbell or kettlebell held at chest for squat pattern.",
        "technique_cues": {
            "hold": "Weight held at chest with elbows down",
            "stance": "Shoulder-width or slightly wider",
            "depth": "Go as deep as mobility allows",
            "posture": "Keep chest up throughout",
        },
        "primary_muscles": [MuscleGroup.QUADRICEPS.value],
        "secondary_muscles": [MuscleGroup.GLUTES.value, MuscleGroup.CORE.value],
        "expected_rom_min": 70.0,
        "expected_rom_max": 90.0,
    },

    # Deadlift variations
    {
        "name": "conventional_deadlift",
        "display_name": "Conventional Deadlift",
        "exercise_type": ExerciseType.DEADLIFT,
        "description": "Barbell deadlift from floor with conventional stance.",
        "technique_cues": {
            "stance": "Hip-width stance",
            "grip": "Hands just outside legs, overhand or mixed",
            "start": "Bar over mid-foot, hips higher than knees",
            "pull": "Drive through floor, lock out at top",
        },
        "primary_muscles": [MuscleGroup.HAMSTRINGS.value, MuscleGroup.GLUTES.value, MuscleGroup.BACK.value],
        "secondary_muscles": [MuscleGroup.QUADRICEPS.value, MuscleGroup.CORE.value],
        "expected_rom_min": 60.0,
        "expected_rom_max": 90.0,
    },
    {
        "name": "sumo_deadlift",
        "display_name": "Sumo Deadlift",
        "exercise_type": ExerciseType.DEADLIFT,
        "description": "Deadlift with wide stance and narrow grip.",
        "technique_cues": {
            "stance": "Very wide stance, toes pointed out",
            "grip": "Hands narrow, inside legs",
            "start": "Torso more upright than conventional",
            "pull": "Push knees out, drive through outer foot",
        },
        "primary_muscles": [MuscleGroup.HAMSTRINGS.value, MuscleGroup.GLUTES.value, MuscleGroup.QUADRICEPS.value],
        "secondary_muscles": [MuscleGroup.BACK.value, MuscleGroup.CORE.value],
        "expected_rom_min": 60.0,
        "expected_rom_max": 90.0,
    },
    {
        "name": "romanian_deadlift",
        "display_name": "Romanian Deadlift",
        "exercise_type": ExerciseType.DEADLIFT,
        "description": "Deadlift variation targeting hamstrings with constant knee bend.",
        "technique_cues": {
            "knees": "Slight knee bend, maintain throughout",
            "hinge": "Push hips back, not down",
            "range": "Lower bar to mid-shin or until stretch",
            "back": "Maintain neutral spine",
        },
        "primary_muscles": [MuscleGroup.HAMSTRINGS.value],
        "secondary_muscles": [MuscleGroup.GLUTES.value, MuscleGroup.BACK.value],
        "expected_rom_min": 90.0,
        "expected_rom_max": 140.0,
    },

    # Bench press variations
    {
        "name": "bench_press",
        "display_name": "Bench Press",
        "exercise_type": ExerciseType.BENCH_PRESS,
        "description": "Barbell bench press for chest, shoulders, and triceps.",
        "technique_cues": {
            "setup": "Retract scapula, slight arch, feet flat",
            "grip": "Grip width varies, typically shoulder-width + hands",
            "descent": "Lower to lower chest/sternum",
            "touch": "Light touch, drive up",
        },
        "primary_muscles": [MuscleGroup.CHEST.value],
        "secondary_muscles": [MuscleGroup.SHOULDERS.value, MuscleGroup.TRICEPS.value],
        "expected_rom_min": 90.0,
        "expected_rom_max": 180.0,
    },
    {
        "name": "close_grip_bench_press",
        "display_name": "Close-Grip Bench Press",
        "exercise_type": ExerciseType.BENCH_PRESS,
        "description": "Bench press with narrow grip for triceps emphasis.",
        "technique_cues": {
            "grip": "Hands shoulder-width or narrower",
            "elbows": "Keep elbows tucked, not flared",
            "descent": "Lower to mid-chest",
            "press": "Press straight up",
        },
        "primary_muscles": [MuscleGroup.TRICEPS.value],
        "secondary_muscles": [MuscleGroup.CHEST.value, MuscleGroup.SHOULDERS.value],
        "expected_rom_min": 100.0,
        "expected_rom_max": 170.0,
    },
    {
        "name": "incline_bench_press",
        "display_name": "Incline Bench Press",
        "exercise_type": ExerciseType.BENCH_PRESS,
        "description": "Bench press on incline bench for upper chest.",
        "technique_cues": {
            "angle": "30-45 degree incline",
            "grip": "Standard bench grip width",
            "descent": "Lower to upper chest/clavicle area",
            "press": "Press up and slightly back",
        },
        "primary_muscles": [MuscleGroup.CHEST.value],
        "secondary_muscles": [MuscleGroup.SHOULDERS.value, MuscleGroup.TRICEPS.value],
        "expected_rom_min": 90.0,
        "expected_rom_max": 170.0,
    },

    # Overhead press variations
    {
        "name": "overhead_press",
        "display_name": "Overhead Press",
        "exercise_type": ExerciseType.OVERHEAD_PRESS,
        "description": "Standing barbell overhead press.",
        "technique_cues": {
            "rack": "Bar at clavicle, elbows slightly forward",
            "stance": "Shoulder-width stance",
            "press": "Press bar overhead, lock out",
            "path": "Bar path straight up, head moves back",
        },
        "primary_muscles": [MuscleGroup.SHOULDERS.value],
        "secondary_muscles": [MuscleGroup.TRICEPS.value, MuscleGroup.CORE.value],
        "expected_rom_min": 90.0,
        "expected_rom_max": 180.0,
    },

    # Row variations
    {
        "name": "barbell_row",
        "display_name": "Barbell Row",
        "exercise_type": ExerciseType.ROW,
        "description": "Bent-over barbell row for back development.",
        "technique_cues": {
            "stance": "Hip-width stance, hinge at hips",
            "grip": "Overhand grip, slightly wider than shoulders",
            "back": "Maintain flat back, torso around 45 degrees",
            "pull": "Pull bar to lower chest/upper abs",
        },
        "primary_muscles": [MuscleGroup.BACK.value],
        "secondary_muscles": [MuscleGroup.BICEPS.value, MuscleGroup.SHOULDERS.value],
        "expected_rom_min": 60.0,
        "expected_rom_max": 120.0,
    },
    {
        "name": "pendlay_row",
        "display_name": "Pendlay Row",
        "exercise_type": ExerciseType.ROW,
        "description": "Barbell row from floor each rep for power.",
        "technique_cues": {
            "start": "Bar starts on floor each rep",
            "stance": "Similar to deadlift setup",
            "pull": "Explosive pull to chest",
            "back": "Keep back flat and parallel to floor",
        },
        "primary_muscles": [MuscleGroup.BACK.value],
        "secondary_muscles": [MuscleGroup.BICEPS.value, MuscleGroup.SHOULDERS.value],
        "expected_rom_min": 70.0,
        "expected_rom_max": 120.0,
    },

    # Pull-ups
    {
        "name": "pull_up",
        "display_name": "Pull-Up",
        "exercise_type": ExerciseType.PULL_UP,
        "description": "Bodyweight pull-up targeting back and biceps.",
        "technique_cues": {
            "grip": "Overhand grip, wider than shoulders",
            "start": "Full hang, arms extended",
            "pull": "Pull chin over bar",
            "descent": "Control back to full hang",
        },
        "primary_muscles": [MuscleGroup.BACK.value],
        "secondary_muscles": [MuscleGroup.BICEPS.value],
        "expected_rom_min": 90.0,
        "expected_rom_max": 180.0,
    },
    {
        "name": "chin_up",
        "display_name": "Chin-Up",
        "exercise_type": ExerciseType.PULL_UP,
        "description": "Pull-up with underhand grip for biceps emphasis.",
        "technique_cues": {
            "grip": "Underhand grip, shoulder-width",
            "start": "Full hang, arms extended",
            "pull": "Pull chin over bar",
            "descent": "Control back to full hang",
        },
        "primary_muscles": [MuscleGroup.BICEPS.value, MuscleGroup.BACK.value],
        "secondary_muscles": [],
        "expected_rom_min": 90.0,
        "expected_rom_max": 180.0,
    },

    # Dips
    {
        "name": "dip",
        "display_name": "Dip",
        "exercise_type": ExerciseType.DIP,
        "description": "Bodyweight dip for triceps and chest.",
        "technique_cues": {
            "setup": "Hands on parallel bars, arms locked",
            "descent": "Lower until shoulders below elbows",
            "lean": "More forward lean = more chest",
            "press": "Press back to locked position",
        },
        "primary_muscles": [MuscleGroup.TRICEPS.value, MuscleGroup.CHEST.value],
        "secondary_muscles": [MuscleGroup.SHOULDERS.value],
        "expected_rom_min": 60.0,
        "expected_rom_max": 120.0,
    },

    # Lunges
    {
        "name": "lunge",
        "display_name": "Lunge",
        "exercise_type": ExerciseType.LUNGE,
        "description": "Walking or reverse lunge for leg development.",
        "technique_cues": {
            "stance": "Step forward into lunge position",
            "depth": "Lower until back knee nearly touches floor",
            "knee": "Front knee tracks over ankle",
            "return": "Push through front heel to return",
        },
        "primary_muscles": [MuscleGroup.QUADRICEPS.value, MuscleGroup.GLUTES.value],
        "secondary_muscles": [MuscleGroup.HAMSTRINGS.value],
        "expected_rom_min": 70.0,
        "expected_rom_max": 120.0,
    },
]


async def seed_exercises() -> None:
    """Seed the database with default exercises."""
    print("Initializing database...")
    await init_db()

    print("Seeding exercises...")
    async with async_session_factory() as session:
        for exercise_data in DEFAULT_EXERCISES:
            # Check if exercise already exists
            from sqlalchemy import select
            result = await session.execute(
                select(Exercise).where(Exercise.name == exercise_data["name"])
            )
            if result.scalar_one_or_none():
                print(f"  Exercise '{exercise_data['name']}' already exists, skipping...")
                continue

            # Create new exercise
            exercise = Exercise(
                name=exercise_data["name"],
                display_name=exercise_data["display_name"],
                exercise_type=exercise_data["exercise_type"],
                description=exercise_data.get("description"),
                technique_cues=json.dumps(exercise_data.get("technique_cues")) if exercise_data.get("technique_cues") else None,
                primary_muscles=json.dumps(exercise_data.get("primary_muscles", [])),
                secondary_muscles=json.dumps(exercise_data.get("secondary_muscles", [])),
                expected_rom_min=exercise_data.get("expected_rom_min"),
                expected_rom_max=exercise_data.get("expected_rom_max"),
            )
            session.add(exercise)
            print(f"  Added exercise: {exercise_data['display_name']}")

        await session.commit()

    print("Seeding complete!")


if __name__ == "__main__":
    asyncio.run(seed_exercises())