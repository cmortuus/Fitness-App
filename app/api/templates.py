"""Workout template API — browse and clone pre-built programs."""

import json
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.exercise import Exercise
from app.models.template import WorkoutTemplate
from app.models.workout import WorkoutPlan
from app.models.user import User

router = APIRouter()


def _enrich_days(days: list[dict], exercise_names: dict[int, str]) -> list[dict]:
    """Add exercise_name to each exercise entry in days."""
    enriched = []
    for day in days:
        exercises = [
            {**ex, "exercise_name": exercise_names.get(ex.get("exercise_id", 0), f"Exercise {ex.get('exercise_id', '?')}")}
            for ex in day.get("exercises", [])
        ]
        enriched.append({**day, "exercises": exercises})
    return enriched


def serialize_template(t: WorkoutTemplate, exercise_names: dict[int, str] | None = None) -> dict:
    try:
        exercises_data = json.loads(t.planned_exercises) if t.planned_exercises else {}
    except (json.JSONDecodeError, TypeError):
        exercises_data = {}

    days = exercises_data.get("days", [])
    exercise_count = sum(len(d.get("exercises", [])) for d in days)

    if exercise_names:
        days = _enrich_days(days, exercise_names)

    return {
        "id": t.id,
        "name": t.name,
        "split_type": t.split_type,
        "days_per_week": t.days_per_week,
        "equipment_tier": t.equipment_tier,
        "description": t.description,
        "block_type": t.block_type,
        "exercise_count": exercise_count,
        "days": days,
    }


async def _load_exercise_names(db: AsyncSession, templates: list[WorkoutTemplate]) -> dict[int, str]:
    """Collect all exercise IDs from templates and fetch their display names."""
    ids: set[int] = set()
    for t in templates:
        try:
            data = json.loads(t.planned_exercises) if t.planned_exercises else {}
        except (json.JSONDecodeError, TypeError):
            data = {}
        for day in data.get("days", []):
            for ex in day.get("exercises", []):
                if eid := ex.get("exercise_id"):
                    ids.add(eid)
    if not ids:
        return {}
    result = await db.execute(select(Exercise.id, Exercise.display_name).where(Exercise.id.in_(ids)))
    return {row.id: row.display_name for row in result}


@router.get("/")
async def list_templates(
    db: Annotated[AsyncSession, Depends(get_db)],
    split_type: str | None = None,
    equipment_tier: str | None = None,
    days_per_week: int | None = None,
) -> list[dict]:
    """List all templates, optionally filtered."""
    stmt = select(WorkoutTemplate).order_by(
        WorkoutTemplate.split_type, WorkoutTemplate.days_per_week, WorkoutTemplate.equipment_tier
    )
    if split_type:
        stmt = stmt.where(WorkoutTemplate.split_type == split_type)
    if equipment_tier:
        stmt = stmt.where(WorkoutTemplate.equipment_tier == equipment_tier)
    if days_per_week:
        stmt = stmt.where(WorkoutTemplate.days_per_week == days_per_week)

    result = await db.execute(stmt)
    template_list = list(result.scalars().all())
    exercise_names = await _load_exercise_names(db, template_list)
    return [serialize_template(t, exercise_names) for t in template_list]


@router.get("/{template_id}")
async def get_template(
    template_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get a single template with full exercise details including names."""
    result = await db.execute(
        select(WorkoutTemplate).where(WorkoutTemplate.id == template_id)
    )
    template = result.scalar_one_or_none()
    if not template:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Template not found")
    exercise_names = await _load_exercise_names(db, [template])
    return serialize_template(template, exercise_names)


@router.post("/{template_id}/clone", status_code=status.HTTP_201_CREATED)
async def clone_template(
    template_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Clone a template into the user's workout plans."""
    result = await db.execute(
        select(WorkoutTemplate).where(WorkoutTemplate.id == template_id)
    )
    template = result.scalar_one_or_none()
    if not template:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Template not found")

    plan = WorkoutPlan(
        user_id=user.id,
        name=template.name,
        description=template.description,
        block_type=template.block_type,
        duration_weeks=4,
        planned_exercises=template.planned_exercises,
        auto_progression=True,
        is_draft=False,
        is_archived=False,
    )
    db.add(plan)
    await db.flush()
    await db.refresh(plan)

    return {
        "id": plan.id,
        "name": plan.name,
        "message": "Template cloned successfully. You can now edit or start this plan.",
    }
