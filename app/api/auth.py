"""Authentication API — register, login, refresh, current user, and settings."""

import json
import logging
from datetime import UTC, datetime
from typing import Annotated

logger = logging.getLogger(__name__)

import jwt
from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings as get_app_settings
from app.database import get_db
from app.models.user import User
from app.services.auth import (
    create_access_token,
    create_purpose_token,
    create_refresh_token,
    decode_purpose_token,
    decode_token,
    hash_password,
    verify_password,
)
from app.services.email import (
    password_reset_html,
    send_email,
    verification_email_html,
)

logger = logging.getLogger(__name__)

router = APIRouter()
security = HTTPBearer(auto_error=False)


# ── Schemas ───────────────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    username: str = Field(min_length=1)
    email: EmailStr
    password: str = Field(min_length=6)


class LoginRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user: dict


class RefreshRequest(BaseModel):
    refresh_token: str


class VerifyEmailRequest(BaseModel):
    token: str


class RequestPasswordResetRequest(BaseModel):
    email: EmailStr


class ResetPasswordRequest(BaseModel):
    token: str
    new_password: str = Field(min_length=6)


# ── Current user dependency ───────────────────────────────────────────────────

async def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> User:
    """Extract and validate the current user from the Authorization header."""
    if not credentials:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")

    try:
        payload = decode_token(credentials.credentials)
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

    if payload.get("type") != "access":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token type")

    user_id = int(payload["sub"])
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    return user


async def get_optional_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> User | None:
    """Like get_current_user but returns None instead of 401 for unauthenticated requests.
    Used during migration period so existing endpoints don't break."""
    if not credentials:
        return None
    try:
        return await get_current_user(credentials, db)
    except HTTPException:
        return None


def serialize_user(user: User) -> dict:
    return {
        "id": user.id,
        "username": user.username,
        "email": user.email,
        "email_verified": user.email_verified_at is not None,
        "created_at": user.created_at.isoformat(),
        # Subscription (#869).  has_access is a convenience for the frontend.
        "subscription_status": user.subscription_status,
        "subscription_current_period_end": (
            user.subscription_current_period_end.isoformat()
            if user.subscription_current_period_end else None
        ),
        "trial_ends_at": user.trial_ends_at.isoformat() if user.trial_ends_at else None,
        "has_access": _user_has_access(user),
    }


async def _send_verification_email(user: User) -> None:
    """Issue a fresh verification token and email the link to the user.
    Safe to call without RESEND_API_KEY — logs a warning and returns.
    """
    settings = get_app_settings()
    token = create_purpose_token(user.id, "email_verification", expires_hours=24)
    verify_url = f"{settings.public_app_url.rstrip('/')}/verify-email?token={token}"
    try:
        await send_email(
            to=user.email,
            subject="Verify your Onyx email",
            html=verification_email_html(user.username, verify_url),
        )
    except Exception:
        logger.exception("Failed to send verification email to %s", user.email)


