"""Nutrition tracking API endpoints — food log, custom foods, goals, and search."""

import json
from datetime import date, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.api.food_search import lookup_barcode, search_foods
from app.database import get_db
from app.models.body_weight import BodyWeightEntry
from app.models.nutrition import COMMUNITY_THRESHOLD, FoodItem, FoodSubmission, MacroGoal, NutritionEntry, TDEEHistory, WaterEntry
from app.models.user import User
from app.schemas.requests import FoodItemCreate, MacroGoalsUpdate, NutritionEntryCreate, NutritionEntryUpdate, WaterEntryCreate
from app.services.expenditure import compute_adaptive_tdee

router = APIRouter()


# ── Serializers ───────────────────────────────────────────────────────────────

def serialize_food_item(item: FoodItem, submission_count: int | None = None) -> dict:
    d = {
        "id": item.id,
        "name": item.name,
        "brand": item.brand,
        "barcode": item.barcode,
        "source": item.source,
        "source_id": item.source_id,
        "calories_per_100g": item.calories_per_100g,
        "protein_per_100g": item.protein_per_100g,
        "carbs_per_100g": item.carbs_per_100g,
        "fat_per_100g": item.fat_per_100g,
        "serving_size_g": item.serving_size_g,
        "serving_label": item.serving_label,
        "is_custom": item.is_custom,
        "micronutrients": json.loads(item.micronutrients) if item.micronutrients else None,
    }
    if submission_count is not None:
        d["submission_count"] = submission_count
    return d


def serialize_entry(entry: NutritionEntry) -> dict:
    return {
        "id": entry.id,
        "food_item_id": entry.food_item_id,
        "name": entry.name,
        "date": entry.date.isoformat(),
        "meal": entry.meal,
        "quantity_g": entry.quantity_g,
        "calories": entry.calories,
        "protein": entry.protein,
        "carbs": entry.carbs,
        "fat": entry.fat,
        "logged_at": entry.logged_at.isoformat(),
        "micronutrients": json.loads(entry.micronutrients) if entry.micronutrients else None,
    }


def serialize_goal(goal: MacroGoal) -> dict:
    return {
        "id": goal.id,
        "calories": goal.calories,
        "protein": goal.protein,
        "carbs": goal.carbs,
        "fat": goal.fat,
        "water_goal_ml": getattr(goal, "water_goal_ml", 2500.0),
        "effective_from": goal.effective_from.isoformat(),
        "micronutrient_goals": json.loads(goal.micronutrient_goals) if goal.micronutrient_goals else None,
    }


# ── Food search (proxy) ──────────────────────────────────────────────────────

@router.get("/search")
async def search(
    q: str = "",
    page: int = 1,
    user: Annotated[User, Depends(get_current_user)] = None,
    db: Annotated[AsyncSession, Depends(get_db)] = None,
) -> list[dict]:
    """Search local food DB first, then external APIs if needed."""
    if not q.strip():
        return []

    query = q.strip()
    results: list[dict] = []

    # Search local DB first (imported + community + custom foods)
    if db and user:
        local_result = await db.execute(
            select(FoodItem)
            .where(
                FoodItem.name.ilike(f"%{query}%"),
                (FoodItem.source != "pending") | (FoodItem.user_id == user.id),
            )
            .order_by(
                desc(FoodItem.source == "custom"),
                desc(FoodItem.source == "community"),
            )
            .limit(15)
        )
        local_foods = local_result.scalars().all()
        results.extend([serialize_food_item(f) for f in local_foods])

    # Only hit external APIs if local results are sparse
    if len(results) < 5:
        external = await search_foods(query, page=page)
        # Deduplicate against local results by name
        local_names = {r["name"].lower() for r in results}
        for item in external:
            if item["name"].lower() not in local_names:
                results.append(item)

    return results[:25]


