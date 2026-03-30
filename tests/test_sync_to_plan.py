"""Tests for sync-to-plan structural changes (#346)."""
import pytest
from httpx import AsyncClient

from tests.conftest import create_exercise, create_plan, start_session_from_plan

pytestmark = pytest.mark.asyncio(loop_scope="function")


async def _create_plan_with_exercises(client, exercises: list[dict], day_name="Day 1") -> dict:
    """Create a plan with multiple exercises on one day."""
    body = {
        "name": "Test Plan",
        "block_type": "hypertrophy",
        "duration_weeks": 4,
        "number_of_days": 1,
        "days": [{
            "day_number": 1,
            "day_name": day_name,
            "exercises": exercises,
        }],
    }
    r = await client.post("/api/plans/", json=body)
    assert r.status_code == 201, r.text
    return r.json()


async def _complete_session(client, session_id):
    """Start and complete a session."""
    await client.post(f"/api/sessions/{session_id}/start")
    r = await client.post(f"/api/sessions/{session_id}/complete")
    assert r.status_code == 200
    return r.json()


async def _get_plan_exercises(client, plan_id) -> list[dict]:
    """Fetch the plan and return the first day's exercises."""
    r = await client.get(f"/api/plans/{plan_id}")
    assert r.status_code == 200
    return r.json()["days"][0]["exercises"]


class TestSyncStructural:
    async def test_sync_updates_weight_and_reps(self, client: AsyncClient):
        """Basic sync — weight and reps updated from actual performance."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        # Complete sets with actual values
        for s in sess["sets"]:
            await client.patch(f"/api/sessions/{sess['id']}/sets/{s['id']}", json={
                "actual_weight_kg": 100.0,
                "actual_reps": 10,
            })

        await _complete_session(client, sess["id"])
        r = await client.post(f"/api/sessions/{sess['id']}/sync-to-plan")
        assert r.status_code == 200
        data = r.json()
        assert data["updated"] >= 1

        exercises = await _get_plan_exercises(client, plan["id"])
        assert exercises[0]["starting_weight_kg"] == 100.0
        assert exercises[0]["reps"] == 10

    async def test_sync_added_exercise(self, client: AsyncClient):
        """Exercise added during session appears in plan after sync."""
        ex1 = await create_exercise(client, name="squat", display_name="Squat")
        ex2 = await create_exercise(client, name="curl", display_name="Curl")
        plan = await create_plan(client, ex1["id"], sets=3, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        # Complete existing sets
        for s in sess["sets"]:
            await client.patch(f"/api/sessions/{sess['id']}/sets/{s['id']}", json={
                "actual_weight_kg": 80.0, "actual_reps": 8,
            })

        # Add a new exercise mid-workout
        r = await client.post(f"/api/sessions/{sess['id']}/sets", json={
            "exercise_id": ex2["id"], "set_number": 1, "planned_reps": 12,
        })
        new_set_id = r.json()["id"]
        await client.patch(f"/api/sessions/{sess['id']}/sets/{new_set_id}", json={
            "actual_weight_kg": 20.0, "actual_reps": 12,
        })

        await _complete_session(client, sess["id"])
        r = await client.post(f"/api/sessions/{sess['id']}/sync-to-plan")
        assert r.json()["structural_changes"] >= 1

        exercises = await _get_plan_exercises(client, plan["id"])
        exercise_ids = [e["exercise_id"] for e in exercises]
        assert ex2["id"] in exercise_ids

    async def test_sync_removed_exercise(self, client: AsyncClient):
        """Exercise removed during session is removed from plan after sync."""
        ex1 = await create_exercise(client, name="squat", display_name="Squat")
        ex2 = await create_exercise(client, name="press", display_name="Press")
        plan = await _create_plan_with_exercises(client, [
            {"exercise_id": ex1["id"], "sets": 3, "reps": 8, "starting_weight_kg": 0, "progression_type": "linear"},
            {"exercise_id": ex2["id"], "sets": 3, "reps": 8, "starting_weight_kg": 0, "progression_type": "linear"},
        ])
        sess = await start_session_from_plan(client, plan["id"])

        # Only complete sets for ex1, delete ex2's sets (simulating removal)
        for s in sess["sets"]:
            if s["exercise_id"] == ex1["id"]:
                await client.patch(f"/api/sessions/{sess['id']}/sets/{s['id']}", json={
                    "actual_weight_kg": 80.0, "actual_reps": 8,
                })
            else:
                await client.delete(f"/api/sessions/{sess['id']}/sets/{s['id']}")

        await _complete_session(client, sess["id"])
        r = await client.post(f"/api/sessions/{sess['id']}/sync-to-plan")
        assert r.json()["structural_changes"] >= 1

        exercises = await _get_plan_exercises(client, plan["id"])
        exercise_ids = [e["exercise_id"] for e in exercises]
        assert ex1["id"] in exercise_ids
        assert ex2["id"] not in exercise_ids

    async def test_sync_set_count_change(self, client: AsyncClient):
        """Changing set count during session updates plan."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)
        sess = await start_session_from_plan(client, plan["id"])

        # Complete the 3 existing sets
        for s in sess["sets"]:
            await client.patch(f"/api/sessions/{sess['id']}/sets/{s['id']}", json={
                "actual_weight_kg": 60.0, "actual_reps": 8,
            })

        # Add a 4th set
        r = await client.post(f"/api/sessions/{sess['id']}/sets", json={
            "exercise_id": ex["id"], "set_number": 4, "planned_reps": 8,
        })
        extra_set_id = r.json()["id"]
        await client.patch(f"/api/sessions/{sess['id']}/sets/{extra_set_id}", json={
            "actual_weight_kg": 60.0, "actual_reps": 8,
        })

        await _complete_session(client, sess["id"])
        r = await client.post(f"/api/sessions/{sess['id']}/sync-to-plan")
        assert r.json()["structural_changes"] >= 1

        exercises = await _get_plan_exercises(client, plan["id"])
        assert exercises[0]["sets"] == 4

    async def test_sync_incomplete_session_rejected(self, client: AsyncClient):
        """Syncing an incomplete session returns 400."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])
        await client.post(f"/api/sessions/{sess['id']}/start")

        r = await client.post(f"/api/sessions/{sess['id']}/sync-to-plan")
        assert r.status_code == 400

    async def test_sync_preserves_plan_fields(self, client: AsyncClient):
        """Sync preserves plan-specific fields like rest_seconds and notes."""
        ex = await create_exercise(client)
        plan = await _create_plan_with_exercises(client, [{
            "exercise_id": ex["id"],
            "sets": 3,
            "reps": 8,
            "starting_weight_kg": 50,
            "progression_type": "linear",
            "rest_seconds": 120,
            "notes": "Pause at bottom",
        }])
        sess = await start_session_from_plan(client, plan["id"])

        for s in sess["sets"]:
            await client.patch(f"/api/sessions/{sess['id']}/sets/{s['id']}", json={
                "actual_weight_kg": 55.0, "actual_reps": 8,
            })

        await _complete_session(client, sess["id"])
        await client.post(f"/api/sessions/{sess['id']}/sync-to-plan")

        exercises = await _get_plan_exercises(client, plan["id"])
        assert exercises[0]["rest_seconds"] == 120
        assert exercises[0]["notes"] == "Pause at bottom"
        assert exercises[0]["starting_weight_kg"] == 55.0
