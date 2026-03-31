"""Workout session API endpoints."""

import json
from datetime import date, datetime
from typing import Annotated

from fastapi import APIRouter, Body, Depends, HTTPException, Request, status
from sqlalchemy import desc, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.api.auth import get_current_user
from app.database import get_db
from app.models.exercise import Exercise
from app.models.user import User
from app.models.workout import ExerciseFeedback, ExerciseSet, WorkoutPlan, WorkoutSession, WorkoutSessionAudit, WorkoutStatus
from app.services.plan_rir import resolve_rir_override
from app.services.progression import adjust_load_for_target_rir, compute_overload
from app.schemas.requests import (
    SetCreate,
    SetResponse,
    SetUpdate,
    WorkoutSessionAuditResponse,
    WorkoutSessionCreate,
    WorkoutSessionResponse,
)

router = APIRouter()


def _exercise_scope(user_id: int):
    return or_(Exercise.user_id.is_(None), Exercise.user_id == user_id)


async def _get_session_with_sets(
    db: AsyncSession, session_id: int, user_id: int | None = None,
) -> WorkoutSession | None:
    """Fetch a WorkoutSession with its sets and exercise names eagerly loaded."""
    stmt = (
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets).selectinload(ExerciseSet.exercise))
        .where(WorkoutSession.id == session_id)
    )
    if user_id is not None:
        stmt = stmt.where(WorkoutSession.user_id == user_id)
    result = await db.execute(stmt)
    return result.scalar_one_or_none()


def serialize_set(exercise_set: ExerciseSet) -> dict:
    """Serialize an ExerciseSet to a dictionary."""
    return {
        "id": exercise_set.id,
        "exercise_id": exercise_set.exercise_id,
        "exercise_name": (
            exercise_set.exercise.display_name
            if "exercise" in exercise_set.__dict__ and exercise_set.__dict__["exercise"] is not None
            else None
        ),
        "movement_type": (
            exercise_set.exercise.movement_type
            if "exercise" in exercise_set.__dict__ and exercise_set.__dict__["exercise"] is not None
            else None
        ),
        "body_region": (
            exercise_set.exercise.body_region
            if "exercise" in exercise_set.__dict__ and exercise_set.__dict__["exercise"] is not None
            else None
        ),
        "equipment_type": (
            exercise_set.exercise.equipment_type
            if "exercise" in exercise_set.__dict__ and exercise_set.__dict__["exercise"] is not None
            else None
        ),
        "set_number": exercise_set.set_number,
        "planned_reps": exercise_set.planned_reps,
        "planned_reps_left": exercise_set.planned_reps_left,
        "planned_reps_right": exercise_set.planned_reps_right,
        "planned_weight_kg": exercise_set.planned_weight_kg,
        "actual_reps": exercise_set.actual_reps,
        "actual_weight_kg": exercise_set.actual_weight_kg,
        "reps_left": exercise_set.reps_left,
        "reps_right": exercise_set.reps_right,
        "set_type": exercise_set.set_type or "standard",
        "sub_sets": json.loads(exercise_set.sub_sets) if exercise_set.sub_sets else None,
        "notes": exercise_set.notes,
        "started_at": exercise_set.started_at,
        "completed_at": exercise_set.completed_at,
        "draft_weight_kg": exercise_set.draft_weight_kg,
        "draft_reps": exercise_set.draft_reps,
        "draft_reps_left": exercise_set.draft_reps_left,
        "draft_reps_right": exercise_set.draft_reps_right,
        "skipped_at": exercise_set.skipped_at.isoformat() if exercise_set.skipped_at else None,
    }


def serialize_session(workout_session: WorkoutSession) -> dict:
    """Serialize a WorkoutSession to a dictionary with sets."""
    sorted_sets = sorted(workout_session.sets, key=lambda s: s.id) if workout_session.sets else []
    sets_data = [serialize_set(s) for s in sorted_sets]
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
        "notes": workout_session.notes,
        "sets": sets_data,
    }


def serialize_session_audit(entry: WorkoutSessionAudit) -> dict:
    return {
        "id": entry.id,
        "workout_session_id": entry.workout_session_id,
        "from_status": entry.from_status,
        "to_status": entry.to_status,
        "reason": entry.reason,
        "endpoint": entry.endpoint,
        "actor_username": entry.actor_username,
        "source_device": entry.source_device,
        "created_at": entry.created_at,
    }


def _set_total_reps(exercise_set: ExerciseSet) -> int:
    if exercise_set.actual_reps is not None:
        return exercise_set.actual_reps
    return (exercise_set.reps_left or 0) + (exercise_set.reps_right or 0)


