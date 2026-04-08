"""Workout plan API endpoints."""

import json
from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy import desc, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.user import User
from app.models.workout import WorkoutPlan, WorkoutSession, ExerciseSet, ExerciseFeedback, WorkoutStatus
from app.models.exercise import Exercise
from app.schemas.requests import WorkoutPlanCreate, WorkoutPlanResponse, PlanRirOverrides
from app.services.plan_rir import normalize_rir_overrides
from app.api.progress import VOLUME_LANDMARKS

router = APIRouter()


def _exercise_scope(user_id: int):
    return or_(Exercise.user_id.is_(None), Exercise.user_id == user_id)


def _ensure_planned_block_ids(planned_data: dict) -> dict:
    """Ensure each planned exercise occurrence has a stable block_id."""
    if not isinstance(planned_data, dict):
        return planned_data
    for day in planned_data.get("days", []):
        for exercise in day.get("exercises", []):
            if not exercise.get("block_id"):
                exercise["block_id"] = str(uuid4())
    return planned_data


def serialize_plan(plan: WorkoutPlan) -> dict:
    """Serialize a WorkoutPlan to a dictionary."""
    try:
        planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}
    except (json.JSONDecodeError, TypeError):
        planned_data = {}

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
        number_of_days = planned_data.get("number_of_days") or len(days)
    planned_data = _ensure_planned_block_ids(planned_data)
    days = planned_data.get("days", days)
    rir_overrides = normalize_rir_overrides(planned_data.get("rir_overrides"))

    return {
        "id": plan.id,
        "name": plan.name,
        "description": plan.description,
        "block_type": plan.block_type,
        "duration_weeks": plan.duration_weeks,
        "current_week": plan.current_week,
        "number_of_days": number_of_days,
        "days": days,
        "rir_overrides": rir_overrides,
        "auto_progression": plan.auto_progression,
        "is_draft": plan.is_draft,
        "is_archived": plan.is_archived,
        "created_at": plan.created_at,
    }


def session_matches_plan(session: WorkoutSession, plan: dict) -> bool:
    if session.workout_plan_id == plan["id"]:
        return True
    return bool(session.name and session.name.startswith(f"{plan['name']} - "))


