from datetime import datetime, timezone

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
