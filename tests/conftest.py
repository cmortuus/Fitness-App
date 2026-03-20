"""Shared test fixtures."""
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.main import app
from app.database import Base, get_db

# Use a named shared-cache in-memory SQLite database for tests.
# The URI "file:testdb?mode=memory&cache=shared" allows multiple aiosqlite
# connections to share the same in-memory database so that tables created
# in setup_db are visible to subsequent sessions/requests.
TEST_DATABASE_URL = (
    "sqlite+aiosqlite:///file:testmemdb?mode=memory&cache=shared&uri=true"
)

test_engine = create_async_engine(TEST_DATABASE_URL, echo=False)
TestSessionFactory = async_sessionmaker(
    test_engine, class_=AsyncSession, expire_on_commit=False, autoflush=False
)


async def override_get_db():
    async with TestSessionFactory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


app.dependency_overrides[get_db] = override_get_db


@pytest_asyncio.fixture(autouse=True)
async def setup_db():
    """Create all tables before each test, drop after."""
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@pytest_asyncio.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture
async def db():
    async with TestSessionFactory() as session:
        yield session


# ── Helpers ───────────────────────────────────────────────────────────────────

async def create_exercise(client: AsyncClient, **kwargs) -> dict:
    defaults = dict(
        name="bench_press",
        display_name="Bench Press",
        movement_type="compound",
        body_region="upper",
        is_unilateral=False,
        is_assisted=False,
        primary_muscles=["chest"],
        secondary_muscles=["triceps"],
    )
    defaults.update(kwargs)
    r = await client.post("/api/exercises/", json=defaults)
    assert r.status_code == 201, r.text
    return r.json()


async def create_plan(client: AsyncClient, exercise_id: int, sets: int = 3,
                       reps: int = 8, name: str = "Test Plan") -> dict:
    body = {
        "name": name,
        "block_type": "hypertrophy",
        "duration_weeks": 4,
        "number_of_days": 1,
        "days": [
            {
                "day_number": 1,
                "day_name": "Day 1",
                "exercises": [
                    {
                        "exercise_id": exercise_id,
                        "sets": sets,
                        "reps": reps,
                        "starting_weight_kg": 0,
                        "progression_type": "linear",
                    }
                ],
            }
        ],
    }
    r = await client.post("/api/plans/", json=body)
    assert r.status_code == 201, r.text
    return r.json()


async def start_session_from_plan(client: AsyncClient, plan_id: int,
                                   day: int = 1, body_weight_kg: float = 0) -> dict:
    # Complete any in-progress session before creating a new one (mirrors real workflow)
    r_list = await client.get("/api/sessions/", params={"limit": 500})
    assert r_list.status_code == 200, r_list.text
    for s in r_list.json():
        if s.get("status") == "in_progress":
            rc = await client.post(f"/api/sessions/{s['id']}/complete")
            assert rc.status_code == 200, rc.text

    r = await client.post(
        f"/api/sessions/from-plan/{plan_id}",
        params={"day_number": day, "overload_style": "rep", "body_weight_kg": body_weight_kg},
    )
    assert r.status_code == 201, r.text
    sess = r.json()
    r2 = await client.post(f"/api/sessions/{sess['id']}/start")
    assert r2.status_code == 200, r2.text
    return r2.json()


async def log_set(client: AsyncClient, session_id: int, set_id: int,
                   actual_weight_kg: float, actual_reps: int) -> dict:
    r = await client.patch(
        f"/api/sessions/{session_id}/sets/{set_id}",
        json={
            "actual_weight_kg": actual_weight_kg,
            "actual_reps": actual_reps,
            "completed_at": "2024-01-01T10:00:00",
        },
    )
    assert r.status_code == 200, r.text
    return r.json()