def resolve_next_workout(sessions: list[WorkoutSession], plans: list[dict]) -> dict | None:
    active_plans = [p for p in plans if not p["is_archived"] and not p["is_draft"]]
    if not active_plans:
        return None

    def completed_sessions_for_plan(plan: dict) -> list[WorkoutSession]:
        return [
            s for s in sessions
            if s.status == "completed"
            and ((s.total_sets or 0) > 0 or (s.total_reps or 0) > 0)
            and session_matches_plan(s, plan)
        ]

    def done_or_skipped_sessions_for_plan(plan: dict) -> list[WorkoutSession]:
        """Completed + skipped sessions — both advance the day counter."""
        return [
            s for s in sessions
            if s.status in ("completed", "skipped")
            and session_matches_plan(s, plan)
        ]

    recent_with_plan = next(
        (
            s for s in sessions
            if s.status != "skipped" and any(session_matches_plan(s, plan) for plan in active_plans)
        ),
        None,
    )

    if recent_with_plan:
        plan = next(
            (p for p in active_plans if session_matches_plan(recent_with_plan, p)),
            active_plans[0],
        )
    else:
        plan = active_plans[0]

    if not plan["days"]:
        return None

    completed_sessions = completed_sessions_for_plan(plan)
    # Count both completed and skipped sessions for day advancement —
    # skipping a day should move the plan forward, not repeat the same day.
    advanced_sessions = done_or_skipped_sessions_for_plan(plan)
    advanced_count = len(advanced_sessions)
    done_count = len(completed_sessions)
    total_needed = plan["duration_weeks"] * len(plan["days"])
    is_complete = done_count >= total_needed
    next_day_idx = 0 if is_complete else advanced_count % len(plan["days"])
    week_number = plan["duration_weeks"] if is_complete else (advanced_count // len(plan["days"])) + 1
    day_number = next_day_idx + 1

    return {
        "plan": plan,
        "day": plan["days"][next_day_idx],
        "week_number": week_number,
        "day_number": day_number,
        "is_complete": is_complete,
        "debug": {
            "selected_plan_id": plan["id"],
            "completed_session_count": done_count,
            "total_sessions_needed": total_needed,
            "recent_session_id": recent_with_plan.id if recent_with_plan else None,
        },
    }


@router.get("/", response_model=list[WorkoutPlanResponse])
async def list_plans(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    include_drafts: bool = Query(False, alias="drafts"),
) -> list[dict]:
    """List all workout plans. Pass ?drafts=true to include drafts."""
    stmt = select(WorkoutPlan).where(WorkoutPlan.user_id == user.id)
    if not include_drafts:
        stmt = stmt.where(WorkoutPlan.is_draft.is_(False))
    result = await db.execute(stmt.order_by(WorkoutPlan.created_at.desc()))
    plans = result.scalars().all()
    return [serialize_plan(p) for p in plans]


@router.get("/next-workout")
async def get_next_workout(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict | None:
    """Return the canonical next workout for the current user."""
    plans_result = await db.execute(
        select(WorkoutPlan)
        .where(WorkoutPlan.user_id == user.id, WorkoutPlan.is_draft.is_(False))
        .order_by(WorkoutPlan.created_at.desc())
    )
    plans = [serialize_plan(p) for p in plans_result.scalars().all()]
    if not plans:
        return None

    sessions_result = await db.execute(
        select(WorkoutSession)
        .where(WorkoutSession.user_id == user.id)
        .order_by(WorkoutSession.date.desc(), WorkoutSession.id.desc())
    )
    sessions = sessions_result.scalars().all()

    return resolve_next_workout(sessions, plans)


@router.get("/exercises/recent", response_model=list[dict])
async def get_recent_exercises(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
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
        .where(_exercise_scope(user.id))
        .group_by(Exercise.id)
        .order_by(func.max(WorkoutSession.date).desc())
        .limit(limit)
    )

    query = query.where(WorkoutSession.user_id == user.id)

    result = await db.execute(query)
    exercises = result.all()

    return [
        {
            "id": ex.id,
            "name": ex.name,
            "display_name": ex.display_name,
            "movement_type": ex.movement_type,
            "primary_muscles": ex.primary_muscles or [],
            "usage_count": ex.usage_count,
            "last_used": ex.last_used.isoformat() if ex.last_used else None,
        }
        for ex in exercises
    ]


@router.get("/exercises/grouped", response_model=dict[str, list[dict]])
async def get_exercises_grouped(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict[str, list[dict]]:
    """Get all exercises grouped by primary muscle group."""
    result = await db.execute(
        select(Exercise)
        .where(_exercise_scope(user.id))
        .order_by(Exercise.display_name)
    )
    exercises = result.scalars().all()

    grouped: dict[str, list[dict]] = {}

    for ex in exercises:
        primary_muscles = ex.primary_muscles or ["other"]

        for muscle in primary_muscles:
            muscle = muscle.lower().replace(" ", "_")
            if muscle not in grouped:
                grouped[muscle] = []
            grouped[muscle].append({
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
                "description": ex.description,
                "primary_muscles": primary_muscles,
                "secondary_muscles": ex.secondary_muscles or [],
            })

    # Sort keys for consistent ordering
    return dict(sorted(grouped.items()))


@router.get("/{plan_id}", response_model=WorkoutPlanResponse)
async def get_plan(
    plan_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Get a workout plan by ID."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout plan {plan_id} not found",
        )
    return serialize_plan(plan)


@router.get("/{plan_id}/recommendations")
async def get_plan_recommendations(
    plan_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Workout plan {plan_id} not found")

    try:
        planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}
    except (json.JSONDecodeError, TypeError):
        planned_data = {}
    days = planned_data.get("days", []) if isinstance(planned_data, dict) else []

    planned_set_counts: dict[int, int] = {}
    muscle_planned_sets: dict[str, int] = {}
    plan_exercise_ids: set[int] = set()
    for day in days:
        for ex in day.get("exercises", []):
            ex_id = ex.get("exercise_id")
            if not ex_id:
                continue
            plan_exercise_ids.add(ex_id)
            planned_set_counts[ex_id] = planned_set_counts.get(ex_id, 0) + max(0, int(ex.get("sets", 0) or 0))

    if not plan_exercise_ids:
        return []

    ex_rows = await db.execute(select(Exercise).where(Exercise.id.in_(plan_exercise_ids)))
    exercises = {exercise.id: exercise for exercise in ex_rows.scalars().all()}
    for ex_id, count in planned_set_counts.items():
        exercise = exercises.get(ex_id)
        for muscle in exercise.primary_muscles or [] if exercise else []:
            muscle_planned_sets[muscle] = muscle_planned_sets.get(muscle, 0) + count

    feedback_rows = await db.execute(
        select(ExerciseFeedback, WorkoutSession)
        .join(WorkoutSession, ExerciseFeedback.session_id == WorkoutSession.id)
        .where(
            ExerciseFeedback.user_id == user.id,
            WorkoutSession.workout_plan_id == plan_id,
            WorkoutSession.status == WorkoutStatus.COMPLETED,
        )
        .order_by(desc(WorkoutSession.date), desc(WorkoutSession.id), desc(ExerciseFeedback.id))
    )

    latest_feedback_by_exercise: dict[int, tuple[ExerciseFeedback, WorkoutSession]] = {}
    for feedback, session in feedback_rows.all():
        if feedback.exercise_id not in latest_feedback_by_exercise:
            latest_feedback_by_exercise[feedback.exercise_id] = (feedback, session)

    recommendations: list[dict] = []
    for exercise_id, (feedback, session) in latest_feedback_by_exercise.items():
        exercise = exercises.get(exercise_id)
        if not exercise:
            continue
        if feedback.rir is None:
            continue

        primary_muscle = exercise.primary_muscles[0] if exercise.primary_muscles else None
        if primary_muscle is None:
            # No muscle data — can't make meaningful volume recommendations
            continue
        muscle_landmarks = VOLUME_LANDMARKS.get(primary_muscle, {"mev": 4, "mav": 10, "mrv": 16})
        weekly_sets = muscle_planned_sets.get(primary_muscle, 0)

        if feedback.rir <= 1 and feedback.recovery_rating in {"poor", "ok"}:
            add_set = weekly_sets < muscle_landmarks["mav"]
            recommendations.append({
                "type": "backoff_rir",
                "exercise_id": exercise_id,
                "exercise_name": exercise.display_name,
                "muscle_group": primary_muscle,
                "current_rir": feedback.rir,
                "recovery_rating": feedback.recovery_rating,
                "recommended_rir": 2,
                "add_set": add_set,
                "set_delta": 1 if add_set else 0,
                "weekly_sets": weekly_sets,
                "mav_sets": muscle_landmarks["mav"],
                "reason": (
                    f"{exercise.display_name} hit {feedback.rir} RIR with {feedback.recovery_rating} recovery. "
                    f"Backing off to 2 RIR should improve recovery consistency."
                ),
                "detail": (
                    f"{primary_muscle.replace('_', ' ').title() if primary_muscle else 'This muscle group'} is at "
                    f"{weekly_sets} planned sets/week. "
                    + ("Add 1 set to keep growth stimulus while easing effort." if add_set else "Hold set count steady for now.")
                ),
                "source_session_id": session.id,
            })

    return recommendations


@router.post("/", response_model=WorkoutPlanResponse, status_code=status.HTTP_201_CREATED)
async def create_plan(
    plan_data: WorkoutPlanCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a new workout plan."""
    # Convert days structure to JSON
    planned_data = {
        "number_of_days": plan_data.number_of_days,
        "days": [d.model_dump() for d in plan_data.days],
        "rir_overrides": normalize_rir_overrides(plan_data.rir_overrides.model_dump()),
    }
    planned_data = _ensure_planned_block_ids(planned_data)
    planned_exercises_json = json.dumps(planned_data)

    # Validate exercise IDs (skip for drafts — allow empty/incomplete plans)
    if not plan_data.is_draft:
        all_exercise_ids = {
            ex.exercise_id
            for day in plan_data.days
            for ex in day.exercises
        }
        if all_exercise_ids:
            result = await db.execute(
                select(Exercise.id)
                .where(Exercise.id.in_(all_exercise_ids))
                .where(_exercise_scope(user.id))
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
        current_week=1,
        planned_exercises=planned_exercises_json,
        auto_progression=plan_data.auto_progression,
        is_draft=plan_data.is_draft,
        user_id=user.id,
    )
    db.add(plan)
    await db.flush()
    await db.refresh(plan)
    return serialize_plan(plan)


@router.post("/{plan_id}/archive", response_model=WorkoutPlanResponse)
async def archive_plan(
    plan_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Mark a completed plan as archived. It stays in history but moves out of the active list."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Plan {plan_id} not found")
    plan.is_archived = True
    await db.flush()
    await db.refresh(plan)
    return serialize_plan(plan)


@router.post("/{plan_id}/publish", response_model=WorkoutPlanResponse)
async def publish_plan(
    plan_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Publish a draft plan — validates exercises and activates it."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Plan {plan_id} not found")
    if not plan.is_draft:
        return serialize_plan(plan)  # Already published

    # Validate all exercises exist before publishing
    try:
        planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}
    except (json.JSONDecodeError, TypeError):
        planned_data = {}
    days = planned_data.get("days", [])
    all_exercise_ids = {ex["exercise_id"] for day in days for ex in day.get("exercises", [])}
    if all_exercise_ids:
        ex_result = await db.execute(
            select(Exercise.id)
            .where(Exercise.id.in_(all_exercise_ids))
            .where(_exercise_scope(user.id))
        )
        found_ids = {row[0] for row in ex_result.all()}
        missing = all_exercise_ids - found_ids
        if missing:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                                detail=f"Cannot publish: exercise IDs not found: {sorted(missing)}")

    plan.is_draft = False
    await db.flush()
    await db.refresh(plan)
    return serialize_plan(plan)


@router.post("/{plan_id}/reuse", response_model=WorkoutPlanResponse, status_code=status.HTTP_201_CREATED)
async def reuse_plan(
    plan_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a fresh active copy of an archived plan so you can run the block again."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id))
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
        user_id=user.id,
    )
    db.add(new_plan)
    await db.flush()
    await db.refresh(new_plan)
    return serialize_plan(new_plan)


@router.delete("/{plan_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_plan(
    plan_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a workout plan."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout plan {plan_id} not found",
        )
    await db.delete(plan)
    await db.flush()


class PlanUpdate(BaseModel):
    """Schema for updating a workout plan."""
    name: str | None = None
    description: str | None = None
    block_type: str | None = None
    duration_weeks: int | None = None
    number_of_days: int | None = None
    days: list | None = None
    auto_progression: bool | None = None
    is_draft: bool | None = None


@router.put("/{plan_id}/rir-overrides", response_model=WorkoutPlanResponse)
async def update_plan_rir_overrides(
    plan_id: int,
    overrides: PlanRirOverrides,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id))
    plan = result.scalar_one_or_none()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Workout plan {plan_id} not found",
        )

    try:
        planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}
    except (json.JSONDecodeError, TypeError):
        planned_data = {}

    if isinstance(planned_data, list):
        planned_data = {
            "number_of_days": len(planned_data) or 1,
            "days": planned_data,
        }

    planned_data["rir_overrides"] = normalize_rir_overrides(overrides.model_dump())
    planned_data = _ensure_planned_block_ids(planned_data)
    plan.planned_exercises = json.dumps(planned_data)
    await db.flush()
    await db.refresh(plan)
    return serialize_plan(plan)


@router.put("/{plan_id}", response_model=WorkoutPlanResponse)
async def update_plan(
    plan_id: int,
    plan_data: PlanUpdate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Update a workout plan."""
    result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan_id, WorkoutPlan.user_id == user.id))
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
    if plan_data.is_draft is not None:
        plan.is_draft = plan_data.is_draft

    # Handle days update
    if plan_data.days is not None or plan_data.number_of_days is not None:
        # Get current planned exercises
        try:
            planned_data = json.loads(plan.planned_exercises) if plan.planned_exercises else {}
        except (json.JSONDecodeError, TypeError):
            planned_data = {}

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
        planned_data = _ensure_planned_block_ids(planned_data)

        all_exercise_ids = {
            ex.get("exercise_id")
            for day in planned_data.get("days", [])
            for ex in day.get("exercises", [])
            if ex.get("exercise_id")
        }
        if all_exercise_ids:
            ex_result = await db.execute(
                select(Exercise.id)
                .where(Exercise.id.in_(all_exercise_ids))
                .where(_exercise_scope(user.id))
            )
            found_ids = {row[0] for row in ex_result.all()}
            missing = all_exercise_ids - found_ids
            if missing:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"Exercise IDs not found: {sorted(missing)}",
                )

        plan.planned_exercises = json.dumps(planned_data)

    await db.flush()
    await db.refresh(plan)
    return serialize_plan(plan)
