"""Nutrition tracking API endpoints — food log, custom foods, goals, and search."""

from datetime import date, datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.food_search import lookup_barcode, search_foods
from app.database import get_db
from app.models.nutrition import FoodItem, MacroGoal, NutritionEntry
from app.schemas.requests import FoodItemCreate, MacroGoalsUpdate, NutritionEntryCreate

router = APIRouter()


# ── Serializers ───────────────────────────────────────────────────────────────

def serialize_food_item(item: FoodItem) -> dict:
    return {
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
    }


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
    }


def serialize_goal(goal: MacroGoal) -> dict:
    return {
        "id": goal.id,
        "calories": goal.calories,
        "protein": goal.protein,
        "carbs": goal.carbs,
        "fat": goal.fat,
        "effective_from": goal.effective_from.isoformat(),
    }


# ── Food search (proxy) ──────────────────────────────────────────────────────

@router.get("/search")
async def search(q: str = "", page: int = 1) -> list[dict]:
    """Search Open Food Facts + USDA for foods matching a query."""
    if not q.strip():
        return []
    return await search_foods(q.strip(), page=page)


@router.get("/barcode/{code}")
async def barcode_lookup(code: str) -> dict:
    """Look up a food by barcode (EAN/UPC)."""
    result = await lookup_barcode(code)
    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Barcode not found")
    return result


# ── Custom foods (CRUD) ──────────────────────────────────────────────────────

@router.get("/foods")
async def list_foods(
    db: Annotated[AsyncSession, Depends(get_db)],
    q: str = "",
    limit: int = 50,
) -> list[dict]:
    """List saved foods, optionally filtered by name substring."""
    stmt = select(FoodItem).order_by(desc(FoodItem.created_at)).limit(limit)
    if q.strip():
        stmt = stmt.where(FoodItem.name.ilike(f"%{q.strip()}%"))
    result = await db.execute(stmt)
    return [serialize_food_item(f) for f in result.scalars().all()]


@router.post("/foods", status_code=status.HTTP_201_CREATED)
async def create_food(
    data: FoodItemCreate,
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
    )
    db.add(food)
    await db.flush()
    await db.refresh(food)
    return serialize_food_item(food)


@router.delete("/foods/{food_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_food(
    food_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a saved food."""
    result = await db.execute(select(FoodItem).where(FoodItem.id == food_id))
    food = result.scalar_one_or_none()
    if not food:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Food not found")
    await db.delete(food)
    await db.flush()


# ── Nutrition entries (daily log) ─────────────────────────────────────────────

@router.get("/entries")
async def list_entries(
    db: Annotated[AsyncSession, Depends(get_db)],
    date: date = Query(default=None),
) -> dict:
    """Get nutrition entries for a date, grouped by meal with totals."""
    target_date = date or datetime.now(timezone.utc).date()
    result = await db.execute(
        select(NutritionEntry)
        .where(NutritionEntry.date == target_date)
        .order_by(NutritionEntry.logged_at)
    )
    entries = result.scalars().all()

    meals: dict[str, list[dict]] = {"breakfast": [], "lunch": [], "dinner": [], "snack": []}
    totals = {"calories": 0.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0}
    for e in entries:
        serialized = serialize_entry(e)
        meals.setdefault(e.meal, []).append(serialized)
        totals["calories"] += e.calories
        totals["protein"] += e.protein
        totals["carbs"] += e.carbs
        totals["fat"] += e.fat

    return {"date": target_date.isoformat(), "meals": meals, "totals": totals}


@router.post("/entries", status_code=status.HTTP_201_CREATED)
async def add_entry(
    data: NutritionEntryCreate,
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
    )
    db.add(entry)
    await db.flush()
    await db.refresh(entry)
    return serialize_entry(entry)


@router.delete("/entries/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_entry(
    entry_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a nutrition entry."""
    result = await db.execute(select(NutritionEntry).where(NutritionEntry.id == entry_id))
    entry = result.scalar_one_or_none()
    if not entry:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Entry not found")
    await db.delete(entry)
    await db.flush()


# ── Daily summary ─────────────────────────────────────────────────────────────

@router.get("/summary")
async def daily_summary(
    db: Annotated[AsyncSession, Depends(get_db)],
    date: date = Query(default=None),
) -> dict:
    """Get daily macro totals vs goals."""
    target_date = date or datetime.now(timezone.utc).date()

    # Totals
    result = await db.execute(
        select(
            func.coalesce(func.sum(NutritionEntry.calories), 0),
            func.coalesce(func.sum(NutritionEntry.protein), 0),
            func.coalesce(func.sum(NutritionEntry.carbs), 0),
            func.coalesce(func.sum(NutritionEntry.fat), 0),
        ).where(NutritionEntry.date == target_date)
    )
    row = result.one()
    totals = {"calories": row[0], "protein": row[1], "carbs": row[2], "fat": row[3]}

    # Goals (most recent effective_from <= target_date)
    goal_result = await db.execute(
        select(MacroGoal)
        .where(MacroGoal.effective_from <= target_date)
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

    return {"date": target_date.isoformat(), "totals": totals, "goals": goals, "remaining": remaining}


# ── Goals ─────────────────────────────────────────────────────────────────────

@router.get("/goals")
async def get_goals(
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict | None:
    """Get current active macro goals."""
    today = datetime.now(timezone.utc).date()
    result = await db.execute(
        select(MacroGoal)
        .where(MacroGoal.effective_from <= today)
        .order_by(desc(MacroGoal.effective_from))
        .limit(1)
    )
    goal = result.scalar_one_or_none()
    return serialize_goal(goal) if goal else None


@router.put("/goals")
async def set_goals(
    data: MacroGoalsUpdate,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Set or update daily macro goals (upserts on effective_from)."""
    effective = data.effective_from or datetime.now(timezone.utc).date()

    # Upsert: check if a goal already exists for this date
    result = await db.execute(
        select(MacroGoal).where(MacroGoal.effective_from == effective)
    )
    goal = result.scalar_one_or_none()

    if goal:
        goal.calories = data.calories
        goal.protein = data.protein
        goal.carbs = data.carbs
        goal.fat = data.fat
    else:
        goal = MacroGoal(
            calories=data.calories,
            protein=data.protein,
            carbs=data.carbs,
            fat=data.fat,
            effective_from=effective,
        )
        db.add(goal)

    await db.flush()
    await db.refresh(goal)
    return serialize_goal(goal)
