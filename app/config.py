"""Application configuration using pydantic-settings."""

from functools import lru_cache
from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


# Known-bad placeholder values that must never reach production.  Guard
# against misconfiguration by refusing to boot with these.
_PLACEHOLDER_JWT_SECRETS = {
    "change-me-in-production-use-a-random-64-char-string",
    "change-me-use-a-random-64-char-string",
    "change-me",
    "",
}


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Application
    app_name: str = "Onyx"
    app_version: str = "0.1.0"
    debug: bool = False
    environment: Literal["development", "production"] = "development"

    # Auth / JWT — secret is REQUIRED (no fallback).  App refuses to boot
    # without a real JWT_SECRET_KEY in the environment.
    jwt_secret_key: str
    jwt_algorithm: str = "HS256"
    jwt_access_expire_minutes: int = 30
    jwt_refresh_expire_days: int = 7

    # External APIs
    usda_api_key: str = "DEMO_KEY"
    calorieninjas_api_key: str = ""

    # Database (PostgreSQL)
    database_url: str = "postgresql+asyncpg://homegym:homegym_secret@localhost:5432/homegym"
    database_sync_url: str = "postgresql://homegym:homegym_secret@localhost:5432/homegym"

    # CORS — comma-separated list of allowed origins for the frontend.
    # Defaults are localhost for dev; production must set this via env.
    cors_allowed_origins: str = "http://localhost:5173,http://localhost:3000"

    @field_validator("jwt_secret_key")
    @classmethod
    def _validate_jwt_secret(cls, v: str) -> str:
        if v.strip() in _PLACEHOLDER_JWT_SECRETS:
            raise ValueError(
                "JWT_SECRET_KEY is a placeholder value. Set JWT_SECRET_KEY "
                "to a random 64+ character string in your environment."
            )
        if len(v) < 32:
            raise ValueError(
                "JWT_SECRET_KEY must be at least 32 characters long."
            )
        return v

    @property
    def cors_origins_list(self) -> list[str]:
        """Parsed list of CORS origins."""
        return [o.strip() for o in self.cors_allowed_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()