"""Transactional email via Resend — thin wrapper.

All functions are safe to call without RESEND_API_KEY configured; they
log a warning and silently no-op so dev/CI runs don't explode.
"""
from __future__ import annotations

import logging
from typing import Any

import httpx

from app.config import get_settings

logger = logging.getLogger(__name__)

_RESEND_API_URL = "https://api.resend.com/emails"


async def send_email(
    to: str,
    subject: str,
    html: str,
    *,
    text: str | None = None,
) -> dict[str, Any] | None:
    """Send a transactional email.

    Returns the Resend response on success, or None in dev/CI when
    RESEND_API_KEY isn't configured.
    """
    settings = get_settings()
    if not settings.resend_api_key:
        logger.info("email: RESEND_API_KEY not set — would send '%s' to %s", subject, to)
        return None

    payload: dict[str, Any] = {
        "from": settings.email_from or "Onyx <noreply@lethal.dev>",
        "to": [to],
        "subject": subject,
        "html": html,
    }
    if text:
        payload["text"] = text

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            _RESEND_API_URL,
            headers={
                "Authorization": f"Bearer {settings.resend_api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
        )
    if resp.status_code >= 400:
        logger.error("email: Resend API returned %s: %s", resp.status_code, resp.text)
        return None
    return resp.json()


# ── Templates ────────────────────────────────────────────────────────────────
# Kept inline for MVP simplicity; migrate to files if they grow.

_BASE_STYLE = (
    "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;"
    "color:#111;line-height:1.5;max-width:520px;margin:0 auto;padding:24px"
)
_BTN_STYLE = (
    "display:inline-block;background:#0170B9;color:#fff;text-decoration:none;"
    "padding:12px 24px;border-radius:8px;font-weight:600;margin:16px 0"
)


def verification_email_html(username: str, verify_url: str) -> str:
    return f"""
    <div style="{_BASE_STYLE}">
      <h2>Welcome to Onyx, {username}</h2>
      <p>Click the button below to verify your email and finish setting up your account.</p>
      <p><a href="{verify_url}" style="{_BTN_STYLE}">Verify email</a></p>
      <p style="color:#666;font-size:13px">
        Or paste this link into your browser:<br>
        <code>{verify_url}</code>
      </p>
      <p style="color:#666;font-size:13px">This link expires in 24 hours.</p>
    </div>
    """


def password_reset_html(username: str, reset_url: str) -> str:
    return f"""
    <div style="{_BASE_STYLE}">
      <h2>Reset your Onyx password</h2>
      <p>Hi {username}, someone (hopefully you) asked to reset your password.</p>
      <p><a href="{reset_url}" style="{_BTN_STYLE}">Reset password</a></p>
      <p style="color:#666;font-size:13px">
        Or paste this link into your browser:<br>
        <code>{reset_url}</code>
      </p>
      <p style="color:#666;font-size:13px">
        This link expires in 1 hour.  If you didn't request this, you can ignore this email.
      </p>
    </div>
    """


def trial_ending_html(username: str, days_left: int, subscribe_url: str) -> str:
    return f"""
    <div style="{_BASE_STYLE}">
      <h2>Your Onyx trial ends in {days_left} days</h2>
      <p>Hi {username}, just a heads up — your free trial ends in {days_left} days.</p>
      <p>Subscribe to keep logging:</p>
      <p><a href="{subscribe_url}" style="{_BTN_STYLE}">Subscribe — $30/year</a></p>
      <p style="color:#666;font-size:13px">
        If you don't subscribe, your account stays put (you'll still see your history)
        but new workouts won't save.
      </p>
    </div>
    """
