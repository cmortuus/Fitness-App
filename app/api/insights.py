"""Nutrition insights API — trends, adherence, and calorie balance."""

from datetime import datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.body_weight import BodyWeightEntry
from app.models.nutrition import MacroGoal, NutritionEntry, TDEEHistory
from app.models.user import User
from app.services.expenditure import compute_weight_trend

router = APIRouter()


@router.get("/trends")
async def nutrition_trends(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    period: int = Query(default=30, ge=7, le=365),
) -> dict:
    """Return daily nutrition data with rolling averages and weight trend."""
    today = datetime.utcnow().date()
    start = today - timedelta(days=period)

    # Daily intake totals
    intake_result = await db.execute(
        select(
            NutritionEntry.date,
            func.sum(NutritionEntry.calories).label("calories"),
            func.sum(NutritionEntry.protein).label("protein"),
            func.sum(NutritionEntry.carbs).label("carbs"),
            func.sum(NutritionEntry.fat).label("fat"),
        )
        .where(NutritionEntry.user_id == user.id, NutritionEntry.date >= start)
        .group_by(NutritionEntry.date)
        .order_by(NutritionEntry.date)
    )
    intake_rows = intake_result.all()
    intake_by_date = {
        row.date: {
            "date": row.date.isoformat(),
            "calories": round(row.calories or 0),
            "protein": round(row.protein or 0),
            "carbs": round(row.carbs or 0),
            "fat": round(row.fat or 0),
        }
        for row in intake_rows
    }

    # Weight data
    weight_result = await db.execute(
        select(BodyWeightEntry)
        .where(BodyWeightEntry.user_id == user.id, BodyWeightEntry.recorded_at >= datetime.combine(start, datetime.min.time()))
        .order_by(BodyWeightEntry.recorded_at)
    )
    weights = weight_result.scalars().all()
    weight_points = [{"date": w.recorded_at.date(), "weight_kg": w.weight_kg} for w in weights]
    smoothed = compute_weight_trend(weight_points) if weight_points else []
    weight_by_date = {s["date"]: s for s in smoothed}

    # Build daily array
    daily = []
    for i in range(period + 1):
        d = start + timedelta(days=i)
        entry = intake_by_date.get(d, {"date": d.isoformat(), "calories": 0, "protein": 0, "carbs": 0, "fat": 0})
        wt = weight_by_date.get(d)
        entry["weight_kg"] = wt["weight_kg"] if wt else None
        entry["weight_trend_kg"] = wt["trend_kg"] if wt else None
        daily.append(entry)

    # Rolling averages (7-day)
    logged_days = [d for d in daily if d["calories"] > 0]
    recent_7 = logged_days[-7:] if len(logged_days) >= 7 else logged_days
    n = max(len(recent_7), 1)
    rolling_7 = {
        "calories": round(sum(d["calories"] for d in recent_7) / n),
        "protein": round(sum(d["protein"] for d in recent_7) / n),
        "carbs": round(sum(d["carbs"] for d in recent_7) / n),
        "fat": round(sum(d["fat"] for d in recent_7) / n),
    }

    recent_14 = logged_days[-14:] if len(logged_days) >= 14 else logged_days
    n14 = max(len(recent_14), 1)
    rolling_14 = {
        "calories": round(sum(d["calories"] for d in recent_14) / n14),
        "protein": round(sum(d["protein"] for d in recent_14) / n14),
        "carbs": round(sum(d["carbs"] for d in recent_14) / n14),
        "fat": round(sum(d["fat"] for d in recent_14) / n14),
    }

    # TDEE history for expenditure overlay
    tdee_result = await db.execute(
        select(TDEEHistory)
        .where(TDEEHistory.user_id == user.id, TDEEHistory.date >= start)
        .order_by(TDEEHistory.date)
    )
    tdee_entries = tdee_result.scalars().all()
    expenditure = [
        {"date": t.date.isoformat(), "tdee": round(t.estimated_tdee), "confidence": t.confidence}
        for t in tdee_entries
    ]

    return {
        "period": period,
        "days_logged": len(logged_days),
        "daily": daily,
        "rolling_7_day": rolling_7,
        "rolling_14_day": rolling_14,
        "expenditure": expenditure,
    }


@router.get("/adherence")
async def nutrition_adherence(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    period: int = Query(default=30, ge=7, le=365),
) -> dict:
    """Return adherence stats: streak, % on target, calorie balance."""
    today = datetime.utcnow().date()
    start = today - timedelta(days=period)

    # Get current goals
    goal_result = await db.execute(
        select(MacroGoal)
        .where(MacroGoal.effective_from <= today, MacroGoal.user_id == user.id)
        .order_by(desc(MacroGoal.effective_from))
        .limit(1)
    )
    goal = goal_result.scalar_one_or_none()
    cal_target = goal.calories if goal else None

    # Daily intake
    intake_result = await db.execute(
        select(NutritionEntry.date, func.sum(NutritionEntry.calories).label("total"))
        .where(NutritionEntry.user_id == user.id, NutritionEntry.date >= start)
        .group_by(NutritionEntry.date)
        .order_by(NutritionEntry.date)
    )
    intake_by_date = {row.date: row.total for row in intake_result.all()}

    # Calculate streaks and adherence
    days_logged = 0
    days_on_target = 0
    current_streak = 0
    best_streak = 0

    for i in range(period, -1, -1):
        d = today - timedelta(days=i)
        intake = intake_by_date.get(d, 0)
        if intake > 0:
            days_logged += 1
            if cal_target and abs(intake - cal_target) / cal_target <= 0.10:
                days_on_target += 1

    # Current logging streak (consecutive days from today backward)
    for i in range(period + 1):
        d = today - timedelta(days=i)
        if intake_by_date.get(d, 0) > 0:
            current_streak += 1
        else:
            break

    # Best streak
    streak = 0
    for i in range(period + 1):
        d = start + timedelta(days=i)
        if intake_by_date.get(d, 0) > 0:
            streak += 1
            best_streak = max(best_streak, streak)
        else:
            streak = 0

    adherence_pct = round(days_on_target / max(days_logged, 1) * 100) if cal_target else None
    protein_target = goal.protein if goal else None

    # Protein adherence
    protein_days_on_target = 0
    if protein_target:
        protein_result = await db.execute(
            select(NutritionEntry.date, func.sum(NutritionEntry.protein).label("total"))
            .where(NutritionEntry.user_id == user.id, NutritionEntry.date >= start)
            .group_by(NutritionEntry.date)
        )
        for row in protein_result.all():
            if row.total and abs(row.total - protein_target) / protein_target <= 0.15:
                protein_days_on_target += 1

    return {
        "period": period,
        "days_logged": days_logged,
        "days_total": period,
        "logging_pct": round(days_logged / period * 100),
        "current_streak": current_streak,
        "best_streak": best_streak,
        "calorie_target": round(cal_target) if cal_target else None,
        "calorie_adherence_pct": adherence_pct,
        "protein_adherence_pct": round(protein_days_on_target / max(days_logged, 1) * 100) if protein_target else None,
    }
