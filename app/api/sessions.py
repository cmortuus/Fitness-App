"""Workout session API endpoints."""

from datetime import date, datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.database import get_db
from app.models.exercise import Exercise
from app.models.workout import ExerciseSet, WorkoutPlan, WorkoutSession, WorkoutStatus
from app.services.progression import compute_overload
from app.schemas.requests import (
    SetCreate,
    SetResponse,
    SetUpdate,
    WorkoutSessionCreate,
    WorkoutSessionResponse,
)

router = APIRouter()


async def _get_session_with_sets(db: AsyncSession, session_id: int) -> WorkoutSession | None:
    """Fetch a WorkoutSession with its sets eagerly loaded."""
    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.id == session_id)
    )
    return result.scalar_one_or_none()


def serialize_set(exercise_set: ExerciseSet) -> dict:
    """Serialize an ExerciseSet to a dictionary."""
    return {
        "id": exercise_set.id,
        "exercise_id": exercise_set.exercise_id,
        "set_number": exercise_set.set_number,
        "planned_reps": exercise_set.planned_reps,
        "planned_weight_kg": exercise_set.planned_weight_kg,
        "actual_reps": exercise_set.actual_reps,
        "actual_weight_kg": exercise_set.actual_weight_kg,
        "notes": exercise_set.notes,
        "started_at": exercise_set.started_at,
        "completed_at": exercise_set.completed_at,
    }


def serialize_session(workout_session: WorkoutSession) -> dict:
    """Serialize a WorkoutSession to a dictionary with sets."""
    sets_data = [serialize_set(s) for s in workout_session.sets] if workout_session.sets else []
    return {
        "id": workout_session.id,
        "name": workout_session.name,
        "date": workout_session.date,
        "status": workout_session.status,
        "workout_plan_id": workout_session.workout_plan_id,
        "total_volume_kg": workout_session.total_volume_kg,
        "total_sets": workout_session.total_sets,
        "total_reps": workout_session.total_reps,
        "started_at": workout_session.started_at,
        "completed_at": workout_session.completed_at,
        "sets": sets_data,
    }


@router.get("/", response_model=list[WorkoutSessionResponse])
async def list_sessions(
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 20,
    offset: int = 0,
) -> list[dict]:
    """List workout sessions, most recent first."""
    limit = min(limit, 500)
    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .order_by(desc(WorkoutSession.date))
        .limit(limit)
        .offset(offset)
    )
    sessions = result.scalars().all()
    return [serialize_session(s) for s in sessions]


@router.post("/", response_model=WorkoutSessionResponse, status_code=status.HTTP_201_CREATED)
async def create_session(
    session_data: WorkoutSessionCreate,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a new workout session."""
    workout_session = WorkoutSession(
        date=session_data.date,
        name=session_data.name,
        workout_plan_id=session_data.workout_plan_id,
        status=WorkoutStatus.PLANNED,
    )
    db.add(workout_session)
    await db.flush()
    workout_session = await _get_session_with_sets(db, workout_session.id)
    return serialize_session(workout_session)


@router.get("/{session_id}", response_model=WorkoutSessionResponse)
async def get_session(
    session_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get a workout session by ID."""
    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.id == session_id)
    )
    workout_session = result.scalar_one_or_none()
    if not workout_session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )
    return serialize_session(workout_session)


@router.post("/{session_id}/start", response_model=WorkoutSessionResponse)
async def start_session(
    session_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Start a workout session."""
    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.id == session_id)
    )
    workout_session = result.scalar_one_or_none()
    if not workout_session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )

    existing_result = await db.execute(
        select(WorkoutSession).where(
            WorkoutSession.status == WorkoutStatus.IN_PROGRESS,
            WorkoutSession.id != session_id,
        )
    )
    existing = existing_result.scalars().first()
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": f"Session '{existing.name}' is already in progress. Complete or delete it first.",
                "session_id": existing.id,
                "session_name": existing.name or "",
            },
        )

    workout_session.status = WorkoutStatus.IN_PROGRESS
    workout_session.started_at = datetime.now(timezone.utc)
    await db.flush()
    workout_session = await _get_session_with_sets(db, workout_session.id)
    return serialize_session(workout_session)


@router.post("/{session_id}/complete", response_model=WorkoutSessionResponse)
async def complete_session(
    session_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Complete a workout session."""
    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.id == session_id)
    )
    workout_session = result.scalar_one_or_none()
    if not workout_session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )

    workout_session.status = WorkoutStatus.COMPLETED
    workout_session.completed_at = datetime.now(timezone.utc)
    await db.flush()
    workout_session = await _get_session_with_sets(db, workout_session.id)
    return serialize_session(workout_session)


