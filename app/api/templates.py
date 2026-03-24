"""Workout template API — browse and clone pre-built programs."""

import json
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.template import WorkoutTemplate
from app.models.workout import WorkoutPlan
from app.models.user import User

router = APIRouter()


def serialize_template(t: WorkoutTemplate) -> dict:
    try:
        exercises_data = json.loads(t.planned_exercises) if t.planned_exercises else {}
    except (json.JSONDecodeError, TypeError):
        exercises_data = {}

    days = exercises_data.get("days", [])
    exercise_count = sum(len(d.get("exercises", [])) for d in days)

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
    return [serialize_template(t) for t in result.scalars().all()]


@router.get("/{template_id}")
async def get_template(
    template_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get a single template with full exercise details."""
    result = await db.execute(
        select(WorkoutTemplate).where(WorkoutTemplate.id == template_id)
    )
    template = result.scalar_one_or_none()
    if not template:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Template not found")
    return serialize_template(template)


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
