"""Progress tracking API endpoints."""

import json
from datetime import date, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel as _PydanticBase
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.api.auth import get_current_user
from app.database import get_db
from app.models.body_weight import BodyWeightEntry
from app.models.exercise import Exercise
from app.models.nutrition import MacroGoal, NutritionEntry
from app.models.user import User
from app.models.workout import ExerciseSet, WorkoutSession, WorkoutStatus
from app.services.overload import OverloadInput, calculate_overload, epley_1rm

router = APIRouter()


def get_training_level(user: User) -> str:
    """Read the saved progression training level from user settings."""
    if not user.settings_json:
        return "intermediate"

    try:
        settings = json.loads(user.settings_json)
    except json.JSONDecodeError:
        return "intermediate"

    training_level = settings.get("progression", {}).get("trainingLevel")
    return training_level if training_level in {"beginner", "intermediate", "advanced"} else "intermediate"


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
        .where(WorkoutSession.started_at >= datetime.combine(week_ago, datetime.min.time()))
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
        .where(BodyWeightEntry.recorded_at >= datetime.combine(week_ago, datetime.min.time()))
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
        .where(WorkoutSession.started_at >= datetime.combine(week_ago, datetime.min.time()))
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
        .where(WorkoutSession.started_at >= datetime.combine(prev_week_ago, datetime.min.time()))
        .where(WorkoutSession.started_at < datetime.combine(week_ago, datetime.min.time()))
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

    # 6. Auto-deload detection: check if performance dropped 2+ sessions in a row
    # Look at last 3 sessions for each exercise and check if estimated 1RM is declining
    recent_sessions = await db.execute(
        select(WorkoutSession)
        .options(selectinload(WorkoutSession.sets))
        .where(WorkoutSession.user_id == user.id)
        .where(WorkoutSession.status == WorkoutStatus.COMPLETED)
        .order_by(desc(WorkoutSession.date))
        .limit(10)
    )
    recent_sess_list = recent_sessions.scalars().all()
    if len(recent_sess_list) >= 3:
        # Group sets by exercise across sessions, track best 1RM per session.
        # Sessions are in DESC date order so history[0] = most recent.
        # Declining = history[0] < history[1] < history[2] (each session lower than the one before).
        exercise_1rm_history: dict[int, list[float]] = {}
        for sess in recent_sess_list[:5]:
            # First pass: find the best estimated 1RM per exercise within this session
            session_best: dict[int, float] = {}
            for s in (sess.sets or []):
                if s.actual_reps and s.actual_weight_kg and s.actual_weight_kg > 0 and (s.set_type or 'standard') != 'warmup':
                    est = s.actual_weight_kg * (1 + s.actual_reps / 30)
                    if s.exercise_id not in session_best or est > session_best[s.exercise_id]:
                        session_best[s.exercise_id] = est
            # Second pass: append this session's best to the per-exercise history
            for eid, best in session_best.items():
                if eid not in exercise_1rm_history:
                    exercise_1rm_history[eid] = []
                exercise_1rm_history[eid].append(best)

        declining = []
        for eid, history in exercise_1rm_history.items():
            if len(history) >= 3 and history[0] < history[1] < history[2]:
                # Performance declining for 3 sessions — get exercise name
                ex_result = await db.execute(select(Exercise.display_name).where(Exercise.id == eid))
                name = ex_result.scalar()
                if name:
                    declining.append(name)

        if declining:
            insights.append({
                "type": "warning",
                "icon": "⚠️",
                "text": f"Performance declining on {', '.join(declining[:3])} — consider a deload week"
            })

    # 7. Exercise rotation suggestions — exercises not done in 4+ weeks
    if len(recent_sess_list) >= 3:
        four_weeks_ago = today - timedelta(days=28)
        recent_exercise_ids = set()
        for sess in recent_sess_list:
            if sess.date >= four_weeks_ago:
                for s in (sess.sets or []):
                    recent_exercise_ids.add(s.exercise_id)

        # Find exercises done in older sessions but not recent ones
        all_exercise_ids = set()
        for sess in recent_sess_list:
            for s in (sess.sets or []):
                all_exercise_ids.add(s.exercise_id)

        stale = all_exercise_ids - recent_exercise_ids
        if stale:
            stale_names = []
            for eid in list(stale)[:3]:
                ex_r = await db.execute(select(Exercise.display_name).where(Exercise.id == eid))
                n = ex_r.scalar()
                if n:
                    stale_names.append(n)
            if stale_names:
                insights.append({
                    "type": "info",
                    "icon": "🔄",
                    "text": f"Haven't done {', '.join(stale_names)} in 4+ weeks — consider rotating back in"
                })

    return insights


