"""Subscription access gate.

A user has access if:
- their 30-day trial is still active, OR
- their Stripe subscription is in a usable state (trialing or active)

`require_access_for_writes` is the primary FastAPI dependency: applied
at the router level, it's a no-op on GET/HEAD/OPTIONS and raises HTTP
402 on writes for lapsed accounts.
"""
from __future__ import annotations

from datetime import datetime
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.database import get_db
from app.models.user import User
from app.services.auth import decode_token

# Subscription statuses that grant access (from Stripe webhooks).
_ACTIVE_STATUSES = {"trialing", "active"}

# HTTP methods we gate.  Reads always pass through.
_WRITE_METHODS = {"POST", "PATCH", "PUT", "DELETE"}


def has_access(user: User) -> bool:
    """True if the user may perform write actions."""
    now = datetime.utcnow()
    if user.trial_ends_at and user.trial_ends_at > now:
        return True
    if user.subscription_status in _ACTIVE_STATUSES:
        # Honor the current period end if we have it — Stripe might have
        # sent a canceled status but left the period running.
        if user.subscription_current_period_end and user.subscription_current_period_end <= now:
            return False
        return True
    return False


def _checkout_url() -> str:
    """Frontend URL the 402 response points at."""
    settings = get_settings()
    return f"{settings.public_app_url.rstrip('/')}/pricing"


async def require_access_for_writes(
    request: Request,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Router-level dependency — 402s on write methods when access lapsed.

    No-op on GET/HEAD/OPTIONS regardless of subscription state (users can
    always view and export their own data).  Auth is NOT enforced here —
    the endpoint's own `get_current_user` handles missing/invalid tokens.
    """
    if request.method not in _WRITE_METHODS:
        return

    auth_header = request.headers.get("authorization", "")
    if not auth_header.lower().startswith("bearer "):
        # No token — let the endpoint's own auth dep return 401.
        return

    token = auth_header[7:].strip()
    try:
        payload = decode_token(token)
    except jwt.InvalidTokenError:
        return
    if payload.get("type") != "access":
        return

    try:
        user_id = int(payload["sub"])
    except (KeyError, ValueError, TypeError):
        return

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        return

    if has_access(user):
        return

    raise HTTPException(
        status_code=status.HTTP_402_PAYMENT_REQUIRED,
        detail={
            "reason": "subscription_required",
            "trial_ended": user.trial_ends_at is not None
            and user.trial_ends_at <= datetime.utcnow(),
            "checkout_url": _checkout_url(),
        },
    )
