# Quick Start Guide

## Prerequisites

- Python 3.11+
- PostgreSQL 14+
- Node.js 18+ (for frontend)
- UniFi cameras with RTSP stream enabled

## Installation

### 1. Backend Setup

```bash
# Create and activate virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Configure environment
cp .env.example .env
# Edit .env with your database and camera settings
```

### 2. Database Setup

```bash
# Create database
createdb homegym

# Run migrations (if using Alembic)
alembic upgrade head

# Or let the app create tables on startup
# Tables are created automatically by init_db()

# Seed default exercises
python scripts/seed_exercises.py
```

### 3. Frontend Setup

```bash
cd frontend

# Install dependencies
npm install

# Start development server
npm run dev
```

### 4. UniFi Camera Configuration

1. Open UniFi Protect web interface
2. Go to Settings > Camera > [Your Camera] > Manage > RTSP
3. Enable RTSP stream
4. Note the RTSP URL (format: `rtsp://[username]:[password]@[camera-ip]/[stream]`)
5. Add URL to `.env`:
   ```
   RTSP_STREAM_URL=rtsp://admin:password@192.168.1.100:554/s0
   ```

### 5. Start the Application

Using the dev script (starts both backend and frontend):
```bash
./dev.sh
```

Or manually:
```bash
# Backend (from project root)
source venv/bin/activate
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# Frontend (from frontend directory)
cd frontend
npm run dev
```

## Usage

1. Open http://localhost:5173 in your browser
2. Start a workout session from the Dashboard
3. Select an exercise and weight
4. The camera will automatically detect:
   - Exercise type (squat, deadlift, bench press, etc.)
   - Rep count
   - Technique score
   - Range of motion
5. Complete your sets and view progress over time

## Multi-Person Tracking

To enable multi-person tracking:

1. Each person should "register" by standing in front of the camera
2. The system will assign a person ID based on appearance features
3. Person identification uses:
   - Body proportions (shoulder width, hip width, torso height)
   - Clothing color histogram (torso region)
   - Pose signature (key landmark ratios)

## Progressive Overload

The system tracks technique quality and recommends weight progression:

- **Green light (increase weight)**: Technique score > 80% with improving trend
- **Yellow (maintain weight)**: Technique score 70-80%
- **Red (decrease weight)**: Technique score < 70% or declining trend

## API Endpoints

Access the interactive API documentation at http://localhost:8000/docs

Key endpoints:
- `POST /api/sessions/` - Create workout session
- `POST /api/sessions/{id}/start` - Start session
- `GET /api/exercises/` - List exercises
- `GET /api/progress/` - Get progress data
- `GET /api/progress/recommendations` - Get progression recommendations
- `WS /ws` - WebSocket for real-time pose data

## Troubleshooting

### Camera not connecting
- Verify RTSP URL is correct
- Check camera is accessible on network
- Ensure RTSP is enabled in UniFi Protect settings

### Pose detection not working
- Check camera FPS setting (15 FPS recommended)
- Ensure good lighting in gym area
- Camera should have clear view of exercise area

### Database connection issues
- Verify PostgreSQL is running: `pg_isready`
- Check connection string in `.env`
- Ensure database `homegym` exists

## Production Deployment

For production:

1. Use Gunicorn/Uvicorn with workers:
   ```bash
   gunicorn app.main:app -w 4 -k uvicorn.workers.UvicornWorker
   ```

2. Set up Nginx reverse proxy

3. Use environment variables for secrets:
   ```bash
   export DATABASE_URL="postgresql+asyncpg://..."
   export RTSP_STREAM_URL="rtsp://..."
   ```

4. Build frontend:
   ```bash
   cd frontend
   npm run build
   ```

5. Set DEBUG=false in .env