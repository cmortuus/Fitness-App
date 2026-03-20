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
    """Get progress metrics over time."""
    # Default to last 30 days
    if not start_date:
        start_date = date.today() - timedelta(days=30)
    if not end_date:
        end_date = date.today()

    # Query completed sessions in date range
    query = select(WorkoutSession).where(
        WorkoutSession.status == "completed",
        WorkoutSession.date >= start_date,
        WorkoutSession.date <= end_date,
    )

    if exercise_id:
        query = query.join(ExerciseSet).where(ExerciseSet.exercise_id == exercise_id)

    result = await db.execute(query)
    sessions = result.scalars().all()

    # Build progress data per exercise
    exercise_data = {}

    for session in sessions:
        sets_result = await db.execute(
            select(ExerciseSet).where(
                ExerciseSet.workout_session_id == session.id,
                ExerciseSet.actual_reps != None,
            )
        )
        sets = sets_result.scalars().all()

        for exercise_set in sets:
            ex_id = exercise_set.exercise_id
            if ex_id not in exercise_data:
                exercise_data[ex_id] = {
                    "volume": 0,
                    "total_reps": 0,
                    "total_sets": 0,
                    "max_weight": 0,
                }

            volume = (exercise_set.actual_reps or 0) * (exercise_set.actual_weight_kg or 0)
            exercise_data[ex_id]["volume"] += volume
            exercise_data[ex_id]["total_reps"] += exercise_set.actual_reps or 0
            exercise_data[ex_id]["total_sets"] += 1
            exercise_data[ex_id]["max_weight"] = max(
                exercise_data[ex_id]["max_weight"],
                exercise_set.actual_weight_kg or 0
            )

    # Get exercise names and format response
    progress_list = []
    for ex_id, data in exercise_data.items():
        exercise = await db.get(Exercise, ex_id)
        if exercise:
            # Estimate 1RM using Epley formula
            estimated_1rm = None
            if data["max_weight"] > 0 and data["total_reps"] > 0:
                estimated_1rm = data["max_weight"] * (1 + data["total_reps"] / 30)

            progress_list.append({
                "exercise_id": ex_id,
                "exercise_name": exercise.display_name,
                "date": session.date.isoformat(),
                "estimated_1rm": round(estimated_1rm, 1) if estimated_1rm else None,
                "volume_load": round(data["volume"], 1),
                "recommended_weight": round(data["max_weight"] * 1.05, 1),
            })

    return progress_list


@router.get("/recommendations")
async def get_recommendations(
    db: Annotated[AsyncSession, Depends(get_db)],
    days_back: int = Query(30, description="Number of days to analyze"),
) -> list[dict]:
    """Get weight progression recommendations based on recent performance."""

    start_date = date.today() - timedelta(days=days_back)

    # Get completed sessions
    result = await db.execute(
        select(WorkoutSession).where(
            WorkoutSession.status == "completed",
            WorkoutSession.date >= start_date,
        )
    )
    sessions = result.scalars().all()

    if not sessions:
        return []

    # Collect data per exercise
    exercise_performance = {}

    for session in sessions:
        sets_result = await db.execute(
            select(ExerciseSet).where(
                ExerciseSet.workout_session_id == session.id,
                ExerciseSet.actual_reps != None,
            )
        )
        sets = sets_result.scalars().all()

        for exercise_set in sets:
            ex_id = exercise_set.exercise_id
            if ex_id not in exercise_performance:
                exercise_performance[ex_id] = {
                    "best_weight": 0,
                    "best_reps": 0,
                    "total_volume": 0,
                    "set_count": 0,
                }

            weight = exercise_set.actual_weight_kg or 0
            reps = exercise_set.actual_reps or 0

            if weight > exercise_performance[ex_id]["best_weight"]:
                exercise_performance[ex_id]["best_weight"] = weight
                exercise_performance[ex_id]["best_reps"] = reps

            exercise_performance[ex_id]["total_volume"] += weight * reps
            exercise_performance[ex_id]["set_count"] += 1

    # Generate recommendations
    recommendations = []
    for ex_id, perf in exercise_performance.items():
        exercise = await db.get(Exercise, ex_id)
        if not exercise:
            continue

        current_weight = perf["best_weight"]
        recommended_weight = current_weight

        # Progression logic based on reps achieved
        if perf["best_reps"] >= 10:
            recommended_weight = current_weight * 1.05
            reason = "Achieved 10+ reps - increase weight by 5%"
        elif perf["best_reps"] >= 8:
            recommended_weight = current_weight * 1.025
            reason = "Achieved 8-9 reps - small weight increase"
        elif perf["best_reps"] >= 5:
            recommended_weight = current_weight
            reason = "Focus on adding reps before increasing weight"
        else:
            recommended_weight = current_weight * 0.95
            reason = "Below 5 reps - consider deloading"

        recommendations.append({
            "exercise_id": ex_id,
            "exercise_name": exercise.display_name,
            "current_weight": round(current_weight, 1),
            "recommended_weight": round(recommended_weight, 1),
            "reason": reason,
            "confidence": min(perf["set_count"] / 5, 1.0),
        })

    return recommendations
