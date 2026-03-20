# Home Gym Tracker - Project Continuity Document

**Last Updated:** 2026-03-19
**Project:** AI-powered home gym workout tracker using computer vision

---

## Project Overview

This is an AI-powered home gym tracking application that uses computer vision (MediaPipe Pose) to automatically detect exercises, count reps, and analyze technique quality from UniFi security camera RTSP streams.

### Key Features Implemented

1. **Exercise Detection**: Automatically classifies exercises (squat, deadlift, bench press, overhead press, row, pull-up, dip, lunge) based on movement patterns
2. **Rep Counting**: Tracks repetitions using joint angle trajectories with phase detection (TOP, DESCENT, BOTTOM, ASCENT)
3. **Technique Analysis**: Scores 4 dimensions (0.0-1.0 scale):
   - Technique Score (overall quality)
   - Range of Motion (depth ROM)
   - Symmetry Score (left/right balance)
   - Stability Score (control balance)
4. **Variation Detection**: Detects grip width, stance width, deadlift style (sumo/conventional)
5. **Multi-Person Tracking**: Person re-identification using appearance features + pose signatures
6. **Progressive Overload**: Evidence-based weight progression recommendations incorporating:
   - Renaissance Periodization volume landmarks (MEV, MAV, MRV)
   - Eric Helms RPE progression
   - Technique quality validation
   - Fatigue management and deload recommendations
7. **Block Periodization**: Auto-generates accumulation/intensification/deload plans

---

## Architecture

### Backend (Python/FastAPI)

```
app/
├── main.py                    # FastAPI app entry point, CORS, router registration
├── config.py                  # Pydantic settings from .env
├── database.py                # SQLAlchemy async setup, Base model, init_db()
├── models/
│   ├── __init__.py           # Exports all models
│   ├── user.py               # User profiles (height, weight, body measurements)
│   ├── person.py             # Multi-person tracking (appearance features, pose signature)
│   ├── exercise.py           # Exercise definitions, types, muscle groups
│   ├── workout.py            # WorkoutSession, ExerciseSet, WorkoutPlan, WorkoutStatus
│   └── pose.py               # PoseData (raw landmarks), ProgressMetric (aggregated)
├── schemas/
│   └── requests.py           # Pydantic request/response schemas
├── api/
│   ├── __init__.py
│   ├── sessions.py           # CRUD + start/complete endpoints, add/update sets
│   ├── exercises.py          # List/get/create exercises
│   ├── plans.py              # Workout plan CRUD
│   ├── progress.py           # Progress metrics + RP recommendations
│   └── websocket.py          # Real-time pose detection streaming
└── services/
    ├── __init__.py
    ├── camera_service.py     # RTSP stream capture, frame buffering, multi-camera manager
    ├── pose_estimator.py     # MediaPipe pose detection, joint angles, person identifier
    ├── exercise_analyzer.py  # Classification, rep counting, technique analysis, variation detection
    ├── workout_planner.py    # Plan creation, next week generation
    └── rp_progressive_overload.py  # RP volume landmarks, fatigue assessment, block plans
```

### Frontend (SvelteKit + Vite)

```
frontend/
├── src/
│   ├── routes/
│   │   ├── +page.svelte      # Dashboard - stats, active session, recommendations
│   │   ├── session/          # Workout session page
│   │   ├── progress/         # Progress charts
│   │   └── plans/            # Workout plans
│   ├── lib/
│   │   ├── api.ts            # API client (axios)
│   │   └── stores.ts         # Svelte stores (sessionStats, currentSession)
│   ├── app.css               # Tailwind styles
│   ├── app.html              # HTML template
│   └── app.d.ts              # Type definitions
├── package.json              # Dependencies: Svelte, Chart.js, axios, @tanstack/svelte-query
└── vite.config.ts
```

---

## Database Schema

### Tables

