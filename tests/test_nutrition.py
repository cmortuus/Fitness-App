from datetime import datetime, timezone

import app.api.nutrition as nutrition_api
from app.api.nutrition import _search_match_score
from app.api.food_search import _relevance_score
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
        logged_at=datetime(2026, 3, 30, 8, 0),
    )
    entry_newer = NutritionEntry(
        user_id=1,
        name="Blueberries",
        date=datetime(2026, 3, 30).date(),
        meal="breakfast",
        quantity_g=100,
        calories=60,
        protein=1,
        carbs=14,
        fat=0,
        logged_at=datetime(2026, 3, 30, 8, 5),
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
    assert payload["calories_per_100g"] == 168
    assert payload["serving_size_g"] == 112
    assert payload["serving_label"] == "4 oz"


async def test_create_custom_food_aligns_calories_to_macros(client):
    response = await client.post("/api/nutrition/foods", json={
        "name": "Macro Match Bar",
        "calories_per_100g": 999,
        "protein_per_100g": 20,
        "carbs_per_100g": 30,
        "fat_per_100g": 10,
        "serving_size_g": 50,
        "serving_label": "1 bar",
    })
    assert response.status_code == 201, response.text

    payload = response.json()
    assert payload["calories_per_100g"] == 290


async def test_update_custom_food_recomputes_calories_from_macros(client, db):
    food = FoodItem(
        user_id=1,
        name="Protein Oats",
        source="custom",
        is_custom=True,
        calories_per_100g=999,
        protein_per_100g=10,
        carbs_per_100g=10,
        fat_per_100g=10,
        serving_size_g=100,
        serving_label="100g",
    )
    db.add(food)
    await db.commit()
    await db.refresh(food)

    response = await client.put(f"/api/nutrition/foods/{food.id}", json={
        "name": "Protein Oats",
        "brand": None,
        "barcode": None,
        "calories_per_100g": 10,
        "protein_per_100g": 25,
        "carbs_per_100g": 40,
        "fat_per_100g": 5,
        "serving_size_g": 100,
        "serving_label": "100g",
    })
    assert response.status_code == 200, response.text
    assert response.json()["calories_per_100g"] == 305


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


# ── Search relevance scoring unit tests ─────────────────────────────────────

class TestSearchMatchScore:
    def test_exact_match_scores_highest(self):
        assert _search_match_score("Bread", "bread") == 1000.0

    def test_prefix_beats_contains(self):
        # "Bread, White" starts with "bread" → should beat "Gluten Free Bread"
        prefix_score = _search_match_score("Bread, White", "bread")
        contains_score = _search_match_score("Gluten Free Bread", "bread")
        assert prefix_score > contains_score

    def test_exact_beats_prefix(self):
        exact = _search_match_score("Bread", "bread")
        prefix = _search_match_score("Breadcrumbs", "bread")
        assert exact > prefix

    def test_shorter_prefix_beats_longer_prefix(self):
        short = _search_match_score("Bread, White", "bread")
        long_ = _search_match_score("Bread, Whole Wheat, Multigrain, Sliced", "bread")
        assert short > long_

    def test_burger_patty_beats_burger_bun(self):
        # "Burger, Beef Patty" and "Hamburger Bun" for query "burger"
        burger = _search_match_score("Burger, Beef Patty", "burger")
        bun = _search_match_score("Hamburger Bun", "burger")
        # Both contain "burger" as a prefix/word; "Burger, Beef Patty" starts with burger
        assert burger >= bun


class TestExternalRelevanceScore:
    def test_exact_is_tier_0(self):
        tier, _ = _relevance_score("Bread", "bread")
        assert tier == 0

    def test_starts_with_is_tier_1(self):
        tier, _ = _relevance_score("Breadcrumbs, Plain", "bread")
        assert tier == 1

    def test_word_boundary_is_tier_2(self):
        tier, _ = _relevance_score("White Bread", "bread")
        assert tier == 2

    def test_gluten_free_bread_word_boundary(self):
        tier, _ = _relevance_score("Gluten Free Bread", "bread")
        assert tier == 2

    def test_cornbread_stuffing_is_tier_1(self):
        # starts with "bread"? No — "cornbread" starts with "corn", not "bread"
        tier, _ = _relevance_score("Cornbread Stuffing", "bread")
        # "bread" is in "cornbread" as substring but NOT as a whole word
        assert tier == 3

    def test_shorter_name_ranks_first_in_same_tier(self):
        _, len_short = _relevance_score("Burger, Beef", "burger")
        _, len_long = _relevance_score("Burger, Beef, Extra Lean, Organic, Grass-Fed", "burger")
        assert len_short < len_long


class TestSearchRelevanceIntegration:
    """API-level tests verifying search result ordering."""

    async def test_exact_match_is_first(self, client, db, monkeypatch):
        """Plain 'Bread' should appear before 'Gluten Free Bread'."""
        async def fake_search_foods(query, page=1, page_size=15):
            return []
        monkeypatch.setattr(nutrition_api, "search_foods", fake_search_foods)

        for name in ["Gluten Free Bread", "Bread", "Sourdough Bread", "Bread, White"]:
            db.add(FoodItem(
                name=name, source="common", is_custom=False,
                calories_per_100g=265, protein_per_100g=9,
                carbs_per_100g=49, fat_per_100g=3, serving_size_g=28,
            ))
        await db.commit()

        r = await client.get("/api/nutrition/search", params={"q": "bread"})
        assert r.status_code == 200
        names = [item["name"] for item in r.json()]
        assert names[0] == "Bread", f"Expected 'Bread' first, got: {names}"

    async def test_burger_patty_before_burger_bun(self, client, db, monkeypatch):
        """Searching 'burger' should put actual burger patty above burger bun."""
        async def fake_search_foods(query, page=1, page_size=15):
            return []
        monkeypatch.setattr(nutrition_api, "search_foods", fake_search_foods)

        for name in ["Hamburger Bun", "Burger, Beef Patty (cooked)", "Turkey Burger Patty"]:
            db.add(FoodItem(
                name=name, source="common", is_custom=False,
                calories_per_100g=265, protein_per_100g=20,
                carbs_per_100g=10, fat_per_100g=12, serving_size_g=85,
            ))
        await db.commit()

        r = await client.get("/api/nutrition/search", params={"q": "burger"})
        assert r.status_code == 200
        names = [item["name"] for item in r.json()]
        # Both "Burger, Beef Patty" and "Turkey Burger Patty" start with or contain burger as word
        # "Hamburger Bun" contains "hamburger" → "burger" is a substring only
        burger_idx = next(i for i, n in enumerate(names) if "Patty" in n)
        bun_idx = next(i for i, n in enumerate(names) if "Bun" in n)
        assert burger_idx < bun_idx, f"Expected burger patty before bun, got: {names}"

    async def test_custom_food_beats_same_relevance_import(self, client, db, monkeypatch):
        """Custom foods should still rank above imported foods at the same relevance tier."""
        async def fake_search_foods(query, page=1, page_size=15):
            return []
        monkeypatch.setattr(nutrition_api, "search_foods", fake_search_foods)

        db.add(FoodItem(
            name="Rice, White", source="common", is_custom=False,
            calories_per_100g=130, protein_per_100g=2.7, carbs_per_100g=28.6, fat_per_100g=0.3,
            serving_size_g=186,
        ))
        db.add(FoodItem(
            user_id=1, name="Rice, White", source="custom", is_custom=True,
            calories_per_100g=135, protein_per_100g=3.0, carbs_per_100g=29.0, fat_per_100g=0.4,
            serving_size_g=200,
        ))
        await db.commit()

        r = await client.get("/api/nutrition/search", params={"q": "rice"})
        assert r.status_code == 200
        results = r.json()
        # Should have both — custom first due to source bonus
        sources = [item["source"] for item in results]
        assert sources[0] == "custom"
