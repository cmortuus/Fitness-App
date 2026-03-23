"""Diet phase API — create/manage cut/bulk/maintenance phases with auto-calculated macros."""

from datetime import date, datetime, timedelta, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.body_weight import BodyWeightEntry
from app.models.nutrition import DietPhase, MacroGoal
from app.models.user import User
from app.schemas.requests import DietPhaseCreate
from app.services.diet_phase import (
    calculate_macros,
    target_end_weight,
    weekly_adjustment,
    weight_trend,
)

router = APIRouter()


# ── Helpers ───────────────────────────────────────────────────────────────────

def serialize_phase(phase: DietPhase, extra: dict | None = None) -> dict:
    data = {
        "id": phase.id,
        "phase_type": phase.phase_type,
        "started_on": phase.started_on.isoformat(),
        "duration_weeks": phase.duration_weeks,
        "starting_weight_kg": phase.starting_weight_kg,
        "target_rate_pct": phase.target_rate_pct,
        "activity_multiplier": phase.activity_multiplier,
        "tdee_override": phase.tdee_override,
        "carb_preset": phase.carb_preset,
        "body_fat_pct": phase.body_fat_pct,
        "protein_per_lb": phase.protein_per_lb,
        "is_active": phase.is_active,
        "ended_on": phase.ended_on.isoformat() if phase.ended_on else None,
    }
    if extra:
        data.update(extra)
    return data


async def _get_weight_entries(db: AsyncSession, user_id: int, days: int = 14) -> list[BodyWeightEntry]:
    """Fetch recent body weight entries."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    result = await db.execute(
        select(BodyWeightEntry)
        .where(BodyWeightEntry.recorded_at >= cutoff, BodyWeightEntry.user_id == user_id)
        .order_by(desc(BodyWeightEntry.recorded_at))
    )
    return list(result.scalars().all())


async def _build_phase_status(phase: DietPhase, db: AsyncSession, user_id: int) -> dict:
    """Build the full status response for a phase."""
    today = datetime.now(timezone.utc).date()
    days_in = (today - phase.started_on).days
    current_week = min(max(1, days_in // 7 + 1), phase.duration_weeks)
    weeks_remaining = max(0, phase.duration_weeks - current_week)

    # Weight data
    entries = await _get_weight_entries(db, user_id=user_id, days=21)
    current_avg = weight_trend(entries, window=7)

    # Split entries into this week and last week for adjustment calc
    week_ago = today - timedelta(days=7)
    this_week = [e for e in entries if e.recorded_at.date() >= week_ago]
    last_week = [e for e in entries if e.recorded_at.date() < week_ago]
    this_avg = weight_trend(this_week, window=7) if this_week else None
    last_avg = weight_trend(last_week, window=7) if last_week else None

    adjustment = weekly_adjustment(this_avg, last_avg, phase.phase_type, phase.target_rate_pct)

    # Current macros
    macros = calculate_macros(
        weight_kg=current_avg or phase.starting_weight_kg,
        phase_type=phase.phase_type,
        target_rate_pct=phase.target_rate_pct,
        activity_multiplier=phase.activity_multiplier,
        tdee_override=phase.tdee_override,
        carb_preset=phase.carb_preset,
        body_fat_pct=phase.body_fat_pct,
        protein_per_lb=phase.protein_per_lb,
    )

    target_wt = target_end_weight(
        phase.starting_weight_kg, phase.phase_type,
        phase.target_rate_pct, phase.duration_weeks,
    )

    weight_change = round((current_avg or phase.starting_weight_kg) - phase.starting_weight_kg, 2)

    return serialize_phase(phase, {
        "current_week": current_week,
        "weeks_remaining": weeks_remaining,
        "current_weight_kg": current_avg,
        "target_weight_kg": target_wt,
        "weight_change_kg": weight_change,
        "actual_rate_pct": adjustment["actual_rate_pct"],
        "status": adjustment["status"],
        "suggestion": adjustment["suggestion"],
        "current_goals": {k: macros[k] for k in ("calories", "protein", "carbs", "fat")},
        "tdee_estimate": macros["tdee_estimate"],
    })


async def _upsert_goal(db: AsyncSession, macros: dict, effective: date, user_id: int) -> None:
    """Create or update a MacroGoal for the given date."""
    result = await db.execute(
        select(MacroGoal).where(MacroGoal.effective_from == effective, MacroGoal.user_id == user_id)
    )
    goal = result.scalar_one_or_none()
    if goal:
        goal.calories = macros["calories"]
        goal.protein = macros["protein"]
        goal.carbs = macros["carbs"]
        goal.fat = macros["fat"]
    else:
        db.add(MacroGoal(
            calories=macros["calories"],
            protein=macros["protein"],
            carbs=macros["carbs"],
            fat=macros["fat"],
            effective_from=effective,
            user_id=user_id,
        ))
    await db.flush()


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/", status_code=status.HTTP_201_CREATED)
async def create_phase(
    data: DietPhaseCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Start a new diet phase. Deactivates any existing active phase."""
    today = datetime.now(timezone.utc).date()

    # Get starting weight
    bw_result = await db.execute(
        select(BodyWeightEntry).where(BodyWeightEntry.user_id == user.id).order_by(desc(BodyWeightEntry.recorded_at)).limit(1)
    )
    latest_bw = bw_result.scalar_one_or_none()
    if not latest_bw:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Log a body weight first before starting a diet phase.",
        )

    # Deactivate any existing active phase
    active_result = await db.execute(
        select(DietPhase).where(DietPhase.is_active == True, DietPhase.user_id == user.id)
    )
    for p in active_result.scalars().all():
        p.is_active = False
        p.ended_on = today

    # Create phase
    phase = DietPhase(
        phase_type=data.phase_type.value,
        started_on=today,
        duration_weeks=data.duration_weeks,
        starting_weight_kg=latest_bw.weight_kg,
        target_rate_pct=data.target_rate_pct,
        activity_multiplier=data.activity_multiplier,
        tdee_override=data.tdee_override,
        carb_preset=data.carb_preset.value,
        body_fat_pct=data.body_fat_pct,
        protein_per_lb=data.protein_per_lb,
        is_active=True,
        user_id=user.id,
    )
    db.add(phase)
    await db.flush()

    # Calculate and save initial macro goals
    macros = calculate_macros(
        weight_kg=latest_bw.weight_kg,
        phase_type=data.phase_type.value,
        target_rate_pct=data.target_rate_pct,
        activity_multiplier=data.activity_multiplier,
        tdee_override=data.tdee_override,
        carb_preset=data.carb_preset.value,
        body_fat_pct=data.body_fat_pct,
        protein_per_lb=data.protein_per_lb,
    )
    await _upsert_goal(db, macros, today, user_id=user.id)

    return await _build_phase_status(phase, db, user_id=user.id)


