from datetime import datetime, timezone

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
