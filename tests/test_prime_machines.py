"""Tests for Prime plate-loaded machine support (#661)."""
import json
import pytest
from httpx import AsyncClient

from tests.conftest import create_exercise, create_plan, start_session_from_plan

pytestmark = pytest.mark.asyncio(loop_scope="function")


class TestPrimeExerciseFlag:
    async def test_create_prime_exercise(self, client: AsyncClient):
        """Creating an exercise with is_prime=True persists correctly."""
        r = await client.post(
            "/api/exercises/",
            json={
                "name": "prime_fitness_row",
                "display_name": "Prime Fitness Row",
                "movement_type": "compound",
                "body_region": "upper",
                "equipment_type": "plate_loaded",
                "is_prime": True,
                "primary_muscles": ["back"],
                "secondary_muscles": ["biceps"],
            },
        )
        assert r.status_code == 201
        data = r.json()
        assert data["is_prime"] is True
        assert data["equipment_type"] == "plate_loaded"

    async def test_create_non_prime_defaults_false(self, client: AsyncClient):
        """Default is_prime is False."""
        r = await client.post(
            "/api/exercises/",
            json={
                "name": "barbell_row",
                "display_name": "Barbell Row",
                "primary_muscles": ["back"],
                "secondary_muscles": [],
            },
        )
        assert r.status_code == 201
        assert r.json()["is_prime"] is False

    async def test_list_exercises_includes_is_prime(self, client: AsyncClient):
        """GET /exercises/ includes is_prime in response."""
        await client.post(
            "/api/exercises/",
            json={
                "name": "prime_fly",
                "display_name": "Prime Fly",
                "equipment_type": "plate_loaded",
                "is_prime": True,
                "primary_muscles": ["chest"],
                "secondary_muscles": [],
            },
        )
        r = await client.get("/api/exercises/")
        assert r.status_code == 200
        exercises = r.json()
        assert len(exercises) == 1
        assert exercises[0]["is_prime"] is True

    async def test_get_exercise_includes_is_prime(self, client: AsyncClient):
        """GET /exercises/{id} includes is_prime."""
        ex = await create_exercise(
            client,
            name="prime_chest_press",
            display_name="Prime Chest Press",
            equipment_type="plate_loaded",
            is_prime=True,
        )
        r = await client.get(f"/api/exercises/{ex['id']}")
        assert r.status_code == 200
        assert r.json()["is_prime"] is True


class TestPegWeights:
    async def test_log_set_with_peg_weights(self, client: AsyncClient):
        """PATCH set with peg_weights stores them and auto-calculates total."""
        ex = await create_exercise(
            client,
            name="prime_row",
            display_name="Prime Row",
            equipment_type="plate_loaded",
            is_prime=True,
        )
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])
        set_id = sess["sets"][0]["id"]

        peg_data = json.dumps({"peg1": 20.0, "peg2": 10.0, "peg3": 15.0})
        r = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_reps": 8,
                "peg_weights": peg_data,
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r.status_code == 200
        data = r.json()

        # peg_weights should be stored and returned
        assert data["peg_weights"] is not None
        assert data["peg_weights"]["peg1"] == 20.0
        assert data["peg_weights"]["peg2"] == 10.0
        assert data["peg_weights"]["peg3"] == 15.0

        # actual_weight_kg should be auto-calculated: 20+10+15 = 45 kg
        assert data["actual_weight_kg"] == 45.0

    async def test_log_set_without_peg_weights(self, client: AsyncClient):
        """Normal sets without peg_weights still work."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])
        set_id = sess["sets"][0]["id"]

        r = await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_reps": 8,
                "actual_weight_kg": 100.0,
                "completed_at": "2024-01-01T10:00:00",
            },
        )
        assert r.status_code == 200
        data = r.json()
        assert data["peg_weights"] is None
        assert data["actual_weight_kg"] == 100.0

    async def test_peg_weights_persisted_in_session(self, client: AsyncClient):
        """peg_weights are visible when fetching the full session."""
        ex = await create_exercise(
            client,
            name="prime_press",
            display_name="Prime Press",
            equipment_type="plate_loaded",
            is_prime=True,
        )
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])
        set_id = sess["sets"][0]["id"]

        peg_data = json.dumps({"peg1": 25.0, "peg2": 0, "peg3": 45.0})
        await client.patch(
            f"/api/sessions/{sess['id']}/sets/{set_id}",
            json={
                "actual_reps": 8,
                "peg_weights": peg_data,
                "completed_at": "2024-01-01T10:00:00",
            },
        )

        r = await client.get(f"/api/sessions/{sess['id']}")
        assert r.status_code == 200
        session_data = r.json()
        logged_set = session_data["sets"][0]
        assert logged_set["peg_weights"]["peg1"] == 25.0
        assert logged_set["peg_weights"]["peg3"] == 45.0
        assert logged_set["actual_weight_kg"] == 70.0  # 25+0+45