@router.post("/{session_id}/sets", response_model=SetResponse, status_code=status.HTTP_201_CREATED)
async def add_set(
    session_id: int,
    set_data: SetCreate,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Add a set to a workout session."""
    # Verify session exists
    result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id)
    )
    if not result.scalar_one_or_none():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )

    exercise_set = ExerciseSet(
        workout_session_id=session_id,
        exercise_id=set_data.exercise_id,
        set_number=set_data.set_number,
        planned_reps=set_data.planned_reps,
        planned_weight_kg=set_data.planned_weight_kg,
    )
    db.add(exercise_set)
    await db.flush()
    await db.refresh(exercise_set)
    return serialize_set(exercise_set)


@router.patch("/{session_id}/sets/{set_id}", response_model=SetResponse)
async def update_set(
    session_id: int,
    set_id: int,
    set_data: SetUpdate,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Update a set with actual values."""
    result = await db.execute(
        select(ExerciseSet).where(
            ExerciseSet.id == set_id,
            ExerciseSet.workout_session_id == session_id,
        )
    )
    exercise_set = result.scalar_one_or_none()
    if not exercise_set:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Set {set_id} not found in session {session_id}",
        )

    update_data = set_data.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(exercise_set, field, value)

    # Update session totals
    session_result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id)
    )
    session = session_result.scalar_one_or_none()
    if session:
        # Recalculate totals from all sets
        all_sets_result = await db.execute(
            select(ExerciseSet).where(ExerciseSet.workout_session_id == session_id)
        )
        all_sets = all_sets_result.scalars().all()
        session.total_sets = len(all_sets)
        session.total_reps = sum(s.actual_reps or 0 for s in all_sets)
        session.total_volume_kg = sum(
            (s.actual_reps or 0) * (s.actual_weight_kg or 0) for s in all_sets
        )

    await db.flush()
    await db.refresh(exercise_set)
    return serialize_set(exercise_set)


@router.delete("/{session_id}/sets/{set_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_set(
    session_id: int,
    set_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a set from a workout session."""
    result = await db.execute(
        select(ExerciseSet).where(
            ExerciseSet.id == set_id,
            ExerciseSet.workout_session_id == session_id,
        )
    )
    exercise_set = result.scalar_one_or_none()
    if not exercise_set:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Set {set_id} not found in session {session_id}",
        )
    await db.delete(exercise_set)
    await db.flush()


@router.delete("/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(
    session_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a workout session and all its sets (cancel an in-progress session)."""
    result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id)
    )
    workout_session = result.scalar_one_or_none()
    if not workout_session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )
    await db.delete(workout_session)
    await db.flush()


