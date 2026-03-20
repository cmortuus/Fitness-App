"""Progress tracking API endpoints."""

from datetime import date, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.exercise import Exercise
from app.models.workout import ExerciseSet, WorkoutSession

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

    # Fetch completed sessions in the requested date range, oldest first
    # so the chart x-axis is naturally ordered.
    session_result = await db.execute(
        select(WorkoutSession)
        .where(
            WorkoutSession.status == "completed",
            WorkoutSession.date >= start_date,
            WorkoutSession.date <= end_date,
        )
        .order_by(WorkoutSession.date, WorkoutSession.id)
    )
    sessions = session_result.scalars().all()

    progress_list: list[dict] = []

    for session in sessions:
        # Fetch all completed sets for this session (optionally filtered)
        sets_query = select(ExerciseSet).where(
            ExerciseSet.workout_session_id == session.id,
            ExerciseSet.actual_reps.is_not(None),
        )
        if exercise_id:
            sets_query = sets_query.where(ExerciseSet.exercise_id == exercise_id)

        sets_result = await db.execute(sets_query)
        sets = sets_result.scalars().all()

        # Group sets by exercise
        exercise_sets: dict[int, list[ExerciseSet]] = {}
        for s in sets:
            exercise_sets.setdefault(s.exercise_id, []).append(s)

        for ex_id, ex_sets in exercise_sets.items():
            exercise = await db.get(Exercise, ex_id)
            if not exercise:
                continue

            # Volume for this session = Σ(weight × reps) across all sets
            volume = sum(
                (s.actual_reps or 0) * (s.actual_weight_kg or 0)
                for s in ex_sets
            )

            # Best Epley 1RM across sets: max(weight × (1 + reps/30))
            # Use per-set reps — NOT the total reps sum, which produces
            # wildly inflated estimates.
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

    return progress_list


@router.get("/recommendations")
async def get_recommendations(
    db: Annotated[AsyncSession, Depends(get_db)],
    days_back: int = Query(30, description="Number of days to analyze"),
) -> list[dict]:
    """Get weight progression recommendations based on recent performance."""

    start_date = date.today() - timedelta(days=days_back)

    result = await db.execute(
        select(WorkoutSession).where(
            WorkoutSession.status == "completed",
            WorkoutSession.date >= start_date,
        )
    )
    sessions = result.scalars().all()

    if not sessions:
        return []

    # Collect best performance per exercise across all sessions
    exercise_performance: dict[int, dict] = {}

    for session in sessions:
        sets_result = await db.execute(
            select(ExerciseSet).where(
                ExerciseSet.workout_session_id == session.id,
                ExerciseSet.actual_reps.is_not(None),
            )
        )
        sets = sets_result.scalars().all()

        for exercise_set in sets:
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

    recommendations = []
    for ex_id, perf in exercise_performance.items():
        exercise = await db.get(Exercise, ex_id)
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

    return recommendations