def _set_total_volume_kg(exercise_set: ExerciseSet) -> float:
    return _set_total_reps(exercise_set) * (exercise_set.actual_weight_kg or 0)


async def record_session_audit(
    db: AsyncSession,
    session: WorkoutSession,
    *,
    from_status: WorkoutStatus | str | None,
    to_status: WorkoutStatus | str | None,
    reason: str,
    endpoint: str,
    actor_username: str | None,
    source_device: str | None,
) -> None:
    db.add(WorkoutSessionAudit(
        workout_session_id=session.id,
        user_id=session.user_id or 0,
        from_status=str(from_status.value if isinstance(from_status, WorkoutStatus) else from_status) if from_status is not None else None,
        to_status=str(to_status.value if isinstance(to_status, WorkoutStatus) else to_status) if to_status is not None else None,
        reason=reason,
        endpoint=endpoint,
        actor_username=actor_username,
        source_device=source_device,
    ))


@router.get("/", response_model=list[WorkoutSessionResponse])
async def list_sessions(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 20,
    offset: int = 0,
    status_filter: str | None = None,
) -> list[dict]:
    """List workout sessions, most recent first. Optional status_filter (e.g. 'in_progress')."""
    limit = min(limit, 500)
    stmt = (
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets).selectinload(ExerciseSet.exercise))
        .where(WorkoutSession.user_id == user.id)
    )
    if status_filter:
        stmt = stmt.where(WorkoutSession.status == status_filter)
    stmt = stmt.order_by(desc(WorkoutSession.date), desc(WorkoutSession.id)).limit(limit).offset(offset)
    result = await db.execute(stmt)
    sessions = result.scalars().all()
    return [serialize_session(s) for s in sessions]


@router.post("/", response_model=WorkoutSessionResponse, status_code=status.HTTP_201_CREATED)
async def create_session(
    session_data: WorkoutSessionCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    request: Request,
) -> dict:
    """Create a new workout session."""
    workout_session = WorkoutSession(
        date=session_data.date,
        name=session_data.name,
        workout_plan_id=session_data.workout_plan_id,
        status=WorkoutStatus.PLANNED,
        user_id=user.id,
    )
    db.add(workout_session)
    await db.flush()
    await record_session_audit(
        db,
        workout_session,
        from_status=None,
        to_status=workout_session.status,
        reason="session_created",
        endpoint=request.url.path,
        actor_username=user.username,
        source_device=request.headers.get("X-Client-Name") or "web",
    )
    workout_session = await _get_session_with_sets(db, workout_session.id, user_id=user.id)
    return serialize_session(workout_session)


