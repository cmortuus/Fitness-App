"""Workout session API endpoints."""

from datetime import date, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.database import get_db
from app.models.exercise import Exercise
from app.models.workout import ExerciseSet, WorkoutPlan, WorkoutSession, WorkoutStatus
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
    from sqlalchemy import desc
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

    workout_session.status = WorkoutStatus.IN_PROGRESS
    workout_session.started_at = datetime.utcnow()
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
    workout_session.completed_at = datetime.utcnow()
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

    def rep_bracket(reps: int) -> int:
        """Same brackets as the in-workout drop-off."""
        if reps >= 15:
            return 3
        if reps >= 10:
            return 2
        return 1

    def epley_weight_for_reps(weight: float, done_reps: int, target_reps: int) -> float:
        """Use Epley 1RM to find the weight equivalent to having done done_reps at `weight`,
        expressed at target_reps.  Rounds to nearest 2.5 kg (~5 lbs)."""
        one_rm = weight * (1 + done_reps / 30)
        new_w  = one_rm / (1 + target_reps / 30)
        return round(new_w / 2.5) * 2.5

    def progressive_overload(exercise_id: int, set_number: int, target_reps: int, ex_model) -> tuple[float | None, int | None]:
        """Return (suggested_weight_kg, suggested_reps) for a specific set.
        Looks up the corresponding set from the prior session so each set
        is overloaded from its own history. Falls back to None if no data."""
        ex_sets = prior_set_data.get(exercise_id)
        if not ex_sets:
            return None, None

        # Use the matching set from the prior session; fall back to the closest
        # set number if the session had fewer sets (e.g. prior had 3, now doing 4).
        prior_set = ex_sets.get(set_number)
        if prior_set is None:
            # Fall back: use the last available set (handles added sets gracefully)
            last_set_num = max(ex_sets.keys())
            prior_set = ex_sets[last_set_num]

        prior_weight = prior_set["weight"]
        prior_reps   = prior_set["reps"]
        planned_reps = prior_set.get("planned_reps") or target_reps

        if prior_reps <= 0:
            return None, None

        is_assisted = ex_model and ex_model.is_assisted

        # Assisted: prior_weight is the NET effective weight (body - assist).
        # Convert back to assist amount so the frontend can pre-fill directly.
        if is_assisted:
            new_reps = prior_reps + 1 if prior_reps >= planned_reps else prior_reps
            if body_weight_kg > 0 and prior_weight > 0:
                assist_kg = max(0.0, round((body_weight_kg - prior_weight) / 1.25) * 1.25)
                return assist_kg, new_reps
            return None, new_reps

        # Bodyweight exercise: no weight to suggest, but still apply rep progression
        if prior_weight <= 0:
            if prior_reps >= planned_reps:
                return None, prior_reps + 1
            return None, prior_reps

        # Didn't hit planned reps → retry same weight / same reps
        if prior_reps < planned_reps:
            return prior_weight, prior_reps

        # ── Hit target: apply progression ─────────────────────────────────────
        if overload_style == "weight":
            new_weight = epley_weight_for_reps(prior_weight, prior_reps + 1, prior_reps)
            return new_weight, prior_reps
        else:
            projected_reps = prior_reps + 1
            if rep_bracket(projected_reps) <= rep_bracket(prior_reps):
                return prior_weight, projected_reps
            else:
                new_weight = epley_weight_for_reps(prior_weight, prior_reps + 1, prior_reps)
                return new_weight, prior_reps

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
            weight_kg, suggested_reps = progressive_overload(exercise_id, set_num, reps, ex_model)
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
