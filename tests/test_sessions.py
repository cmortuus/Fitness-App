"""Tests for workout session lifecycle API."""
from datetime import date

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.workout import WorkoutSession, WorkoutStatus
from tests.conftest import create_exercise, create_plan, start_session_from_plan

pytestmark = pytest.mark.asyncio(loop_scope="function")


class TestSessionLifecycle:
    async def test_create_session_from_plan(self, client: AsyncClient):
        """POST /sessions/from-plan/{id} returns 201 with sets pre-filled."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        r = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        assert r.status_code == 201
        data = r.json()
        assert "id" in data
        assert len(data["sets"]) == 3

    async def test_start_session(self, client: AsyncClient):
        """POST /sessions/{id}/start transitions status to in_progress."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=2, reps=8)

        r = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        assert r.status_code == 201
        session_id = r.json()["id"]

        r2 = await client.post(f"/api/sessions/{session_id}/start")
        assert r2.status_code == 200
        assert r2.json()["status"] == "in_progress"

    async def test_prevent_duplicate_in_progress(self, client: AsyncClient):
        """Starting a second session while one is in_progress returns 409."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)

        # Create and start first session
        r1 = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        sess1_id = r1.json()["id"]
        await client.post(f"/api/sessions/{sess1_id}/start")

        # Create a second session and attempt to start it
        r2 = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        # from-plan also checks for in-progress; expect 409 with structured body
        assert r2.status_code == 409
        body = r2.json()
        # detail must be a dict with session_id so the frontend can target the right session
        assert isinstance(body["detail"], dict)
        assert "session_id" in body["detail"]
        assert isinstance(body["detail"]["session_id"], int)

    async def test_complete_session(self, client: AsyncClient):
        """POST /sessions/{id}/complete transitions to completed."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        r = await client.post(f"/api/sessions/{sess['id']}/complete")
        assert r.status_code == 200
        assert r.json()["status"] == "completed"

    async def test_log_set(self, client: AsyncClient):
        """PATCH /sessions/{id}/sets/{set_id} updates actual_reps/weight."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        set_id = sess["sets"][0]["id"]
        r = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_weight_kg": 80.0,
                "actual_reps": 10,
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r.status_code == 200
        data = r.json()
        assert data["actual_weight_kg"] == 80.0
        assert data["actual_reps"] == 10

    async def test_guard_survives_multiple_in_progress_sessions(
        self, client: AsyncClient, db: AsyncSession
    ):
        """Guard uses .scalars().first() so pre-existing dirty data (multiple
        in-progress sessions) does not cause a MultipleResultsFound 500 crash.

        Why this wasn't caught before: tests use a fresh DB per run and
        always complete sessions before creating new ones, so there is never
        more than one in-progress row.  This test simulates the real-world
        scenario where a user has orphaned in-progress sessions in their DB.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)

        # Bypass the guard by inserting two IN_PROGRESS sessions directly into the DB
        for i in range(2):
            db.add(WorkoutSession(
                name=f"Orphaned Session {i}",
                date=date.today(),
                status=WorkoutStatus.IN_PROGRESS,
                workout_plan_id=plan["id"],
            ))
        await db.commit()

        # Now calling from-plan must return 409 (not 500) even with 2 in-progress rows
        r = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        assert r.status_code == 409, (
            f"Expected 409 (duplicate guard), got {r.status_code}: {r.text}"
        )

    async def test_pagination_cap(self, client: AsyncClient):
        """GET /sessions/?limit=9999 returns at most 500 results."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)

        # Create 3 sessions
        for _ in range(3):
            await start_session_from_plan(client, plan["id"])

        r = await client.get("/api/sessions/", params={"limit": 9999})
        assert r.status_code == 200
        data = r.json()
        assert isinstance(data, list)
        assert len(data) <= 500
