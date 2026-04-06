"""Tests for the progress tracking API."""
from datetime import date

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.workout import WorkoutSession
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

    async def test_overload_uses_saved_training_level(self, client: AsyncClient):
        """POST /progress/overload should respect the user's saved training level."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)
        sess = await start_session_from_plan(client, plan["id"])
        await log_set(client, sess["id"], sess["sets"][0]["id"], 36.29, 8)
        await client.post(f"/api/sessions/{sess['id']}/complete")

        settings_res = await client.put("/api/auth/settings", json={
            "progression": {"trainingLevel": "beginner"}
        })
        assert settings_res.status_code == 200, settings_res.text

        beginner_res = await client.post("/api/progress/overload", json={
            "exercise_id": ex["id"],
            "current_weight": 100.0,
            "current_reps": 15,
            "target_reps": 8,
            "weight_unit": "lbs",
        })
        assert beginner_res.status_code == 200, beginner_res.text

        settings_res = await client.put("/api/auth/settings", json={
            "progression": {"trainingLevel": "advanced"}
        })
        assert settings_res.status_code == 200, settings_res.text

        advanced_res = await client.post("/api/progress/overload", json={
            "exercise_id": ex["id"],
            "current_weight": 100.0,
            "current_reps": 15,
            "target_reps": 8,
            "weight_unit": "lbs",
        })
        assert advanced_res.status_code == 200, advanced_res.text
        assert beginner_res.json()["next_weight"] > advanced_res.json()["next_weight"]

    async def test_records_return_db_backed_prs_with_achieved_dates(
        self, client: AsyncClient, db: AsyncSession
    ):
        """GET /progress/records should use persisted history and include achieved dates."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=1, reps=8)

        sess1 = await start_session_from_plan(client, plan["id"])
        await log_set(client, sess1["id"], sess1["sets"][0]["id"], 100.0, 8)
        await client.post(f"/api/sessions/{sess1['id']}/complete")

        sess2 = await start_session_from_plan(client, plan["id"])
        await log_set(client, sess2["id"], sess2["sets"][0]["id"], 95.0, 12)
        await client.post(f"/api/sessions/{sess2['id']}/complete")

        sessions = (
            await db.execute(select(WorkoutSession).order_by(WorkoutSession.id))
        ).scalars().all()
        assert len(sessions) == 2
        sessions[0].date = date(2024, 1, 1)
        sessions[1].date = date(2024, 2, 1)
        await db.commit()

        r = await client.get("/api/progress/records")
        assert r.status_code == 200
        records = r.json()
        assert len(records) == 1

        record = records[0]
        assert record["exercise_id"] == ex["id"]
        assert record["max_weight_kg"] == 100.0
        assert record["max_weight_date"] == "2024-01-01"
        assert record["max_reps"] == 12
        assert record["max_reps_date"] == "2024-02-01"
        assert record["best_1rm_kg"] == 133.0
        assert record["best_1rm_date"] == "2024-02-01"
        assert record["best_set_weight_kg"] == 95.0
        assert record["best_set_reps"] == 12
