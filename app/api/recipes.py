"""Recipe builder API endpoints — create, manage, and log multi-ingredient recipes."""

from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.api.auth import get_current_user
from app.database import get_db
from app.models.nutrition import NutritionEntry, Recipe, RecipeIngredient
from app.models.user import User

router = APIRouter()


# ── Request / response schemas ────────────────────────────────────────────────

class IngredientIn(BaseModel):
    name: str = Field(..., max_length=200)
    quantity: float = Field(default=1.0, gt=0)
    unit: str = Field(default="serving", max_length=50)
    calories: float = Field(default=0.0, ge=0)
    protein: float = Field(default=0.0, ge=0)
    carbs: float = Field(default=0.0, ge=0)
    fat: float = Field(default=0.0, ge=0)


class RecipeIn(BaseModel):
    name: str = Field(..., max_length=200)
    description: str | None = Field(default=None, max_length=500)
    servings: float = Field(default=1.0, gt=0)
    ingredients: list[IngredientIn] = Field(default_factory=list)


class RecipeLogIn(BaseModel):
    date: date
    servings: float = Field(default=1.0, gt=0)
    meal_type: str = Field(default="snack")


# ── Serializers ───────────────────────────────────────────────────────────────

def _serialize_ingredient(ing: RecipeIngredient) -> dict:
    return {
        "id": ing.id,
        "name": ing.name,
        "quantity": ing.quantity,
        "unit": ing.unit,
        "calories": ing.calories,
        "protein": ing.protein,
        "carbs": ing.carbs,
        "fat": ing.fat,
    }


def _serialize_recipe(recipe: Recipe, *, include_ingredients: bool = True) -> dict:
    out: dict = {
        "id": recipe.id,
        "name": recipe.name,
        "description": recipe.description,
        "servings": recipe.servings,
        "total_calories": recipe.total_calories,
        "total_protein": recipe.total_protein,
        "total_carbs": recipe.total_carbs,
        "total_fat": recipe.total_fat,
        "created_at": recipe.created_at.isoformat(),
    }
    if include_ingredients:
        out["ingredients"] = [_serialize_ingredient(i) for i in recipe.ingredients]
    return out


# ── Helpers ───────────────────────────────────────────────────────────────────

def _compute_totals(ingredients: list[IngredientIn]) -> tuple[float, float, float, float]:
    """Return (calories, protein, carbs, fat) summed across all ingredients."""
    calories = sum(i.calories for i in ingredients)
    protein = sum(i.protein for i in ingredients)
    carbs = sum(i.carbs for i in ingredients)
    fat = sum(i.fat for i in ingredients)
    return calories, protein, carbs, fat


