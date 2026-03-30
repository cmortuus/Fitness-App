import pytest

from httpx import AsyncClient

from tests.conftest import create_exercise, create_plan, start_session_from_plan

pytestmark = pytest.mark.asyncio(loop_scope="function")


async def test_session_audit_records_create_start_complete(client: AsyncClient):
    ex = await create_exercise(client)
    plan = await create_plan(client, ex["id"], sets=1, reps=8)

    create_resp = await client.post(
        f"/api/sessions/from-plan/{plan['id']}",
        params={"day_number": 1, "overload_style": "rep", "body_weight_kg": 0},
    )
    assert create_resp.status_code == 201
    session_id = create_resp.json()["id"]

    start_resp = await client.post(f"/api/sessions/{session_id}/start")
    assert start_resp.status_code == 200

    complete_resp = await client.post(f"/api/sessions/{session_id}/complete")
    assert complete_resp.status_code == 200

    audit_resp = await client.get(f"/api/sessions/{session_id}/audit")
    assert audit_resp.status_code == 200
    audit = audit_resp.json()

    assert audit[0]["reason"] == "session_completed"
    assert audit[0]["from_status"] == "in_progress"
    assert audit[0]["to_status"] == "completed"
    assert audit[1]["reason"] == "session_started"
    assert audit[1]["from_status"] == "planned"
    assert audit[1]["to_status"] == "in_progress"
    assert audit[2]["reason"] == "session_created_from_plan"
    assert audit[2]["from_status"] is None
    assert audit[2]["to_status"] == "planned"


async def test_session_audit_records_reset_to_planned(client: AsyncClient):
    ex = await create_exercise(client)
    plan = await create_plan(client, ex["id"], sets=1, reps=8)
    session = await start_session_from_plan(client, plan["id"])

    reset_resp = await client.post(f"/api/sessions/{session['id']}/reset-to-planned")
    assert reset_resp.status_code == 200

    audit_resp = await client.get(f"/api/sessions/{session['id']}/audit")
    assert audit_resp.status_code == 200
    audit = audit_resp.json()

    assert audit[0]["reason"] == "session_reset_to_planned"
    assert audit[0]["from_status"] == "in_progress"
    assert audit[0]["to_status"] == "planned"
