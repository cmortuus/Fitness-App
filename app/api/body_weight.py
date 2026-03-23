"""Body weight weigh-in API endpoints."""

from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.database import get_db
from app.models.body_weight import BodyWeightEntry
from app.models.user import User
from app.schemas.requests import BodyWeightCreate

router = APIRouter()


def serialize_entry(entry: BodyWeightEntry) -> dict:
    d = {
        "id": entry.id,
        "weight_kg": entry.weight_kg,
        "body_fat_pct": entry.body_fat_pct,
        "recorded_at": entry.recorded_at.isoformat(),
        "notes": entry.notes,
    }
    # Derived lean/fat mass when body fat is known
    if entry.body_fat_pct is not None:
        d["fat_mass_kg"] = round(entry.weight_kg * entry.body_fat_pct / 100, 2)
        d["lean_mass_kg"] = round(entry.weight_kg * (1 - entry.body_fat_pct / 100), 2)
    return d


@router.get("/", response_model=list[dict])
async def list_entries(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 50,
) -> list[dict]:
    """Return weigh-in history, most recent first."""
    result = await db.execute(
        select(BodyWeightEntry)
        .where(BodyWeightEntry.user_id == user.id)
        .order_by(desc(BodyWeightEntry.recorded_at))
        .limit(limit)
    )
    return [serialize_entry(e) for e in result.scalars().all()]


@router.get("/latest", response_model=dict)
async def get_latest(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Return the most recent weigh-in, or 404 if none exists."""
    result = await db.execute(
        select(BodyWeightEntry)
        .where(BodyWeightEntry.user_id == user.id)
        .order_by(desc(BodyWeightEntry.recorded_at))
        .limit(1)
    )
    entry = result.scalar_one_or_none()
    if not entry:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No weigh-in entries found")
    return serialize_entry(entry)


@router.post("/", response_model=dict, status_code=status.HTTP_201_CREATED)
async def add_entry(
    data: BodyWeightCreate,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Log a new weigh-in."""
    entry = BodyWeightEntry(
        weight_kg=data.weight_kg,
        body_fat_pct=data.body_fat_pct,
        recorded_at=datetime.fromisoformat(data.recorded_at) if data.recorded_at else datetime.now(timezone.utc),
        notes=data.notes,
        user_id=user.id,
    )
    db.add(entry)
    await db.flush()
    await db.refresh(entry)
    return serialize_entry(entry)


@router.delete("/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_entry(
    entry_id: int,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a weigh-in entry."""
    result = await db.execute(
        select(BodyWeightEntry).where(BodyWeightEntry.id == entry_id, BodyWeightEntry.user_id == user.id)
    )
    entry = result.scalar_one_or_none()
    if not entry:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Entry {entry_id} not found")
    await db.delete(entry)
    await db.flush()
