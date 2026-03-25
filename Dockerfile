# ── Stage 1: Build frontend ──────────────────────────────────────────────────
FROM node:20-alpine AS frontend-build

WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --ignore-scripts

COPY frontend/ ./
RUN npm run build

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM python:3.11-slim

# Install nginx and curl (for health checks)
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx curl && \
    rm -rf /var/lib/apt/lists/*

# Install Node.js (needed for adapter-node runtime)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Python dependencies (cached unless requirements.txt changes)
COPY requirements.txt pyproject.toml ./
RUN pip install --no-cache-dir -r requirements.txt

# Frontend runtime deps (cached unless package.json/lock changes)
COPY frontend/package.json frontend/package-lock.json ./frontend/
RUN cd frontend && npm ci --omit=dev --ignore-scripts

# Rarely changing config files (cached)
COPY alembic.ini ./
COPY nginx/container.conf /etc/nginx/sites-available/default
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Code that changes frequently (last = minimal cache busting)
COPY app/ ./app/
COPY alembic/ ./alembic/
COPY scripts/ ./scripts/
COPY --from=frontend-build /app/frontend/build ./frontend/build

# Data directory for SQLite
RUN mkdir -p /app/data

EXPOSE 80

CMD ["./docker-entrypoint.sh"]
