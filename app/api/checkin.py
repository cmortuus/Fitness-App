"""Weekly nutrition check-in API — adaptive TDEE + macro coaching."""

from datetime import datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.body_weight import BodyWeightEntry
from app.models.nutrition import (
    DietPhase,
    MacroGoal,
    NutritionEntry,
    TDEEHistory,
    WeeklyCheckIn,
)
from app.models.user import User
from app.services.expenditure import (
    compute_adaptive_tdee,
    compute_checkin_recommendation,
    detect_rate_too_fast,
    detect_stall,
)

router = APIRouter()


def serialize_checkin(c: WeeklyCheckIn) -> dict:
    return {
        "id": c.id,
        "week_start": c.week_start.isoformat(),
        "weight_trend_kg": c.weight_trend_kg,
        "avg_intake": c.avg_intake,
        "tdee_estimate": c.tdee_estimate,
        "recommended_calories": c.recommended_calories,
        "recommended_protein": c.recommended_protein,
        "recommended_carbs": c.recommended_carbs,
        "recommended_fat": c.recommended_fat,
        "status": c.status,
        "stall_detected": c.stall_detected,
        "rate_too_fast": c.rate_too_fast,
        "notes": c.notes,
        "created_at": c.created_at.isoformat(),
    }


@router.post("/weekly-checkin")
async def create_weekly_checkin(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    apply: bool = Query(default=False),
) -> dict:
    """Compute weekly nutrition check-in with adaptive TDEE and recommendations."""
    today = datetime.utcnow().date()
    # Week starts on Monday
    week_start = today - timedelta(days=today.weekday())

    # Check if already exists for this week
    existing = await db.execute(
        select(WeeklyCheckIn).where(
            WeeklyCheckIn.user_id == user.id,
            WeeklyCheckIn.week_start == week_start,
        )
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=400, detail="Check-in already exists for this week")

    # Gather 28 days of data
    start_date = today - timedelta(days=28)

    # Intake data
    intake_result = await db.execute(
        select(NutritionEntry.date, func.sum(NutritionEntry.calories).label("total"))
        .where(NutritionEntry.user_id == user.id, NutritionEntry.date >= start_date)
        .group_by(NutritionEntry.date)
    )
    intake_by_date = {row.date: row.total for row in intake_result.all()}

    # Weight data
    weight_result = await db.execute(
        select(BodyWeightEntry)
        .where(BodyWeightEntry.user_id == user.id, BodyWeightEntry.recorded_at >= datetime.combine(start_date, datetime.min.time()))
        .order_by(BodyWeightEntry.recorded_at)
    )
    weight_entries = weight_result.scalars().all()

    # Build daily records
    daily_records = []
    for i in range(29):
        d = start_date + timedelta(days=i)
        daily_records.append({
            "date": d,
            "intake_calories": intake_by_date.get(d),
            "weight_kg": next((w.weight_kg for w in weight_entries if w.recorded_at.date() == d), None),
        })

    # Compute adaptive TDEE
    tdee_result = compute_adaptive_tdee(daily_records)

    # Get active phase for recommendations
    phase_result = await db.execute(
        select(DietPhase).where(DietPhase.user_id == user.id, DietPhase.is_active == True)  # noqa: E712
    )
    phase = phase_result.scalar_one_or_none()

    # Weekly weight changes for stall detection
    weekly_changes = []
    weight_dates = sorted([(w.recorded_at.date(), w.weight_kg) for w in weight_entries])
    for i in range(7, len(weight_dates), 7):
        weekly_changes.append(weight_dates[i][1] - weight_dates[max(0, i - 7)][1])

    current_weight = weight_entries[-1].weight_kg if weight_entries else 80.0

    stall = detect_stall(weekly_changes, phase.phase_type if phase else "maintenance", current_weight)
    rate_fast = False
    if phase and weekly_changes:
        actual_rate = (weekly_changes[-1] / current_weight) * 100 if current_weight > 0 else 0
        rate_fast = detect_rate_too_fast(actual_rate, phase.target_rate_pct)

    # Generate recommendations
    rec = {"calories": None, "protein": None, "carbs": None, "fat": None}
    notes = []
    if phase and tdee_result["method"] == "adaptive":
        rec = compute_checkin_recommendation(
            adaptive_tdee=tdee_result["estimated_tdee"],
            phase_type=phase.phase_type,
            target_rate_pct=phase.target_rate_pct,
            current_weight_kg=current_weight,
            protein_per_lb=phase.protein_per_lb or 1.0,
            carb_preset=phase.carb_preset or "moderate",
        )
        if stall:
            notes.append("Weight has stalled for 2+ weeks. Consider adjusting calories by 100-150 kcal.")
        if rate_fast:
            notes.append("Weight is changing faster than target. Consider moderating the deficit/surplus.")
    else:
        notes.append("Not enough data for adaptive recommendations. Keep logging for more accurate results.")

    # Save check-in
    checkin = WeeklyCheckIn(
        user_id=user.id,
        week_start=week_start,
        weight_trend_kg=tdee_result["weight_trend_kg"],
        avg_intake=tdee_result["avg_intake"],
        tdee_estimate=tdee_result["estimated_tdee"],
        recommended_calories=rec["calories"],
        recommended_protein=rec["protein"],
        recommended_carbs=rec["carbs"],
        recommended_fat=rec["fat"],
        status="applied" if apply else "pending",
        stall_detected=stall,
        rate_too_fast=rate_fast,
        notes=" ".join(notes) if notes else None,
    )
    db.add(checkin)

    # Persist TDEE snapshot
    tdee_entry = TDEEHistory(
        user_id=user.id,
        date=today,
        estimated_tdee=tdee_result["estimated_tdee"],
        intake_calories=tdee_result["avg_intake"],
        weight_trend_kg=tdee_result["weight_trend_kg"],
        confidence=tdee_result["confidence"],
        method=tdee_result["method"],
    )
    db.add(tdee_entry)

    # Apply recommendations if requested
    if apply and rec["calories"]:
        goal = MacroGoal(
            user_id=user.id,
            calories=rec["calories"],
            protein=rec["protein"],
            carbs=rec["carbs"],
            fat=rec["fat"],
            effective_from=today,
        )
        db.add(goal)

    await db.flush()
    await db.refresh(checkin)
    return serialize_checkin(checkin)