@router.get("/records")
async def get_personal_records(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    """Get personal records per exercise — heaviest weight, most reps, best estimated 1RM."""
    result = await db.execute(
        select(ExerciseSet, Exercise.display_name, Exercise.name, WorkoutSession.date)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .join(Exercise, ExerciseSet.exercise_id == Exercise.id)
        .where(WorkoutSession.user_id == user.id)
        .where(WorkoutSession.status == WorkoutStatus.COMPLETED)
        .where(ExerciseSet.actual_reps.isnot(None))
        .where(ExerciseSet.actual_weight_kg.isnot(None))
        .where(ExerciseSet.actual_weight_kg > 0)
        .where(ExerciseSet.set_type != 'warmup')
    )
    rows = result.all()

    # Group by exercise
    exercise_data: dict[int, dict] = {}
    for exercise_set, display_name, name, session_date in rows:
        eid = exercise_set.exercise_id
        w = exercise_set.actual_weight_kg or 0
        r = exercise_set.actual_reps or 0
        est_1rm = w * (1 + r / 30) if r > 0 and w > 0 else 0
        achieved_on = session_date.isoformat()

        if eid not in exercise_data:
            exercise_data[eid] = {
                "exercise_id": eid,
                "display_name": display_name,
                "name": name,
                "max_weight_kg": 0,
                "max_weight_date": None,
                "max_reps": 0,
                "max_reps_date": None,
                "best_1rm_kg": 0,
                "best_1rm_date": None,
                "best_set_weight_kg": 0,
                "best_set_reps": 0,
            }

        d = exercise_data[eid]
        if w > d["max_weight_kg"]:
            d["max_weight_kg"] = w
            d["max_weight_date"] = achieved_on
        if r > d["max_reps"]:
            d["max_reps"] = r
            d["max_reps_date"] = achieved_on
        if est_1rm > d["best_1rm_kg"]:
            d["best_1rm_kg"] = round(est_1rm, 1)
            d["best_1rm_date"] = achieved_on
            d["best_set_weight_kg"] = w
            d["best_set_reps"] = r

    records = sorted(exercise_data.values(), key=lambda x: x["best_1rm_kg"], reverse=True)
    return records


# ── Volume landmarks (MEV/MRV) ────────────────────────────────────────────

# Evidence-based volume landmarks per muscle group (sets per week)
# Based on RP/Israetel recommendations
VOLUME_LANDMARKS = {
    "chest":       {"mev": 8,  "mav": 14, "mrv": 20},
    "back":        {"mev": 8,  "mav": 14, "mrv": 22},
    "quads":       {"mev": 6,  "mav": 12, "mrv": 18},
    "hamstrings":  {"mev": 4,  "mav": 10, "mrv": 16},
    "glutes":      {"mev": 4,  "mav": 10, "mrv": 16},
    "shoulders":   {"mev": 6,  "mav": 14, "mrv": 20},
    "biceps":      {"mev": 4,  "mav": 10, "mrv": 18},
    "triceps":     {"mev": 4,  "mav": 10, "mrv": 16},
    "calves":      {"mev": 6,  "mav": 10, "mrv": 16},
    "abs":         {"mev": 0,  "mav": 8,  "mrv": 16},
    "traps":       {"mev": 0,  "mav": 8,  "mrv": 16},
    "forearms":    {"mev": 0,  "mav": 6,  "mrv": 12},
}


@router.get("/volume-landmarks")
async def get_volume_landmarks(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    days: int = Query(default=7, description="Look-back window in days"),
) -> dict:
    """Weekly sets per muscle group vs MEV/MAV/MRV landmarks."""
    cutoff = datetime.utcnow() - timedelta(days=days)

    # Get completed sets with exercise data
    result = await db.execute(
        select(ExerciseSet, Exercise)
        .join(Exercise, ExerciseSet.exercise_id == Exercise.id)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .where(
            WorkoutSession.user_id == user.id,
            WorkoutSession.started_at >= cutoff,
            ExerciseSet.completed_at.isnot(None),
            ExerciseSet.skipped_at.is_(None),
        )
    )
    rows = result.all()

    # Count sets per muscle group
    muscle_sets: dict[str, int] = {}
    for exercise_set, exercise in rows:
        muscles = exercise.primary_muscles or []
        for muscle in muscles:
            m = muscle.lower().strip()
            muscle_sets[m] = muscle_sets.get(m, 0) + 1

    # Build response with landmarks
    muscle_data = []
    # Include all muscles that have landmarks OR have sets logged
    all_muscles = set(VOLUME_LANDMARKS.keys()) | set(muscle_sets.keys())
    for muscle in sorted(all_muscles):
        landmarks = VOLUME_LANDMARKS.get(muscle, {"mev": 4, "mav": 10, "mrv": 16})
        sets = muscle_sets.get(muscle, 0)
        status = "below_mev"
        if sets == 0:
            status = "none"
        elif sets >= landmarks["mrv"]:
            status = "above_mrv"
        elif sets >= landmarks["mav"]:
            status = "above_mav"
        elif sets >= landmarks["mev"]:
            status = "in_range"

        muscle_data.append({
            "muscle": muscle,
            "sets": sets,
            "mev": landmarks["mev"],
            "mav": landmarks["mav"],
            "mrv": landmarks["mrv"],
            "status": status,
        })

    # Sort: muscles with sets first, then alphabetical
    muscle_data.sort(key=lambda x: (-x["sets"], x["muscle"]))

    return {
        "days": days,
        "muscles": muscle_data,
        "total_sets": sum(muscle_sets.values()),
    }


# ── Progressive Overload ───────────────────────────────────────────────────


class OverloadRequest(_PydanticBase):
    exercise_id: int
    current_weight: float
    current_reps: int
    target_reps: int | None = None
    weight_unit: str = "lbs"  # "lbs" or "kg"


@router.post("/overload")
async def get_overload_suggestion(
    body: OverloadRequest,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Calculate progressive overload suggestion for an exercise."""

    # Get exercise info
    ex_result = await db.execute(
        select(Exercise).where(Exercise.id == body.exercise_id)
    )
    exercise = ex_result.scalar_one_or_none()
    exercise_type = exercise.movement_type if exercise else "compound"

    # Get recent completed sets for this exercise (last 5 sessions)
    recent_sets_q = await db.execute(
        select(ExerciseSet)
        .join(WorkoutSession, ExerciseSet.workout_session_id == WorkoutSession.id)
        .where(
            WorkoutSession.user_id == user.id,
            WorkoutSession.status == "completed",
            ExerciseSet.exercise_id == body.exercise_id,
            ExerciseSet.completed_at.isnot(None),
        )
        .order_by(desc(ExerciseSet.completed_at))
        .limit(20)
    )
    recent_sets = recent_sets_q.scalars().all()

    # Conversion
    kg_to_unit = 2.20462 if body.weight_unit == "lbs" else 1.0
    weight_increment = 5.0 if body.weight_unit == "lbs" else 2.5

    # Determine baseline (oldest of recent sets)
    if recent_sets:
        oldest = recent_sets[-1]
        baseline_weight = (oldest.actual_weight_kg or 0) * kg_to_unit
        baseline_reps = oldest.actual_reps or 0
    else:
        baseline_weight = body.current_weight
        baseline_reps = body.current_reps

    # Calculate rolling e1RM trend
    e1rms = []
    for s in recent_sets:
        w = (s.actual_weight_kg or 0) * kg_to_unit
        r = s.actual_reps or 0
        if w > 0 and r > 0:
            e1rms.append(epley_1rm(w, r))

    rolling_trend = 0.0
    if len(e1rms) >= 3:
        # Average change between consecutive sessions
        changes = [e1rms[i] - e1rms[i + 1] for i in range(min(len(e1rms) - 1, 4))]
        rolling_trend = sum(changes) / len(changes) if changes else 0

    result = calculate_overload(OverloadInput(
        current_weight=body.current_weight,
        current_reps=body.current_reps,
        baseline_weight=baseline_weight,
        baseline_reps=baseline_reps,
        target_reps=body.target_reps,
        exercise_type=exercise_type,
        training_level=get_training_level(user),
        rolling_e1rm_trend=rolling_trend,
        weight_increment=weight_increment,
    ))

    return {
        "next_weight": result.next_weight,
        "next_reps": result.next_reps,
        "strategy": result.strategy,
        "confidence": result.confidence,
        "explanation": result.explanation,
        "estimated_1rm": round(result.estimated_1rm, 1),
        "projected_1rm": round(result.projected_1rm, 1),
    }
