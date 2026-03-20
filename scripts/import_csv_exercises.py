"""Import exercises from CSV into database."""

import csv
import json
import re
from pathlib import Path

from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from app.database import Base
from app.models.exercise import Exercise, MovementType, BodyRegion


# Mapping tables
CATEGORY_MAPPING = {
    "Isolation": {
        "movement_type": MovementType.ISOLATION,
        "body_region": None,  # Determined by exercise name
    },
    "Hinge": {
        "movement_type": MovementType.COMPOUND,
        "body_region": BodyRegion.FULL_BODY,
    },
    "Squat": {
        "movement_type": MovementType.COMPOUND,
        "body_region": BodyRegion.LOWER,
    },
    "Press": {
        "movement_type": MovementType.COMPOUND,
        "body_region": BodyRegion.UPPER,
    },
    "Pull": {
        "movement_type": MovementType.COMPOUND,
        "body_region": BodyRegion.UPPER,
    },
}

# Exercise name → muscle group mapping
EXERCISE_MUSCLE_GROUPS = {
    # Chest
    "bench": ("chest", ["chest"], ["triceps", "shoulders"]),
    "incline press": ("chest", ["chest"], ["triceps", "shoulders"]),
    "decline bench": ("chest", ["chest"], ["triceps", "shoulders"]),
    "dip": ("chest", ["chest", "triceps"], ["shoulders"]),
    "fly": ("chest", ["chest"], []),
    "cable crossover": ("chest", ["chest"], []),
    "pec deck": ("chest", ["chest"], []),
    "push-up": ("chest", ["chest"], ["triceps", "shoulders"]),

    # Back
    "deadlift": ("back", ["hamstrings", "glutes", "back"], ["traps", "quadriceps"]),
    "romanian deadlift": ("back", ["hamstrings", "glutes"], ["back"]),
    "pull-up": ("back", ["back"], ["biceps"]),
    "chin-up": ("back", ["back"], ["biceps"]),
    "row": ("back", ["back"], ["biceps"]),
    "cable row": ("back", ["back"], ["biceps"]),
    "t-bar row": ("back", ["back"], ["biceps"]),
    "lat pulldown": ("back", ["back"], ["biceps"]),
    "face pull": ("back", ["back", "shoulders"], []),
    "good morning": ("back", ["hamstrings", "back"], ["glutes"]),
    "back extension": ("back", ["back"], ["hamstrings", "glutes"]),

    # Shoulders
    "overhead press": ("shoulders", ["shoulders"], ["triceps"]),
    "shoulder press": ("shoulders", ["shoulders"], ["triceps"]),
    "lateral raise": ("shoulders", ["shoulders"], []),
    "front raise": ("shoulders", ["shoulders"], []),
    "reverse fly": ("shoulders", ["shoulders"], []),
    "upright row": ("shoulders", ["shoulders", "traps"], ["biceps"]),
    "arnold press": ("shoulders", ["shoulders"], ["triceps"]),

    # Quads
    "squat": ("quads", ["quadriceps"], ["glutes", "hamstrings"]),
    "front squat": ("quads", ["quadriceps"], ["glutes", "back"]),
    "goblet squat": ("quads", ["quadriceps"], ["glutes", "hamstrings"]),
    "leg press": ("quads", ["quadriceps"], ["glutes", "hamstrings"]),
    "hack squat": ("quads", ["quadriceps"], ["glutes", "hamstrings"]),
    "lunge": ("quads", ["quadriceps", "glutes"], ["hamstrings"]),
    "bulgarian split squat": ("quads", ["quadriceps", "glutes"], ["hamstrings"]),
    "leg extension": ("quads", ["quadriceps"], []),

    # Hamstrings
    "leg curl": ("hamstrings", ["hamstrings"], []),
    "hip thrust": ("glutes", ["glutes"], ["hamstrings"]),
    "glute bridge": ("glutes", ["glutes"], ["hamstrings"]),

    # Triceps
    "tricep pushdown": ("triceps", ["triceps"], []),
    "tricep extension": ("triceps", ["triceps"], []),
    "skull crusher": ("triceps", ["triceps"], []),
    "close grip bench": ("triceps", ["triceps"], ["chest"]),

    # Biceps
    "bicep curl": ("biceps", ["biceps"], []),
    "hammer curl": ("biceps", ["biceps"], []),
    "preacher curl": ("biceps", ["biceps"], []),
    "concentration curl": ("biceps", ["biceps"], []),

    # Calves
    "calf raise": ("calves", ["calves"], []),

    # Core
    "crunch": ("core", ["abs"], []),
    "plank": ("core", ["abs", "core"], []),
    "leg raise": ("core", ["abs"], []),
    "cable crunch": ("core", ["abs"], []),
    "ab wheel": ("core", ["abs", "core"], []),
    "russian twist": ("core", ["obliques", "abs"], []),

    # Traps
    "shrug": ("traps", ["traps"], []),
    "farmer": ("traps", ["traps", "forearms"], ["core"]),
}