@router.get("/checkin-history")
async def checkin_history(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 12,
) -> list[dict]:
    """Return past weekly check-ins."""
    result = await db.execute(
        select(WeeklyCheckIn)
        .where(WeeklyCheckIn.user_id == user.id)
        .order_by(desc(WeeklyCheckIn.week_start))
        .limit(limit)
    )
    return [serialize_checkin(c) for c in result.scalars().all()]


@router.post("/weekly-checkin/{checkin_id}/apply")
async def apply_checkin(
    checkin_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Apply a check-in's recommended macros."""
    result = await db.execute(
        select(WeeklyCheckIn).where(WeeklyCheckIn.id == checkin_id, WeeklyCheckIn.user_id == user.id)
    )
    checkin = result.scalar_one_or_none()
    if not checkin:
        raise HTTPException(status_code=404, detail="Check-in not found")
    if checkin.status == "applied":
        raise HTTPException(status_code=400, detail="Already applied")

    checkin.status = "applied"
    if checkin.recommended_calories:
        goal = MacroGoal(
            user_id=user.id,
            calories=checkin.recommended_calories,
            protein=checkin.recommended_protein or 0,
            carbs=checkin.recommended_carbs or 0,
            fat=checkin.recommended_fat or 0,
            effective_from=datetime.utcnow().date(),
        )
        db.add(goal)

    await db.flush()
    await db.refresh(checkin)
    return serialize_checkin(checkin)


@router.post("/weekly-checkin/{checkin_id}/dismiss")
async def dismiss_checkin(
    checkin_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Dismiss a check-in without applying changes."""
    result = await db.execute(
        select(WeeklyCheckIn).where(WeeklyCheckIn.id == checkin_id, WeeklyCheckIn.user_id == user.id)
    )
    checkin = result.scalar_one_or_none()
    if not checkin:
        raise HTTPException(status_code=404, detail="Check-in not found")

    checkin.status = "dismissed"
    await db.flush()
    await db.refresh(checkin)
    return serialize_checkin(checkin)
