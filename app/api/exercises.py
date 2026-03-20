"""Exercise API endpoints."""

import json
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.exercise import Exercise
from app.models.workout import ExerciseSet, WorkoutSession
from app.schemas.requests import ExerciseCreate, ExerciseResponse

router = APIRouter()


@router.get("/", response_model=list[ExerciseResponse])
async def list_exercises(
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    """List all available exercises."""
    result = await db.execute(select(Exercise).order_by(Exercise.name))
    exercises = result.scalars().all()

    # Convert to response format with proper JSON parsing
    responses = []
    for ex in exercises:
        responses.append({
            "id": ex.id,
            "name": ex.name,
            "display_name": ex.display_name,
            "movement_type": getattr(ex, 'movement_type', 'compound'),
            "body_region": getattr(ex, 'body_region', 'upper'),
            "is_unilateral": bool(getattr(ex, 'is_unilateral', False)),
            "is_assisted":   bool(getattr(ex, 'is_assisted',   False)),
            "description": ex.description,
            "primary_muscles": json.loads(ex.primary_muscles) if ex.primary_muscles else [],
            "secondary_muscles": json.loads(ex.secondary_muscles) if ex.secondary_muscles else [],
        })
    return responses


@router.get("/{exercise_id}", response_model=ExerciseResponse)
async def get_exercise(
    exercise_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get an exercise by ID."""
    result = await db.execute(select(Exercise).where(Exercise.id == exercise_id))
    ex = result.scalar_one_or_none()
    if not ex:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise {exercise_id} not found",
        )
    return {
        "id": ex.id,
        "name": ex.name,
        "display_name": ex.display_name,
        "movement_type": getattr(ex, 'movement_type', 'compound'),
        "body_region": getattr(ex, 'body_region', 'upper'),
        "description": ex.description,
        "primary_muscles": json.loads(ex.primary_muscles) if ex.primary_muscles else [],
        "secondary_muscles": json.loads(ex.secondary_muscles) if ex.secondary_muscles else [],
    }


@router.post("/", response_model=ExerciseResponse, status_code=status.HTTP_201_CREATED)
async def create_exercise(
    exercise_data: ExerciseCreate,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a new exercise definition."""
    exercise = Exercise(
        name=exercise_data.name,
        display_name=exercise_data.display_name,
        movement_type=exercise_data.movement_type.value,
        body_region=exercise_data.body_region.value,
        is_unilateral=exercise_data.is_unilateral,
        is_assisted=exercise_data.is_assisted,
        description=exercise_data.description,
        primary_muscles=json.dumps(exercise_data.primary_muscles),
        secondary_muscles=json.dumps(exercise_data.secondary_muscles),
    )
    db.add(exercise)
    await db.flush()
    await db.refresh(exercise)
    return {
        "id": exercise.id,
        "name": exercise.name,
        "display_name": exercise.display_name,
        "movement_type": exercise.movement_type,
        "body_region": exercise.body_region,
        "is_unilateral": bool(exercise.is_unilateral),
        "is_assisted":   bool(exercise.is_assisted),
        "description": exercise.description,
        "primary_muscles": exercise_data.primary_muscles,
        "secondary_muscles": exercise_data.secondary_muscles,
    }


@router.get("/{exercise_id}/history")
async def get_exercise_history(
    exercise_id: int,
    limit: int = 10,
    db: Annotated[AsyncSession, Depends(get_db)] = None,
) -> list[dict]:
    """Get the most recent completed sessions for a given exercise."""
    # Subquery: sessions that have at least one completed set
    sessions_with_data = (
        select(ExerciseSet.workout_session_id)
        .where(ExerciseSet.actual_reps.is_not(None))
    )

    result = await db.execute(
        select(ExerciseSet, WorkoutSession)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .where(
            ExerciseSet.exercise_id == exercise_id,
            ExerciseSet.actual_reps.is_not(None),
        )
        .order_by(desc(WorkoutSession.date), desc(WorkoutSession.id), ExerciseSet.set_number)
    )
    rows = result.all()

    # Group by session preserving order
    sessions_dict: dict[int, dict] = {}
    for exercise_set, session in rows:
        if session.id not in sessions_dict:
            sessions_dict[session.id] = {
                "session_id": session.id,
                "session_name": session.name,
                "workout_plan_id": session.workout_plan_id,
                "date": str(session.date),
                "week_number": None,
                "sets": [],
            }
        sessions_dict[session.id]["sets"].append({
            "set_number": exercise_set.set_number,
            "actual_reps": exercise_set.actual_reps,
            "actual_weight_kg": exercise_set.actual_weight_kg,
            "notes": exercise_set.notes,
        })

    sessions = list(sessions_dict.values())[:limit]

    # Compute week number and fetch plan name for plan-based sessions.
    # "Week N" = this was the Nth time this specific day was done within the plan.
    plan_ids = {s["workout_plan_id"] for s in sessions if s["workout_plan_id"]}
    for plan_id in plan_ids:
        # Fetch the plan name
        plan_result = await db.execute(
            select(WorkoutPlan.name).where(WorkoutPlan.id == plan_id)
        )
        plan_name = plan_result.scalar_one_or_none() or ""

        # Fetch all sessions for this plan that have data, in chronological order,
        # grouped by day name so each day has its own independent week counter.
        plan_sessions_result = await db.execute(
            select(WorkoutSession.id, WorkoutSession.name)
            .where(
                WorkoutSession.workout_plan_id == plan_id,
                WorkoutSession.id.in_(sessions_with_data),
            )
            .order_by(WorkoutSession.date, WorkoutSession.id)
        )
        plan_sessions = plan_sessions_result.all()

        # Build week number per session_name — each day name restarts at 1
        day_counters: dict[str, int] = {}
        session_week: dict[int, int] = {}
        for ps in plan_sessions:
            day_key = ps.name or ""
            day_counters[day_key] = day_counters.get(day_key, 0) + 1
            session_week[ps.id] = day_counters[day_key]

        for s in sessions:
            if s["workout_plan_id"] == plan_id:
                s["week_number"] = session_week.get(s["session_id"])
                s["plan_name"] = plan_name

    return sessions


@router.delete("/{exercise_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_exercise(
    exercise_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete an exercise definition."""
    # Check if exercise exists
    result = await db.execute(select(Exercise).where(Exercise.id == exercise_id))
    ex = result.scalar_one_or_none()
    if not ex:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise {exercise_id} not found",
        )

    # Check if exercise is used in any sets
    sets_result = await db.execute(
        select(ExerciseSet).where(ExerciseSet.exercise_id == exercise_id)
    )
    sets = sets_result.scalars().all()

    if sets and len(sets) > 0:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Cannot delete exercise '{ex.display_name}' - it is used in {len(sets)} workout set(s)",
        )

    # Delete the exercise
    await db.execute(delete(Exercise).where(Exercise.id == exercise_id))
    await db.commit()