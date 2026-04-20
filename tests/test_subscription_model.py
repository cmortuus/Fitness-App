"""Tests for the subscription data model (#869).

Covers:
- new users get trial_ends_at set 30 days out on register
- /me returns subscription_status, trial_ends_at, has_access
- has_access computation matches trial + subscription_status logic
- stripe_events table exists and enforces event_id uniqueness
"""
from datetime import datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.main import app
from app.models.stripe_event import StripeEvent
from app.models.user import User

pytestmark = pytest.mark.asyncio(loop_scope="function")


async def _register(c: AsyncClient, username: str) -> dict:
    r = await c.post(
        "/api/auth/register",
        json={"username": username, "email": f"{username}@test.com", "password": "testpass123"},
    )
    assert r.status_code == 201, r.text
    return r.json()


class TestTrialInitialization:
    async def test_new_user_gets_30_day_trial(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "trial_user")
            user = auth["user"]
            assert user["trial_ends_at"] is not None
            assert user["subscription_status"] is None
            assert user["has_access"] is True
            # Parse ISO and confirm it's ~30 days out (tolerate a day of slop)
            trial = datetime.fromisoformat(user["trial_ends_at"])
            expected = datetime.utcnow() + timedelta(days=30)
            delta = abs((trial - expected).total_seconds())
            assert delta < 60 * 60 * 24, f"trial_ends_at off by {delta}s"


class TestHasAccess:
    async def test_has_access_during_trial(self):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "access_user")
            token = auth["access_token"]
            r = await c.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
            assert r.status_code == 200
            assert r.json()["has_access"] is True

    async def test_no_access_when_trial_expired_and_no_subscription(self, db):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "expired_user")
            # Force-expire the trial
            result = await db.execute(select(User).where(User.username == "expired_user"))
            user = result.scalar_one()
            user.trial_ends_at = datetime.utcnow() - timedelta(days=1)
            await db.commit()

            token = auth["access_token"]
            r = await c.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
            assert r.json()["has_access"] is False

    async def test_has_access_when_subscription_active(self, db):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            auth = await _register(c, "sub_user")
            result = await db.execute(select(User).where(User.username == "sub_user"))
            user = result.scalar_one()
            # Expire trial but activate subscription
            user.trial_ends_at = datetime.utcnow() - timedelta(days=1)
            user.subscription_status = "active"
            user.subscription_current_period_end = datetime.utcnow() + timedelta(days=30)
            await db.commit()

            token = auth["access_token"]
            r = await c.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
            assert r.json()["has_access"] is True
            assert r.json()["subscription_status"] == "active"


class TestStripeEventsTable:
    async def test_stripe_events_enforces_event_id_uniqueness(self, db):
        db.add(StripeEvent(event_id="evt_dup_123", event_type="test", payload_json="{}"))
        await db.commit()

        db.add(StripeEvent(event_id="evt_dup_123", event_type="test", payload_json="{}"))
        with pytest.raises(Exception):
            await db.commit()
        await db.rollback()

    async def test_stripe_events_can_be_inserted_and_queried(self, db):
        db.add(StripeEvent(
            event_id="evt_unique_456",
            event_type="customer.subscription.created",
            payload_json='{"hello":"world"}',
        ))
        await db.commit()

        result = await db.execute(
            select(StripeEvent).where(StripeEvent.event_id == "evt_unique_456")
        )
        row = result.scalar_one()
        assert row.event_type == "customer.subscription.created"
        assert row.processed_at is None
