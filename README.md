# GymTracker

A full-featured workout and nutrition tracker built as a Progressive Web App. Science-based programming with progressive overload tracking, myo-rep sets, diet phase management, and barcode-based food logging.

**Live at [lethal.dev](https://lethal.dev)**

## Features

### Workout Tracking
- **Workout Plans** — Create multi-day training plans with customizable exercises, sets, and rep ranges
- **Progressive Overload** — Automatic weight/rep progression using Epley 1RM formula (rep-first or weight-first modes)
- **Set Types** — Standard, myo-rep, myo-rep match, and drop sets
- **Unilateral Support** — Separate L/R tracking for single-limb exercises
- **Rest Timer** — Always-visible countdown with adjustable duration per exercise category (upper compound, lower compound, isolation)
- **Plate Calculator** — Visual plate breakdown with real gym colors for barbell and plate-loaded exercises
- **Equipment Types** — Barbell, dumbbell, plate-loaded machines, selectorized machines, cable, bodyweight
- **Exercise Library** — 150+ seeded exercises across all muscle groups and movement types

### Nutrition
- **Barcode Scanning** — Scan food barcodes to auto-fill nutrition data via OpenFoodFacts
- **Label Scanning** — Camera-based nutrition label reader (OCR) for foods not in the database
- **Diet Phases** — Cut, bulk, and maintenance phases with auto-calculated macro targets
- **Daily Tracking** — Log meals with calories, protein, carbs, and fat

### General
- **PWA** — Installable on mobile, works offline
- **JWT Auth** — Secure authentication with access + refresh tokens
- **Body Weight Logging** — Track weight over time
- **Settings** — Configurable units (lbs/kg), rest durations, equipment base weights

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | SvelteKit (Svelte 5), TypeScript, Tailwind CSS, Vite |
| Backend | FastAPI (async), Python 3.11+, SQLAlchemy async ORM |
| Database | SQLite (dev/production), PostgreSQL (supported) |
| Testing | Pytest (backend), Playwright (E2E) |
| CI/CD | GitHub Actions (lint, unit tests, E2E) |
| Deployment | Docker Compose with nginx routing, Let's Encrypt SSL |

## Project Structure

```
app/                    # Backend
├── api/                # FastAPI route handlers
├── models/             # SQLAlchemy ORM models
├── schemas/            # Pydantic request/response schemas
├── services/           # Business logic
├── main.py             # App entrypoint
└── database.py         # DB connection setup

frontend/
├── src/
│   ├── routes/         # SvelteKit pages (workout, nutrition, settings, etc.)
│   ├── lib/
│   │   ├── api.ts      # API client
│   │   ├── stores.ts   # Client-side state (settings, auth)
│   │   ├── actions/    # Svelte actions (swipeable)
│   │   └── components/ # Shared components (PlateVisual)
│   └── app.css         # Global styles
└── tests/e2e/          # Playwright E2E tests

deploy.sh               # Deployment script (bare-metal → Docker migration)
docker-compose.yml      # Main + dev containers with nginx router
Dockerfile              # Multi-stage build (Python + Node)
```

## Local Development

### Prerequisites
- Python 3.11+
- Node.js 18+
- npm

### Setup

```bash
# Backend
python -m venv venv
source venv/bin/activate
pip install -e .
alembic upgrade head

# Frontend
cd frontend
npm ci

# Run both (separate terminals)
uvicorn app.main:app --reload --port 8000
npm run dev
```

The app will be available at `http://localhost:5173` with the API at `http://localhost:8000`.

### Running Tests

```bash
# Backend unit tests
pytest tests/

# Lint
ruff check app/

# E2E tests (starts backend + frontend automatically)
cd frontend
npx playwright test
```

## Deployment

The app deploys via Docker Compose with dual main/dev containers and an nginx router.

### First deploy (migrates from bare-metal to Docker)
```bash
./deploy.sh
```

### Subsequent deploys
```bash
./deploy.sh          # Rebuild both containers
./deploy.sh --watch  # Auto-rebuild when main or dev branches change
```

### Architecture

```
                    ┌──────────────────────────┐
                    │    nginx (router:443)     │
                    │  SSL termination          │
                    │  cookie-based routing     │
                    └─────┬──────────┬──────────┘
                          │          │
              ┌───────────▼──┐  ┌───▼───────────┐
              │  main (stable)│  │  dev (testing) │
              │  ┌──────────┐│  │  ┌──────────┐ │
              │  │ nginx    ││  │  │ nginx    │ │
              │  │ :80      ││  │  │ :80      │ │
              │  ├──────────┤│  │  ├──────────┤ │
              │  │ SvelteKit││  │  │ SvelteKit│ │
              │  │ :3000    ││  │  │ :3000    │ │
              │  ├──────────┤│  │  ├──────────┤ │
              │  │ FastAPI  ││  │  │ FastAPI  │ │
              │  │ :8000    ││  │  │ :8000    │ │
              │  └──────────┘│  │  └──────────┘ │
              └──────────────┘  └───────────────┘
                     │                  │
                     └────────┬─────────┘
                        ┌─────▼─────┐
                        │  SQLite   │
                        │ (shared)  │
                        └───────────┘
```

Users switch between main and dev via a toggle in Settings → Developer.

## License

MIT
