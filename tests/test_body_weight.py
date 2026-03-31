"""Tests for the body-weight weigh-in API."""
import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio(loop_scope="function")


class TestBodyWeightCRUD:
    async def test_list_empty(self, client: AsyncClient):
        """GET /body-weight/ returns [] when no entries exist."""
        r = await client.get("/api/body-weight/")
        assert r.status_code == 200
        assert r.json() == []

    async def test_add_entry(self, client: AsyncClient):
        """POST /body-weight/ creates a new weigh-in entry."""
        r = await client.post("/api/body-weight/", json={"weight_kg": 80.5})
        assert r.status_code == 201
        data = r.json()
        assert data["weight_kg"] == 80.5
        assert "id" in data
        assert "recorded_at" in data

    async def test_list_returns_newest_first(self, client: AsyncClient):
        """Multiple entries are returned newest-first."""
        await client.post("/api/body-weight/", json={"weight_kg": 80.0, "recorded_at": "2026-03-28T08:00:00"})
        await client.post("/api/body-weight/", json={"weight_kg": 81.0, "recorded_at": "2026-03-29T08:00:00"})
        await client.post("/api/body-weight/", json={"weight_kg": 82.0, "recorded_at": "2026-03-30T08:00:00"})

        r = await client.get("/api/body-weight/")
        assert r.status_code == 200
        entries = r.json()
        assert len(entries) == 3
        # Newest should be first (82 kg)
        assert entries[0]["weight_kg"] == 82.0

    async def test_add_with_notes(self, client: AsyncClient):
        """POST /body-weight/ stores optional notes."""
        r = await client.post(
            "/api/body-weight/",
            json={"weight_kg": 75.0, "notes": "morning weigh-in"},
        )
        assert r.status_code == 201
        assert r.json()["notes"] == "morning weigh-in"

    async def test_add_rejects_zero_weight(self, client: AsyncClient):
        """POST /body-weight/ with weight_kg=0 returns 422."""
        r = await client.post("/api/body-weight/", json={"weight_kg": 0})
        assert r.status_code == 422

    async def test_add_rejects_negative_weight(self, client: AsyncClient):
        """POST /body-weight/ with negative weight returns 422."""
        r = await client.post("/api/body-weight/", json={"weight_kg": -5})
        assert r.status_code == 422

    async def test_delete_entry(self, client: AsyncClient):
        """DELETE /body-weight/{id} removes the entry."""
        r = await client.post("/api/body-weight/", json={"weight_kg": 78.0})
        entry_id = r.json()["id"]

        rd = await client.delete(f"/api/body-weight/{entry_id}")
        assert rd.status_code == 204

        # Should be gone from the list
        r2 = await client.get("/api/body-weight/")
        assert all(e["id"] != entry_id for e in r2.json())

    async def test_delete_nonexistent(self, client: AsyncClient):
        """DELETE /body-weight/9999 returns 404."""
        r = await client.delete("/api/body-weight/9999")
        assert r.status_code == 404

    async def test_limit_parameter(self, client: AsyncClient):
        """GET /body-weight/?limit=2 returns at most 2 entries."""
        for i, w in enumerate([70.0, 71.0, 72.0, 73.0]):
            await client.post("/api/body-weight/", json={"weight_kg": w, "recorded_at": f"2026-03-{25+i}T08:00:00"})

        r = await client.get("/api/body-weight/", params={"limit": 2})
        assert r.status_code == 200
        assert len(r.json()) == 2

    async def test_latest_endpoint(self, client: AsyncClient):
        """GET /body-weight/latest returns the most recent entry."""
        await client.post("/api/body-weight/", json={"weight_kg": 80.0})
        await client.post("/api/body-weight/", json={"weight_kg": 81.0})

        r = await client.get("/api/body-weight/latest")
        assert r.status_code == 200
        assert r.json()["weight_kg"] == 81.0

    async def test_latest_empty(self, client: AsyncClient):
        """GET /body-weight/latest with no entries returns 404."""
        r = await client.get("/api/body-weight/latest")
        assert r.status_code == 404