def parse_variation(variation_str: str) -> dict:
    """Parse variation string into structured data.

    Example: "Pronated, Narrow, Barbell" → {
        "grip": "pronated",
        "stance": "narrow",
        "equipment": "barbell"
    }
    """
    parts = [p.strip().lower() for p in variation_str.split(",")]

    result = {
        "grip": None,
        "stance": None,
        "equipment": None,
        "modifiers": [],
    }

    grip_keywords = ["pronated", "supinated", "neutral", "mixed", "false", "hammer"]
    stance_keywords = ["narrow", "wide", "shoulder width", "staggered", "sumo",
                       "conventional", "feet elevated", "elevated heels", "single leg",
                       "single arm", "bodyweight"]
    equipment_keywords = ["barbell", "dumbbell", "smith machine", "cable", "machine",
                          "bodyweight", "bands", "chains", "kettlebell", "trap bar",
                          "ez bar", "swiss bar", "axle bar"]

    for part in parts:
        if any(g in part for g in grip_keywords):
            result["grip"] = part
        elif any(s in part for s in stance_keywords):
            result["stance"] = part
        elif any(e in part for e in equipment_keywords):
            result["equipment"] = part
        else:
            result["modifiers"].append(part)

    return result


def get_muscle_groups(exercise_name: str) -> tuple[list[str], list[str]]:
    """Look up primary and secondary muscle groups for an exercise."""
    exercise_lower = exercise_name.lower()

    # Try to find a match
    for key, (_, primary, secondary) in EXERCISE_MUSCLE_GROUPS.items():
        if key in exercise_lower:
            return primary, secondary

    # Fallback based on category
    if "press" in exercise_lower or "bench" in exercise_lower:
        return ["chest"], ["triceps", "shoulders"]
    elif "pull" in exercise_lower or "row" in exercise_lower:
        return ["back"], ["biceps"]
    elif "squat" in exercise_lower:
        return ["quadriceps"], ["glutes", "hamstrings"]
    elif "curl" in exercise_lower:
        return ["biceps"], []
    elif "extension" in exercise_lower or "raise" in exercise_lower:
        return ["triceps"], []
    elif "thrust" in exercise_lower or "bridge" in exercise_lower:
        return ["glutes"], ["hamstrings"]

    return ["full_body"], []


def normalize_exercise_name(name: str) -> str:
    """Create a URL-safe name for the exercise."""
    # Lowercase and replace spaces with underscores
    name = name.lower().replace(" ", "_")
    # Remove special characters
    name = re.sub(r"[^a-z0-9_]", "", name)
    return name


def import_exercises(csv_path: str, db_url: str = "sqlite:///./homegym.db"):
    """Import exercises from CSV into database."""

    engine = create_engine(db_url)
    Base.metadata.create_all(engine)

    imported_count = 0
    skipped_count = 0

    with Session(engine) as session:
        with open(csv_path, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)

            for row in reader:
                category = row["Category"]
                exercise = row["Exercise"]
                variation = row["Variation"]

                # Create normalized name
                base_name = normalize_exercise_name(exercise)
                variation_data = parse_variation(variation)

                # Add variation details to name for uniqueness
                if variation_data["equipment"]:
                    base_name = f"{base_name}_{variation_data['equipment'].replace(' ', '_')}"
                if variation_data["grip"]:
                    base_name = f"{base_name}_{variation_data['grip'].replace(' ', '_')}"
                if variation_data["stance"]:
                    base_name = f"{base_name}_{variation_data['stance'].replace(' ', '_')}"

                # Check for duplicates
                existing = session.execute(
                    select(Exercise).where(Exercise.name == base_name)
                ).scalar_one_or_none()

                if existing:
                    skipped_count += 1
                    continue

                # Get muscle groups
                primary_muscles, secondary_muscles = get_muscle_groups(exercise)

                # Determine body region from category mapping or exercise name
                cat_info = CATEGORY_MAPPING.get(category, {})
                body_region = cat_info.get("body_region")

                # Override based on muscle groups if needed
                if not body_region:
                    if any(m in ["chest", "back", "shoulders", "biceps", "triceps", "traps"]
                           for m in primary_muscles):
                        body_region = BodyRegion.UPPER
                    elif any(m in ["quadriceps", "hamstrings", "glutes", "calves"]
                             for m in primary_muscles):
                        body_region = BodyRegion.LOWER
                    elif any(m in ["abs", "core", "obliques"] for m in primary_muscles):
                        body_region = BodyRegion.FULL_BODY
                    else:
                        body_region = BodyRegion.FULL_BODY

                # Create exercise
                exercise_obj = Exercise(
                    name=base_name,
                    display_name=exercise,
                    movement_type=cat_info.get("movement_type", MovementType.COMPOUND),
                    body_region=body_region,
                    primary_muscles=json.dumps(primary_muscles),
                    secondary_muscles=json.dumps(secondary_muscles),
                    detection_params=json.dumps(variation_data),
                    technique_cues=json.dumps({
                        "grip": variation_data.get("grip"),
                        "stance": variation_data.get("stance"),
                        "equipment": variation_data.get("equipment"),
                    }),
                )

                session.add(exercise_obj)
                imported_count += 1

                # Commit in batches
                if imported_count % 1000 == 0:
                    session.commit()
                    print(f"Imported {imported_count} exercises...")

            session.commit()

    print(f"\nImport complete!")
    print(f"  Imported: {imported_count}")
    print(f"  Skipped (duplicates): {skipped_count}")
    print(f"  Total processed: {imported_count + skipped_count}")


if __name__ == "__main__":
    csv_path = Path(__file__).parent.parent / "extreme_gym_exercises_no_intensity.csv"
    import_exercises(str(csv_path))