@router.get("/active")
async def get_active_phase(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict | None:
    """Get the active diet phase with current status."""
    result = await db.execute(
        select(DietPhase).where(DietPhase.is_active == True, DietPhase.user_id == user.id)
    )
    phase = result.scalar_one_or_none()
    if not phase:
        return None
    return await _build_phase_status(phase, db, user_id=user.id)


@router.get("/")
async def list_phases(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    """List all phases (history)."""
    result = await db.execute(
        select(DietPhase).where(DietPhase.user_id == user.id).order_by(desc(DietPhase.started_on))
    )
    return [serialize_phase(p) for p in result.scalars().all()]


@router.post("/active/recalculate")
async def recalculate_phase(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    apply: bool = False,
) -> dict:
    """Recalculate weekly targets based on current weight trend."""
    result = await db.execute(
        select(DietPhase).where(DietPhase.is_active == True, DietPhase.user_id == user.id)
    )
    phase = result.scalar_one_or_none()
    if not phase:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No active phase")

    status_data = await _build_phase_status(phase, db, user_id=user.id)

    if apply and status_data.get("current_weight_kg"):
        # Recalculate macros based on current weight
        macros = calculate_macros(
            weight_kg=status_data["current_weight_kg"],
            phase_type=phase.phase_type,
            target_rate_pct=phase.target_rate_pct,
            activity_multiplier=phase.activity_multiplier,
            tdee_override=phase.tdee_override,
            carb_preset=phase.carb_preset,
            body_fat_pct=phase.body_fat_pct,
            protein_per_lb=phase.protein_per_lb,
        )
        # Apply calorie adjustment if suggested
        cal_adj = status_data.get("cal_adjustment", 0)
        if cal_adj:
            macros["calories"] = max(1200, macros["calories"] + cal_adj)

        today = datetime.now(timezone.utc).date()
        await _upsert_goal(db, macros, today, user_id=user.id)
        status_data["current_goals"] = {k: macros[k] for k in ("calories", "protein", "carbs", "fat")}

    return status_data


@router.delete("/active", status_code=status.HTTP_204_NO_CONTENT)
async def end_phase(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """End the active phase."""
    result = await db.execute(
        select(DietPhase).where(DietPhase.is_active == True, DietPhase.user_id == user.id)
    )
    phase = result.scalar_one_or_none()
    if not phase:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No active phase")
    phase.is_active = False
    phase.ended_on = datetime.now(timezone.utc).date()
    await db.flush()
