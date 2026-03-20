"""Workout plan API endpoints."""

import json
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.workout import WorkoutPlan, WorkoutSession, ExerciseSet
from app.models.exercise import Exercise
from app.schemas.requests import WorkoutPlanCreate, WorkoutPlanResponse

router = APIRouter()


def serialize_plan(plan: WorkoutPlan) -> dict:
    """Serialize a WorkoutPlan to a dictionary."""
    planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}

    # Handle both old format (list of exercises) and new format (days structure)
    if isinstance(planned_data, list):
        # Old format - convert to new days structure
        days = [{
            "day_number": 1,
            "day_name": "Day 1",
            "exercises": planned_data
        }]
        number_of_days = 1
    else:
        # New format
        days = planned_data.get("days", [])
        number_of_days = planned_data.get("number_of_days", len(days))

    return {
        "id": plan.id,
        "name": plan.name,
        "description": plan.description,
        "block_type": getattr(plan, 'block_type', 'other'),
        "duration_weeks": getattr(plan, 'duration_weeks', 4),
        "current_week": getattr(plan, 'current_week', 1),
        "number_of_days": number_of_days,
        "days": days,
        "auto_progression": plan.auto_progression,
        "is_archived": getattr(plan, 'is_archived', False),
        "created_at": plan.created_at,
    }


