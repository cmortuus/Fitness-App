import { writable, derived } from 'svelte/store';
import type { BodyWeightEntry, DietPhase, Exercise, WorkoutSession, WorkoutPlan } from '$lib/api';

// ─── Persistent settings ──────────────────────────────────────────────────────
export interface RestDurations {
  upperCompound:  number;  // e.g. bench press, rows, OHP  → default 3 min
  upperIsolation: number;  // e.g. curls, laterals          → default 90 s
  lowerCompound:  number;  // e.g. squat, deadlift          → default 4 min
  lowerIsolation: number;  // e.g. leg curl, leg extension  → default 2 min
}

export interface UserProfile {
  age: number | null;
  sex: 'male' | 'female' | null;
  heightIn: number | null;       // height in inches
  activityLevel: number;          // 1.0-1.8 multiplier
}

export interface AppSettings {
  restDurations: RestDurations;
  weightUnit: 'lbs' | 'kg';
  progressionStyle: 'rep' | 'weight';  // prefer rep overload vs immediate weight overload
  profile: UserProfile;
}

const SETTINGS_KEY = 'hgt_settings';

const defaultSettings: AppSettings = {
  restDurations: {
    upperCompound:  180,
    upperIsolation:  90,
    lowerCompound:  240,
    lowerIsolation: 120,
  },
  weightUnit: 'lbs',
  progressionStyle: 'rep',
  profile: {
    age: null,
    sex: null,
    heightIn: null,
    activityLevel: 1.4,
  },
};

function loadSettings(): AppSettings {
  if (typeof localStorage === 'undefined') return defaultSettings;
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    return raw ? { ...defaultSettings, ...JSON.parse(raw) } : defaultSettings;
  } catch {
    return defaultSettings;
  }
}

function createSettingsStore() {
  const { subscribe, set, update } = writable<AppSettings>(loadSettings());
  return {
    subscribe,
    set(value: AppSettings) {
      if (typeof localStorage !== 'undefined') {
        localStorage.setItem(SETTINGS_KEY, JSON.stringify(value));
      }
      set(value);
    },
    update(fn: (s: AppSettings) => AppSettings) {
      update(s => {
        const next = fn(s);
        if (typeof localStorage !== 'undefined') {
          localStorage.setItem(SETTINGS_KEY, JSON.stringify(next));
        }
        return next;
      });
    },
  };
}

export const settings = createSettingsStore();

// Current workout session
export const currentSession = writable<WorkoutSession | null>(null);

// Active exercises in current session
export const activeExercises = writable<Map<number, Exercise[]>>(new Map());

// Available exercises
export const exercises = writable<Exercise[]>([]);

// Workout plans
export const workoutPlans = writable<WorkoutPlan[]>([]);

// Current set tracking
export const currentSet = derived(
  currentSession,
  ($currentSession) => {
    if (!$currentSession) return null;

    // Find the next incomplete set (first one without a completed_at)
    const activeSets = $currentSession.sets.filter(s => !s.completed_at);
    return activeSets[0] || null;
  }
);

// Latest body weight from the server (null = not loaded yet)
export const latestBodyWeight = writable<BodyWeightEntry | null>(null);

// Active diet phase
export const activeDietPhase = writable<DietPhase | null>(null);

// URL for the next planned workout — set by the home page after resolving the plan
// Falls back to /workout/active if not yet computed
export const nextWorkoutUrl = writable<string>('/workout/active');

// Session statistics
export const sessionStats = derived(
  currentSession,
  ($currentSession) => {
    if (!$currentSession) return null;

    const completedSets = $currentSession.sets.filter(s => s.actual_reps !== null);
    const totalVolume = completedSets.reduce(
      (sum, s) => sum + (s.actual_weight_kg || 0) * (s.actual_reps || 0),
      0
    );

    return {
      totalSets: completedSets.length,
      totalReps: completedSets.reduce((sum, s) => sum + (s.actual_reps || 0), 0),
      totalVolume,
    };
  }
);