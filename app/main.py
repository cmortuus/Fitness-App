"""FastAPI application entry point."""

from contextlib import asynccontextmanager
from typing import AsyncGenerator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from fastapi import Depends

from app.api import auth, billing, body_weight, checkin, diet_phase, errors, exercises, insights, nutrition, plans, progress, recipes, sessions, templates, websocket
from app.config import get_settings
from app.database import init_db
from app.services.access import require_access_for_writes

settings = get_settings()

# ── Sentry ──────────────────────────────────────────────────────────────────
# Initialize at import time so startup errors are captured too.  Only
# active when SENTRY_DSN is set — a silent no-op in dev/CI.
if settings.sentry_dsn:
    import sentry_sdk
    from sentry_sdk.integrations.fastapi import FastApiIntegration
    from sentry_sdk.integrations.starlette import StarletteIntegration

    sentry_sdk.init(
        dsn=settings.sentry_dsn,
        environment=settings.sentry_environment or settings.environment,
        release=settings.app_version,
        traces_sample_rate=settings.sentry_traces_sample_rate,
        profiles_sample_rate=0.0,
        send_default_pii=False,
        integrations=[
            StarletteIntegration(transaction_style="endpoint"),
            FastApiIntegration(transaction_style="endpoint"),
        ],
    )


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Application lifespan events."""
    # Startup
    await init_db()
    print(f"🚀 {settings.app_name} v{settings.app_version} started")
    print(f"📊 Database: {settings.database_url.split('@')[-1] if '@' in settings.database_url else 'configured'}")
    yield
    # Shutdown
    pass


app = FastAPI(
    title=settings.app_name,
    version=settings.app_version,
    lifespan=lifespan,
)

# CORS middleware for frontend — origins configurable via CORS_ALLOWED_ORIGINS
# environment variable (comma-separated).  Defaults to localhost for dev.
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Access-gate dependency applied to every gated router.  Only raises 402
# on write methods for users whose trial is expired AND don't have an
# active subscription.  See app/services/access.py.
_GATED = [Depends(require_access_for_writes)]

# Include API routers.  Routers that touch user-owned data are gated by
# the subscription access check (no-op on GET, 402 on write methods when
# trial has lapsed and no active subscription).
app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
app.include_router(sessions.router, prefix="/api/sessions", tags=["sessions"], dependencies=_GATED)
app.include_router(exercises.router, prefix="/api/exercises", tags=["exercises"], dependencies=_GATED)
app.include_router(progress.router, prefix="/api/progress", tags=["progress"])
app.include_router(plans.router, prefix="/api/plans", tags=["plans"], dependencies=_GATED)
app.include_router(body_weight.router, prefix="/api/body-weight", tags=["body-weight"], dependencies=_GATED)
app.include_router(nutrition.router, prefix="/api/nutrition", tags=["nutrition"], dependencies=_GATED)
app.include_router(diet_phase.router, prefix="/api/nutrition/phases", tags=["diet-phases"], dependencies=_GATED)
app.include_router(checkin.router, prefix="/api/nutrition", tags=["checkin"], dependencies=_GATED)
app.include_router(insights.router, prefix="/api/nutrition", tags=["insights"], dependencies=_GATED)
app.include_router(recipes.router, prefix="/api/recipes", tags=["recipes"], dependencies=_GATED)
app.include_router(templates.router, prefix="/api/templates", tags=["templates"])
app.include_router(errors.router, prefix="/api/errors", tags=["errors"])
app.include_router(billing.router, prefix="/api/billing", tags=["billing"])
app.include_router(websocket.router, tags=["websocket"])


@app.get("/")
async def root() -> dict[str, str]:
    """Root endpoint."""
    return {"name": settings.app_name, "version": settings.app_version}


@app.get("/health")
async def health() -> dict[str, str]:
    """Health check endpoint."""
    return {"status": "healthy"}