| Table | Columns |
|-------|---------|
| `users` | id, username, email, hashed_password, height_cm, weight_kg, arm_span_cm, leg_length_cm, created_at, updated_at |
| `persons` | id, user_id, name, height_cm, weight_kg, arm_span_cm, leg_length_cm, appearance_features (JSON), pose_signature (JSON), first_seen, last_seen, created_at |
| `exercises` | id, name, display_name, exercise_type, description, technique_cues (JSON), primary_muscles (JSON), secondary_muscles (JSON), detection_params (JSON), expected_rom_min/max, created_at, updated_at |
| `workout_sessions` | id, user_id, workout_plan_id, name, date, status, total_volume_kg, total_sets, total_reps, duration_minutes, avg_technique_score, started_at, completed_at, created_at, updated_at |
| `exercise_sets` | id, workout_session_id, exercise_id, set_number, planned_reps/weight, actual_reps/weight, technique_score, range_of_motion, symmetry_score, stability_score, grip_width_cm, stance_width_cm, notes, started_at, completed_at |
| `pose_data` | id, exercise_set_id, timestamp, frame_number, landmarks (JSON), joint_angles (JSON), confidence |
| `progress_metrics` | id, user_id, exercise_id, date, estimated_1rm, volume_load, total_reps/sets, avg_technique_score, avg_range_of_motion, avg_symmetry, avg_stability, recommended_weight, progression_notes, created_at |
| `workout_plans` | id, user_id, name, description, block_name, week_number, day_of_week, planned_exercises (JSON), auto_progression, min_technique_score, created_at, updated_at |

---

## API Endpoints

### Sessions
- `POST /api/sessions/` - Create workout session
- `GET /api/sessions/{id}` - Get session details
- `POST /api/sessions/{id}/start` - Start session
- `POST /api/sessions/{id}/complete` - Complete session
- `POST /api/sessions/{id}/sets` - Add set to session
- `PATCH /api/sessions/{id}/sets/{set_id}` - Update set (actual values)

### Exercises
- `GET /api/exercises/` - List all exercises
- `GET /api/exercises/{id}` - Get exercise details
- `POST /api/exercises/` - Create new exercise

### Progress
- `GET /api/progress/` - Get progress metrics (filters: exercise_id, start_date, end_date)
- `GET /api/progress/recommendations` - Get RP-based recommendations (days_back, training_level, block_week)
- `GET /api/progress/recommendations/{exercise_id}` - Detailed recommendation with volume/fatigue data
- `GET /api/progress/block-plan` - Generate block periodization plan

### Plans
- `GET /api/plans/` - List workout plans
- `GET /api/plans/{id}` - Get plan details
- `POST /api/plans/` - Create new plan
- `DELETE /api/plans/{id}` - Delete plan

### WebSocket
- `WS /ws` - Real-time pose detection stream
- `WS /ws/detect` - Frame detection endpoint (demo mode)

---

## Services Architecture

### PoseEstimator
- Uses MediaPipe Pose with 33 landmarks
- Calculates joint angles: elbow, shoulder, hip, knee (left/right), torso_lean
- Supports multi-person tracking with PersonIdentifier
- Person re-identification uses:
  - Torso color histogram
  - Body proportions (shoulder/hip width, torso height)
  - Pose signature (landmark ratios)

### ExerciseAnalyzer
- **ExerciseClassifier**: Matches movement patterns to exercise signatures (squat, deadlift, bench, etc.)
- **RepCounter**: Phase-based rep detection (TOP→DESCENT→BOTTOM→ASCENT→TOP)
- **TechniqueAnalyzer**: Exercise-specific technique scoring
- **VariationDetector**: Grip width, stance width, deadlift style

### CameraStream
- RTSP stream connection with exponential backoff reconnect
- Frame buffer (circular deque, max 10 frames)
- Callback-based frame notification
- MultiCameraManager for multi-angle views

### RPProgressiveOverloadEngine
- Volume landmarks by exercise type (MEV, MAV, MRV)
- RPE progression by week (6-7 → 7-8 → 8-9 → deload)
- Fatigue assessment (technique decline, ROM decline, volume trends)
- Block periodization generation (accumulation → intensification → deload)

