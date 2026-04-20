"""Billing API — Stripe Checkout, Customer Portal, and webhook handler.

Flow:
- POST /api/billing/checkout → returns a Stripe-hosted checkout URL
- POST /api/billing/portal   → returns a Customer Portal URL (manage subscription)
- POST /api/billing/webhook  → Stripe events land here; updates user state

Webhooks are idempotent: every event is inserted into `stripe_events`
with event_id UNIQUE, so replays are no-ops.

All endpoints safely no-op in dev/CI when STRIPE_SECRET_KEY is unset —
the checkout/portal endpoints return 503 with a clear error so the
frontend can surface "billing not configured" during local testing.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.config import get_settings
from app.database import get_db
from app.models.stripe_event import StripeEvent
from app.models.user import User

logger = logging.getLogger(__name__)
router = APIRouter()


# ── Lazy import of stripe so tests/CI don't force-install it ────────────────
def _stripe():
    """Return the configured stripe SDK, or None if not configured."""
    settings = get_settings()
    if not settings.stripe_secret_key:
        return None
    import stripe  # type: ignore
    stripe.api_key = settings.stripe_secret_key
    return stripe


def _require_stripe():
    s = _stripe()
    if s is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Billing not configured on this server",
        )
    return s


# ── Customer helper ──────────────────────────────────────────────────────────

def _get_or_create_customer(stripe: Any, user: User) -> str:
    """Return the Stripe customer id for this user, creating it if needed.

    We call this synchronously against Stripe; the caller is responsible
    for persisting any newly-minted customer id back to the DB.
    """
    if user.stripe_customer_id:
        return user.stripe_customer_id
    customer = stripe.Customer.create(
        email=user.email,
        name=user.username,
        metadata={"user_id": str(user.id)},
    )
    return customer.id


# ── Endpoints: checkout & portal ─────────────────────────────────────────────

@router.post("/checkout")
async def create_checkout_session(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a Stripe Checkout session and return the URL."""
    stripe = _require_stripe()
    settings = get_settings()
    if not settings.stripe_price_id_yearly:
        raise HTTPException(503, "Billing price not configured")

    customer_id = _get_or_create_customer(stripe, user)
    if not user.stripe_customer_id:
        user.stripe_customer_id = customer_id
        await db.flush()

    base = settings.public_app_url.rstrip("/")
    session = stripe.checkout.Session.create(
        customer=customer_id,
        mode="subscription",
        payment_method_types=["card"],
        line_items=[{"price": settings.stripe_price_id_yearly, "quantity": 1}],
        success_url=f"{base}/settings/billing?status=success",
        cancel_url=f"{base}/pricing?status=canceled",
        allow_promotion_codes=True,
        client_reference_id=str(user.id),
        # Always attach user_id so webhook can always find the user even
        # if customer metadata isn't returned in an event payload.
        metadata={"user_id": str(user.id)},
        subscription_data={"metadata": {"user_id": str(user.id)}},
    )
    return {"url": session.url, "id": session.id}


@router.post("/portal")
async def create_portal_session(
    user: Annotated[User, Depends(get_current_user)],
) -> dict:
    """Create a Stripe Customer Portal session and return the URL."""
    stripe = _require_stripe()
    settings = get_settings()
    if not user.stripe_customer_id:
        raise HTTPException(400, "No Stripe customer for this user")

    portal = stripe.billing_portal.Session.create(
        customer=user.stripe_customer_id,
        return_url=f"{settings.public_app_url.rstrip('/')}/settings/billing",
    )
    return {"url": portal.url}


# ── Endpoint: webhook ────────────────────────────────────────────────────────

# The subset of events we care about.  Others are logged + ignored.
_HANDLED_EVENTS = {
    "customer.subscription.created",
    "customer.subscription.updated",
    "customer.subscription.deleted",
    "invoice.payment_succeeded",
    "invoice.payment_failed",
}


async def _apply_subscription_event(
    db: AsyncSession, event_type: str, obj: dict[str, Any]
) -> None:
    """Sync the User row from a Stripe subscription or invoice payload."""
    # For subscription.* events, obj is the subscription object.
    # For invoice.* events, obj is the invoice object — we pull the customer id.
    customer_id = obj.get("customer")
    if not customer_id:
        logger.warning("stripe webhook %s: no customer id on object", event_type)
        return

    result = await db.execute(
        select(User).where(User.stripe_customer_id == customer_id)
    )
    user = result.scalar_one_or_none()
    if not user:
        # Fallback: try metadata.user_id from the subscription object
        user_id = (obj.get("metadata") or {}).get("user_id")
        if user_id:
            result = await db.execute(select(User).where(User.id == int(user_id)))
            user = result.scalar_one_or_none()
            if user:
                user.stripe_customer_id = customer_id
    if not user:
        logger.warning("stripe webhook %s: no matching user for customer %s", event_type, customer_id)
        return

    if event_type.startswith("customer.subscription."):
        user.subscription_status = obj.get("status")
        cpe = obj.get("current_period_end")
        if cpe:
            user.subscription_current_period_end = datetime.utcfromtimestamp(int(cpe))
        # Deleted: Stripe sends status="canceled"; we honor current_period_end
        # so the user keeps access until their paid period truly ends.


@router.post("/webhook")
async def stripe_webhook(
    request: Request,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Receive Stripe events, dedupe via stripe_events, and update user state."""
    settings = get_settings()
    stripe = _require_stripe()

    if not settings.stripe_webhook_secret:
        raise HTTPException(503, "Webhook secret not configured")

    # Raw payload is needed for signature verification
    body = await request.body()
    sig_header = request.headers.get("stripe-signature", "")
    try:
        event = stripe.Webhook.construct_event(
            body, sig_header, settings.stripe_webhook_secret
        )
    except (ValueError, stripe.error.SignatureVerificationError) as exc:  # type: ignore[attr-defined]
        logger.warning("stripe webhook: bad signature: %s", exc)
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid signature")

    event_id = event["id"]
    event_type = event["type"]

    # Idempotency: insert into stripe_events; if it already exists, return 200.
    db.add(StripeEvent(
        event_id=event_id,
        event_type=event_type,
        payload_json=json.dumps(event, default=str),
    ))
    try:
        await db.flush()
    except Exception:
        # IntegrityError on event_id unique → already processed
        await db.rollback()
        logger.info("stripe webhook: replay of %s ignored", event_id)
        return {"status": "duplicate"}

    if event_type not in _HANDLED_EVENTS:
        logger.info("stripe webhook: ignored %s", event_type)
        # Mark processed so we don't keep the row in a pending state forever
        result = await db.execute(
            select(StripeEvent).where(StripeEvent.event_id == event_id)
        )
        row = result.scalar_one_or_none()
        if row:
            row.processed_at = datetime.utcnow()
        await db.flush()
        return {"status": "ignored"}

    await _apply_subscription_event(db, event_type, event["data"]["object"])

    # Mark processed
    result = await db.execute(
        select(StripeEvent).where(StripeEvent.event_id == event_id)
    )
    row = result.scalar_one_or_none()
    if row:
        row.processed_at = datetime.utcnow()
    await db.flush()

    return {"status": "ok"}