def _user_has_access(user: User) -> bool:
    """Quick inline check — formalised in app/services/access.py in #871."""
    now = datetime.utcnow()
    if user.trial_ends_at and user.trial_ends_at > now:
        return True
    if user.subscription_status in ("trialing", "active"):
        return True
    return False


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
async def register(
    data: RegisterRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Create a new user account and send a verification email."""
    # Check for duplicate username
    existing = await db.execute(
        select(User).where(User.username == data.username)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Username already taken",
        )

    # Check for duplicate email (emails are now required)
    existing_email = await db.execute(
        select(User).where(User.email == data.email)
    )
    if existing_email.scalar_one_or_none():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email already registered",
        )

    from datetime import timedelta
    user = User(
        username=data.username,
        email=data.email,
        hashed_password=hash_password(data.password),
        # 30-day free trial starts on signup (#869)
        trial_ends_at=datetime.utcnow() + timedelta(days=30),
    )
    db.add(user)
    await db.flush()
    await db.refresh(user)

    # Send verification email (no-op in dev/CI without RESEND_API_KEY)
    await _send_verification_email(user)

    return {
        "access_token": create_access_token(user.id, user.username),
        "refresh_token": create_refresh_token(user.id),
        "token_type": "bearer",
        "user": serialize_user(user),
    }


@router.post("/login", response_model=TokenResponse)
async def login(
    data: LoginRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Authenticate and return tokens."""
    result = await db.execute(select(User).where(User.username == data.username))
    user = result.scalar_one_or_none()

    if not user or not verify_password(data.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password",
        )

    return {
        "access_token": create_access_token(user.id, user.username),
        "refresh_token": create_refresh_token(user.id),
        "token_type": "bearer",
        "user": serialize_user(user),
    }


@router.post("/refresh", response_model=TokenResponse)
async def refresh(
    data: RefreshRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Exchange a refresh token for new access + refresh tokens."""
    try:
        payload = decode_token(data.refresh_token)
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")

    if payload.get("type") != "refresh":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token type")

    user_id = int(payload["sub"])
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")

    return {
        "access_token": create_access_token(user.id, user.username),
        "refresh_token": create_refresh_token(user.id),
        "token_type": "bearer",
        "user": serialize_user(user),
    }


@router.get("/me")
async def get_me(
    user: Annotated[User, Depends(get_current_user)],
) -> dict:
    """Get the current authenticated user."""
    return serialize_user(user)


@router.get("/settings")
async def get_settings(
    user: Annotated[User, Depends(get_current_user)],
) -> dict:
    """Get the user's app settings from the database."""
    if user.settings_json:
        try:
            return json.loads(user.settings_json)
        except json.JSONDecodeError:
            return {}
    return {}


@router.put("/settings")
async def save_settings(
    request: Request,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Save the user's app settings to the database."""
    body = await request.json()
    incoming_meta = body.get("settingsMeta") if isinstance(body.get("settingsMeta"), dict) else {}
    source_device = (
        request.headers.get("X-Client-Name")
        or incoming_meta.get("source_device")
        or "web"
    )
    body["settingsMeta"] = {
        "schema_version": 1,
        "updated_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "updated_by": user.username,
        "source_device": source_device,
    }
    user.settings_json = json.dumps(body)
    await db.flush()
    return body


# ── Email verification ───────────────────────────────────────────────────────

@router.post("/verify-email")
async def verify_email(
    data: VerifyEmailRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Consume a verification token and mark the user's email verified."""
    try:
        user_id = decode_purpose_token(data.token, "email_verification")
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Verification link expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid verification link")

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="User not found")

    if user.email_verified_at is None:
        user.email_verified_at = datetime.utcnow()
        await db.flush()

    return {"verified": True, "email": user.email}


@router.post("/resend-verification")
async def resend_verification(
    user: Annotated[User, Depends(get_current_user)],
) -> dict:
    """Resend the verification email to the current user."""
    if user.email_verified_at is not None:
        return {"status": "already_verified"}
    await _send_verification_email(user)
    return {"status": "sent"}


# ── Password reset ───────────────────────────────────────────────────────────

@router.post("/request-password-reset")
async def request_password_reset(
    data: RequestPasswordResetRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Issue a reset token and email it.  Always returns 200 even if the
    email isn't registered, to avoid leaking which emails have accounts.
    """
    result = await db.execute(select(User).where(User.email == data.email))
    user = result.scalar_one_or_none()
    if user:
        settings = get_app_settings()
        token = create_purpose_token(user.id, "password_reset", expires_hours=1)
        reset_url = f"{settings.public_app_url.rstrip('/')}/reset-password?token={token}"
        try:
            await send_email(
                to=user.email,
                subject="Reset your Onyx password",
                html=password_reset_html(user.username, reset_url),
            )
        except Exception:
            logger.exception("Failed to send password reset email to %s", user.email)
    return {"status": "sent"}


@router.post("/reset-password")
async def reset_password(
    data: ResetPasswordRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Consume a password-reset token and update the password."""
    try:
        user_id = decode_purpose_token(data.token, "password_reset")
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Reset link expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid reset link")

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="User not found")

    user.hashed_password = hash_password(data.new_password)
    await db.flush()
    return {"status": "reset"}


# ── Account controls (#875) ──────────────────────────────────────────────────

class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str = Field(min_length=6)


class ChangeEmailRequest(BaseModel):
    current_password: str
    new_email: str = Field(min_length=3)


@router.post("/change-password")
async def change_password(
    data: ChangePasswordRequest,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Rotate password. Requires the current password."""
    if not verify_password(data.current_password, user.hashed_password):
        raise HTTPException(status_code=401, detail="Current password is incorrect")
    user.hashed_password = hash_password(data.new_password)
    await db.flush()
    return {"status": "ok"}


@router.post("/change-email")
async def change_email(
    data: ChangeEmailRequest,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Update email.  Requires current password.  Email is persisted
    immediately.  If #885 (email verification) is in place, the new email
    will be unverified until the user confirms via the emailed link."""
    if not verify_password(data.current_password, user.hashed_password):
        raise HTTPException(status_code=401, detail="Current password is incorrect")

    # Duplicate check
    result = await db.execute(
        select(User).where(User.email == data.new_email).where(User.id != user.id)
    )
    if result.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Email already in use")

    user.email = data.new_email
    # If an email_verified_at column exists (added in #885), clear it so
    # the user must re-verify.  Use getattr to tolerate branches where the
    # column isn't present yet.
    if hasattr(user, "email_verified_at"):
        setattr(user, "email_verified_at", None)
    await db.flush()
    return {"status": "ok", "email": user.email}


@router.delete("/account")
async def delete_account(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Delete the account.  Cancels the Stripe subscription (if any) and
    cascade-deletes all user-owned data (workout plans, sessions, exercises,
    nutrition entries, etc.) via the existing SQLAlchemy relationships."""
    # Best-effort Stripe cancellation — don't block deletion if Stripe errors
    if user.stripe_customer_id:
        try:
            from app.api.billing import _stripe  # lazy import
            stripe = _stripe()
            if stripe is not None:
                subs = stripe.Subscription.list(customer=user.stripe_customer_id, status="all", limit=10)
                for sub in subs.auto_paging_iter():
                    if sub.status not in ("canceled", "incomplete_expired"):
                        stripe.Subscription.delete(sub.id)
        except Exception as exc:  # pragma: no cover
            logger.warning("Stripe cancel during delete failed for user %s: %s", user.id, exc)

    await db.delete(user)
    await db.flush()
    return {"status": "deleted"}


@router.get("/export")
async def export_user_data(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Return a full JSON dump of the user's data (GDPR-safe export).

    Pulls from the ORM rather than joining DB-side so the shape is stable
    and the response body is streamable by FastAPI.
    """
    from app.models.body_weight import BodyWeightEntry
    from app.models.nutrition import NutritionEntry
    from app.models.workout import ExerciseSet, WorkoutPlan, WorkoutSession

    async def dump(model_cls, where):
        result = await db.execute(select(model_cls).where(where))
        rows = result.scalars().all()
        out = []
        for row in rows:
            item = {c.name: getattr(row, c.name) for c in model_cls.__table__.columns}
            # ISO-format timestamps; the default JSON encoder can't handle
            # datetimes and some session fields hold bytes/Decimal too.
            for k, v in list(item.items()):
                if isinstance(v, datetime):
                    item[k] = v.isoformat()
                elif isinstance(v, bytes):
                    item[k] = v.decode(errors="replace")
            out.append(item)
        return out

    payload = {
        "exported_at": datetime.utcnow().isoformat() + "Z",
        "user": {
            "id": user.id,
            "username": user.username,
            "email": user.email,
            "created_at": user.created_at.isoformat(),
        },
        "settings": json.loads(user.settings_json) if user.settings_json else {},
        "workout_plans": await dump(WorkoutPlan, WorkoutPlan.user_id == user.id),
        "workout_sessions": await dump(WorkoutSession, WorkoutSession.user_id == user.id),
        "exercise_sets": await dump(
            ExerciseSet,
            ExerciseSet.workout_session_id.in_(
                select(WorkoutSession.id).where(WorkoutSession.user_id == user.id)
            ),
        ),
        "body_weight_entries": await dump(BodyWeightEntry, BodyWeightEntry.user_id == user.id),
        "nutrition_entries": await dump(NutritionEntry, NutritionEntry.user_id == user.id),
    }
    return payload