@router.get("/{session_id}", response_model=WorkoutSessionResponse)
async def get_session(
    session_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get a workout session by ID."""
    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets).selectinload(ExerciseSet.exercise))
        .where(WorkoutSession.id == session_id)
        .where(WorkoutSession.user_id == user.id)
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
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    request: Request,
) -> dict:
    """Start a workout session."""
    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.id == session_id)
        .where(WorkoutSession.user_id == user.id)
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
            WorkoutSession.user_id == user.id,
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

    prior_status = workout_session.status
    workout_session.status = WorkoutStatus.IN_PROGRESS
    workout_session.started_at = datetime.utcnow()
    await record_session_audit(
        db,
        workout_session,
        from_status=prior_status,
        to_status=workout_session.status,
        reason="session_started",
        endpoint=request.url.path,
        actor_username=user.username,
        source_device=request.headers.get("X-Client-Name") or "web",
    )
    await db.flush()
    workout_session = await _get_session_with_sets(db, workout_session.id, user_id=user.id)
    return serialize_session(workout_session)


@router.post("/{session_id}/complete", response_model=WorkoutSessionResponse)
async def complete_session(
    session_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    request: Request,
) -> dict:
    """Complete a workout session."""
    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.id == session_id)
        .where(WorkoutSession.user_id == user.id)
    )
    workout_session = result.scalar_one_or_none()
    if not workout_session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )

    prior_status = workout_session.status
    workout_session.status = WorkoutStatus.COMPLETED
    workout_session.completed_at = datetime.utcnow()
    await record_session_audit(
        db,
        workout_session,
        from_status=prior_status,
        to_status=workout_session.status,
        reason="session_completed",
        endpoint=request.url.path,
        actor_username=user.username,
        source_device=request.headers.get("X-Client-Name") or "web",
    )
    await db.flush()
    workout_session = await _get_session_with_sets(db, workout_session.id, user_id=user.id)
    return serialize_session(workout_session)


@router.post("/{session_id}/reset-to-planned", response_model=WorkoutSessionResponse)
async def reset_session_to_planned(
    session_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    request: Request,
) -> dict:
    """Reset a session back to a clean planned state for repair/debug workflows."""
    workout_session = await _get_session_with_sets(db, session_id, user_id=user.id)
    if not workout_session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )

    prior_status = workout_session.status
    workout_session.status = WorkoutStatus.PLANNED
    workout_session.started_at = None
    workout_session.completed_at = None
    workout_session.total_volume_kg = 0
    workout_session.total_sets = 0
    workout_session.total_reps = 0
    workout_session.duration_minutes = None

    for exercise_set in workout_session.sets:
        exercise_set.actual_reps = None
        exercise_set.actual_weight_kg = None
        exercise_set.reps_left = None
        exercise_set.reps_right = None
        exercise_set.started_at = None
        exercise_set.completed_at = None
        exercise_set.skipped_at = None
        exercise_set.sub_sets = None
        exercise_set.draft_weight_kg = None
        exercise_set.draft_reps = None
        exercise_set.draft_reps_left = None
        exercise_set.draft_reps_right = None

    await record_session_audit(
        db,
        workout_session,
        from_status=prior_status,
        to_status=workout_session.status,
        reason="session_reset_to_planned",
        endpoint=request.url.path,
        actor_username=user.username,
        source_device=request.headers.get("X-Client-Name") or "web",
    )
    await db.flush()
    workout_session = await _get_session_with_sets(db, workout_session.id, user_id=user.id)
    return serialize_session(workout_session)


@router.patch("/{session_id}", response_model=WorkoutSessionResponse)
async def update_session(
    session_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    notes: str | None = Body(default=None, embed=True),
    name: str | None = Body(default=None, embed=True),
) -> dict:
    """Patch mutable fields (notes, name) on a session."""
    result = await db.execute(
        select(WorkoutSession)
        .where(WorkoutSession.id == session_id)
        .where(WorkoutSession.user_id == user.id)
    )
    workout_session = result.scalar_one_or_none()
    if not workout_session:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Session not found")
    if notes is not None:
        workout_session.notes = notes
    if name is not None:
        workout_session.name = name
    await db.flush()
    workout_session = await _get_session_with_sets(db, workout_session.id, user_id=user.id)
    return serialize_session(workout_session)


@router.post("/{session_id}/sync-to-plan")
async def sync_session_to_plan(
    session_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Sync a completed session back to its plan — weights/reps AND structural changes.

    Structural changes synced: added/removed exercises, reordering,
    set count changes, set type changes. Weight/rep updates use
    progressive overload values (max weight, most common reps).
    """
    # Load session and verify ownership + completion
    result = await db.execute(
        select(WorkoutSession).where(
            WorkoutSession.id == session_id,
            WorkoutSession.user_id == user.id,
        )
    )
    session = result.scalar_one_or_none()
    if not session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )
    if session.status != WorkoutStatus.COMPLETED:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Session must be completed before syncing to plan",
        )

    if not session.workout_plan_id:
        return {"updated": 0, "structural_changes": 0}

    # Load ALL sets for this session (including those without actual weight)
    all_sets_result = await db.execute(
        select(ExerciseSet)
        .where(ExerciseSet.workout_session_id == session_id)
        .order_by(ExerciseSet.exercise_id, ExerciseSet.set_number)
    )
    all_sets = all_sets_result.scalars().all()

    if not all_sets:
        return {"updated": 0, "structural_changes": 0}

    # Build session exercise list: ordered by first appearance, with set counts and types
    seen_order: list[int] = []
    session_exercises: dict[int, dict] = {}
    for s in all_sets:
        eid = s.exercise_id
        if eid not in session_exercises:
            seen_order.append(eid)
            session_exercises[eid] = {
                "set_count": 0,
                "set_type": s.set_type or "standard",
                "max_weight": 0.0,
                "reps_counts": {},
            }
        session_exercises[eid]["set_count"] += 1
        if s.actual_weight_kg is not None:
            if s.actual_weight_kg > session_exercises[eid]["max_weight"]:
                session_exercises[eid]["max_weight"] = s.actual_weight_kg
        if s.actual_reps is not None:
            rc = session_exercises[eid]["reps_counts"]
            rc[s.actual_reps] = rc.get(s.actual_reps, 0) + 1

    # Load the linked plan
    plan_result = await db.execute(
        select(WorkoutPlan).where(
            WorkoutPlan.id == session.workout_plan_id,
            WorkoutPlan.user_id == user.id,
        )
    )
    plan = plan_result.scalar_one_or_none()
    if not plan:
        return {"updated": 0, "structural_changes": 0}

    planned = json.loads(plan.planned_exercises) if isinstance(plan.planned_exercises, str) else plan.planned_exercises
    days = planned.get("days", [])

    # Find the matching day by parsing day_name from session name ("Plan - DayName")
    target_day = None
    if session.name and " - " in session.name:
        session_day_name = session.name.split(" - ", 1)[1]
        target_day = next((d for d in days if d.get("day_name") == session_day_name), None)
    if target_day is None and days:
        target_day = days[0]
    if target_day is None:
        return {"updated": 0, "structural_changes": 0}

    # Build map of existing plan exercises for this day
    plan_exercise_map: dict[int, dict] = {}
    for ex in target_day.get("exercises", []):
        plan_exercise_map[ex.get("exercise_id")] = ex

    plan_exercise_ids = set(plan_exercise_map.keys())
    session_exercise_ids = set(seen_order)

    # Rebuild the day's exercise list in session order
    new_exercises = []
    updated_count = 0
    structural_changes = 0

    for eid in seen_order:
        sdata = session_exercises[eid]
        most_common_reps = None
        if sdata["reps_counts"]:
            most_common_reps = max(sdata["reps_counts"], key=lambda r: sdata["reps_counts"][r])

        if eid in plan_exercise_map:
            # Existing exercise — update weight/reps and structural fields
            ex = dict(plan_exercise_map[eid])
            if sdata["max_weight"] > 0:
                ex["starting_weight_kg"] = sdata["max_weight"]
                updated_count += 1
            if most_common_reps is not None:
                ex["reps"] = most_common_reps
            # Structural: set count changed
            if ex.get("sets") != sdata["set_count"]:
                ex["sets"] = sdata["set_count"]
                structural_changes += 1
            # Structural: set type changed
            if ex.get("set_type", "standard") != sdata["set_type"]:
                ex["set_type"] = sdata["set_type"]
                structural_changes += 1
            new_exercises.append(ex)
        else:
            # New exercise added during session
            new_exercises.append({
                "exercise_id": eid,
                "sets": sdata["set_count"],
                "reps": most_common_reps or 8,
                "starting_weight_kg": sdata["max_weight"] if sdata["max_weight"] > 0 else 0.0,
                "progression_type": "linear",
                "set_type": sdata["set_type"],
                "rest_seconds": 90,
                "notes": None,
            })
            structural_changes += 1

    # Count removed exercises
    removed = plan_exercise_ids - session_exercise_ids
    structural_changes += len(removed)

    # Check if order changed (comparing exercise IDs in order)
    old_order = [ex.get("exercise_id") for ex in target_day.get("exercises", [])]
    new_order = [ex.get("exercise_id") for ex in new_exercises]
    if old_order != new_order:
        structural_changes = max(structural_changes, 1)  # ensure at least 1 if reordered

    # Apply changes
    target_day["exercises"] = new_exercises
    plan.planned_exercises = json.dumps(planned)
    await db.flush()

    return {"updated": updated_count, "structural_changes": structural_changes}


