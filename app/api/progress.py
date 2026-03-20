"""Progress tracking API endpoints."""

from datetime import date, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.exercise import Exercise
from app.models.workout import ExerciseSet, WorkoutSession, WorkoutStatus

router = APIRouter()


@router.get("/")
async def get_progress(
    db: Annotated[AsyncSession, Depends(get_db)],
    exercise_id: int | None = Query(None, description="Filter by exercise ID"),
    start_date: date | None = Query(None, description="Start date for progress"),
    end_date: date | None = Query(None, description="End date for progress"),
) -> list[dict]:
    """Get progress metrics over time.

    Returns one entry per completed session × exercise so the frontend
    can plot a proper trend line.  Previously this endpoint collapsed
    every session for an exercise into a single aggregate row and then
    stamped the wrong date on it (the last session's date rather than
    each session's own date).
    """
    if not start_date:
        start_date = date.today() - timedelta(days=30)
    if not end_date:
        end_date = date.today()

    # ── Batch fetch all completed sessions in range ──────────────────────────
    session_result = await db.execute(
        select(WorkoutSession)
        .where(
            WorkoutSession.status == WorkoutStatus.COMPLETED,
            WorkoutSession.date >= start_date,
            WorkoutSession.date <= end_date,
        )
        .order_by(WorkoutSession.date, WorkoutSession.id)
    )
    sessions = session_result.scalars().all()
    if not sessions:
        return []

    session_ids = [s.id for s in sessions]
    session_map = {s.id: s for s in sessions}

    # ── Batch fetch all completed sets for these sessions ────────────────────
    sets_query = (
        select(ExerciseSet)
        .where(
            ExerciseSet.workout_session_id.in_(session_ids),
            ExerciseSet.actual_reps.is_not(None),
        )
    )
    if exercise_id:
        sets_query = sets_query.where(ExerciseSet.exercise_id == exercise_id)

    sets_result = await db.execute(sets_query)
    all_sets = sets_result.scalars().all()

    # ── Batch fetch all referenced exercises ─────────────────────────────────
    exercise_ids = {s.exercise_id for s in all_sets}
    if not exercise_ids:
        return []

    exercises_result = await db.execute(
        select(Exercise).where(Exercise.id.in_(exercise_ids))
    )
    exercise_map = {e.id: e for e in exercises_result.scalars().all()}

    # ── Group sets by (session_id, exercise_id) ──────────────────────────────
    grouped: dict[tuple[int, int], list[ExerciseSet]] = {}
    for s in all_sets:
        key = (s.workout_session_id, s.exercise_id)
        grouped.setdefault(key, []).append(s)

    # ── Build one progress row per (session, exercise) pair ──────────────────
    progress_list: list[dict] = []
    for (sess_id, ex_id), ex_sets in grouped.items():
        exercise = exercise_map.get(ex_id)
        if not exercise:
            continue
        session = session_map[sess_id]

        volume = sum(
            (s.actual_reps or 0) * (s.actual_weight_kg or 0)
            for s in ex_sets
        )

        estimated_1rm: float | None = None
        max_weight: float = 0.0
        for s in ex_sets:
            w = s.actual_weight_kg or 0.0
            r = s.actual_reps or 0
            max_weight = max(max_weight, w)
            if w > 0 and r > 0:
                one_rm = w * (1 + r / 30)
                if estimated_1rm is None or one_rm > estimated_1rm:
                    estimated_1rm = one_rm

        progress_list.append({
            "exercise_id": ex_id,
            "exercise_name": exercise.display_name,
            "date": session.date.isoformat(),
            "estimated_1rm": round(estimated_1rm, 1) if estimated_1rm else None,
            "volume_load": round(volume, 1),
            "recommended_weight": round(max_weight * 1.05, 1),
        })

    # Sort by date then exercise name for stable output
    progress_list.sort(key=lambda x: (x["date"], x["exercise_name"]))
    return progress_list


@router.get("/recommendations")
async def get_recommendations(
    db: Annotated[AsyncSession, Depends(get_db)],
    days_back: int = Query(30, description="Number of days to analyze"),
) -> list[dict]:
    """Get weight progression recommendations based on recent performance."""

    start_date = date.today() - timedelta(days=days_back)

    # ── Batch fetch sessions ──────────────────────────────────────────────────
    sessions_result = await db.execute(
        select(WorkoutSession).where(
            WorkoutSession.status == WorkoutStatus.COMPLETED,
            WorkoutSession.date >= start_date,
        )
    )
    sessions = sessions_result.scalars().all()
    if not sessions:
        return []

    session_ids = [s.id for s in sessions]

    # ── Batch fetch all completed sets for these sessions ────────────────────
    sets_result = await db.execute(
        select(ExerciseSet).where(
            ExerciseSet.workout_session_id.in_(session_ids),
            ExerciseSet.actual_reps.is_not(None),
        )
    )
    all_sets = sets_result.scalars().all()

    # ── Batch fetch all referenced exercises ─────────────────────────────────
    exercise_ids = {s.exercise_id for s in all_sets}
    if not exercise_ids:
        return []

    exercises_result = await db.execute(
        select(Exercise).where(Exercise.id.in_(exercise_ids))
    )
    exercise_map = {e.id: e for e in exercises_result.scalars().all()}

    # ── Collect best performance per exercise ─────────────────────────────────
    exercise_performance: dict[int, dict] = {}
    for exercise_set in all_sets:
        ex_id = exercise_set.exercise_id
        if ex_id not in exercise_performance:
            exercise_performance[ex_id] = {
                "best_weight": 0.0,
                "best_reps": 0,
                "total_volume": 0.0,
                "set_count": 0,
            }

        weight = exercise_set.actual_weight_kg or 0.0
        reps = exercise_set.actual_reps or 0

        if weight > exercise_performance[ex_id]["best_weight"]:
            exercise_performance[ex_id]["best_weight"] = weight
            exercise_performance[ex_id]["best_reps"] = reps

        exercise_performance[ex_id]["total_volume"] += weight * reps
        exercise_performance[ex_id]["set_count"] += 1

    # ── Build recommendations ─────────────────────────────────────────────────
    recommendations = []
    for ex_id, perf in exercise_performance.items():
        exercise = exercise_map.get(ex_id)
        if not exercise:
            continue

        current_weight = perf["best_weight"]

        if perf["best_reps"] >= 10:
            recommended_weight = current_weight * 1.05
            reason = "Achieved 10+ reps — increase weight by 5%"
        elif perf["best_reps"] >= 8:
            recommended_weight = current_weight * 1.025
            reason = "Achieved 8–9 reps — small weight increase"
        elif perf["best_reps"] >= 5:
            recommended_weight = current_weight
            reason = "Focus on adding reps before increasing weight"
        else:
            recommended_weight = current_weight * 0.95
            reason = "Below 5 reps — consider deloading"

        recommendations.append({
            "exercise_id": ex_id,
            "exercise_name": exercise.display_name,
            "current_weight": round(current_weight, 1),
            "recommended_weight": round(recommended_weight, 1),
            "reason": reason,
            "confidence": min(perf["set_count"] / 5, 1.0),
        })

    return sorted(recommendations, key=lambda r: r["exercise_name"])
