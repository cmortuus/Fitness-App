"""Tests for the workout plans CRUD API."""
import pytest
from httpx import AsyncClient

from tests.conftest import create_exercise, create_plan

pytestmark = pytest.mark.asyncio(loop_scope="function")


class TestPlansCRUD:
    async def test_create_plan(self, client: AsyncClient):
        """POST /plans/ creates plan, returns 201."""
        ex = await create_exercise(client)
        r = await client.post(
            "/api/plans/",
            json={
                "name": "Push Pull Legs",
                "block_type": "hypertrophy",
                "duration_weeks": 8,
                "number_of_days": 1,
                "days": [
                    {
                        "day_number": 1,
                        "day_name": "Day 1",
                        "exercises": [
                            {
                                "exercise_id": ex["id"],
                                "sets": 3,
                                "reps": 8,
                                "starting_weight_kg": 0,
                                "progression_type": "linear",
                            }
                        ],
                    }
                ],
            },
        )
        assert r.status_code == 201
        data = r.json()
        assert data["name"] == "Push Pull Legs"
        assert data["block_type"] == "hypertrophy"
        assert data["duration_weeks"] == 8
        assert "id" in data

    async def test_create_plan_invalid_exercise_id(self, client: AsyncClient):
        """exercise_id that doesn't exist returns 422."""
        r = await client.post(
            "/api/plans/",
            json={
                "name": "Bad Plan",
                "block_type": "hypertrophy",
                "duration_weeks": 4,
                "number_of_days": 1,
                "days": [
                    {
                        "day_number": 1,
                        "day_name": "Day 1",
                        "exercises": [
                            {
                                "exercise_id": 99999,
                                "sets": 3,
                                "reps": 8,
                                "starting_weight_kg": 0,
                                "progression_type": "linear",
                            }
                        ],
                    }
                ],
            },
        )
        assert r.status_code == 422

    async def test_list_plans(self, client: AsyncClient):
        """GET /plans/ returns created plans."""
        ex = await create_exercise(client)
        plan1 = await create_plan(client, ex["id"], name="Plan Alpha")
        plan2 = await create_plan(client, ex["id"], name="Plan Beta")

        r = await client.get("/api/plans/")
        assert r.status_code == 200
        plans = r.json()
        plan_ids = {p["id"] for p in plans}
        assert plan1["id"] in plan_ids
        assert plan2["id"] in plan_ids

    async def test_archive_plan(self, client: AsyncClient):
        """POST /plans/{id}/archive sets is_archived=True."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"])

        r = await client.post(f"/api/plans/{plan['id']}/archive")
        assert r.status_code == 200
        data = r.json()
        assert data["is_archived"] is True

    async def test_reuse_plan(self, client: AsyncClient):
        """POST /plans/{id}/reuse creates new unarchived copy."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], name="Original Plan")

        # Archive first
        await client.post(f"/api/plans/{plan['id']}/archive")

        # Reuse it
        r = await client.post(f"/api/plans/{plan['id']}/reuse")
        assert r.status_code == 201
        data = r.json()
        assert data["is_archived"] is False
        assert data["name"] == "Original Plan"
        assert data["id"] != plan["id"]

    async def test_delete_plan(self, client: AsyncClient):
        """DELETE /plans/{id} returns 204."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"])

        r = await client.delete(f"/api/plans/{plan['id']}")
        assert r.status_code == 204