@router.post("/{session_id}/sets", response_model=SetResponse, status_code=status.HTTP_201_CREATED)
async def add_set(
    session_id: int,
    set_data: SetCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Add a set to a workout session."""
    # Verify session exists and belongs to user
    result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id, WorkoutSession.user_id == user.id)
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
        set_type=set_data.set_type,
    )
    db.add(exercise_set)
    await db.flush()

    # Update session totals
    session_result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id)
    )
    session = session_result.scalar_one_or_none()
    if session:
        all_sets_result = await db.execute(
            select(ExerciseSet).where(ExerciseSet.workout_session_id == session_id)
        )
        all_sets = all_sets_result.scalars().all()
        session.total_sets = len(all_sets)
        session.total_reps = sum(_set_total_reps(s) for s in all_sets)
        session.total_volume_kg = sum(_set_total_volume_kg(s) for s in all_sets)
        await db.flush()

    await db.refresh(exercise_set)
    return serialize_set(exercise_set)


@router.patch("/{session_id}/sets/{set_id}", response_model=SetResponse)
async def update_set(
    session_id: int,
    set_id: int,
    set_data: SetUpdate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Update a set with actual values."""
    # Verify session belongs to user
    sess_result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id, WorkoutSession.user_id == user.id)
    )
    if not sess_result.scalar_one_or_none():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )
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
        # Strip timezone info — DB uses naive timestamps
        if isinstance(value, datetime) and value.tzinfo is not None:
            value = value.replace(tzinfo=None)
        if field == "sub_sets" and isinstance(value, list):
            value = json.dumps(value)
        setattr(exercise_set, field, value)

    # Update session totals
    session_result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id)
    )
    session = session_result.scalar_one_or_none()
    if session:
        prior_status = session.status
        # Recalculate totals from all sets
        all_sets_result = await db.execute(
            select(ExerciseSet).where(ExerciseSet.workout_session_id == session_id)
        )
        all_sets = all_sets_result.scalars().all()
        session.total_sets = len(all_sets)
        session.total_reps = sum(_set_total_reps(s) for s in all_sets)
        session.total_volume_kg = sum(_set_total_volume_kg(s) for s in all_sets)

        has_completed_sets = any(s.completed_at is not None and s.skipped_at is None for s in all_sets)
        if has_completed_sets and session.status == WorkoutStatus.PLANNED:
            session.status = WorkoutStatus.IN_PROGRESS
            session.started_at = session.started_at or datetime.utcnow()
            await record_session_audit(
                db,
                session,
                from_status=prior_status,
                to_status=session.status,
                reason="first_set_completed",
                endpoint=f"/api/sessions/{session_id}/sets/{set_id}",
                actor_username=user.username,
                source_device="web",
            )
        elif not has_completed_sets and session.status == WorkoutStatus.IN_PROGRESS and session.completed_at is None:
            session.status = WorkoutStatus.PLANNED
            session.started_at = None
            await record_session_audit(
                db,
                session,
                from_status=prior_status,
                to_status=session.status,
                reason="last_completed_set_removed",
                endpoint=f"/api/sessions/{session_id}/sets/{set_id}",
                actor_username=user.username,
                source_device="web",
            )

    await db.flush()
    await db.refresh(exercise_set)
    return serialize_set(exercise_set)


