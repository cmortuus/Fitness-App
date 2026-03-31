from datetime import datetime, timezone

import app.api.nutrition as nutrition_api
from app.models.nutrition import FoodItem
from app.models.nutrition import NutritionEntry


async def test_list_entries_returns_newest_first(client, db):
    entry_older = NutritionEntry(
        user_id=1,
        name="Greek Yogurt",
        date=datetime(2026, 3, 30, tzinfo=timezone.utc).date(),
        meal="breakfast",
        quantity_g=200,
        calories=150,
        protein=20,
        carbs=8,
        fat=2,
        logged_at=datetime(2026, 3, 30, 8, 0, tzinfo=timezone.utc),
    )
    entry_newer = NutritionEntry(
        user_id=1,
        name="Blueberries",
        date=datetime(2026, 3, 30, tzinfo=timezone.utc).date(),
        meal="breakfast",
        quantity_g=100,
        calories=60,
        protein=1,
        carbs=14,
        fat=0,
        logged_at=datetime(2026, 3, 30, 8, 5, tzinfo=timezone.utc),
    )
    db.add_all([entry_older, entry_newer])
    await db.commit()

    response = await client.get("/api/nutrition/entries", params={"date": "2026-03-30"})
    assert response.status_code == 200, response.text

    breakfast = response.json()["meals"]["breakfast"]
    assert [entry["name"] for entry in breakfast] == ["Blueberries", "Greek Yogurt"]


async def test_update_custom_food(client, db):
    food = FoodItem(
        user_id=1,
        name="Chicken Breast",
        brand="Store Brand",
        source="custom",
        is_custom=True,
        calories_per_100g=165,
        protein_per_100g=31,
        carbs_per_100g=0,
        fat_per_100g=3.6,
        serving_size_g=100,
        serving_label="100g",
    )
    db.add(food)
    await db.commit()
    await db.refresh(food)

    response = await client.put(f"/api/nutrition/foods/{food.id}", json={
        "name": "Chicken Breast, Cooked",
        "brand": "Store Brand",
        "barcode": "123456789012",
        "calories_per_100g": 180,
        "protein_per_100g": 32,
        "carbs_per_100g": 1,
        "fat_per_100g": 4,
        "serving_size_g": 112,
        "serving_label": "4 oz",
    })
    assert response.status_code == 200, response.text

    payload = response.json()
    assert payload["name"] == "Chicken Breast, Cooked"
    assert payload["barcode"] == "123456789012"
    assert payload["calories_per_100g"] == 180
    assert payload["serving_size_g"] == 112
    assert payload["serving_label"] == "4 oz"


async def test_search_prioritizes_matching_recipes(client, db, monkeypatch):
    async def fake_search_foods(query: str, page: int = 1, page_size: int = 15):
        return []

    monkeypatch.setattr(nutrition_api, "search_foods", fake_search_foods)

    food = FoodItem(
        user_id=1,
        name="Chicken Rice Soup",
        source="custom",
        is_custom=True,
        calories_per_100g=90,
        protein_per_100g=6,
        carbs_per_100g=10,
        fat_per_100g=2,
        serving_size_g=240,
        serving_label="1 bowl",
    )
    db.add(food)
    await db.commit()

    recipe_response = await client.post("/api/recipes/", json={
        "name": "Chicken Rice Bowl",
        "description": "Easy prep lunch",
        "servings": 2.0,
        "ingredients": [
            {
                "name": "Chicken",
                "quantity": 200.0,
                "unit": "g",
                "calories": 330.0,
                "protein": 62.0,
                "carbs": 0.0,
                "fat": 7.0,
            },
            {
                "name": "Rice",
                "quantity": 300.0,
                "unit": "g",
                "calories": 390.0,
                "protein": 8.0,
                "carbs": 84.0,
                "fat": 1.0,
            },
        ],
    })
    assert recipe_response.status_code == 201, recipe_response.text

    response = await client.get("/api/nutrition/search", params={"q": "chicken rice"})
    assert response.status_code == 200, response.text

    payload = response.json()
    assert payload[0]["source"] == "recipe"
    assert payload[0]["name"] == "Chicken Rice Bowl"
    assert payload[0]["serving_label"] == "1 serving"
    assert payload[0]["calories_per_100g"] == 360