---

## Configuration (.env)

```bash
# Application
APP_NAME=Home Gym Tracker
DEBUG=false
ENVIRONMENT=development

# Database (defaults to SQLite)
DATABASE_URL=sqlite+aiosqlite:///./homegym.db
DATABASE_SYNC_URL=sqlite:///./homegym.db

# Camera
RTSP_STREAM_URL=rtsp://admin:password@192.168.1.100:554/stream1
CAMERA_FPS=15
CAMERA_BUFFER_SIZE=10

# Pose Detection
POSE_MODEL_COMPLEXITY=1
POSE_MIN_CONFIDENCE=0.5
POSE_MIN_TRACKING_CONFIDENCE=0.5

# Exercise Detection
REP_COUNT_THRESHOLD=0.7
TECHNIQUE_GOOD_THRESHOLD=0.8
```

---

## Current Implementation Status

### ✅ Completed

1. **Database Models**: All models defined with proper relationships
2. **API Endpoints**: Full CRUD for sessions, exercises, plans, progress
3. **Pose Detection**: MediaPipe integration with joint angle calculation
4. **Exercise Classification**: Movement pattern matching for 7 exercise types
5. **Rep Counting**: Phase-based detection with angle thresholds
6. **Technique Analysis**: Exercise-specific scoring (squat, deadlift, bench, OHP, row)
7. **Progressive Overload**: RP-based recommendations with technique validation
8. **Fatigue Assessment**: Technique/ROM decline tracking, MRV monitoring
9. **Block Periodization**: Auto-generation of 4-week blocks
10. **Frontend Dashboard**: Stats display, recommendations, progress table
11. **WebSocket**: Real-time pose streaming endpoint

### ⚠️ Partially Implemented / Needs Work

1. **Multi-Person Tracking**: `PersonIdentifier` class exists but not fully integrated into main flow
2. **Camera Integration**: `CameraStream` class complete but WebSocket frame processing loop needs testing
3. **Frontend Pages**: `/session`, `/progress`, `/plans` routes exist but may need completion
4. **Set Auto-Population**: Exercise sets need to auto-populate from AI detection (currently manual API calls)
5. **Pose Data Storage**: `pose_data` table exists but not being populated during sessions
6. **Exercise Seeding**: No seed script found for default exercises

### ❌ Not Yet Implemented

1. **User Authentication**: User endpoints defined but no auth middleware
2. **Frontend Camera Integration**: No UI for camera stream display
3. **Live Rep Counter UI**: No real-time rep counting display in frontend
4. **Exercise Form Cues**: `technique_cues` field exists but not used in analysis
5. **Appearance Feature Persistence**: Person features not saved to database
6. **Multi-Camera Support**: `MultiCameraManager` exists but not wired to API
7. **1RM Testing**: Estimated 1RM calculated but no dedicated test flow

---

## Key Design Decisions

1. **SQLite Default**: Uses SQLite by default for simplicity, PostgreSQL compatible via env config
2. **Async SQLAlchemy**: All DB operations use async/await patterns
3. **JSON Storage**: Complex data (landmarks, angles, planned exercises) stored as JSON strings
4. **Evidence-Based Training**: Incorporates RP volume landmarks, Helms RPE progression
5. **Technique-First Progression**: Weight progression gated by technique quality thresholds
6. **Single-Person Default**: Multi-person architecture exists but defaults to person_id=0

---

## Dependencies

### Backend (pyproject.toml)
- fastapi>=0.109.0
- uvicorn[standard]>=0.27.0
- sqlalchemy>=2.0.0
- asyncpg>=0.29.0 (PostgreSQL)
- psycopg2-binary>=2.9.9
- alembic>=1.13.0
- pydantic>=2.5.0
- pydantic-settings>=2.1.0
- opencv-python>=4.9.0
- mediapipe>=0.10.8
- numpy>=1.26.0
- httpx>=0.26.0

