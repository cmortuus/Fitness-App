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

    async def test_delete_plan_gone(self, client: AsyncClient):
        """Deleted plan is no longer retrievable."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"])
        await client.delete(f"/api/plans/{plan['id']}")

        r = await client.get(f"/api/plans/{plan['id']}")
        assert r.status_code == 404

    async def test_recent_exercises_empty(self, client: AsyncClient):
        """GET /plans/exercises/recent returns [] when no sets have been logged."""
        r = await client.get("/api/plans/exercises/recent")
        assert r.status_code == 200
        assert r.json() == []

    async def test_recent_exercises_returns_muscle_lists(self, client: AsyncClient):
        """GET /plans/exercises/recent returns primary_muscles as a list, not a string."""
        from tests.conftest import create_plan, start_session_from_plan, log_set

        ex = await create_exercise(
            client,
            name="squat",
            display_name="Squat",
            body_region="lower",
            primary_muscles=["quads", "glutes"],
            secondary_muscles=["hamstrings"],
        )
        plan = await create_plan(client, ex["id"])
        sess = await start_session_from_plan(client, plan["id"])

        # Log one set so this exercise shows up in recent
        set_id = sess["sets"][0]["id"]
        await log_set(client, sess["id"], set_id, 100.0, 8)

        r = await client.get("/api/plans/exercises/recent")
        assert r.status_code == 200
        exercises = r.json()
        assert len(exercises) >= 1
        found = next((e for e in exercises if e["id"] == ex["id"]), None)
        assert found is not None
        # primary_muscles must be a list, not a JSON string
        assert isinstance(found["primary_muscles"], list)
        assert "quads" in found["primary_muscles"]

    async def test_grouped_exercises_empty(self, client: AsyncClient):
        """GET /plans/exercises/grouped returns {} when no exercises exist."""
        r = await client.get("/api/plans/exercises/grouped")
        assert r.status_code == 200
        assert r.json() == {}

    async def test_grouped_exercises_structure(self, client: AsyncClient):
        """GET /plans/exercises/grouped returns dict keyed by muscle, values are lists."""
        await create_exercise(
            client,
            name="bench",
            display_name="Bench Press",
            primary_muscles=["chest"],
            secondary_muscles=["triceps"],
        )
        await create_exercise(
            client,
            name="squat",
            display_name="Squat",
            body_region="lower",
            primary_muscles=["quads"],
            secondary_muscles=["glutes"],
        )

        r = await client.get("/api/plans/exercises/grouped")
        assert r.status_code == 200
        data = r.json()
        assert isinstance(data, dict)
        assert "chest" in data
        assert "quads" in data
        # Each value must be a list of dicts with correct keys
        bench_list = data["chest"]
        assert isinstance(bench_list, list)
        assert bench_list[0]["display_name"] == "Bench Press"
        # primary_muscles inside each item must be a list
        assert isinstance(bench_list[0]["primary_muscles"], list)
