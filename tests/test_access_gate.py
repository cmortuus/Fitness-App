"""Tests for the subscription access gate (#871).

Verifies:
- GET requests always pass through
- Writes pass for trial users and active subscribers
- Writes return 402 for expired trials with no subscription
- 402 response includes a checkout_url
- Missing/invalid tokens let the endpoint's own 401 handler run (no 402)
"""
from datetime import datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.main import app
from app.models.user import User

pytestmark = pytest.mark.asyncio(loop_scope="function")


async def _register(c: AsyncClient, username: str) -> dict:
    r = await c.post(
        "/api/auth/register",
        json={"username": username, "email": f"{username}@test.com", "password": "testpass123"},
    )
    assert r.status_code == 201, r.text
    return r.json()


class TestAccessGate:
    async def test_get_always_passes(self, db):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "gate_get")
            # Force trial to expire — user has no access
            result = await db.execute(select(User).where(User.username == "gate_get"))
            user = result.scalar_one()
            user.trial_ends_at = datetime.utcnow() - timedelta(days=1)
            await db.commit()

            token = auth["access_token"]
            # GET /sessions should work even with expired trial
            r = await c.get("/api/sessions/", headers={"Authorization": f"Bearer {token}"})
            assert r.status_code == 200

    async def test_write_passes_during_trial(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "gate_trial")
            token = auth["access_token"]

            # POST a session — should succeed while trial is active
            r = await c.post(
                "/api/sessions/",
                json={"name": "trial-test", "date": "2026-04-20"},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code == 201, r.text

    async def test_write_blocked_when_trial_expired(self, db):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "gate_expired")
            # Expire trial
            result = await db.execute(select(User).where(User.username == "gate_expired"))
            user = result.scalar_one()
            user.trial_ends_at = datetime.utcnow() - timedelta(days=1)
            await db.commit()

            token = auth["access_token"]
            r = await c.post(
                "/api/sessions/",
                json={"name": "expired-test", "date": "2026-04-20"},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code == 402, r.text
            body = r.json()
            assert body["detail"]["reason"] == "subscription_required"
            assert body["detail"]["trial_ended"] is True
            assert "pricing" in body["detail"]["checkout_url"]

    async def test_write_passes_with_active_subscription(self, db):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "gate_sub")
            result = await db.execute(select(User).where(User.username == "gate_sub"))
            user = result.scalar_one()
            # Expire trial but activate subscription
            user.trial_ends_at = datetime.utcnow() - timedelta(days=1)
            user.subscription_status = "active"
            user.subscription_current_period_end = datetime.utcnow() + timedelta(days=30)
            await db.commit()

            token = auth["access_token"]
            r = await c.post(
                "/api/sessions/",
                json={"name": "sub-test", "date": "2026-04-20"},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code == 201, r.text

    async def test_missing_token_returns_401_not_402(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            r = await c.post(
                "/api/sessions/",
                json={"name": "unauth-test", "date": "2026-04-20"},
            )
            # 401 from the endpoint's own auth layer, not 402 from the gate
            assert r.status_code == 401

    async def test_auth_endpoints_not_gated(self, db):
        """Login/register/refresh must always work even with expired trial."""
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "gate_auth")
            # Expire trial
            result = await db.execute(select(User).where(User.username == "gate_auth"))
            user = result.scalar_one()
            user.trial_ends_at = datetime.utcnow() - timedelta(days=1)
            await db.commit()

            # Login should still work
            r = await c.post(
                "/api/auth/login",
                json={"username": "gate_auth", "password": "testpass123"},
            )
            assert r.status_code == 200

    async def test_billing_endpoints_not_gated(self, db):
        """Without billing access, the /api/billing/* routes must not return 402
        (that would be circular — user can't subscribe if gated from subscribing)."""
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "gate_billing")
            result = await db.execute(select(User).where(User.username == "gate_billing"))
            user = result.scalar_one()
            user.trial_ends_at = datetime.utcnow() - timedelta(days=1)
            await db.commit()

            token = auth["access_token"]
            # POST /api/billing/checkout — expect 503 (stripe not configured)
            # but NOT 402.
            r = await c.post(
                "/api/billing/checkout",
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code != 402, "Billing endpoints must not be gated"
