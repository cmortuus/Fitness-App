#!/bin/bash
set -e

echo "[entrypoint] Running database migrations..."
DATABASE_URL="${DATABASE_URL:-sqlite+aiosqlite:///./data/homegym.db}" \
DATABASE_SYNC_URL="${DATABASE_SYNC_URL:-sqlite:///./data/homegym.db}" \
alembic upgrade head || echo "[entrypoint] Migration warning (may be first run)"

echo "[entrypoint] Starting backend..."
DATABASE_URL="${DATABASE_URL:-sqlite+aiosqlite:///./data/homegym.db}" \
DATABASE_SYNC_URL="${DATABASE_SYNC_URL:-sqlite:///./data/homegym.db}" \
uvicorn app.main:app --host 0.0.0.0 --port 8000 &

echo "[entrypoint] Starting frontend..."
cd /app/frontend
PORT=3000 node build/index.js &
cd /app

echo "[entrypoint] Starting nginx..."
nginx -g 'daemon off;'
