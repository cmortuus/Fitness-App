"""Body weight weigh-in API endpoints."""

from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.body_weight import BodyWeightEntry
from app.schemas.requests import BodyWeightCreate

router = APIRouter()


def serialize_entry(entry: BodyWeightEntry) -> dict:
    return {
        "id": entry.id,
        "weight_kg": entry.weight_kg,
        "recorded_at": entry.recorded_at.isoformat(),
        "notes": entry.notes,
    }


@router.get("/", response_model=list[dict])
async def list_entries(
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 50,
) -> list[dict]:
    """Return weigh-in history, most recent first."""
    result = await db.execute(
        select(BodyWeightEntry)
        .order_by(desc(BodyWeightEntry.recorded_at))
        .limit(limit)
    )
    return [serialize_entry(e) for e in result.scalars().all()]


@router.get("/latest", response_model=dict | None)
async def get_latest(
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict | None:
    """Return the most recent weigh-in, or null if none exists."""
    result = await db.execute(
        select(BodyWeightEntry)
        .order_by(desc(BodyWeightEntry.recorded_at))
        .limit(1)
    )
    entry = result.scalar_one_or_none()
    return serialize_entry(entry) if entry else None


@router.post("/", response_model=dict, status_code=status.HTTP_201_CREATED)
async def add_entry(
    data: BodyWeightCreate,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict:
    """Log a new weigh-in."""
    if not data.weight_kg or data.weight_kg <= 0:
        raise HTTPException(status_code=400, detail="weight_kg must be a positive number")
    entry = BodyWeightEntry(
        weight_kg=data.weight_kg,
        recorded_at=datetime.fromisoformat(data.recorded_at) if data.recorded_at else datetime.now(timezone.utc),
        notes=data.notes,
    )
    db.add(entry)
    await db.flush()
    await db.refresh(entry)
    return serialize_entry(entry)


@router.delete("/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_entry(
    entry_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Delete a weigh-in entry."""
    result = await db.execute(
        select(BodyWeightEntry).where(BodyWeightEntry.id == entry_id)
    )
    entry = result.scalar_one_or_none()
    if not entry:
        raise HTTPException(status_code=404, detail=f"Entry {entry_id} not found")
    await db.delete(entry)
    await db.flush()
