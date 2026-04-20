"""Tests for account-control endpoints (#875).

Covers:
- change-password with correct/incorrect current password
- change-email (not gated by verify status, but clears verified if column exists)
- change-email rejects duplicate email
- delete-account cascades and returns 200
- export-user-data returns user + plans + sessions + sets
"""
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.main import app
from app.models.user import User

pytestmark = pytest.mark.asyncio(loop_scope="function")


async def _register(c: AsyncClient, username: str, email: str | None = None) -> dict:
    r = await c.post(
        "/api/auth/register",
        json={
            "username": username,
            "email": email or f"{username}@test.com",
            "password": "oldpass123",
        },
    )
    assert r.status_code == 201, r.text
    return r.json()


class TestChangePassword:
    async def test_success(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "pw_success")
            token = auth["access_token"]
            r = await c.post(
                "/api/auth/change-password",
                json={"current_password": "oldpass123", "new_password": "newpass456"},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code == 200, r.text
            # Old password no longer works
            r2 = await c.post("/api/auth/login", json={"username": "pw_success", "password": "oldpass123"})
            assert r2.status_code == 401
            # New password works
            r3 = await c.post("/api/auth/login", json={"username": "pw_success", "password": "newpass456"})
            assert r3.status_code == 200

    async def test_wrong_current_rejected(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "pw_wrong")
            token = auth["access_token"]
            r = await c.post(
                "/api/auth/change-password",
                json={"current_password": "WRONG", "new_password": "newpass456"},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code == 401


class TestChangeEmail:
    async def test_success(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "email_change")
            token = auth["access_token"]
            r = await c.post(
                "/api/auth/change-email",
                json={"current_password": "oldpass123", "new_email": "changed@test.com"},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code == 200, r.text
            assert r.json()["email"] == "changed@test.com"

    async def test_duplicate_email_rejected(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            await _register(c, "existing", "taken@test.com")
            auth = await _register(c, "mover")
            token = auth["access_token"]
            r = await c.post(
                "/api/auth/change-email",
                json={"current_password": "oldpass123", "new_email": "taken@test.com"},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code == 409


class TestDeleteAccount:
    async def test_success(self, db):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "deleter")
            token = auth["access_token"]
            user_id = auth["user"]["id"]

            r = await c.delete("/api/auth/account", headers={"Authorization": f"Bearer {token}"})
            assert r.status_code == 200
            assert r.json()["status"] == "deleted"

            # User row is gone
            result = await db.execute(select(User).where(User.id == user_id))
            assert result.scalar_one_or_none() is None


class TestExport:
    async def test_export_returns_full_payload(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "exporter")
            token = auth["access_token"]
            r = await c.get("/api/auth/export", headers={"Authorization": f"Bearer {token}"})
            assert r.status_code == 200, r.text
            body = r.json()
            assert body["user"]["username"] == "exporter"
            # All list sections present
            for key in ("workout_plans", "workout_sessions", "exercise_sets",
                        "body_weight_entries", "nutrition_entries"):
                assert key in body, f"missing {key} in export"
                assert isinstance(body[key], list)