async def _get_recipe_or_404(
    recipe_id: int, user_id: int, db: AsyncSession
) -> Recipe:
    result = await db.execute(
        select(Recipe)
        .where(Recipe.id == recipe_id, Recipe.user_id == user_id)
        .options(selectinload(Recipe.ingredients))
    )
    recipe = result.scalar_one_or_none()
    if recipe is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Recipe not found")
    return recipe


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get("/", response_model=list[dict])
async def list_recipes(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[dict]:
    """Return all recipes belonging to the current user (ingredients excluded for brevity)."""
    result = await db.execute(
        select(Recipe)
        .where(Recipe.user_id == user.id)
        .order_by(Recipe.created_at.desc())
    )
    recipes = result.scalars().all()
    return [_serialize_recipe(r, include_ingredients=False) for r in recipes]


@router.post("/", status_code=status.HTTP_201_CREATED)
async def create_recipe(
    data: RecipeIn,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a new recipe with its ingredients. Totals are auto-computed."""
    calories, protein, carbs, fat = _compute_totals(data.ingredients)

    recipe = Recipe(
        user_id=user.id,
        name=data.name,
        description=data.description,
        servings=data.servings,
        total_calories=calories,
        total_protein=protein,
        total_carbs=carbs,
        total_fat=fat,
    )
    db.add(recipe)
    await db.flush()  # obtain recipe.id before inserting children

    for ing_data in data.ingredients:
        ingredient = RecipeIngredient(
            recipe_id=recipe.id,
            name=ing_data.name,
            quantity=ing_data.quantity,
            unit=ing_data.unit,
            calories=ing_data.calories,
            protein=ing_data.protein,
            carbs=ing_data.carbs,
            fat=ing_data.fat,
        )
        db.add(ingredient)

    await db.flush()
    await db.refresh(recipe)
    # Reload with ingredients for the response
    result = await db.execute(
        select(Recipe)
        .where(Recipe.id == recipe.id)
        .options(selectinload(Recipe.ingredients))
    )
    recipe = result.scalar_one()
    return _serialize_recipe(recipe)


@router.get("/{recipe_id}")
async def get_recipe(
    recipe_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Return a single recipe with its full ingredient list."""
    recipe = await _get_recipe_or_404(recipe_id, user.id, db)
    return _serialize_recipe(recipe)


@router.put("/{recipe_id}")
async def update_recipe(
    recipe_id: int,
    data: RecipeIn,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Replace a recipe's metadata and ingredients entirely. Totals are recomputed."""
    recipe = await _get_recipe_or_404(recipe_id, user.id, db)

    # Update scalar fields
    recipe.name = data.name
    recipe.description = data.description
    recipe.servings = data.servings

    # Recompute totals
    calories, protein, carbs, fat = _compute_totals(data.ingredients)
    recipe.total_calories = calories
    recipe.total_protein = protein
    recipe.total_carbs = carbs
    recipe.total_fat = fat

    # Replace ingredient set (cascade delete-orphan handles removal)
    recipe.ingredients.clear()
    for ing_data in data.ingredients:
        recipe.ingredients.append(
            RecipeIngredient(
                recipe_id=recipe.id,
                name=ing_data.name,
                quantity=ing_data.quantity,
                unit=ing_data.unit,
                calories=ing_data.calories,
                protein=ing_data.protein,
                carbs=ing_data.carbs,
                fat=ing_data.fat,
            )
        )

    await db.flush()
    await db.refresh(recipe)
    result = await db.execute(
        select(Recipe)
        .where(Recipe.id == recipe.id)
        .options(selectinload(Recipe.ingredients))
    )
    recipe = result.scalar_one()
    return _serialize_recipe(recipe)


@router.delete("/{recipe_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_recipe(
    recipe_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a recipe and all its ingredients."""
    recipe = await _get_recipe_or_404(recipe_id, user.id, db)
    await db.delete(recipe)


@router.post("/{recipe_id}/log", status_code=status.HTTP_201_CREATED)
async def log_recipe(
    recipe_id: int,
    data: RecipeLogIn,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Log a recipe as a nutrition entry for a given date and serving count.

    Macros are scaled proportionally: (recipe total / recipe.servings) * requested servings.
    """
    recipe = await _get_recipe_or_404(recipe_id, user.id, db)

    # Scale by the ratio of requested servings to recipe's defined servings
    ratio = data.servings / recipe.servings if recipe.servings else data.servings

    entry = NutritionEntry(
        user_id=user.id,
        food_item_id=None,
        name=recipe.name,
        date=data.date,
        meal=data.meal_type,
        # quantity_g is not meaningful for recipes; store servings * 100 as a
        # conventional placeholder so the field remains non-null
        quantity_g=data.servings * 100,
        calories=round(recipe.total_calories * ratio, 2),
        protein=round(recipe.total_protein * ratio, 2),
        carbs=round(recipe.total_carbs * ratio, 2),
        fat=round(recipe.total_fat * ratio, 2),
        micronutrients=None,
    )
    db.add(entry)
    await db.flush()
    await db.refresh(entry)

    return {
        "id": entry.id,
        "name": entry.name,
        "date": entry.date.isoformat(),
        "meal": entry.meal,
        "servings": data.servings,
        "quantity_g": entry.quantity_g,
        "calories": entry.calories,
        "protein": entry.protein,
        "carbs": entry.carbs,
        "fat": entry.fat,
        "logged_at": entry.logged_at.isoformat(),
    }