@router.post("/from-plan/{plan_id}", response_model=WorkoutSessionResponse, status_code=status.HTTP_201_CREATED)
async def create_session_from_plan(
    plan_id: int,
    day_number: int = 1,
    overload_style: str = "rep",
    body_weight_kg: float = 0.0,
    db: Annotated[AsyncSession, Depends(get_db)] = None,
) -> dict:
    """Create a new workout session from a plan, pre-populating sets."""
    import json

    # Get the plan
    result = await db.execute(
        select(WorkoutPlan).where(WorkoutPlan.id == plan_id)
    )
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout plan {plan_id} not found",
        )

    # Parse planned exercises
    planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}
    days = planned_data.get("days", [])
    day = next((d for d in days if d.get("day_number") == day_number), days[0] if days else None)

    if not day:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Day {day_number} not found in plan",
        )

    day_name = day.get("day_name", f"Day {day_number}")

    # Guard: only one in-progress session at a time.
    # Use .scalars().first() (not scalar_one_or_none) so pre-existing dirty data
    # with multiple in-progress sessions doesn't cause a MultipleResultsFound crash.
    existing_result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.status == WorkoutStatus.IN_PROGRESS)
    )
    existing = existing_result.scalars().first()
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": f"Session '{existing.name}' is already in progress. Complete or delete it first.",
                "session_id": existing.id,
                "session_name": existing.name or "",
            },
        )

    # ── Look up most recent prior session for the same plan + same day ────────
    # Require at least one set with actual_reps filled in — this is the real
    # quality gate. Sessions with no completed sets (e.g. abandoned mid-start)
    # are useless for progression and must be skipped regardless of status.
    sessions_with_data = (
        select(ExerciseSet.workout_session_id)
        .where(ExerciseSet.actual_reps.is_not(None))
    )
    prior_result = await db.execute(
        select(WorkoutSession)
        .where(
            WorkoutSession.workout_plan_id == plan_id,
            WorkoutSession.name.contains(day_name),
            WorkoutSession.id.in_(sessions_with_data),
        )
        .order_by(desc(WorkoutSession.date), desc(WorkoutSession.id))
        .limit(1)
    )
    prior_session = prior_result.scalar_one_or_none()

    # Build per-exercise PER-SET lookup from prior session so each set can
    # be progressively overloaded from its own corresponding prior-session set.
    # Structure: prior_set_data[exercise_id][set_number] = {weight, reps, planned_reps}
    prior_set_data: dict[int, dict[int, dict]] = {}
    if prior_session:
        prior_sets_result = await db.execute(
            select(ExerciseSet).where(ExerciseSet.workout_session_id == prior_session.id)
        )
        for s in prior_sets_result.scalars().all():
            if s.actual_weight_kg is None or s.actual_reps is None:
                continue
            ex_id = s.exercise_id
            if ex_id not in prior_set_data:
                prior_set_data[ex_id] = {}
            prior_set_data[ex_id][s.set_number] = {
                "weight": s.actual_weight_kg,
                "reps": s.actual_reps,
                "planned_reps": s.planned_reps,
            }

    def _overload_for_set(
        exercise_id: int, set_number: int, target_reps: int, ex_model
    ) -> tuple[float | None, int | None]:
        """Resolve prior-session data for this set and delegate to compute_overload()."""
        ex_sets = prior_set_data.get(exercise_id)
        if not ex_sets:
            return None, None

        prior_set = ex_sets.get(set_number) or ex_sets[max(ex_sets.keys())]
        prior_weight = prior_set["weight"]
        prior_reps = prior_set["reps"]
        planned_reps = prior_set.get("planned_reps") or target_reps

        return compute_overload(
            prior_weight=prior_weight,
            prior_reps=prior_reps,
            planned_reps=planned_reps,
            overload_style=overload_style,
            is_assisted=bool(ex_model and ex_model.is_assisted),
            is_bodyweight=prior_weight <= 0,
            body_weight_kg=body_weight_kg,
        )

    # Create session
    workout_session = WorkoutSession(
        date=date.today(),
        name=f"{plan.name} - {day_name}",
        workout_plan_id=plan_id,
        status=WorkoutStatus.PLANNED,
    )
    db.add(workout_session)
    await db.flush()

    # Create sets for each exercise
    day_exercises = day.get("exercises", [])
    for exercise_data in day_exercises:
        exercise_id = exercise_data.get("exercise_id")
        sets = exercise_data.get("sets", 3)
        reps = exercise_data.get("reps", 8)

        # Look up exercise metadata for overload logic
        ex_model = await db.get(Exercise, exercise_id)

        for set_num in range(1, sets + 1):
            # Compute progression individually per set so each set uses
            # its own history from the prior session.
            weight_kg, suggested_reps = _overload_for_set(exercise_id, set_num, reps, ex_model)
            planned_reps_val = suggested_reps if suggested_reps is not None else None

            exercise_set = ExerciseSet(
                workout_session_id=workout_session.id,
                exercise_id=exercise_id,
                set_number=set_num,
                planned_reps=planned_reps_val,
                planned_weight_kg=weight_kg,
            )
            db.add(exercise_set)

    await db.flush()
    # Re-fetch with sets eagerly loaded (required for async SQLAlchemy)
    refetch = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.id == workout_session.id)
    )
    workout_session = refetch.scalar_one()
    return serialize_session(workout_session)
