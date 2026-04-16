"""Authentication service — password hashing and JWT token management."""

from datetime import datetime, timedelta, timezone

import bcrypt
import jwt

from app.config import get_settings

settings = get_settings()


# ── Password hashing ─────────────────────────────────────────────────────────

def hash_password(password: str) -> str:
    """Hash a plaintext password using bcrypt."""
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(password: str, hashed: str) -> bool:
    """Verify a plaintext password against a bcrypt hash."""
    return bcrypt.checkpw(password.encode(), hashed.encode())


# ── JWT tokens ────────────────────────────────────────────────────────────────

def create_access_token(user_id: int, username: str) -> str:
    """Create a short-lived access token."""
    payload = {
        "sub": str(user_id),
        "username": username,
        "type": "access",
        "exp": datetime.now(timezone.utc) + timedelta(minutes=settings.jwt_access_expire_minutes),
        "iat": datetime.now(timezone.utc),
    }
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def create_refresh_token(user_id: int) -> str:
    """Create a long-lived refresh token."""
    payload = {
        "sub": str(user_id),
        "type": "refresh",
        "exp": datetime.now(timezone.utc) + timedelta(days=settings.jwt_refresh_expire_days),
        "iat": datetime.now(timezone.utc),
    }
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def decode_token(token: str) -> dict:
    """Decode and validate a JWT token. Raises jwt.InvalidTokenError on failure."""
    return jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])


# ── Purpose-scoped tokens (email verify, password reset) ────────────────────
# Separate `type` from access/refresh so a stolen access token can't be
# reused for verification, and vice versa.

def create_purpose_token(user_id: int, purpose: str, *, expires_hours: int = 24) -> str:
    """Create a short-lived JWT for an out-of-band action (email verify, password reset)."""
    payload = {
        "sub": str(user_id),
        "type": "purpose",
        "purpose": purpose,
        "exp": datetime.now(timezone.utc) + timedelta(hours=expires_hours),
        "iat": datetime.now(timezone.utc),
    }
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def decode_purpose_token(token: str, expected_purpose: str) -> int:
    """Decode a purpose token and return the user_id.

    Raises jwt.InvalidTokenError (or a subclass) on any failure, including
    wrong type or wrong purpose.
    """
    payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
    if payload.get("type") != "purpose" or payload.get("purpose") != expected_purpose:
        raise jwt.InvalidTokenError("Token purpose mismatch")
    return int(payload["sub"])
