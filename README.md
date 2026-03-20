# Home Gym Tracker

AI-powered home gym workout tracking using computer vision from security cameras.

## Features

- **Automatic Exercise Detection**: Uses MediaPipe Pose to detect exercises from camera feeds
- **Rep Counting**: Automatically counts sets and reps
- **Technique Analysis**: Scores range of motion, symmetry, and stability
- **Variation Detection**: Detects grip width, stance width, and exercise variations
- **Multi-Person Tracking**: Identify and track multiple users
- **Progressive Overload**: Smart weight progression recommendations based on technique quality
- **Workout Planning**: Create and manage workout plans similar to RP/MacroFactor

## Tech Stack

### Backend
- Python 3.11+
- FastAPI (async web framework)
- PostgreSQL with SQLAlchemy
- OpenCV (video processing)
- MediaPipe (pose estimation)

### Frontend
- Svelte (or React) with Vite
- Tailwind CSS
- Chart.js for progress visualization

## Setup

### Prerequisites

- Python 3.11 or higher
- PostgreSQL 14+
- UniFi cameras with RTSP stream access

### Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/home-gym-tracker.git
cd home-gym-tracker
```

2. Create a virtual environment:
```bash
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

3. Install dependencies:
```bash
pip install -r requirements.txt
```

4. Set up environment variables:
```bash
cp .env.example .env
# Edit .env with your configuration
```

5. Create the PostgreSQL database:
```bash
createdb homegym
```

6. Run the application:
```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### UniFi Camera Setup

1. Enable RTSP streams on your UniFi cameras in the Protect app
2. Note the RTSP URL format: `rtsp://username:password@camera-ip:554/stream1`
3. Add the RTSP URL to your `.env` file

## API Endpoints

### Sessions
- `POST /api/sessions/` - Create a new workout session
- `GET /api/sessions/{session_id}` - Get session details
- `POST /api/sessions/{session_id}/start` - Start a session
- `POST /api/sessions/{session_id}/complete` - Complete a session
- `POST /api/sessions/{session_id}/sets` - Add a set to session
- `PATCH /api/sessions/{session_id}/sets/{set_id}` - Update set data

### Exercises
- `GET /api/exercises/` - List all exercises
- `GET /api/exercises/{exercise_id}` - Get exercise details
- `POST /api/exercises/` - Create new exercise

### Progress
- `GET /api/progress/` - Get progress metrics
- `GET /api/progress/recommendations` - Get progression recommendations

### Plans
- `GET /api/plans/` - List workout plans
- `POST /api/plans/` - Create workout plan
- `DELETE /api/plans/{plan_id}` - Delete plan

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  UniFi Cameras  │────▶│  RTSP Stream     │────▶│  Frame Buffer   │
│  (RTSP streams) │     │  Capture Service  │     │  & Queue        │
└─────────────────┘     └──────────────────┘     └────────┬────────┘
                                                          │
                                                          ▼
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Web Frontend   │◀───▶│  FastAPI Backend  │◀───▶│  Pose Analysis   │
│  (React/Svelte) │     │  + REST API       │     │  Engine          │
└─────────────────┘     └────────┬─────────┘     └────────┬────────┘
                                 │                         │
                                 ▼                         ▼
                        ┌──────────────────┐     ┌─────────────────┐
                        │  Workout Planner  │     │  MediaPipe      │
                        │  + Recommendations│     │  Pose Detection │
                        └────────┬─────────┘     └────────┬────────┘
                                 │                         │
                                 ▼                         ▼
                        ┌──────────────────────────────────────────┐
                        │              PostgreSQL Database          │
                        │  (Users, Exercises, Workouts, Sets, etc) │
                        └──────────────────────────────────────────┘
```

## Development

### Running Tests
```bash
pytest tests/
```

### Code Formatting
```bash
black app/
ruff check app/
```

### Type Checking
```bash
mypy app/
```

## License

MIT License - see LICENSE file for details.