### Frontend (package.json)
- @sveltejs/kit:^2.0.0
- svelte:^4.2.0
- @tanstack/svelte-query:^5.17.0
- chart.js:^4.4.0
- axios:^1.6.0
- tailwindcss:^3.4.0

---

## Running the Application

```bash
# From project root
./dev.sh  # Starts backend + frontend

# Or manually:
# Backend
source venv/bin/activate
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# Frontend
cd frontend
npm run dev
```

---

## Next Likely Tasks (Where We May Have Left Off)

Based on code analysis, the following tasks were likely in progress:

1. **Frontend Session Page**: Connecting the `/session` route to WebSocket for live tracking
2. **Exercise Seeding**: Creating default exercise definitions in database
3. **Camera Testing**: Verifying RTSP stream integration with pose detection
4. **Set Auto-Creation**: Wiring exercise analyzer to auto-create sets on rep completion
5. **Progress Charts**: Implementing Chart.js visualizations on `/progress` page
6. **Person Registration**: UI flow for users to register their person ID

---

## Known Gaps / Technical Debt

1. **No Tests**: No pytest tests found in codebase
2. **No Migration Files**: Alembic configured but no migrations present (relies on auto-create)
3. **Hardcoded Person ID**: Defaults to person_id=0, multi-person not fully wired
4. **No Error Handling**: Limited try/catch in service layers
5. **Demo Mode WebSocket**: `/ws/detect` returns "not implemented in demo mode"
6. **No User ID in Progress**: `get_progression_recommendation` accepts user_id=None

---

## Files to Check for Recent Changes

If investigating what was being worked on:

1. Check file modification times:
   ```bash
   find /Users/calebmorton/home-gym-tracker -name "*.py" -o -name "*.svelte" -o -name "*.ts" | xargs ls -lt | head -20
   ```

2. Check git history (if initialized):
   ```bash
   git log --oneline -20
   ```

3. Look for TODO/FIXME comments:
   ```bash
   grep -r "TODO\|FIXME\|XXX" app/ frontend/
   ```

---

## Quick Reference: Key Classes

| Class | File | Purpose |
|-------|------|---------|
| `PoseEstimator` | pose_estimator.py | MediaPipe pose detection, 33 landmarks |
| `PersonIdentifier` | pose_estimator.py | Multi-person re-identification |
| `ExerciseClassifier` | exercise_analyzer.py | Movement pattern → exercise type |
| `RepCounter` | exercise_analyzer.py | Phase-based rep detection |
| `TechniqueAnalyzer` | exercise_analyzer.py | Exercise-specific form scoring |
| `RPProgressiveOverloadEngine` | rp_progressive_overload.py | Volume landmarks, fatigue, block plans |
| `CameraStream` | camera_service.py | RTSP capture with reconnect |
| `WorkoutPlanner` | workout_planner.py | Plan templates, week generation |

---

## Evidence-Based Training Principles Implemented

1. **Volume Landmarks** (Israetel):
   - MEV: Minimum Effective Volume (growth threshold)
   - MAV: Maximum Adaptive Volume (optimal range)
   - MRV: Maximum Recoverable Volume (upper limit)

2. **RPE Progression** (Helms):
   - Week 1: RPE 6-7 (conservative start)
   - Week 2: RPE 7-8 (moderate)
   - Week 3: RPE 8-9 (hard)
   - Week 4: RPE 5-6 (deload)

3. **Block Periodization**:
   - Accumulation: High volume, low intensity (65-72% 1RM)
   - Intensification: Moderate volume, high intensity (72-84% 1RM)
   - Deload: Reduced volume/intensity for recovery

4. **Technique Validation**:
   - Excellent (≥90%): Aggressive progression
   - Good (≥80%): Normal progression
   - Acceptable (≥70%): Conservative/maintain
   - Poor (<70%): Deload/reduce weight

---

**End of Document**
