"""Tests for the recipes API (CRUD + log as food entry)."""
import pytest
from httpx import AsyncClient


RECIPE_BASE = {
    "name": "Protein Oatmeal",
    "description": "Quick high-protein breakfast",
    "servings": 1.0,
    "ingredients": [
        {
            "name": "Oats",
            "quantity": 80.0,
            "unit": "g",
            "calories": 300.0,
            "protein": 10.0,
            "carbs": 54.0,
            "fat": 5.0,
        },
        {
            "name": "Protein Powder",
            "quantity": 30.0,
            "unit": "g",
            "calories": 120.0,
            "protein": 24.0,
            "carbs": 3.0,
            "fat": 1.5,
        },
    ],
}


# ── Helpers ────────────────────────────────────────────────────────────────────


async def create_recipe(client: AsyncClient, **overrides) -> dict:
    body = {**RECIPE_BASE, **overrides}
    r = await client.post("/api/recipes/", json=body)
    assert r.status_code == 201, r.text
    return r.json()


# ── Tests ─────────────────────────────────────────────────────────────────────


class TestRecipeCRUD:
    @pytest.mark.asyncio
    async def test_create_recipe(self, client: AsyncClient):
        r = await client.post("/api/recipes/", json=RECIPE_BASE)
        assert r.status_code == 201
        data = r.json()
        assert data["name"] == "Protein Oatmeal"
        assert data["servings"] == 1.0
        assert len(data["ingredients"]) == 2
        # Totals should be sum of ingredients
        assert data["total_calories"] == pytest.approx(420.0)
        assert data["total_protein"] == pytest.approx(34.0)
        assert data["total_carbs"] == pytest.approx(57.0)
        assert data["total_fat"] == pytest.approx(6.5)

    @pytest.mark.asyncio
    async def test_list_recipes(self, client: AsyncClient):
        await create_recipe(client, name="Recipe A")
        await create_recipe(client, name="Recipe B")
        r = await client.get("/api/recipes/")
        assert r.status_code == 200
        names = [item["name"] for item in r.json()]
        assert "Recipe A" in names
        assert "Recipe B" in names

    @pytest.mark.asyncio
    async def test_get_recipe(self, client: AsyncClient):
        recipe = await create_recipe(client)
        r = await client.get(f"/api/recipes/{recipe['id']}")
        assert r.status_code == 200
        assert r.json()["name"] == "Protein Oatmeal"
        assert len(r.json()["ingredients"]) == 2

    @pytest.mark.asyncio
    async def test_get_recipe_not_found(self, client: AsyncClient):
        r = await client.get("/api/recipes/99999")
        assert r.status_code == 404

    @pytest.mark.asyncio
    async def test_update_recipe(self, client: AsyncClient):
        recipe = await create_recipe(client)
        update = {
            "name": "Updated Oatmeal",
            "servings": 2.0,
            "ingredients": [
                {
                    "name": "Oats",
                    "quantity": 160.0,
                    "unit": "g",
                    "calories": 600.0,
                    "protein": 20.0,
                    "carbs": 108.0,
                    "fat": 10.0,
                }
            ],
        }
        r = await client.put(f"/api/recipes/{recipe['id']}", json=update)
        assert r.status_code == 200
        data = r.json()
        assert data["name"] == "Updated Oatmeal"
        assert data["servings"] == 2.0
        assert len(data["ingredients"]) == 1
        assert data["total_calories"] == pytest.approx(600.0)

    @pytest.mark.asyncio
    async def test_delete_recipe(self, client: AsyncClient):
        recipe = await create_recipe(client)
        r = await client.delete(f"/api/recipes/{recipe['id']}")
        assert r.status_code == 204
        # Confirm deletion
        r2 = await client.get(f"/api/recipes/{recipe['id']}")
        assert r2.status_code == 404

    @pytest.mark.asyncio
    async def test_cannot_access_other_users_recipe(self, client: AsyncClient, raw_client: AsyncClient):
        # Create recipe with test user
        recipe = await create_recipe(client)

        # Register second user
        r = await raw_client.post("/api/auth/register", json={
            "username": "user2", "email": "user2@test.com", "password": "pass123"
        })
        assert r.status_code == 201
        token2 = r.json()["access_token"]
        raw_client.headers["Authorization"] = f"Bearer {token2}"

        # Second user should get 404 for first user's recipe
        r2 = await raw_client.get(f"/api/recipes/{recipe['id']}")
        assert r2.status_code == 404

        # Delete also forbidden
        r3 = await raw_client.delete(f"/api/recipes/{recipe['id']}")
        assert r3.status_code == 404


