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

    async def test_create_session_from_plan_preserves_duplicate_exercise_blocks(self, client: AsyncClient):
        """Duplicate exercise occurrences should get distinct block IDs in the session."""
        ex1 = await create_exercise(client, name="lateral_raise", display_name="Lateral Raise")
        ex2 = await create_exercise(client, name="chest_press", display_name="Chest Press")

        plan_r = await client.post(
            "/api/plans/",
            json={
                "name": "Duplicate Block Plan",
                "block_type": "hypertrophy",
                "duration_weeks": 4,
                "number_of_days": 1,
                "days": [{
                    "day_number": 1,
                    "day_name": "Day 1",
                    "exercises": [
                        {"exercise_id": ex1["id"], "sets": 2, "reps": 10, "starting_weight_kg": 0, "progression_type": "linear"},
                        {"exercise_id": ex2["id"], "sets": 2, "reps": 8, "starting_weight_kg": 0, "progression_type": "linear"},
                        {"exercise_id": ex1["id"], "sets": 2, "reps": 15, "starting_weight_kg": 0, "progression_type": "linear"},
                    ],
                }],
            },
        )
        assert plan_r.status_code == 201, plan_r.text
        plan = plan_r.json()
        day_exercises = plan["days"][0]["exercises"]
        lateral_block_ids = [ex["block_id"] for ex in day_exercises if ex["exercise_id"] == ex1["id"]]
        assert len(lateral_block_ids) == 2
        assert lateral_block_ids[0] != lateral_block_ids[1]

        session_r = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        assert session_r.status_code == 201, session_r.text
        session = session_r.json()

        lateral_session_block_ids = sorted({
            s["exercise_block_id"]
            for s in session["sets"]
            if s["exercise_id"] == ex1["id"]
        })
        assert lateral_session_block_ids == sorted(lateral_block_ids)

    async def test_create_session_from_plan_respects_exercise_rir_override(self, client: AsyncClient):
        """Exercise RIR override should back off the programmed load for the next session."""
        ex = await create_exercise(client, primary_muscles=["quadriceps"])
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])
        set_id = sess["sets"][0]["id"]

        r1 = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_weight_kg": 100.0,
                "actual_reps": 8,
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r1.status_code == 200
        complete_r = await client.post(f"/api/sessions/{sess['id']}/complete")
        assert complete_r.status_code == 200

        rir_r = await client.put(
            f"/api/plans/{plan['id']}/rir-overrides",
            json={"plan": None, "muscles": {}, "exercises": {str(ex["id"]): 2}},
        )
        assert rir_r.status_code == 200, rir_r.text

        next_r = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        assert next_r.status_code == 201, next_r.text
        next_set = next_r.json()["sets"][0]
        assert next_set["planned_reps"] == 8
        assert next_set["planned_weight_kg"] == 95.0

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

    async def test_log_set_allows_changing_exercise(self, client: AsyncClient):
        """PATCH /sessions/{id}/sets/{set_id} can move a logged set to another visible exercise."""
        ex = await create_exercise(client, name="incline_press", display_name="Incline Press")
        replacement = await create_exercise(client, name="prime_press", display_name="Prime Press")
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        set_id = sess["sets"][0]["id"]
        r = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "exercise_id": replacement["id"],
                "actual_weight_kg": 70.0,
                "actual_reps": 9,
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r.status_code == 200, r.text
        data = r.json()
        assert data["exercise_id"] == replacement["id"]
        assert data["exercise_name"] == replacement["display_name"]

    async def test_log_set_with_partials(self, client: AsyncClient):
        """PATCH /sessions/{id}/sets/{set_id} accepts partial-rep sub_sets payloads."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        set_id = sess["sets"][0]["id"]
        r = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_weight_kg": 35.0,
                "actual_reps": 10,
                "set_type": "standard_partials",
                "sub_sets": [{"weight_kg": 35.0, "reps": 4, "type": "partial"}],
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r.status_code == 200
        data = r.json()
        assert data["set_type"] == "standard_partials"
        assert data["sub_sets"] == [{"weight_kg": 35.0, "reps": 4, "type": "partial"}]

    async def test_unilateral_set_updates_session_rep_totals(self, client: AsyncClient):
        """Unilateral reps should contribute to session total_reps and volume."""
        ex = await create_exercise(client, is_unilateral=True)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        set_id = sess["sets"][0]["id"]
        r = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_weight_kg": 20.0,
                "reps_left": 10,
                "reps_right": 12,
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r.status_code == 200

        r2 = await client.get(f"/api/sessions/{sess['id']}")
        assert r2.status_code == 200
        assert r2.json()["total_reps"] == 22
        assert r2.json()["total_volume_kg"] == 440.0

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
        sess2 = await start_session_from_plan(client, plan["id"])

        # Try to delete sess1's set via sess2's endpoint
        set_id = sess1["sets"][0]["id"]
        r = await client.delete(f"/api/sessions/{sess2['id']}/sets/{set_id}")
        assert r.status_code == 404

    async def test_reset_session_to_planned_clears_progress_and_drafts(self, client: AsyncClient):
        """Resetting a session should clear started/completed state and set progress."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])
        set_id = sess["sets"][0]["id"]

        r = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_weight_kg": 100.0,
                "actual_reps": 8,
                "draft_weight_kg": 95.0,
                "draft_reps": 9,
                "started_at": "2024-01-01T09:00:00",
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r.status_code == 200

        r2 = await client.post(f"/api/sessions/{sess['id']}/reset-to-planned")
        assert r2.status_code == 200
        data = r2.json()
        assert data["status"] == "planned"
        assert data["started_at"] is None
        assert data["completed_at"] is None
        assert data["total_volume_kg"] == 0
        assert data["total_sets"] == 0
        assert data["total_reps"] == 0
        assert data["sets"][0]["actual_weight_kg"] is None
        assert data["sets"][0]["actual_reps"] is None
        assert data["sets"][0]["draft_weight_kg"] is None
        assert data["sets"][0]["draft_reps"] is None
        assert data["sets"][0]["started_at"] is None
        assert data["sets"][0]["completed_at"] is None

    async def test_reset_session_to_planned_not_found(self, client: AsyncClient):
        """Resetting an unknown session should return 404."""
        r = await client.post("/api/sessions/999999/reset-to-planned")
        assert r.status_code == 404
