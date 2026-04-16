"""Application configuration using pydantic-settings."""

from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Application
    app_name: str = "Home Gym Tracker"
    app_version: str = "0.1.0"
    debug: bool = False
    environment: Literal["development", "production"] = "development"

    # Auth / JWT
    jwt_secret_key: str = "change-me-in-production-use-a-random-64-char-string"
    jwt_algorithm: str = "HS256"
    jwt_access_expire_minutes: int = 30
    jwt_refresh_expire_days: int = 7

    # External APIs
    usda_api_key: str = "DEMO_KEY"
    calorieninjas_api_key: str = ""

    # Email (Resend) — no-op if unset; verification/reset emails still issue
    # tokens and log a warning in dev/CI.
    resend_api_key: str = ""
    email_from: str = "Onyx <noreply@lethal.dev>"

    # Public base URL — used to build links in emails (e.g. verify email).
    public_app_url: str = "http://localhost:5173"

    # Database (PostgreSQL)
    database_url: str = "postgresql+asyncpg://homegym:homegym_secret@localhost:5432/homegym"
    database_sync_url: str = "postgresql://homegym:homegym_secret@localhost:5432/homegym"



@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()