@router.get("/", response_model=list[WorkoutPlanResponse])
async def list_plans(
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    """List all workout plans."""
    result = await db.execute(select(WorkoutPlan).order_by(WorkoutPlan.created_at.desc()))
    plans = result.scalars().all()
    return [serialize_plan(p) for p in plans]


@router.get("/exercises/recent", response_model=list[dict])
async def get_recent_exercises(
    db: Annotated[AsyncSession, Depends(get_db)],
    user_id: int | None = Query(None, description="Filter by user ID"),
    limit: int = Query(10, ge=1, le=50),
) -> list[dict]:
    """Get recently used exercises with frequency count.

    Returns exercises ordered by most recently used, with usage count.
    """
    # Query to get exercises used in recent sessions with their frequency
    query = (
        select(
            Exercise.id,
            Exercise.name,
            Exercise.display_name,
            Exercise.movement_type,
            Exercise.primary_muscles,
            func.count(ExerciseSet.id).label("usage_count"),
            func.max(WorkoutSession.date).label("last_used")
        )
        .join(ExerciseSet, Exercise.id == ExerciseSet.exercise_id)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .group_by(Exercise.id)
        .order_by(func.max(WorkoutSession.date).desc())
        .limit(limit)
    )

    if user_id:
        query = query.where(WorkoutSession.user_id == user_id)

    result = await db.execute(query)
    exercises = result.all()

    return [
        {
            "id": ex.id,
            "name": ex.name,
            "display_name": ex.display_name,
            "movement_type": ex.movement_type,
            "primary_muscles": json.loads(ex.primary_muscles) if ex.primary_muscles else [],
            "usage_count": ex.usage_count,
            "last_used": ex.last_used.isoformat() if ex.last_used else None,
        }
        for ex in exercises
    ]


@router.get("/exercises/grouped", response_model=dict[str, list[dict]])
async def get_exercises_grouped(
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict[str, list[dict]]:
    """Get all exercises grouped by primary muscle group."""
    result = await db.execute(select(Exercise).order_by(Exercise.display_name))
    exercises = result.scalars().all()

    grouped: dict[str, list[dict]] = {}

    for ex in exercises:
        primary_muscles = json.loads(ex.primary_muscles) if ex.primary_muscles else ["other"]

        for muscle in primary_muscles:
            muscle = muscle.lower().replace(" ", "_")
            if muscle not in grouped:
                grouped[muscle] = []
            grouped[muscle].append({
                "id": ex.id,
                "name": ex.name,
                "display_name": ex.display_name,
                "movement_type": getattr(ex, 'movement_type', 'compound'),
                "body_region": getattr(ex, 'body_region', 'upper'),
                "primary_muscles": primary_muscles,
            })

    # Sort keys for consistent ordering
    return dict(sorted(grouped.items()))


@router.get("/{plan_id}", response_model=WorkoutPlanResponse)
async def get_plan(
    plan_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get a workout plan by ID."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout plan {plan_id} not found",
        )
    return serialize_plan(plan)


@router.post("/", response_model=WorkoutPlanResponse, status_code=status.HTTP_201_CREATED)
async def create_plan(
    plan_data: WorkoutPlanCreate,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a new workout plan."""
    # Convert days structure to JSON
    planned_data = {
        "number_of_days": plan_data.number_of_days,
        "days": [d.model_dump() for d in plan_data.days]
    }
    planned_exercises_json = json.dumps(planned_data)

    # Validate all exercise IDs exist
    all_exercise_ids = {
        ex.exercise_id
        for day in plan_data.days
        for ex in day.exercises
    }
    if all_exercise_ids:
        result = await db.execute(
            select(Exercise.id).where(Exercise.id.in_(all_exercise_ids))
        )
        found_ids = {row[0] for row in result.all()}
        missing = all_exercise_ids - found_ids
        if missing:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Exercise IDs not found: {sorted(missing)}",
            )

    plan = WorkoutPlan(
        name=plan_data.name,
        description=plan_data.description,
        block_type=plan_data.block_type.value,
        duration_weeks=plan_data.duration_weeks,
        current_week=1,  # Start at week 1
        planned_exercises=planned_exercises_json,
        auto_progression=plan_data.auto_progression,
    )
    db.add(plan)
    await db.flush()
    await db.refresh(plan)
    return serialize_plan(plan)


@router.post("/{plan_id}/archive", response_model=WorkoutPlanResponse)
async def archive_plan(
    plan_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Mark a completed plan as archived. It stays in history but moves out of the active list."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Plan {plan_id} not found")
    plan.is_archived = True
    await db.commit()
    await db.refresh(plan)
    return serialize_plan(plan)


@router.post("/{plan_id}/reuse", response_model=WorkoutPlanResponse, status_code=status.HTTP_201_CREATED)
async def reuse_plan(
    plan_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a fresh active copy of an archived plan so you can run the block again."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id))
    source = result.scalar_one_or_none()
    if not source:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Plan {plan_id} not found")

    new_plan = WorkoutPlan(
        name=source.name,
        description=source.description,
        block_type=source.block_type,
        duration_weeks=source.duration_weeks,
        current_week=1,
        planned_exercises=source.planned_exercises,
        auto_progression=source.auto_progression,
        min_technique_score=source.min_technique_score,
        is_archived=False,
    )
    db.add(new_plan)
    await db.flush()
    await db.refresh(new_plan)
    return serialize_plan(new_plan)


@router.delete("/{plan_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_plan(
    plan_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a workout plan."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout plan {plan_id} not found",
        )
    await db.delete(plan)


class PlanUpdate(BaseModel):
    """Schema for updating a workout plan."""
    name: str | None = None
    description: str | None = None
    block_type: str | None = None
    duration_weeks: int | None = None
    number_of_days: int | None = None
    days: list | None = None
    auto_progression: bool | None = None


@router.put("/{plan_id}", response_model=WorkoutPlanResponse)
async def update_plan(
    plan_id: int,
    plan_data: PlanUpdate,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Update a workout plan."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout plan {plan_id} not found",
        )

    # Update fields if provided
    if plan_data.name is not None:
        plan.name = plan_data.name
    if plan_data.description is not None:
        plan.description = plan_data.description
    if plan_data.block_type is not None:
        plan.block_type = plan_data.block_type
    if plan_data.duration_weeks is not None:
        plan.duration_weeks = plan_data.duration_weeks
    if plan_data.auto_progression is not None:
        plan.auto_progression = plan_data.auto_progression

    # Handle days update
    if plan_data.days is not None or plan_data.number_of_days is not None:
        # Get current planned exercises
        planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}

        if isinstance(planned_data, list):
            # Old format - convert to new days structure
            planned_data = {
                "number_of_days": plan_data.number_of_days or 1,
                "days": planned_data
            }

        # Update days if provided
        if plan_data.days is not None:
            planned_data["days"] = plan_data.days
        if plan_data.number_of_days is not None:
            planned_data["number_of_days"] = plan_data.number_of_days

        plan.planned_exercises = json.dumps(planned_data)

    await db.commit()
    await db.refresh(plan)
    return serialize_plan(plan)
