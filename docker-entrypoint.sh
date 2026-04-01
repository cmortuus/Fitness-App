#!/bin/bash
set -e

echo "[entrypoint] Running database migrations..."
alembic upgrade head || echo "[entrypoint] Migration warning (may be first run)"

echo "[entrypoint] Seeding exercises..."
PYTHONPATH=/app python scripts/seed_all_exercises.py || echo "[entrypoint] Seed warning"

echo "[entrypoint] Seeding common foods..."
PYTHONPATH=/app python scripts/seed_food_db/seed_common.py || echo "[entrypoint] Common food seed warning"

echo "[entrypoint] Starting backend..."
uvicorn app.main:app --host 0.0.0.0 --port 8000 &

echo "[entrypoint] Starting frontend..."
cd /app/frontend
PORT=3000 node build/index.js &
cd /app

echo "[entrypoint] Starting nginx..."
nginx -g 'daemon off;'
