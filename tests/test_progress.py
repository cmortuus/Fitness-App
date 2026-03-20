"""Tests for the progress tracking API."""
import pytest
from httpx import AsyncClient

from tests.conftest import create_exercise, create_plan, start_session_from_plan, log_set

pytestmark = pytest.mark.asyncio(loop_scope="function")


class TestProgressAPI:
    async def test_progress_empty(self, client: AsyncClient):
        """GET /progress/ with no completed sessions returns []."""
        r = await client.get("/api/progress/")
        assert r.status_code == 200
        assert r.json() == []

    async def test_progress_returns_per_session_rows(self, client: AsyncClient):
        """Complete 2 sessions, GET /progress/ returns 2 rows with correct dates."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)

        # Session 1
        sess1 = await start_session_from_plan(client, plan["id"])
        await log_set(client, sess1["id"], sess1["sets"][0]["id"], 100.0, 8)
        await client.post(f"/api/sessions/{sess1['id']}/complete")

        # Session 2
        sess2 = await start_session_from_plan(client, plan["id"])
        await log_set(client, sess2["id"], sess2["sets"][0]["id"], 102.5, 8)
        await client.post(f"/api/sessions/{sess2['id']}/complete")

        r = await client.get("/api/progress/")
        assert r.status_code == 200
        rows = r.json()
        assert len(rows) == 2
        # Each row should have a date field
        for row in rows:
            assert "date" in row
            assert "exercise_id" in row

    async def test_recommendations_empty(self, client: AsyncClient):
        """GET /progress/recommendations returns [] when no data."""
        r = await client.get("/api/progress/recommendations")
        assert r.status_code == 200
        assert r.json() == []

    async def test_recommendations_after_workout(self, client: AsyncClient):
        """Complete a session, recommendations returns non-empty list."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=2, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        for s in sess["sets"]:
            await log_set(client, sess["id"], s["id"], 100.0, 8)
        await client.post(f"/api/sessions/{sess['id']}/complete")

        r = await client.get("/api/progress/recommendations")
        assert r.status_code == 200
        data = r.json()
        assert len(data) > 0
        # Verify the structure of a recommendation
        rec = data[0]
        assert "exercise_id" in rec
        assert "exercise_name" in rec
        assert "current_weight" in rec
        assert "recommended_weight" in rec
        assert "reason" in rec
