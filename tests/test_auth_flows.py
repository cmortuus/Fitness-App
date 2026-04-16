"""Tests for the new auth flows — email verification + password reset.

These cover:
- signup requires email
- verify-email consumes a valid token and sets email_verified_at
- verify-email rejects bad/expired tokens
- request-password-reset always 200s (no user enumeration)
- reset-password rotates the password
"""
import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.services.auth import create_purpose_token

pytestmark = pytest.mark.asyncio(loop_scope="function")


async def _client() -> AsyncClient:
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


class TestRegisterRequiresEmail:
    async def test_register_without_email_rejected(self):
        async with await _client() as c:
            r = await c.post(
                "/api/auth/register",
                json={"username": "no_email_user", "password": "testpass123"},
            )
            assert r.status_code == 422, r.text

    async def test_register_with_invalid_email_rejected(self):
        async with await _client() as c:
            r = await c.post(
                "/api/auth/register",
                json={"username": "bad_email_user", "email": "not-an-email", "password": "testpass123"},
            )
            assert r.status_code == 422, r.text

    async def test_register_duplicate_email_rejected(self):
        async with await _client() as c:
            r1 = await c.post(
                "/api/auth/register",
                json={"username": "dup_a", "email": "dup@test.com", "password": "testpass123"},
            )
            assert r1.status_code == 201, r1.text
            r2 = await c.post(
                "/api/auth/register",
                json={"username": "dup_b", "email": "dup@test.com", "password": "testpass123"},
            )
            assert r2.status_code == 409, r2.text


class TestVerifyEmail:
    async def test_verify_email_with_valid_token(self):
        async with await _client() as c:
            r = await c.post(
                "/api/auth/register",
                json={"username": "verifier", "email": "verify@test.com", "password": "testpass123"},
            )
            assert r.status_code == 201
            user_id = r.json()["user"]["id"]
            assert r.json()["user"]["email_verified"] is False

            token = create_purpose_token(user_id, "email_verification")
            r2 = await c.post("/api/auth/verify-email", json={"token": token})
            assert r2.status_code == 200, r2.text
            assert r2.json()["verified"] is True

            # Subsequent /me should show verified
            access = r.json()["access_token"]
            r3 = await c.get("/api/auth/me", headers={"Authorization": f"Bearer {access}"})
            assert r3.json()["email_verified"] is True

    async def test_verify_email_with_wrong_purpose_rejected(self):
        async with await _client() as c:
            r = await c.post(
                "/api/auth/register",
                json={"username": "wrong_purpose", "email": "wp@test.com", "password": "testpass123"},
            )
            user_id = r.json()["user"]["id"]
            # Wrong purpose
            bad_token = create_purpose_token(user_id, "password_reset")
            r2 = await c.post("/api/auth/verify-email", json={"token": bad_token})
            assert r2.status_code == 400

    async def test_verify_email_with_garbage_token_rejected(self):
        async with await _client() as c:
            r = await c.post("/api/auth/verify-email", json={"token": "not-a-jwt"})
            assert r.status_code == 400


class TestPasswordReset:
    async def test_request_reset_returns_ok_even_for_unknown_email(self):
        """Must not leak which emails have accounts."""
        async with await _client() as c:
            r = await c.post(
                "/api/auth/request-password-reset",
                json={"email": "nobody@test.com"},
            )
            assert r.status_code == 200
            assert r.json()["status"] == "sent"

    async def test_full_reset_flow(self):
        async with await _client() as c:
            # Register
            r = await c.post(
                "/api/auth/register",
                json={"username": "reset_user", "email": "reset@test.com", "password": "oldpass123"},
            )
            assert r.status_code == 201
            user_id = r.json()["user"]["id"]

            # Request reset (200 regardless)
            r2 = await c.post(
                "/api/auth/request-password-reset",
                json={"email": "reset@test.com"},
            )
            assert r2.status_code == 200

            # Simulate the email link's token
            token = create_purpose_token(user_id, "password_reset", expires_hours=1)
            r3 = await c.post(
                "/api/auth/reset-password",
                json={"token": token, "new_password": "newpass456"},
            )
            assert r3.status_code == 200, r3.text

            # Old password rejected
            r4 = await c.post(
                "/api/auth/login",
                json={"username": "reset_user", "password": "oldpass123"},
            )
            assert r4.status_code == 401

            # New password works
            r5 = await c.post(
                "/api/auth/login",
                json={"username": "reset_user", "password": "newpass456"},
            )
            assert r5.status_code == 200

    async def test_reset_with_wrong_purpose_token_rejected(self):
        async with await _client() as c:
            r = await c.post(
                "/api/auth/register",
                json={"username": "rpw_user", "email": "rpw@test.com", "password": "testpass123"},
            )
            user_id = r.json()["user"]["id"]
            # email_verification token used for reset — should fail
            bad_token = create_purpose_token(user_id, "email_verification")
            r2 = await c.post(
                "/api/auth/reset-password",
                json={"token": bad_token, "new_password": "whatever"},
            )
            assert r2.status_code == 422 or r2.status_code == 400
