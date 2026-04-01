"""Tests for the exercises CRUD API."""
import json

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.models.exercise import Exercise
from app.models.workout import ExerciseSet, WorkoutPlan
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

    async def test_delete_exercise_used_only_in_planned_session(self, client: AsyncClient, db):
        """DELETE removes planned-only references and succeeds."""
        ex = await create_exercise(client, name="leg_press", display_name="Leg Press")
        plan = await create_plan(client, ex["id"], sets=2, reps=10)

        planned = await client.post(
            f"/api/sessions/from-plan/{plan['id']}",
            params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
        )
        assert planned.status_code == 201, planned.text

        r = await client.delete(f"/api/exercises/{ex['id']}")
        assert r.status_code == 204

        stored_plan_result = await db.execute(select(WorkoutPlan).where(WorkoutPlan.id == plan["id"]))
        stored_plan = stored_plan_result.scalar_one()
        planned_data = json.loads(stored_plan.planned_exercises)
        assert planned_data["days"][0]["exercises"] == []

        set_rows = await db.execute(select(ExerciseSet).where(ExerciseSet.exercise_id == ex["id"]))
        assert set_rows.scalars().all() == []

    async def test_exercise_history_empty(self, client: AsyncClient):
        """GET /exercises/{id}/history returns [] when no completed sets."""
        ex = await create_exercise(client)
        r = await client.get(f"/api/exercises/{ex['id']}/history")
        assert r.status_code == 200
        assert r.json() == []

    async def test_list_exercises_includes_globals_and_user_customs(self, client: AsyncClient, db):
        """Users can see built-ins plus their own custom exercises."""
        db.add(Exercise(
            name="barbell_row",
            display_name="Barbell Row",
            movement_type="compound",
            body_region="upper",
            primary_muscles=["lats"],
            secondary_muscles=["biceps"],
        ))
        await db.commit()

        custom = await create_exercise(client, name="seal_row", display_name="Seal Row")
        r = await client.get("/api/exercises/")
        assert r.status_code == 200
        data = r.json()
        names = {ex["name"] for ex in data}
        assert "barbell_row" in names
        assert custom["name"] in names
        own = next(ex for ex in data if ex["name"] == custom["name"])
        assert own["is_custom"] is True

    async def test_update_exercise_future_only_remaps_plans_and_planned_sessions_only(self, client: AsyncClient, db):
        """Future-only customization swaps plans/planned sessions to a new custom exercise."""
        base = Exercise(
            name="lat_pulldown",
            display_name="Lat Pulldown",
            movement_type="compound",
            body_region="upper",
            primary_muscles=["lats"],
            secondary_muscles=["biceps"],
        )
        db.add(base)
        await db.commit()
        await db.refresh(base)

        plan = await create_plan(client, base.id, sets=2, reps=10)
        planned = await client.post(f"/api/sessions/from-plan/{plan['id']}", params={"day_number": 1})
        assert planned.status_code == 201, planned.text
        planned_session = planned.json()

        second_plan = await create_plan(client, base.id, sets=1, reps=10, name="History Plan")
        started = await start_session_from_plan(client, second_plan["id"])
        await log_set(client, started["id"], started["sets"][0]["id"], 45.0, 10)

        update = await client.put(
            f"/api/exercises/{base.id}",
            json={
                "display_name": "Upper Back Pulldown",
                "movement_type": "compound",
                "body_region": "upper",
                "is_unilateral": False,
                "is_assisted": False,
                "description": "Customized for upper-back focus",
                "primary_muscles": ["upper_back"],
                "secondary_muscles": ["biceps"],
                "apply_mode": "future_only",
            },
        )
        assert update.status_code == 200, update.text
        customized = update.json()
        assert customized["id"] != base.id
        assert customized["is_custom"] is True

        plan_after = await client.get(f"/api/plans/{plan['id']}")
        assert plan_after.status_code == 200
        assert plan_after.json()["days"][0]["exercises"][0]["exercise_id"] == customized["id"]

        second_plan_after = await client.get(f"/api/plans/{second_plan['id']}")
        assert second_plan_after.status_code == 200
        assert second_plan_after.json()["days"][0]["exercises"][0]["exercise_id"] == customized["id"]

        planned_after = await client.get(f"/api/sessions/{planned_session['id']}")
        assert planned_after.status_code == 200
        assert {s["exercise_id"] for s in planned_after.json()["sets"]} == {customized["id"]}

        started_after = await client.get(f"/api/sessions/{started['id']}")
        assert started_after.status_code == 200
        assert {s["exercise_id"] for s in started_after.json()["sets"]} == {base.id}

    async def test_update_exercise_retroactive_remaps_history(self, client: AsyncClient, db):
        """Retroactive customization remaps past sets to the new custom exercise."""
        base = Exercise(
            name="seated_cable_row",
            display_name="Seated Cable Row",
            movement_type="compound",
            body_region="upper",
            primary_muscles=["mid_back"],
            secondary_muscles=["biceps"],
        )
        db.add(base)
        await db.commit()
        await db.refresh(base)

        plan = await create_plan(client, base.id, sets=1, reps=8)
        started = await start_session_from_plan(client, plan["id"])
        await log_set(client, started["id"], started["sets"][0]["id"], 60.0, 8)

        update = await client.put(
            f"/api/exercises/{base.id}",
            json={
                "display_name": "Rear Delt Row",
                "movement_type": "isolation",
                "body_region": "upper",
                "is_unilateral": False,
                "is_assisted": False,
                "description": None,
                "primary_muscles": ["rear_delts"],
                "secondary_muscles": ["upper_back"],
                "apply_mode": "retroactive",
            },
        )
        assert update.status_code == 200, update.text
        customized = update.json()

        session_after = await client.get(f"/api/sessions/{started['id']}")
        assert session_after.status_code == 200
        assert {s["exercise_id"] for s in session_after.json()["sets"]} == {customized["id"]}

        history = await client.get(f"/api/exercises/{customized['id']}/history")
        assert history.status_code == 200
        assert len(history.json()) == 1

        old_history = await client.get(f"/api/exercises/{base.id}/history")
        assert old_history.status_code == 200
        assert old_history.json() == []

        rows = await db.execute(select(Exercise).where(Exercise.id == customized["id"]))
        stored = rows.scalar_one()
        assert stored.primary_muscles == ["rear_delts"]
