"""Tests for community food verification flow."""
import contextlib
import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app


FOOD_DATA = {
    "name": "Test Protein Bar",
    "brand": "TestBrand",
    "barcode": "1234567890123",
    "calories_per_100g": 400,
    "protein_per_100g": 30,
    "carbs_per_100g": 40,
    "fat_per_100g": 15,
    "serving_size_g": 60,
}


@contextlib.contextmanager
def override_threshold(n: int):
    import app.api.nutrition as api_mod
    old = api_mod.COMMUNITY_THRESHOLD
    api_mod.COMMUNITY_THRESHOLD = n
    try:
        yield
    finally:
        api_mod.COMMUNITY_THRESHOLD = old


async def make_authed_client(username: str) -> AsyncClient:
    c = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
    r = await c.post("/api/auth/register", json={
        "username": username,
        "email": f"{username}@test.com",
        "password": "testpass123",
    })
    assert r.status_code == 201
    c.headers["Authorization"] = f"Bearer {r.json()['access_token']}"
    return c


@pytest.mark.asyncio
async def test_community_submission_returns_pending(client: AsyncClient):
    with override_threshold(3):
        r = await client.post("/api/nutrition/foods/community", json=FOOD_DATA)
        assert r.status_code == 201
        data = r.json()
        assert data["source"] == "pending"
        assert data["submission_count"] == 1


@pytest.mark.asyncio
async def test_pending_food_visible_in_user_library(client: AsyncClient):
    with override_threshold(3):
        await client.post("/api/nutrition/foods/community", json=FOOD_DATA)
        r = await client.get("/api/nutrition/foods")
        assert r.status_code == 200
        foods = r.json()
        names = [f["name"] for f in foods]
        assert "Test Protein Bar" in names
        pending = [f for f in foods if f["name"] == "Test Protein Bar"][0]
        assert pending["source"] == "pending"
        assert pending["submission_count"] == 1


@pytest.mark.asyncio
async def test_multi_user_promotion(client: AsyncClient):
    with override_threshold(2):
        r1 = await client.post("/api/nutrition/foods/community", json=FOOD_DATA)
        assert r1.json()["source"] == "pending"

        client2 = await make_authed_client("user2")
        try:
            food2 = {**FOOD_DATA, "calories_per_100g": 420, "protein_per_100g": 32}
            r2 = await client2.post("/api/nutrition/foods/community", json=food2)
            assert r2.status_code == 201
            data = r2.json()
            assert data["source"] == "community"
            assert data["calories_per_100g"] == 419.0
            assert data["protein_per_100g"] == 31.0
        finally:
            await client2.aclose()


@pytest.mark.asyncio
async def test_barcode_returns_pending_for_submitter(client: AsyncClient):
    with override_threshold(3):
        await client.post("/api/nutrition/foods/community", json=FOOD_DATA)
        r = await client.get(f"/api/nutrition/barcode/{FOOD_DATA['barcode']}")
        assert r.status_code == 200
        assert r.json()["source"] == "pending"
        assert r.json()["submission_count"] == 1


@pytest.mark.asyncio
async def test_promoted_food_still_in_submitter_library(client: AsyncClient):
    with override_threshold(1):
        r = await client.post("/api/nutrition/foods/community", json=FOOD_DATA)
        assert r.json()["source"] == "community"

        r2 = await client.get("/api/nutrition/foods")
        names = [f["name"] for f in r2.json()]
        assert "Test Protein Bar" in names
