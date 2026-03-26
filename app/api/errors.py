"""Client error reporting endpoint."""

from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from sqlalchemy import Column, DateTime, Integer, String, Text
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_optional_user
from app.database import Base, get_db
from app.models.user import User


class ClientError(Base):
    """Stores client-side errors reported by the frontend."""
    __tablename__ = "client_errors"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, nullable=True)
    message = Column(Text, nullable=False)
    stack = Column(Text, nullable=True)
    url = Column(String(500), nullable=True)
    user_agent = Column(String(500), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)


class ErrorReport(BaseModel):
    message: str
    stack: str | None = None
    url: str | None = None


router = APIRouter()


@router.post("/", status_code=201)
async def report_error(
    body: ErrorReport,
    request: Request,
    db: Annotated[AsyncSession, Depends(get_db)],
    user: Annotated[User | None, Depends(get_optional_user)],
) -> dict:
    """Log a client-side error."""
    error = ClientError(
        user_id=user.id if user else None,
        message=body.message[:2000],
        stack=body.stack[:5000] if body.stack else None,
        url=body.url[:500] if body.url else None,
        user_agent=str(request.headers.get("user-agent", ""))[:500],
    )
    db.add(error)
    await db.flush()
    return {"id": error.id}


@router.get("/")
async def list_errors(
    user: Annotated[User, Depends(get_optional_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    limit: int = 50,
) -> list[dict]:
    """List recent errors (admin use)."""
    from sqlalchemy import select, desc
    result = await db.execute(
        select(ClientError).order_by(desc(ClientError.created_at)).limit(limit)
    )
    errors = result.scalars().all()
    return [
        {
            "id": e.id,
            "user_id": e.user_id,
            "message": e.message,
            "stack": e.stack,
            "url": e.url,
            "user_agent": e.user_agent,
            "created_at": e.created_at.isoformat() if e.created_at else None,
        }
        for e in errors
    ]
