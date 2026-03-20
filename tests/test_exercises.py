"""Tests for the exercises CRUD API."""
import pytest
from httpx import AsyncClient

from tests.conftest import create_exercise, create_plan, start_session_from_plan, log_set

pytestmark = pytest.mark.asyncio(loop_scope="function")


class TestExercisesCRUD:
    async def test_list_exercises_empty(self, client: AsyncClient):
        """GET /exercises/ returns empty list when no exercises exist."""
        r = await client.get("/api/exercises/")
        assert r.status_code == 200
        assert r.json() == []

    async def test_create_exercise(self, client: AsyncClient):
        """POST creates exercise, returns 201 with correct fields."""
        r = await client.post(
            "/api/exercises/",
            json={
                "name": "bench_press",
                "display_name": "Bench Press",
                "movement_type": "compound",
                "body_region": "upper",
                "is_unilateral": False,
                "is_assisted": False,
                "primary_muscles": ["chest"],
                "secondary_muscles": ["triceps"],
            },
        )
        assert r.status_code == 201
        data = r.json()
        assert data["name"] == "bench_press"
        assert data["display_name"] == "Bench Press"
        assert data["movement_type"] == "compound"
        assert data["body_region"] == "upper"
        assert data["is_unilateral"] is False
        assert data["is_assisted"] is False
        assert data["primary_muscles"] == ["chest"]
        assert data["secondary_muscles"] == ["triceps"]
        assert "id" in data

    async def test_create_exercise_sets_is_unilateral(self, client: AsyncClient):
        """is_unilateral=True is persisted correctly."""
        r = await client.post(
            "/api/exercises/",
            json={
                "name": "single_leg_rdl",
                "display_name": "Single Leg RDL",
                "movement_type": "hinge",
                "body_region": "lower",
                "is_unilateral": True,
                "is_assisted": False,
                "primary_muscles": ["hamstrings"],
                "secondary_muscles": [],
            },
        )
        assert r.status_code == 201
        data = r.json()
        assert data["is_unilateral"] is True

    async def test_create_exercise_rejects_overlapping_muscles(self, client: AsyncClient):
        """Creating an exercise where a muscle appears in both primary and secondary is rejected."""
        r = await client.post(
            "/api/exercises/",
            json={
                "name": "overlap_test",
                "display_name": "Overlap Test",
                "primary_muscles": ["back"],
                "secondary_muscles": ["back", "biceps"],
            },
        )
        assert r.status_code == 422
        assert "primary and secondary" in r.text

    async def test_get_exercise_by_id(self, client: AsyncClient):
        """GET /exercises/{id} returns correct exercise."""
        ex = await create_exercise(client, name="squat", display_name="Squat")
        r = await client.get(f"/api/exercises/{ex['id']}")
        assert r.status_code == 200
        data = r.json()
        assert data["id"] == ex["id"]
        assert data["name"] == "squat"
        assert data["display_name"] == "Squat"

    async def test_get_exercise_not_found(self, client: AsyncClient):
        """GET /exercises/9999 returns 404."""
        r = await client.get("/api/exercises/9999")
        assert r.status_code == 404

    async def test_delete_exercise_not_used(self, client: AsyncClient):
        """DELETE on unused exercise returns 204."""
        ex = await create_exercise(client)
        r = await client.delete(f"/api/exercises/{ex['id']}")
        assert r.status_code == 204

    async def test_delete_exercise_in_use(self, client: AsyncClient):
        """DELETE on exercise used in a set returns 409."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])
        await log_set(client, sess["id"], sess["sets"][0]["id"], 100.0, 8)

        r = await client.delete(f"/api/exercises/{ex['id']}")
        assert r.status_code == 409

    async def test_exercise_history_empty(self, client: AsyncClient):
        """GET /exercises/{id}/history returns [] when no completed sets."""
        ex = await create_exercise(client)
        r = await client.get(f"/api/exercises/{ex['id']}/history")
        assert r.status_code == 200
        assert r.json() == []
