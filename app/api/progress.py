"""Progress tracking API endpoints."""

from datetime import date, datetime, timedelta, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.body_weight import BodyWeightEntry
from app.models.exercise import Exercise
from app.models.nutrition import MacroGoal, NutritionEntry
from app.models.user import User
from app.models.workout import ExerciseSet, WorkoutSession, WorkoutStatus

router = APIRouter()


@router.get("/")
async def get_progress(
    user: Annotated[User, Depends(get_current_user)],
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
            WorkoutSession.user_id == user.id,
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
    user: Annotated[User, Depends(get_current_user)],
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
            WorkoutSession.user_id == user.id,
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


@router.get("/insights")
async def get_insights(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    """Generate actionable fitness + nutrition insights for the past 7 days."""
    today = date.today()
    week_ago = today - timedelta(days=7)
    insights: list[dict] = []

    # 1. Protein adherence
    goal_result = await db.execute(
        select(MacroGoal).where(MacroGoal.effective_from <= today, MacroGoal.user_id == user.id)
        .order_by(desc(MacroGoal.effective_from)).limit(1)
    )
    goal = goal_result.scalar_one_or_none()
    if goal and goal.protein > 0:
        days_hit = 0
        for i in range(7):
            d = today - timedelta(days=i)
            result = await db.execute(
                select(func.sum(NutritionEntry.protein)).where(NutritionEntry.date == d, NutritionEntry.user_id == user.id)
            )
            total = result.scalar() or 0
            if total >= goal.protein * 0.9:  # within 90% of target
                days_hit += 1
        if days_hit >= 5:
            insights.append({"type": "success", "icon": "💪", "text": f"Hit protein target {days_hit}/7 days this week"})
        elif days_hit <= 2:
            insights.append({"type": "warning", "icon": "⚠️", "text": f"Protein target met only {days_hit}/7 days — aim for {round(goal.protein)}g daily"})

    # 2. Calorie adherence
    if goal and goal.calories > 0:
        days_on = 0
        for i in range(7):
            d = today - timedelta(days=i)
            result = await db.execute(
                select(func.sum(NutritionEntry.calories)).where(NutritionEntry.date == d, NutritionEntry.user_id == user.id)
            )
            total = result.scalar() or 0
            if total > 0 and abs(total - goal.calories) <= goal.calories * 0.1:
                days_on += 1
        if days_on >= 5:
            insights.append({"type": "success", "icon": "🎯", "text": f"Calories within 10% of target {days_on}/7 days"})

    # 3. Workout frequency
    ws_result = await db.execute(
        select(func.count(WorkoutSession.id))
        .where(WorkoutSession.started_at >= datetime.combine(week_ago, datetime.min.time(), tzinfo=timezone.utc))
        .where(WorkoutSession.completed_at.isnot(None))
        .where(WorkoutSession.user_id == user.id)
    )
    workout_count = ws_result.scalar() or 0
    if workout_count >= 4:
        insights.append({"type": "success", "icon": "🔥", "text": f"{workout_count} workouts this week — great consistency"})
    elif workout_count == 0:
        insights.append({"type": "warning", "icon": "🏋️", "text": "No workouts logged this week"})

    # 4. Weight trend
    bw_result = await db.execute(
        select(BodyWeightEntry)
        .where(BodyWeightEntry.recorded_at >= datetime.combine(week_ago, datetime.min.time(), tzinfo=timezone.utc))
        .where(BodyWeightEntry.user_id == user.id)
        .order_by(BodyWeightEntry.recorded_at)
    )
    bw_entries = bw_result.scalars().all()
    if len(bw_entries) >= 2:
        change = bw_entries[-1].weight_kg - bw_entries[0].weight_kg
        change_lbs = change * 2.205
        if abs(change_lbs) >= 0.5:
            direction = "down" if change < 0 else "up"
            insights.append({
                "type": "info",
                "icon": "📉" if change < 0 else "📈",
                "text": f"Weight trending {direction} {abs(change_lbs):.1f} lbs this week",
            })

    # 5. PR detection (estimate 1RM improvement)
    recent_sets = await db.execute(
        select(ExerciseSet, Exercise.name)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .join(Exercise, ExerciseSet.exercise_id == Exercise.id)
        .where(WorkoutSession.started_at >= datetime.combine(week_ago, datetime.min.time(), tzinfo=timezone.utc))
        .where(ExerciseSet.actual_reps.isnot(None))
        .where(ExerciseSet.actual_weight_kg > 0)
        .where(WorkoutSession.user_id == user.id)
    )
    # Group by exercise, find max estimated 1RM
    exercise_maxes: dict[str, float] = {}
    for s, name in recent_sets.all():
        e1rm = s.actual_weight_kg * (1 + (s.actual_reps or 0) / 30)
        if name not in exercise_maxes or e1rm > exercise_maxes[name]:
            exercise_maxes[name] = e1rm

    # Compare to previous week
    prev_week_ago = week_ago - timedelta(days=7)
    prev_sets = await db.execute(
        select(ExerciseSet, Exercise.name)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .join(Exercise, ExerciseSet.exercise_id == Exercise.id)
        .where(WorkoutSession.started_at >= datetime.combine(prev_week_ago, datetime.min.time(), tzinfo=timezone.utc))
        .where(WorkoutSession.started_at < datetime.combine(week_ago, datetime.min.time(), tzinfo=timezone.utc))
        .where(ExerciseSet.actual_reps.isnot(None))
        .where(ExerciseSet.actual_weight_kg > 0)
        .where(WorkoutSession.user_id == user.id)
    )
    prev_maxes: dict[str, float] = {}
    for s, name in prev_sets.all():
        e1rm = s.actual_weight_kg * (1 + (s.actual_reps or 0) / 30)
        if name not in prev_maxes or e1rm > prev_maxes[name]:
            prev_maxes[name] = e1rm

    prs = []
    for name, e1rm in exercise_maxes.items():
        prev = prev_maxes.get(name)
        if prev and e1rm > prev * 1.02:  # >2% improvement
            prs.append(name)
    if prs:
        if len(prs) == 1:
            insights.append({"type": "success", "icon": "🏆", "text": f"New estimated PR on {prs[0]}"})
        else:
            insights.append({"type": "success", "icon": "🏆", "text": f"PRs on {len(prs)} exercises this week"})

    return insights
