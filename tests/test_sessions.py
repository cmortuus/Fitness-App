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
        """POST /sessions/{id}/start opens the session but keeps it planned."""
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
        assert r2.json()["status"] == "planned"
        assert r2.json()["started_at"] is None

    async def test_first_completed_set_starts_session(self, client: AsyncClient):
        """The first completed set promotes the session to in_progress."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)

        r1 = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        assert r1.status_code == 201
        sess = r1.json()

        await client.post(f"/api/sessions/{sess['id']}/start")

        set_id = sess["sets"][0]["id"]
        r2 = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_weight_kg": 80.0,
                "actual_reps": 10,
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r2.status_code == 200

        r3 = await client.get(f"/api/sessions/{sess['id']}")
        assert r3.status_code == 200
        assert r3.json()["status"] == "in_progress"
        assert r3.json()["started_at"] == "2024-01-01T10:00:00"

    async def test_prevent_duplicate_in_progress(self, client: AsyncClient):
        """Starting a second session while one is in_progress returns 409."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)

        sess1 = await start_session_from_plan(client, plan["id"])
        await client.patch(
            f"/api/sessions/{sess1['id']}/sets/{sess1['sets'][0]['id']}",
            json={
                "actual_weight_kg": 80.0,
                "actual_reps": 10,
                "completed_at": "2024-01-01T10:00:00",
            },
        )

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

        r2 = await client.get(f"/api/sessions/{sess['id']}")
        assert r2.status_code == 200
        assert r2.json()["status"] == "in_progress"
        assert r2.json()["started_at"] == "2024-01-01T10:00:00"

    async def test_uncompleting_last_done_set_resets_session_to_planned(self, client: AsyncClient):
        """Removing the only completed set should clear in_progress state."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        set_id = sess["sets"][0]["id"]
        await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_weight_kg": 80.0,
                "actual_reps": 10,
                "completed_at": "2024-01-01T10:00:00",
            },
        )

        r = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_weight_kg": None,
                "actual_reps": None,
                "completed_at": None,
            },
        )
        assert r.status_code == 200

        r2 = await client.get(f"/api/sessions/{sess['id']}")
        assert r2.status_code == 200
        assert r2.json()["status"] == "planned"
        assert r2.json()["started_at"] is None

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

        # Get the authenticated user's ID
        me = await client.get("/api/auth/me")
        user_id = me.json()["id"]

        # Bypass the guard by inserting two IN_PROGRESS sessions directly into the DB
        for i in range(2):
            db.add(WorkoutSession(
                name=f"Orphaned Session {i}",
                date=date.today(),
                status=WorkoutStatus.IN_PROGRESS,
                workout_plan_id=plan["id"],
                user_id=user_id,
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

    async def test_add_set_to_session(self, client: AsyncClient):
        """POST /sessions/{id}/sets creates a new set and returns 201."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        r = await client.post(
            f"/api/sessions/{sess['id']}/sets",
            json={
                "exercise_id": ex["id"],
                "set_number": 99,
                "planned_reps": 10,
                "planned_weight_kg": 60.0,
            },
        )
        assert r.status_code == 201
        data = r.json()
        assert data["exercise_id"] == ex["id"]
        assert data["set_number"] == 99
        assert data["planned_reps"] == 10
        assert data["planned_weight_kg"] == 60.0
        assert "id" in data

    async def test_add_set_session_not_found(self, client: AsyncClient):
        """POST /sessions/99999/sets returns 404 when session doesn't exist."""
        ex = await create_exercise(client)
        r = await client.post(
            "/api/sessions/99999/sets",
            json={
                "exercise_id": ex["id"],
                "set_number": 1,
                "planned_reps": 8,
            },
        )
        assert r.status_code == 404

    async def test_delete_set(self, client: AsyncClient):
        """DELETE /sessions/{id}/sets/{set_id} removes the set and returns 204."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=2, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        set_id = sess["sets"][0]["id"]
        r = await client.delete(f"/api/sessions/{sess['id']}/sets/{set_id}")
        assert r.status_code == 204

        # Verify the set is gone
        r2 = await client.get(f"/api/sessions/{sess['id']}")
        assert r2.status_code == 200
        remaining_ids = [s["id"] for s in r2.json()["sets"]]
        assert set_id not in remaining_ids

    async def test_delete_set_not_found(self, client: AsyncClient):
        """DELETE /sessions/{id}/sets/99999 returns 404."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        r = await client.delete(f"/api/sessions/{sess['id']}/sets/99999")
        assert r.status_code == 404

    async def test_delete_set_wrong_session(self, client: AsyncClient):
        """DELETE with set_id belonging to a different session returns 404."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess1 = await start_session_from_plan(client, plan["id"])
        complete = await client.post(f"/api/sessions/{sess1['id']}/complete")
        assert complete.status_code == 200
        sess2 = await start_session_from_plan(client, plan["id"])

        # Try to delete sess1's set via sess2's endpoint
        set_id = sess1["sets"][0]["id"]
        r = await client.delete(f"/api/sessions/{sess2['id']}/sets/{set_id}")
        assert r.status_code == 404