@router.get("/{session_id}/audit", response_model=list[WorkoutSessionAuditResponse])
async def get_session_audit(
    session_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    session = await _get_session_with_sets(db, session_id, user_id=user.id)
    if not session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )
    result = await db.execute(
        select(WorkoutSessionAudit)
        .where(
            WorkoutSessionAudit.workout_session_id == session_id,
            WorkoutSessionAudit.user_id == user.id,
        )
        .order_by(desc(WorkoutSessionAudit.created_at), desc(WorkoutSessionAudit.id))
    )
    return [serialize_session_audit(entry) for entry in result.scalars().all()]


@router.delete("/{session_id}/sets/{set_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_set(
    session_id: int,
    set_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a set from a workout session."""
    # Verify session belongs to user
    sess_result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id, WorkoutSession.user_id == user.id)
    )
    if not sess_result.scalar_one_or_none():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout session {session_id} not found",
        )
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

    # Recalculate session totals after deletion
    session_result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id)
    )
    session = session_result.scalar_one_or_none()
    if session:
        remaining_result = await db.execute(
            select(ExerciseSet).where(
                ExerciseSet.workout_session_id == session_id,
                ExerciseSet.id != set_id,
            )
        )
        remaining = remaining_result.scalars().all()
        session.total_sets = len(remaining)
        session.total_reps = sum(_set_total_reps(s) for s in remaining)
        session.total_volume_kg = sum(_set_total_volume_kg(s) for s in remaining)

    await db.flush()


@router.delete("/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(
    session_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a workout session and all its sets (cancel an in-progress session)."""
    result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.id == session_id, WorkoutSession.user_id == user.id)
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
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    request: Request,
    day_number: int = 1,
    overload_style: str = "rep",
    body_weight_kg: float = 0.0,
) -> dict:
    """Create a new workout session from a plan, pre-populating sets."""
    # Get the plan
    result = await db.execute(
        select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id)
    )
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout plan {plan_id} not found",
        )
    if plan.is_draft:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cannot start a workout from a draft plan. Publish it first.",
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
    day_exercises = day.get("exercises", [])

    # Batch-fetch all exercise models needed by this day in one query
    day_exercise_ids = [
        ex_d.get("exercise_id") for ex_d in day_exercises if ex_d.get("exercise_id")
    ]
    if day_exercise_ids:
        ex_rows = await db.execute(
            select(Exercise)
            .where(Exercise.id.in_(day_exercise_ids))
            .where(_exercise_scope(user.id))
        )
        exercise_model_map: dict[int, Exercise] = {
            ex.id: ex for ex in ex_rows.scalars().all()
        }
        missing = [eid for eid in day_exercise_ids if eid not in exercise_model_map]
        if missing:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Plan references exercises that no longer exist: {missing}. Edit the plan to replace them.",
            )
    else:
        exercise_model_map = {}

    # Guard: only one in-progress session at a time.
    # Use .scalars().first() (not scalar_one_or_none) so pre-existing dirty data
    # with multiple in-progress sessions doesn't cause a MultipleResultsFound crash.
    existing_result = await db.execute(
        select(WorkoutSession).where(WorkoutSession.status == WorkoutStatus.IN_PROGRESS, WorkoutSession.user_id == user.id)
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

    # Guard: reuse existing PLANNED session for the same plan + day instead of
    # creating duplicates.  This prevents orphan pile-up when the client calls
    # from-plan but crashes/navigates away before calling /start.
    planned_result = await db.execute(
        select(WorkoutSession).where(
            WorkoutSession.workout_plan_id == plan_id,
            WorkoutSession.name == f"{plan.name} - {day_name}",
            WorkoutSession.status == WorkoutStatus.PLANNED,
            WorkoutSession.started_at.is_(None),
            WorkoutSession.user_id == user.id,
        )
        .order_by(desc(WorkoutSession.id))
    )
    existing_planned = planned_result.scalars().first()
    if existing_planned:
        # Return the existing PLANNED session so the client can /start it
        existing_planned = await _get_session_with_sets(db, existing_planned.id, user_id=user.id)
        return serialize_session(existing_planned)

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
            WorkoutSession.name == f"{plan.name} - {day_name}",
            WorkoutSession.id.in_(sessions_with_data),
            WorkoutSession.user_id == user.id,
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
            if s.skipped_at is not None:
                continue  # Skipped sets don't count for progression
            if s.actual_weight_kg is None or s.actual_reps is None:
                continue
            ex_id = s.exercise_id
            if ex_id not in prior_set_data:
                prior_set_data[ex_id] = {}

            weight = s.actual_weight_kg
            # Fix legacy data: old code stored net load for assisted exercises
            # instead of the assist amount.  Detect by checking if the stored
            # weight exceeds body weight (assist can never be > body weight).
            ex_m = exercise_model_map.get(ex_id)
            if ex_m and ex_m.is_assisted and body_weight_kg > 0 and weight > body_weight_kg * 0.5:
                weight = max(0.0, body_weight_kg - weight)

            prior_set_data[ex_id][s.set_number] = {
                "weight": weight,
                "reps": s.actual_reps,
                "planned_reps": s.planned_reps,
                "reps_left": s.reps_left,
                "reps_right": s.reps_right,
                "planned_reps_left": s.planned_reps_left,
                "planned_reps_right": s.planned_reps_right,
                "set_type": s.set_type or "standard",
            }

    def _overload_for_side(
        prior_weight: float | None,
        prior_reps: int | None,
        prior_planned: int | None,
        target_reps: int,
        ex_model,
        target_rir: int | None = None,
    ) -> tuple[float | None, int | None]:
        """Compute overload for one side (or a bilateral set) given prior values."""
        if prior_reps is None or prior_reps <= 0:
            return None, None

        # Determine the effective planned target for the prior session's set.
        # Priority: 1) stored planned_reps from prior set, 2) plan target (if valid),
        # 3) actual reps as fallback (week 1 / plan has reps=0 — assume they hit target).
        if prior_planned and prior_planned > 0:
            planned = prior_planned
        elif target_reps and target_reps > 0:
            planned = target_reps
        else:
            planned = prior_reps  # week 1 / no target: treat actual as the goal

        # Epley conversion when the rep target changed between weeks (user edited plan)
        if target_reps and target_reps > 0 and target_reps != planned and prior_weight and prior_weight > 0:
            one_rm   = prior_weight * (1 + prior_reps / 30)
            prior_weight = round(one_rm / (1 + target_reps / 30) / 2.5) * 2.5
            prior_reps   = target_reps
            planned      = target_reps

        is_assisted = bool(ex_model and ex_model.is_assisted)
        suggested_weight, suggested_reps = compute_overload(
            prior_weight=prior_weight,
            prior_reps=prior_reps,
            planned_reps=planned,
            overload_style=overload_style,
            is_assisted=is_assisted,
            # Assisted exercises always have a weight (assist amount); only flag
            # as bodyweight for non-assisted exercises with no weight tracked.
            is_bodyweight=(not is_assisted) and (prior_weight is None or prior_weight <= 0),
            body_weight_kg=body_weight_kg,
        )
        if target_rir is not None and target_rir > 0:
            suggested_weight = adjust_load_for_target_rir(
                prior_weight,
                prior_reps,
                target_reps if target_reps > 0 else (suggested_reps or planned),
                target_rir,
                is_assisted=is_assisted,
                body_weight_kg=body_weight_kg,
            )
            if target_reps > 0:
                suggested_reps = target_reps
        return suggested_weight, suggested_reps

    def _overload_for_set(
        exercise_id: int, set_num: int, target_reps: int, ex_model,
        current_set_type: str = "standard",
    ) -> tuple[float | None, int | None, int | None, int | None]:
        """Return (weight_kg, planned_reps, planned_reps_left, planned_reps_right).

        Bilateral exercises: planned_reps_left/right are None.
        Unilateral exercises: each side is progressed independently from its
        own prior reps_left / reps_right; planned_reps is set to the weaker side.

        Only matches prior sets whose set_type matches current_set_type.
        """
        ex_sets = prior_set_data.get(exercise_id)
        if not ex_sets:
            return None, None, None, None

        # Filter prior sets to only those matching the current set_type
        matched_sets = {
            k: v for k, v in ex_sets.items()
            if v.get("set_type", "standard") == current_set_type
        }
        if not matched_sets:
            return None, None, None, None

        prior_set = matched_sets.get(set_num) or matched_sets.get(1) or matched_sets[min(matched_sets.keys())]
        target_rir = resolve_rir_override(
            planned_data,
            exercise_id,
            ex_model.primary_muscles if ex_model else None,
        )

        left_reps  = prior_set.get("reps_left")
        right_reps = prior_set.get("reps_right")
        is_unilateral = bool(ex_model and ex_model.is_unilateral)

        if is_unilateral and (left_reps is not None or right_reps is not None):
            # Each side progresses independently
            prior_weight = prior_set["weight"]
            # Use the stronger side for the weight calc (both sides use same weight)
            ref_reps = left_reps if right_reps is None else (
                right_reps if left_reps is None else max(left_reps, right_reps)
            )
            weight_kg, _ = _overload_for_side(
                prior_weight, ref_reps,
                prior_set.get("planned_reps_left") or prior_set.get("planned_reps"),
                target_reps, ex_model, target_rir,
            )
            _, new_reps_left = _overload_for_side(
                prior_weight, left_reps,
                prior_set.get("planned_reps_left") or prior_set.get("planned_reps"),
                target_reps, ex_model,
            )
            _, new_reps_right = _overload_for_side(
                prior_weight, right_reps,
                prior_set.get("planned_reps_right") or prior_set.get("planned_reps"),
                target_reps, ex_model,
            )
            # planned_reps = weaker side (conservative display)
            if new_reps_left is not None and new_reps_right is not None:
                weaker = min(new_reps_left, new_reps_right)
            else:
                weaker = new_reps_left if new_reps_left is not None else new_reps_right
            return weight_kg, weaker, new_reps_left, new_reps_right

        # Bilateral: standard single-side logic
        weight_kg, planned_reps = _overload_for_side(
            prior_set["weight"], prior_set["reps"],
            prior_set.get("planned_reps"), target_reps, ex_model, target_rir,
        )
        return weight_kg, planned_reps, None, None

    # Create session
    workout_session = WorkoutSession(
        date=date.today(),
        name=f"{plan.name} - {day_name}",
        workout_plan_id=plan_id,
        status=WorkoutStatus.PLANNED,
        user_id=user.id,
    )
    db.add(workout_session)
    await db.flush()
    await record_session_audit(
        db,
        workout_session,
        from_status=None,
        to_status=workout_session.status,
        reason="session_created_from_plan",
        endpoint=request.url.path,
        actor_username=user.username,
        source_device=request.headers.get("X-Client-Name") or "web",
    )

    # Create sets for each exercise
    for exercise_data in day_exercises:
        exercise_id = exercise_data.get("exercise_id")
        sets = exercise_data.get("sets", 3)
        reps = exercise_data.get("reps", 8)

        ex_model = exercise_model_map.get(exercise_id) if exercise_id else None

        plan_set_type = exercise_data.get("set_type", "standard")

        # Track set 1's planned values so myo_rep_match sets can copy them
        set1_weight_kg = None
        set1_reps = None
        set1_left = None
        set1_right = None

        for set_num in range(1, sets + 1):
            # Inherit set_type from prior session's matching set (user may have changed it mid-workout)
            prior_sets = prior_set_data.get(exercise_id, {})
            prior_set_for_num = prior_sets.get(set_num, {})
            effective_set_type = prior_set_for_num.get("set_type", plan_set_type)

            if effective_set_type == "myo_rep_match" and set_num > 1 and set1_weight_kg is not None:
                # Myo match sets copy set 1 exactly — no independent progression
                weight_kg = set1_weight_kg
                suggested_reps = set1_reps
                planned_left = set1_left
                planned_right = set1_right
            else:
                # Normal progression from prior session's corresponding set
                weight_kg, suggested_reps, planned_left, planned_right = \
                    _overload_for_set(exercise_id, set_num, reps, ex_model, current_set_type=effective_set_type)

            # Save set 1's values for myo_rep_match copying
            if set_num == 1:
                set1_weight_kg = weight_kg
                set1_reps = suggested_reps
                set1_left = planned_left
                set1_right = planned_right

            exercise_set = ExerciseSet(
                workout_session_id=workout_session.id,
                exercise_id=exercise_id,
                set_number=set_num,
                planned_reps=suggested_reps,
                planned_reps_left=planned_left,
                planned_reps_right=planned_right,
                planned_weight_kg=weight_kg,
                set_type=effective_set_type,
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


@router.get("/export/csv")
async def export_sessions_csv(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    """Export all workout data as CSV."""
    import csv
    import io
    from fastapi.responses import StreamingResponse

    result = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.user_id == user.id)
        .where(WorkoutSession.status == WorkoutStatus.COMPLETED)
        .order_by(desc(WorkoutSession.date))
    )
    sessions = result.scalars().all()

    # Get exercise names
    ex_result = await db.execute(select(Exercise))
    exercises = {e.id: e.display_name for e in ex_result.scalars().all()}

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["Date", "Workout", "Exercise", "Set", "Weight (kg)", "Reps", "Set Type", "Notes"])

    for session in sessions:
        for s in sorted(session.sets, key=lambda x: (x.exercise_id, x.set_number)):
            if s.actual_reps is None and s.actual_weight_kg is None:
                continue
            writer.writerow([
                session.date,
                session.name or "",
                exercises.get(s.exercise_id, f"Exercise {s.exercise_id}"),
                s.set_number,
                round(s.actual_weight_kg or 0, 2),
                s.actual_reps or 0,
                s.set_type or "standard",
                s.notes or "",
            ])

    output.seek(0)
    return StreamingResponse(
        iter([output.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=gymtracker-export.csv"},
    )


# ── Exercise feedback (autoregulation) ────────────────────────────────────────

@router.post("/{session_id}/feedback", response_model=dict, status_code=status.HTTP_201_CREATED)
async def save_exercise_feedback(
    session_id: int,
    data: dict,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Save recovery/effort feedback for an exercise in a session."""
    # Validate session belongs to user
    result = await db.execute(
        select(WorkoutSession).where(
            WorkoutSession.id == session_id, WorkoutSession.user_id == user.id
        )
    )
    session = result.scalar_one_or_none()
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    exercise_id = data.get("exercise_id")
    if not exercise_id:
        raise HTTPException(status_code=400, detail="exercise_id required")

    # Upsert — update existing feedback or create new
    existing_result = await db.execute(
        select(ExerciseFeedback).where(
            ExerciseFeedback.session_id == session_id,
            ExerciseFeedback.exercise_id == exercise_id,
            ExerciseFeedback.user_id == user.id,
        )
    )
    feedback = existing_result.scalar_one_or_none()

    if feedback:
        if "recovery_rating" in data:
            feedback.recovery_rating = data["recovery_rating"]
        if "rir" in data:
            feedback.rir = data["rir"]
        if "pump_rating" in data:
            feedback.pump_rating = data["pump_rating"]
        if "suggestion" in data:
            feedback.suggestion = data["suggestion"]
        if "suggestion_detail" in data:
            feedback.suggestion_detail = data["suggestion_detail"]
        if "suggestion_accepted" in data:
            feedback.suggestion_accepted = data["suggestion_accepted"]
    else:
        feedback = ExerciseFeedback(
            session_id=session_id,
            exercise_id=exercise_id,
            user_id=user.id,
            recovery_rating=data.get("recovery_rating"),
            rir=data.get("rir"),
            pump_rating=data.get("pump_rating"),
            suggestion=data.get("suggestion"),
            suggestion_detail=data.get("suggestion_detail"),
            suggestion_accepted=data.get("suggestion_accepted", False),
        )
        db.add(feedback)

    await db.flush()
    await db.refresh(feedback)
    return {
        "id": feedback.id,
        "session_id": feedback.session_id,
        "exercise_id": feedback.exercise_id,
        "recovery_rating": feedback.recovery_rating,
        "rir": feedback.rir,
        "pump_rating": feedback.pump_rating,
        "suggestion": feedback.suggestion,
        "suggestion_detail": feedback.suggestion_detail,
        "suggestion_accepted": feedback.suggestion_accepted,
    }


@router.get("/{session_id}/feedback", response_model=list[dict])
async def get_exercise_feedback(
    session_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    """Get all exercise feedback for a session."""
    result = await db.execute(
        select(ExerciseFeedback).where(
            ExerciseFeedback.session_id == session_id,
            ExerciseFeedback.user_id == user.id,
        )
    )
    return [
        {
            "id": f.id,
            "exercise_id": f.exercise_id,
            "recovery_rating": f.recovery_rating,
            "rir": f.rir,
            "pump_rating": f.pump_rating,
            "suggestion": f.suggestion,
            "suggestion_detail": f.suggestion_detail,
            "suggestion_accepted": f.suggestion_accepted,
        }
        for f in result.scalars().all()
    ]