@router.get("/barcode/{code}")
async def barcode_lookup(
    code: str,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Look up a food by barcode — checks local DB first (community > pending by this user), then external APIs."""
    local_result = await db.execute(
        select(FoodItem)
        .where(
            FoodItem.barcode == code,
            (FoodItem.source == "community")
            | (FoodItem.source == "custom")
            | ((FoodItem.source == "pending") & (FoodItem.user_id == user.id)),
        )
        .order_by(
            desc(FoodItem.source == "community"),
            desc(FoodItem.source == "custom"),
        )
        .limit(1)
    )
    local_food = local_result.scalar_one_or_none()
    if local_food:
        sc = None
        if local_food.source == "pending":
            cr = await db.execute(
                select(func.count()).select_from(FoodSubmission).where(FoodSubmission.food_item_id == local_food.id)
            )
            sc = cr.scalar_one()
        return serialize_food_item(local_food, submission_count=sc)

    # Fall back to external APIs
    result = await lookup_barcode(code)
    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Barcode not found")
    return result


# ── Custom foods (CRUD) ──────────────────────────────────────────────────────

@router.get("/foods")
async def list_foods(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    q: str = "",
    limit: int = 50,
) -> list[dict]:
    """List saved foods — includes custom foods and pending community submissions by this user."""
    own_ids = select(FoodItem.id).where(FoodItem.user_id == user.id)
    submitted_ids = select(FoodSubmission.food_item_id).where(FoodSubmission.user_id == user.id)
    stmt = (
        select(FoodItem)
        .where(FoodItem.id.in_(own_ids.union(submitted_ids)))
        .order_by(desc(FoodItem.created_at))
        .limit(limit)
    )
    if q.strip():
        stmt = stmt.where(FoodItem.name.ilike(f"%{q.strip()}%"))
    result = await db.execute(stmt)
    foods = result.scalars().all()

    # Enrich pending foods with submission counts
    pending_ids = [f.id for f in foods if f.source == "pending"]
    counts: dict[int, int] = {}
    if pending_ids:
        count_result = await db.execute(
            select(FoodSubmission.food_item_id, func.count())
            .where(FoodSubmission.food_item_id.in_(pending_ids))
            .group_by(FoodSubmission.food_item_id)
        )
        counts = dict(count_result.all())

    return [serialize_food_item(f, submission_count=counts.get(f.id)) for f in foods]


@router.post("/foods", status_code=status.HTTP_201_CREATED)
async def create_food(
    data: FoodItemCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Save a custom food to the library."""
    food = FoodItem(
        name=data.name,
        brand=data.brand,
        barcode=data.barcode,
        source="custom",
        calories_per_100g=data.calories_per_100g,
        protein_per_100g=data.protein_per_100g,
        carbs_per_100g=data.carbs_per_100g,
        fat_per_100g=data.fat_per_100g,
        serving_size_g=data.serving_size_g,
        serving_label=data.serving_label,
        is_custom=True,
        user_id=user.id,
        micronutrients=json.dumps(data.micronutrients) if data.micronutrients else None,
    )
    db.add(food)
    await db.flush()
    await db.refresh(food)
    return serialize_food_item(food)


@router.post("/foods/community", status_code=status.HTTP_201_CREATED)
async def create_community_food(
    data: FoodItemCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Submit a food to the shared community library.

    Foods enter a pending state and are promoted to community once
    COMMUNITY_THRESHOLD distinct users have submitted the same item
    (matched by barcode, or name+brand when no barcode). Macros are
    averaged across all submissions on promotion.
    """
    # 1. Already promoted to community?
    if data.barcode:
        result = await db.execute(
            select(FoodItem).where(FoodItem.barcode == data.barcode, FoodItem.source == "community")
        )
        promoted = result.scalar_one_or_none()
        if promoted:
            return serialize_food_item(promoted)

    # 2. Find existing pending food for same item
    pending: FoodItem | None = None
    if data.barcode:
        result = await db.execute(
            select(FoodItem).where(FoodItem.barcode == data.barcode, FoodItem.source == "pending")
        )
        pending = result.scalar_one_or_none()
    if pending is None:
        # Fallback: match by name + brand
        q = select(FoodItem).where(
            FoodItem.name == data.name,
            FoodItem.source == "pending",
        )
        if data.brand:
            q = q.where(FoodItem.brand == data.brand)
        result = await db.execute(q)
        pending = result.scalar_one_or_none()

    # 3. Create pending entry if none exists
    if pending is None:
        pending = FoodItem(
            name=data.name,
            brand=data.brand,
            barcode=data.barcode,
            source="pending",
            calories_per_100g=data.calories_per_100g,
            protein_per_100g=data.protein_per_100g,
            carbs_per_100g=data.carbs_per_100g,
            fat_per_100g=data.fat_per_100g,
            serving_size_g=data.serving_size_g,
            serving_label=data.serving_label,
            is_custom=False,
            user_id=user.id,
            micronutrients=json.dumps(data.micronutrients) if data.micronutrients else None,
        )
        db.add(pending)
        await db.flush()

    # 4. Record this user's submission (ignore duplicate)
    existing_sub = await db.execute(
        select(FoodSubmission).where(
            FoodSubmission.food_item_id == pending.id,
            FoodSubmission.user_id == user.id,
        )
    )
    if existing_sub.scalar_one_or_none() is None:
        db.add(FoodSubmission(
            food_item_id=pending.id,
            user_id=user.id,
            calories_per_100g=data.calories_per_100g,
            protein_per_100g=data.protein_per_100g,
            carbs_per_100g=data.carbs_per_100g,
            fat_per_100g=data.fat_per_100g,
        ))
        await db.flush()

    # 5. Count distinct submissions — promote if threshold reached
    count_result = await db.execute(
        select(func.count()).select_from(FoodSubmission).where(FoodSubmission.food_item_id == pending.id)
    )
    submission_count = count_result.scalar_one()

    if submission_count >= COMMUNITY_THRESHOLD:
        # Average macros across all submissions
        subs_result = await db.execute(
            select(FoodSubmission).where(FoodSubmission.food_item_id == pending.id)
        )
        subs = subs_result.scalars().all()

        def _avg(vals: list[float | None]) -> float | None:
            clean = [v for v in vals if v is not None]
            return sum(clean) / len(clean) if clean else None

        pending.source = "community"
        pending.user_id = None
        pending.calories_per_100g = _avg([s.calories_per_100g for s in subs])
        pending.protein_per_100g = _avg([s.protein_per_100g for s in subs])
        pending.carbs_per_100g = _avg([s.carbs_per_100g for s in subs])
        pending.fat_per_100g = _avg([s.fat_per_100g for s in subs])

    await db.flush()
    await db.refresh(pending)
    return serialize_food_item(pending, submission_count=submission_count)


@router.delete("/foods/{food_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_food(
    food_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a saved food."""
    result = await db.execute(select(FoodItem).where(FoodItem.id == food_id, FoodItem.user_id == user.id))
    food = result.scalar_one_or_none()
    if not food:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Food not found")
    await db.delete(food)
    await db.flush()


# ── Nutrition entries (daily log) ─────────────────────────────────────────────

@router.get("/entries")
async def list_entries(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    date: date = Query(default=None),
) -> dict:
    """Get nutrition entries for a date, grouped by meal with totals."""
    target_date = date or datetime.utcnow().date()
    result = await db.execute(
        select(NutritionEntry)
        .where(NutritionEntry.date == target_date, NutritionEntry.user_id == user.id)
        .order_by(NutritionEntry.logged_at)
    )
    entries = result.scalars().all()

    meals: dict[str, list[dict]] = {"breakfast": [], "lunch": [], "dinner": [], "snack": []}
    totals = {"calories": 0.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0}
    micro_totals: dict[str, float] = {}
    for e in entries:
        serialized = serialize_entry(e)
        meals.setdefault(e.meal, []).append(serialized)
        totals["calories"] += e.calories
        totals["protein"] += e.protein
        totals["carbs"] += e.carbs
        totals["fat"] += e.fat
        if e.micronutrients:
            micros = json.loads(e.micronutrients)
            for key, val in micros.items():
                micro_totals[key] = micro_totals.get(key, 0.0) + val

    return {"date": target_date.isoformat(), "meals": meals, "totals": totals, "micronutrient_totals": micro_totals or None}


@router.post("/entries", status_code=status.HTTP_201_CREATED)
async def add_entry(
    data: NutritionEntryCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Log a food entry."""
    entry = NutritionEntry(
        food_item_id=data.food_item_id,
        name=data.name,
        date=data.date,
        meal=data.meal.value,
        quantity_g=data.quantity_g,
        calories=data.calories,
        protein=data.protein,
        carbs=data.carbs,
        fat=data.fat,
        user_id=user.id,
        micronutrients=json.dumps(data.micronutrients) if data.micronutrients else None,
    )
    db.add(entry)
    await db.flush()
    await db.refresh(entry)
    return serialize_entry(entry)


@router.patch("/entries/{entry_id}")
async def update_entry(
    entry_id: int,
    data: NutritionEntryUpdate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Update a nutrition entry (quantity, macros, or meal)."""
    result = await db.execute(select(NutritionEntry).where(NutritionEntry.id == entry_id, NutritionEntry.user_id == user.id))
    entry = result.scalar_one_or_none()
    if not entry:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Entry not found")
    if data.quantity_g is not None:
        entry.quantity_g = data.quantity_g
    if data.calories is not None:
        entry.calories = data.calories
    if data.protein is not None:
        entry.protein = data.protein
    if data.carbs is not None:
        entry.carbs = data.carbs
    if data.fat is not None:
        entry.fat = data.fat
    if data.meal is not None:
        entry.meal = data.meal.value
    await db.flush()
    await db.refresh(entry)
    return serialize_entry(entry)


@router.delete("/entries/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_entry(
    entry_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a nutrition entry."""
    result = await db.execute(select(NutritionEntry).where(NutritionEntry.id == entry_id, NutritionEntry.user_id == user.id))
    entry = result.scalar_one_or_none()
    if not entry:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Entry not found")
    await db.delete(entry)
    await db.flush()


@router.get("/entries/recent")
async def recent_foods(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 20,
) -> list[dict]:
    """Return the user's most recently logged distinct foods."""
    result = await db.execute(
        select(NutritionEntry)
        .where(NutritionEntry.user_id == user.id)
        .order_by(desc(NutritionEntry.logged_at))
        .limit(limit * 3)  # fetch extra to deduplicate by name
    )
    entries = result.scalars().all()
    seen: set[str] = set()
    unique: list[dict] = []
    for e in entries:
        key = e.name.lower().strip()
        if key not in seen:
            seen.add(key)
            unique.append(serialize_entry(e))
        if len(unique) >= limit:
            break
    return unique


@router.get("/entries/frequent")
async def frequent_foods(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 20,
) -> list[dict]:
    """Return the user's most frequently logged foods."""
    count_result = await db.execute(
        select(NutritionEntry.name, func.count().label("times"), func.max(NutritionEntry.logged_at).label("last_logged"))
        .where(NutritionEntry.user_id == user.id)
        .group_by(NutritionEntry.name)
        .order_by(desc("times"))
        .limit(limit)
    )
    rows = count_result.all()
    if not rows:
        return []

    names = [r.name for r in rows]
    entry_result = await db.execute(
        select(NutritionEntry)
        .where(NutritionEntry.user_id == user.id, NutritionEntry.name.in_(names))
        .order_by(desc(NutritionEntry.logged_at))
    )
    all_entries = entry_result.scalars().all()
    latest: dict[str, NutritionEntry] = {}
    for e in all_entries:
        if e.name not in latest:
            latest[e.name] = e

    return [serialize_entry(latest[r.name]) for r in rows if r.name in latest]


@router.post("/entries/copy-day")
async def copy_day(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    from_date: date = Query(),
    to_date: date = Query(),
) -> dict:
    """Copy all entries from from_date to to_date."""
    result = await db.execute(
        select(NutritionEntry)
        .where(NutritionEntry.date == from_date, NutritionEntry.user_id == user.id)
    )
    source_entries = result.scalars().all()
    if not source_entries:
        return {"copied": 0}

    now = datetime.utcnow()
    for e in source_entries:
        new_entry = NutritionEntry(
            user_id=user.id,
            food_item_id=e.food_item_id,
            name=e.name,
            date=to_date,
            meal=e.meal,
            quantity_g=e.quantity_g,
            calories=e.calories,
            protein=e.protein,
            carbs=e.carbs,
            fat=e.fat,
            micronutrients=e.micronutrients,
            logged_at=now,
        )
        db.add(new_entry)
    await db.flush()
    return {"copied": len(source_entries)}


# ── Daily summary ─────────────────────────────────────────────────────────────

@router.get("/summary")
async def daily_summary(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    date: date = Query(default=None),
) -> dict:
    """Get daily macro totals vs goals."""
    target_date = date or datetime.utcnow().date()

    # Totals
    result = await db.execute(
        select(
            func.coalesce(func.sum(NutritionEntry.calories), 0),
            func.coalesce(func.sum(NutritionEntry.protein), 0),
            func.coalesce(func.sum(NutritionEntry.carbs), 0),
            func.coalesce(func.sum(NutritionEntry.fat), 0),
        ).where(NutritionEntry.date == target_date, NutritionEntry.user_id == user.id)
    )
    row = result.one()
    totals = {"calories": row[0], "protein": row[1], "carbs": row[2], "fat": row[3]}

    # Micronutrient totals (need to iterate entries since these are JSON)
    entry_result = await db.execute(
        select(NutritionEntry.micronutrients)
        .where(NutritionEntry.date == target_date, NutritionEntry.user_id == user.id)
    )
    micro_totals: dict[str, float] = {}
    for (micro_json,) in entry_result.all():
        if micro_json:
            micros = json.loads(micro_json)
            for key, val in micros.items():
                micro_totals[key] = micro_totals.get(key, 0.0) + val

    # Goals (most recent effective_from <= target_date)
    goal_result = await db.execute(
        select(MacroGoal)
        .where(MacroGoal.effective_from <= target_date, MacroGoal.user_id == user.id)
        .order_by(desc(MacroGoal.effective_from))
        .limit(1)
    )
    goal = goal_result.scalar_one_or_none()
    goals = serialize_goal(goal) if goal else None

    remaining = None
    if goal:
        remaining = {
            "calories": goal.calories - totals["calories"],
            "protein": goal.protein - totals["protein"],
            "carbs": goal.carbs - totals["carbs"],
            "fat": goal.fat - totals["fat"],
        }

    return {
        "date": target_date.isoformat(), "totals": totals, "goals": goals,
        "remaining": remaining, "micronutrient_totals": micro_totals or None,
    }


@router.get("/weekly-report")
async def weekly_report(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Aggregate last 7 days of nutrition, body weight, and workouts."""
    from app.models.body_weight import BodyWeightEntry
    from app.models.workout import WorkoutSession

    today = datetime.utcnow().date()
    week_ago = today - timedelta(days=7)

    # Daily nutrition totals for each of the last 7 days
    days = []
    for i in range(7):
        d = today - timedelta(days=6 - i)
        result = await db.execute(
            select(
                func.sum(NutritionEntry.calories).label("calories"),
                func.sum(NutritionEntry.protein).label("protein"),
                func.sum(NutritionEntry.carbs).label("carbs"),
                func.sum(NutritionEntry.fat).label("fat"),
            ).where(NutritionEntry.date == d, NutritionEntry.user_id == user.id)
        )
        row = result.one()
        days.append({
            "date": d.isoformat(),
            "calories": round(row.calories or 0),
            "protein": round(row.protein or 0),
            "carbs": round(row.carbs or 0),
            "fat": round(row.fat or 0),
        })

    # Weekly averages
    logged_days = [d for d in days if d["calories"] > 0]
    n = max(len(logged_days), 1)
    avg = {
        "calories": round(sum(d["calories"] for d in logged_days) / n),
        "protein": round(sum(d["protein"] for d in logged_days) / n),
        "carbs": round(sum(d["carbs"] for d in logged_days) / n),
        "fat": round(sum(d["fat"] for d in logged_days) / n),
    }

    # Body weight entries this week
    bw_result = await db.execute(
        select(BodyWeightEntry)
        .where(BodyWeightEntry.recorded_at >= datetime.combine(week_ago, datetime.min.time()))
        .where(BodyWeightEntry.user_id == user.id)
        .order_by(BodyWeightEntry.recorded_at)
    )
    bw_entries = bw_result.scalars().all()
    weight_data = [{
        "date": e.recorded_at.date().isoformat(),
        "weight_kg": e.weight_kg,
        "body_fat_pct": e.body_fat_pct,
        "lean_mass_kg": round(e.weight_kg * (1 - e.body_fat_pct / 100), 2) if e.body_fat_pct else None,
    } for e in bw_entries]

    # Weight change
    weight_change = None
    if len(bw_entries) >= 2:
        weight_change = round(bw_entries[-1].weight_kg - bw_entries[0].weight_kg, 2)

    # Workout count this week
    ws_result = await db.execute(
        select(func.count(WorkoutSession.id))
        .where(WorkoutSession.started_at >= datetime.combine(week_ago, datetime.min.time()))
        .where(WorkoutSession.completed_at.isnot(None))
        .where(WorkoutSession.user_id == user.id)
    )
    workout_count = ws_result.scalar() or 0

    # Current goals for comparison
    goal_result = await db.execute(
        select(MacroGoal).where(MacroGoal.effective_from <= today, MacroGoal.user_id == user.id).order_by(desc(MacroGoal.effective_from)).limit(1)
    )
    goal = goal_result.scalar_one_or_none()
    goals = {
        "calories": goal.calories, "protein": goal.protein,
        "carbs": goal.carbs, "fat": goal.fat,
    } if goal else None

    return {
        "period": {"start": week_ago.isoformat(), "end": today.isoformat()},
        "days": days,
        "averages": avg,
        "days_logged": len(logged_days),
        "goals": goals,
        "weight_data": weight_data,
        "weight_change_kg": weight_change,
        "workout_count": workout_count,
    }


# ── Goals ─────────────────────────────────────────────────────────────────────

@router.get("/goals")
async def get_goals(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict | None:
    """Get current active macro goals."""
    today = datetime.utcnow().date()
    result = await db.execute(
        select(MacroGoal)
        .where(MacroGoal.effective_from <= today, MacroGoal.user_id == user.id)
        .order_by(desc(MacroGoal.effective_from))
        .limit(1)
    )
    goal = result.scalar_one_or_none()
    return serialize_goal(goal) if goal else None


@router.put("/goals")
async def set_goals(
    data: MacroGoalsUpdate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Set or update daily macro goals (upserts on effective_from)."""
    effective = data.effective_from or datetime.utcnow().date()

    # Upsert: check if a goal already exists for this date
    result = await db.execute(
        select(MacroGoal).where(MacroGoal.effective_from == effective, MacroGoal.user_id == user.id)
    )
    goal = result.scalar_one_or_none()

    micro_goals_json = json.dumps(data.micronutrient_goals) if data.micronutrient_goals else None
    if goal:
        goal.calories = data.calories
        goal.protein = data.protein
        goal.carbs = data.carbs
        goal.fat = data.fat
        goal.micronutrient_goals = micro_goals_json
        if data.water_goal_ml is not None:
            goal.water_goal_ml = data.water_goal_ml
    else:
        goal = MacroGoal(
            calories=data.calories,
            protein=data.protein,
            carbs=data.carbs,
            fat=data.fat,
            water_goal_ml=data.water_goal_ml or 2500.0,
            effective_from=effective,
            user_id=user.id,
            micronutrient_goals=micro_goals_json,
        )
        db.add(goal)

    await db.flush()
    await db.refresh(goal)
    return serialize_goal(goal)


# ── Water tracking ────────────────────────────────────────────────────────────

@router.get("/water")
async def get_water(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    date: date = Query(default=None),
) -> dict:
    """Get water entries and total for a date."""
    target_date = date or datetime.utcnow().date()
    result = await db.execute(
        select(WaterEntry)
        .where(WaterEntry.date == target_date, WaterEntry.user_id == user.id)
        .order_by(WaterEntry.logged_at)
    )
    entries = result.scalars().all()
    total_ml = sum(e.amount_ml for e in entries)

    goal_result = await db.execute(
        select(MacroGoal)
        .where(MacroGoal.effective_from <= target_date, MacroGoal.user_id == user.id)
        .order_by(desc(MacroGoal.effective_from))
        .limit(1)
    )
    goal = goal_result.scalar_one_or_none()
    water_goal_ml = getattr(goal, "water_goal_ml", 2500.0) if goal else 2500.0

    return {
        "date": target_date.isoformat(),
        "total_ml": total_ml,
        "goal_ml": water_goal_ml,
        "entries": [{"id": e.id, "amount_ml": e.amount_ml, "logged_at": e.logged_at.isoformat()} for e in entries],
    }


@router.post("/water", status_code=status.HTTP_201_CREATED)
async def add_water(
    data: WaterEntryCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Log a water entry."""
    entry = WaterEntry(user_id=user.id, date=data.date, amount_ml=data.amount_ml)
    db.add(entry)
    await db.flush()
    await db.refresh(entry)
    return {"id": entry.id, "amount_ml": entry.amount_ml, "logged_at": entry.logged_at.isoformat()}


@router.delete("/water/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_water(
    entry_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a water entry."""
    result = await db.execute(select(WaterEntry).where(WaterEntry.id == entry_id, WaterEntry.user_id == user.id))
    entry = result.scalar_one_or_none()
    if not entry:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Water entry not found")
    await db.delete(entry)
    await db.flush()


# ── Expenditure (adaptive TDEE) ───────────────────────────────────────────────

@router.get("/expenditure")
async def get_expenditure(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    days: int = Query(default=90, ge=7, le=365),
) -> dict:
    """Return adaptive TDEE history and current estimate."""
    today = datetime.utcnow().date()
    start = today - timedelta(days=days)

    # Check for stored TDEE history
    tdee_result = await db.execute(
        select(TDEEHistory)
        .where(TDEEHistory.user_id == user.id, TDEEHistory.date >= start)
        .order_by(TDEEHistory.date)
    )
    history = tdee_result.scalars().all()

    # Compute current TDEE on the fly
    intake_result = await db.execute(
        select(NutritionEntry.date, func.sum(NutritionEntry.calories).label("total"))
        .where(NutritionEntry.user_id == user.id, NutritionEntry.date >= today - timedelta(days=28))
        .group_by(NutritionEntry.date)
    )
    intake_by_date = {row.date: row.total for row in intake_result.all()}

    weight_result = await db.execute(
        select(BodyWeightEntry)
        .where(BodyWeightEntry.user_id == user.id, BodyWeightEntry.recorded_at >= datetime.combine(today - timedelta(days=28), datetime.min.time()))
        .order_by(BodyWeightEntry.recorded_at)
    )
    weights = weight_result.scalars().all()

    daily_records = []
    for i in range(29):
        d = today - timedelta(days=28) + timedelta(days=i)
        daily_records.append({
            "date": d,
            "intake_calories": intake_by_date.get(d),
            "weight_kg": next((w.weight_kg for w in weights if w.recorded_at.date() == d), None),
        })

    current = compute_adaptive_tdee(daily_records)

    return {
        "current_tdee": current["estimated_tdee"],
        "confidence": current["confidence"],
        "method": current["method"],
        "weight_trend_kg": current["weight_trend_kg"],
        "history": [
            {
                "date": h.date.isoformat(),
                "estimated_tdee": round(h.estimated_tdee),
                "intake_calories": round(h.intake_calories) if h.intake_calories else None,
                "weight_trend_kg": h.weight_trend_kg,
                "confidence": h.confidence,
            }
            for h in history
        ],
    }
