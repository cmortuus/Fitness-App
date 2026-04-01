"""Exercise API endpoints."""

import json
import re
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, desc, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.exercise import Exercise
from app.models.exercise_note import ExerciseNote
from app.models.user import User
from app.models.workout import ExerciseFeedback, ExerciseSet, WorkoutPlan, WorkoutSession, WorkoutStatus
from pydantic import BaseModel as _PydanticBase
from app.schemas.requests import ExerciseCreate, ExerciseResponse, ExerciseUpdate

router = APIRouter()


def _serialize_exercise(ex: Exercise) -> dict:
    return {
        "id": ex.id,
        "name": ex.name,
        "display_name": ex.display_name,
        "user_id": ex.user_id,
        "source_exercise_id": ex.source_exercise_id,
        "is_custom": ex.user_id is not None,
        "movement_type": ex.movement_type,
        "body_region": ex.body_region,
        "equipment_type": ex.equipment_type or "other",
        "is_unilateral": bool(ex.is_unilateral),
        "is_assisted": bool(ex.is_assisted),
        "is_prime": bool(ex.is_prime),
        "description": ex.description,
        "primary_muscles": ex.primary_muscles or [],
        "secondary_muscles": ex.secondary_muscles or [],
    }


def _exercise_scope(user_id: int):
    return or_(Exercise.user_id.is_(None), Exercise.user_id == user_id)


async def _get_visible_exercise(db: AsyncSession, exercise_id: int, user_id: int) -> Exercise | None:
    result = await db.execute(
        select(Exercise).where(Exercise.id == exercise_id).where(_exercise_scope(user_id))
    )
    return result.scalar_one_or_none()


def _slugify_name(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    return slug or "custom_exercise"


async def _generate_unique_name(db: AsyncSession, user_id: int, display_name: str) -> str:
    base = _slugify_name(display_name)
    candidate = base
    suffix = 2
    while True:
        result = await db.execute(
            select(Exercise.id).where(Exercise.name == candidate)
        )
        if result.scalar_one_or_none() is None:
            return candidate
        candidate = f"{base}_{user_id}_{suffix}"
        suffix += 1


async def _replace_exercise_in_plans(
    db: AsyncSession,
    *,
    user_id: int,
    old_exercise_id: int,
    new_exercise_id: int,
) -> int:
    updated = 0
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.user_id == user_id))
    for plan in result.scalars().all():
        try:
            planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}
        except (json.JSONDecodeError, TypeError):
            planned_data = {}
        changed = False
        for day in planned_data.get("days", []):
            for exercise in day.get("exercises", []):
                if exercise.get("exercise_id") == old_exercise_id:
                    exercise["exercise_id"] = new_exercise_id
                    changed = True
        if changed:
            plan.planned_exercises = json.dumps(planned_data)
            updated += 1
    return updated


async def _replace_exercise_in_sessions(
    db: AsyncSession,
    *,
    user_id: int,
    old_exercise_id: int,
    new_exercise_id: int,
    retroactive: bool,
) -> int:
    stmt = (
        select(ExerciseSet)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .where(
            WorkoutSession.user_id == user_id,
            ExerciseSet.exercise_id == old_exercise_id,
        )
    )
    if not retroactive:
        stmt = stmt.where(
            WorkoutSession.status == WorkoutStatus.PLANNED,
            WorkoutSession.started_at.is_(None),
        )
    result = await db.execute(stmt)
    sets = result.scalars().all()
    for exercise_set in sets:
        exercise_set.exercise_id = new_exercise_id
    return len(sets)


async def _remove_exercise_from_plans(
    db: AsyncSession,
    *,
    user_id: int,
    exercise_id: int,
) -> int:
    updated = 0
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.user_id == user_id))
    for plan in result.scalars().all():
        try:
            planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}
        except (json.JSONDecodeError, TypeError):
            planned_data = {}
        changed = False
        for day in planned_data.get("days", []):
            exercises = day.get("exercises", [])
            filtered = [exercise for exercise in exercises if exercise.get("exercise_id") != exercise_id]
            if len(filtered) != len(exercises):
                day["exercises"] = filtered
                changed = True
        if changed:
            plan.planned_exercises = json.dumps(planned_data)
            updated += 1
    return updated


