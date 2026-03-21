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

    # External APIs
    usda_api_key: str = "DEMO_KEY"

    # Database
    database_url: str = "sqlite+aiosqlite:///./homegym.db"
    database_sync_url: str = "sqlite:///./homegym.db"
    # For PostgreSQL, use:
    # database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/homegym"
    # database_sync_url: str = "postgresql://postgres:postgres@localhost:5432/homegym"



@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()