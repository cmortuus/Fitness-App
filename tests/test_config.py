"""Tests for app.config — JWT secret validation and CORS parsing."""
import pytest
from pydantic import ValidationError

from app.config import Settings


def _mk_settings(**overrides) -> Settings:
    """Build a Settings with a valid base, allowing overrides for the test."""
    base = {
        "jwt_secret_key": "x" * 48,
        "database_url": "postgresql+asyncpg://u:p@h:5432/d",
        "database_sync_url": "postgresql://u:p@h:5432/d",
    }
    base.update(overrides)
    return Settings(**base)


class TestJwtSecretValidation:
    def test_accepts_long_random_secret(self):
        s = _mk_settings(jwt_secret_key="a" * 48)
        assert s.jwt_secret_key == "a" * 48

    def test_rejects_placeholder(self):
        with pytest.raises(ValidationError) as exc:
            _mk_settings(jwt_secret_key="change-me-in-production-use-a-random-64-char-string")
        assert "placeholder" in str(exc.value).lower()

    def test_rejects_short_secret(self):
        with pytest.raises(ValidationError) as exc:
            _mk_settings(jwt_secret_key="short")
        assert "32 characters" in str(exc.value)

    def test_rejects_empty_secret(self):
        with pytest.raises(ValidationError) as exc:
            _mk_settings(jwt_secret_key="")
        assert "placeholder" in str(exc.value).lower()


class TestCorsOriginsList:
    def test_default_localhost(self):
        s = _mk_settings()
        assert s.cors_origins_list == [
            "http://localhost:5173",
            "http://localhost:3000",
        ]

    def test_single_origin(self):
        s = _mk_settings(cors_allowed_origins="https://lethal.dev")
        assert s.cors_origins_list == ["https://lethal.dev"]

    def test_comma_separated_origins(self):
        s = _mk_settings(
            cors_allowed_origins="https://lethal.dev, https://www.lethal.dev"
        )
        assert s.cors_origins_list == [
            "https://lethal.dev",
            "https://www.lethal.dev",
        ]

    def test_strips_empty_entries(self):
        s = _mk_settings(cors_allowed_origins="https://a.com,,https://b.com,")
        assert s.cors_origins_list == ["https://a.com", "https://b.com"]