async def _delete_planned_session_sets(
    db: AsyncSession,
    *,
    user_id: int,
    exercise_id: int,
) -> int:
    result = await db.execute(
        select(ExerciseSet)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .where(
            WorkoutSession.user_id == user_id,
            WorkoutSession.status == WorkoutStatus.PLANNED,
            ExerciseSet.exercise_id == exercise_id,
        )
    )
    sets = result.scalars().all()
    for exercise_set in sets:
        await db.delete(exercise_set)
    return len(sets)


@router.get("/", response_model=list[ExerciseResponse])
async def list_exercises(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    """List all available exercises."""
    result = await db.execute(
        select(Exercise)
        .where(_exercise_scope(user.id))
        .order_by(Exercise.user_id.is_not(None), Exercise.display_name)
    )
    exercises = result.scalars().all()
    return [_serialize_exercise(ex) for ex in exercises]


@router.get("/{exercise_id}", response_model=ExerciseResponse)
async def get_exercise(
    exercise_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get an exercise by ID."""
    ex = await _get_visible_exercise(db, exercise_id, user.id)
    if not ex:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise {exercise_id} not found",
        )
    return _serialize_exercise(ex)


@router.post("/", response_model=ExerciseResponse, status_code=status.HTTP_201_CREATED)
async def create_exercise(
    exercise_data: ExerciseCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a new exercise definition."""
    existing = await db.execute(select(Exercise.id).where(Exercise.name == exercise_data.name))
    exercise_name = (
        await _generate_unique_name(db, user.id, exercise_data.display_name)
        if existing.scalar_one_or_none() is not None
        else exercise_data.name
    )
    exercise = Exercise(
        name=exercise_name,
        display_name=exercise_data.display_name,
        user_id=user.id,
        movement_type=exercise_data.movement_type.value,
        body_region=exercise_data.body_region.value,
        equipment_type=exercise_data.equipment_type,
        is_unilateral=exercise_data.is_unilateral,
        is_assisted=exercise_data.is_assisted,
        is_prime=exercise_data.is_prime,
        description=exercise_data.description,
        primary_muscles=exercise_data.primary_muscles,
        secondary_muscles=exercise_data.secondary_muscles,
    )
    db.add(exercise)
    await db.flush()
    await db.refresh(exercise)
    return _serialize_exercise(exercise)


@router.put("/{exercise_id}", response_model=ExerciseResponse)
async def update_exercise(
    exercise_id: int,
    exercise_data: ExerciseUpdate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create or update a user-customized exercise and optionally remap history."""
    source_exercise = await _get_visible_exercise(db, exercise_id, user.id)
    if not source_exercise:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise {exercise_id} not found",
        )

    retroactive = exercise_data.apply_mode == "retroactive"
    if source_exercise.user_id == user.id and retroactive:
        target_exercise = source_exercise
    else:
        target_exercise = Exercise(
            name=await _generate_unique_name(db, user.id, exercise_data.display_name),
            display_name=exercise_data.display_name,
            user_id=user.id,
            source_exercise_id=source_exercise.source_exercise_id or source_exercise.id,
            movement_type=exercise_data.movement_type.value,
            body_region=exercise_data.body_region.value,
            equipment_type=source_exercise.equipment_type or "other",
            is_unilateral=exercise_data.is_unilateral,
            is_assisted=exercise_data.is_assisted,
            description=exercise_data.description,
            primary_muscles=exercise_data.primary_muscles,
            secondary_muscles=exercise_data.secondary_muscles,
        )
        db.add(target_exercise)
        await db.flush()

    if target_exercise is source_exercise:
        target_exercise.display_name = exercise_data.display_name
        target_exercise.movement_type = exercise_data.movement_type.value
        target_exercise.body_region = exercise_data.body_region.value
        target_exercise.is_unilateral = exercise_data.is_unilateral
        target_exercise.is_assisted = exercise_data.is_assisted
        target_exercise.description = exercise_data.description
        target_exercise.primary_muscles = exercise_data.primary_muscles
        target_exercise.secondary_muscles = exercise_data.secondary_muscles

    if target_exercise.id != source_exercise.id:
        await _replace_exercise_in_plans(
            db,
            user_id=user.id,
            old_exercise_id=source_exercise.id,
            new_exercise_id=target_exercise.id,
        )
        await _replace_exercise_in_sessions(
            db,
            user_id=user.id,
            old_exercise_id=source_exercise.id,
            new_exercise_id=target_exercise.id,
            retroactive=retroactive,
        )
        if retroactive:
            feedback_result = await db.execute(
                select(ExerciseFeedback).where(
                    ExerciseFeedback.user_id == user.id,
                    ExerciseFeedback.exercise_id == source_exercise.id,
                )
            )
            for feedback in feedback_result.scalars().all():
                feedback.exercise_id = target_exercise.id

            notes_result = await db.execute(
                select(ExerciseNote).where(
                    ExerciseNote.user_id == user.id,
                    ExerciseNote.exercise_id == source_exercise.id,
                )
            )
            for note in notes_result.scalars().all():
                note.exercise_id = target_exercise.id

            if source_exercise.user_id == user.id:
                await db.execute(
                    delete(Exercise)
                    .where(Exercise.id == source_exercise.id)
                    .where(Exercise.user_id == user.id)
                )

    await db.flush()
    await db.refresh(target_exercise)
    return _serialize_exercise(target_exercise)


@router.get("/{exercise_id}/history")
async def get_exercise_history(
    exercise_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 10,
) -> list[dict]:
    """Get the most recent completed sessions for a given exercise."""
    ex = await _get_visible_exercise(db, exercise_id, user.id)
    if not ex:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise {exercise_id} not found",
        )

    # Subquery: sessions that have at least one completed set (bilateral or unilateral)
    sessions_with_data = (
        select(ExerciseSet.workout_session_id)
        .where(
            (ExerciseSet.actual_reps.is_not(None))
            | (ExerciseSet.reps_left.is_not(None))
            | (ExerciseSet.reps_right.is_not(None))
        )
    )

    result = await db.execute(
        select(ExerciseSet, WorkoutSession)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .where(
            ExerciseSet.exercise_id == exercise_id,
            ExerciseSet.workout_session_id.in_(sessions_with_data),
            (ExerciseSet.actual_reps.is_not(None))
            | (ExerciseSet.reps_left.is_not(None))
            | (ExerciseSet.reps_right.is_not(None)),
            WorkoutSession.user_id == user.id,
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
            "reps_left": exercise_set.reps_left,
            "reps_right": exercise_set.reps_right,
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
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete an exercise definition."""
    result = await db.execute(
        select(Exercise).where(Exercise.id == exercise_id, Exercise.user_id == user.id)
    )
    ex = result.scalar_one_or_none()
    if not ex:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Custom exercise {exercise_id} not found",
        )

    # Block deletion if the exercise has been used beyond draft/planned work.
    sets_result = await db.execute(
        select(ExerciseSet)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .where(
            WorkoutSession.user_id == user.id,
            WorkoutSession.status != WorkoutStatus.PLANNED,
            ExerciseSet.exercise_id == exercise_id,
        )
    )
    sets = sets_result.scalars().all()

    if sets and len(sets) > 0:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Cannot delete exercise '{ex.display_name}' - it is used in {len(sets)} workout set(s)",
        )

    # Remove future references so the exercise can be safely cleaned up.
    await _remove_exercise_from_plans(db, user_id=user.id, exercise_id=exercise_id)
    await _delete_planned_session_sets(db, user_id=user.id, exercise_id=exercise_id)
    await db.flush()

    # Delete the exercise
    await db.execute(delete(Exercise).where(Exercise.id == exercise_id))
    await db.flush()


# ── Exercise Notes ────────────────────────────────────────────────────────────

@router.get("/{exercise_id}/notes")
async def get_exercise_note(
    exercise_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict | None:
    """Get the user's note for an exercise."""
    ex = await _get_visible_exercise(db, exercise_id, user.id)
    if not ex:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise {exercise_id} not found",
        )

    result = await db.execute(
        select(ExerciseNote).where(
            ExerciseNote.exercise_id == exercise_id,
            ExerciseNote.user_id == user.id,
        )
    )
    note = result.scalar_one_or_none()
    if not note:
        return None
    return {"id": note.id, "exercise_id": note.exercise_id, "note": note.note, "updated_at": note.updated_at.isoformat()}


class _NoteBody(_PydanticBase):
    note: str = ""


@router.put("/{exercise_id}/notes")
async def set_exercise_note(
    exercise_id: int,
    body: _NoteBody,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create or update the user's note for an exercise. Empty string deletes."""
    note = body.note
    ex = await _get_visible_exercise(db, exercise_id, user.id)
    if not ex:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise {exercise_id} not found",
        )

    result = await db.execute(
        select(ExerciseNote).where(
            ExerciseNote.exercise_id == exercise_id,
            ExerciseNote.user_id == user.id,
        )
    )
    existing = result.scalar_one_or_none()

    if not note.strip():
        if existing:
            await db.delete(existing)
            await db.flush()
        return {"deleted": True}

    if existing:
        existing.note = note.strip()
        await db.flush()
        return {"id": existing.id, "exercise_id": exercise_id, "note": existing.note, "updated_at": existing.updated_at.isoformat()}

    new_note = ExerciseNote(user_id=user.id, exercise_id=exercise_id, note=note.strip())
    db.add(new_note)
    await db.flush()
    await db.refresh(new_note)
    return {"id": new_note.id, "exercise_id": exercise_id, "note": new_note.note, "updated_at": new_note.updated_at.isoformat()}


@router.get("/notes/all")
async def get_all_notes(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get all exercise notes for the current user (keyed by exercise_id)."""
    result = await db.execute(
        select(ExerciseNote).where(ExerciseNote.user_id == user.id)
    )
    notes = {}
    for n in result.scalars().all():
        notes[n.exercise_id] = {"note": n.note, "updated_at": n.updated_at.isoformat()}
    return notes


class _RecalcBody(_PydanticBase):
    exercise_name_pattern: str  # e.g. "smith" to match all smith machine exercises
    old_base_kg: float
    new_base_kg: float


@router.post("/recalculate-weights")
async def recalculate_weights(
    body: _RecalcBody,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Retroactively adjust weights on historical sets when a machine's base weight changes."""
    diff_kg = body.new_base_kg - body.old_base_kg
    if abs(diff_kg) < 0.01:
        return {"adjusted": 0}

    # Find matching exercises by name pattern
    result = await db.execute(
        select(Exercise).where(Exercise.name.ilike(f"%{body.exercise_name_pattern}%"))
    )
    exercise_ids = [e.id for e in result.scalars().all()]
    if not exercise_ids:
        return {"adjusted": 0}

    # Find all completed sets for these exercises belonging to this user
    sets_result = await db.execute(
        select(ExerciseSet)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .where(
            WorkoutSession.user_id == user.id,
            ExerciseSet.exercise_id.in_(exercise_ids),
            ExerciseSet.actual_weight_kg.isnot(None),
        )
    )
    sets = sets_result.scalars().all()

    count = 0
    for s in sets:
        s.actual_weight_kg = max(0, (s.actual_weight_kg or 0) + diff_kg)
        if s.planned_weight_kg is not None:
            s.planned_weight_kg = max(0, s.planned_weight_kg + diff_kg)
        count += 1

    await db.flush()
    return {"adjusted": count, "diff_kg": round(diff_kg, 2)}