class TestRecipeLog:
    @pytest.mark.asyncio
    async def test_log_recipe_full_serving(self, client: AsyncClient):
        recipe = await create_recipe(client)
        r = await client.post(f"/api/recipes/{recipe['id']}/log", json={
            "date": "2025-01-15",
            "servings": 1.0,
            "meal_type": "breakfast",
        })
        assert r.status_code == 201
        data = r.json()
        assert data["name"] == "Protein Oatmeal"
        assert data["calories"] == pytest.approx(420.0, rel=0.01)
        assert data["protein"] == pytest.approx(34.0, rel=0.01)

    @pytest.mark.asyncio
    async def test_log_recipe_half_serving(self, client: AsyncClient):
        recipe = await create_recipe(client)
        r = await client.post(f"/api/recipes/{recipe['id']}/log", json={
            "date": "2025-01-15",
            "servings": 0.5,
            "meal_type": "snack",
        })
        assert r.status_code == 201
        data = r.json()
        # Half serving should be half the macros
        assert data["calories"] == pytest.approx(210.0, rel=0.01)
        assert data["protein"] == pytest.approx(17.0, rel=0.01)

    @pytest.mark.asyncio
    async def test_log_recipe_double_serving(self, client: AsyncClient):
        recipe = await create_recipe(client)
        r = await client.post(f"/api/recipes/{recipe['id']}/log", json={
            "date": "2025-01-15",
            "servings": 2.0,
            "meal_type": "lunch",
        })
        assert r.status_code == 201
        data = r.json()
        assert data["calories"] == pytest.approx(840.0, rel=0.01)

    @pytest.mark.asyncio
    async def test_log_recipe_not_found(self, client: AsyncClient):
        r = await client.post("/api/recipes/99999/log", json={
            "date": "2025-01-15",
            "servings": 1.0,
            "meal_type": "dinner",
        })
        assert r.status_code == 404


class TestRecipeTotals:
    @pytest.mark.asyncio
    async def test_empty_ingredients(self, client: AsyncClient):
        r = await client.post("/api/recipes/", json={
            "name": "Empty Recipe",
            "servings": 1.0,
            "ingredients": [],
        })
        assert r.status_code == 201
        data = r.json()
        assert data["total_calories"] == pytest.approx(0.0)
        assert data["total_protein"] == pytest.approx(0.0)

    @pytest.mark.asyncio
    async def test_totals_recomputed_on_update(self, client: AsyncClient):
        recipe = await create_recipe(client)
        original_cals = recipe["total_calories"]

        # Add more ingredients via update
        r = await client.put(f"/api/recipes/{recipe['id']}", json={
            "name": recipe["name"],
            "servings": recipe["servings"],
            "ingredients": [
                *RECIPE_BASE["ingredients"],
                {
                    "name": "Milk",
                    "quantity": 200.0,
                    "unit": "ml",
                    "calories": 100.0,
                    "protein": 6.0,
                    "carbs": 9.0,
                    "fat": 3.5,
                },
            ],
        })
        assert r.status_code == 200
        new_cals = r.json()["total_calories"]
        assert new_cals == pytest.approx(original_cals + 100.0)
