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

export interface MachineWeights {
  smithMachine: number;   // lbs (0, 15, 25, 45 common)
  legPress: number;       // sled weight
  hackSquat: number;
  tBarRow: number;
  barbell: number;        // standard bar weight
  [key: string]: number;  // custom entries
}

export interface ProgressionSettings {
  trainingLevel: 'beginner' | 'intermediate' | 'advanced';
  upperWeightIncrement: number;  // lbs
  lowerWeightIncrement: number;  // lbs
  maxSetsPerExercise: number;
  setsAddedPerCycle: number;
  minRepsForIncrease: number;
  maxRepsForIncrease: number;
}

export interface DashboardWidget {
  id: string;
  enabled: boolean;
}

export interface AppSettings {
  restDurations: RestDurations;
  weightUnit: 'lbs' | 'kg';
  heightUnit: 'in' | 'ft' | 'cm';
  progressionStyle: 'rep' | 'weight';
  profile: UserProfile;
  machineWeights: MachineWeights;
  maxWarmupSets: number;
  progression: ProgressionSettings;
  dashboardWidgets: DashboardWidget[];
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
  heightUnit: 'ft',
  progressionStyle: 'rep',
  profile: {
    age: null,
    sex: null,
    heightIn: null,
    activityLevel: 1.4,
  },
  machineWeights: {
    barbell: 45,
    ezBar: 25,
    ezBarRackable: 35,
    safetySquatBar: 65,
    trapBar: 45,
    beltSquat: 0,
    smithMachine: 25,
    legPress: 75,
    hackSquat: 45,
    tBarRow: 20,
    chestPress: 0,
    shoulderPress: 0,
    inclinePress: 0,
    declinePress: 0,
    calfRaise: 0,
    seatedRow: 0,
    latPulldown: 0,
    pendulumSquat: 0,
    hipThrust: 0,
    legExtension: 0,
    legCurl: 0,
  },
  maxWarmupSets: 4,
  dashboardWidgets: [
    { id: 'stats', enabled: true },
    { id: 'nextWorkout', enabled: true },
    { id: 'nutrition', enabled: true },
    { id: 'insights', enabled: true },
    { id: 'calendar', enabled: true },
    { id: 'recentSessions', enabled: true },
    { id: 'plans', enabled: true },
    { id: 'trainingLog', enabled: true },
    { id: 'weekView', enabled: true },
    { id: 'calculator', enabled: false },
    { id: 'repeatLast', enabled: false },
    { id: 'pinnedCharts', enabled: false },
  ],
  progression: {
    trainingLevel: 'intermediate',
    upperWeightIncrement: 2.5,
    lowerWeightIncrement: 5,
    maxSetsPerExercise: 6,
    setsAddedPerCycle: 1,
    minRepsForIncrease: 8,
    maxRepsForIncrease: 12,
  },
};

function deepMergeSettings(stored: any): AppSettings {
  // Merge dashboard widgets: preserve user order/enabled state, add any new widgets
  const storedWidgets: DashboardWidget[] = stored.dashboardWidgets ?? [];
  const storedIds = new Set(storedWidgets.map((w: DashboardWidget) => w.id));
  const mergedWidgets = [
    ...storedWidgets,
    ...defaultSettings.dashboardWidgets.filter(w => !storedIds.has(w.id)),
  ];

  return {
    ...defaultSettings,
    ...stored,
    restDurations: { ...defaultSettings.restDurations, ...(stored.restDurations ?? {}) },
    profile: { ...defaultSettings.profile, ...(stored.profile ?? {}) },
    machineWeights: { ...defaultSettings.machineWeights, ...(stored.machineWeights ?? {}) },
    progression: { ...defaultSettings.progression, ...(stored.progression ?? {}) },
    dashboardWidgets: mergedWidgets,
  };
}

function loadSettings(): AppSettings {
  if (typeof localStorage === 'undefined') return defaultSettings;
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (!raw) return defaultSettings;
    return deepMergeSettings(JSON.parse(raw));
  } catch {
    return defaultSettings;
  }
}

// Debounce timer for DB saves
let dbSaveTimer: ReturnType<typeof setTimeout> | null = null;

function createSettingsStore() {
  const { subscribe, set, update } = writable<AppSettings>(loadSettings());

  function persist(value: AppSettings) {
    // Always save to localStorage (instant, offline-capable)
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(value));
    }
    // Debounce save to DB (500ms) — avoids hammering API on rapid changes
    if (dbSaveTimer) clearTimeout(dbSaveTimer);
    dbSaveTimer = setTimeout(async () => {
      try {
        const { saveSettings } = await import('$lib/api');
        await saveSettings(value);
      } catch { /* offline or not logged in — localStorage has it */ }
    }, 500);
  }

  return {
    subscribe,
    set(value: AppSettings) {
      persist(value);
      set(value);
    },
    update(fn: (s: AppSettings) => AppSettings) {
      update(s => {
        const next = fn(s);
        persist(next);
        return next;
      });
    },
    /** Load settings from DB (call after login) */
    async loadFromDb() {
      try {
        const { getSettings } = await import('$lib/api');
        const remote = await getSettings();
        if (remote && Object.keys(remote).length > 0) {
          const merged = deepMergeSettings(remote);
          if (typeof localStorage !== 'undefined') {
            localStorage.setItem(SETTINGS_KEY, JSON.stringify(merged));
          }
          set(merged);
        }
      } catch { /* not logged in or offline — use localStorage */ }
    },
  };
}

export const settings = createSettingsStore();

// ─── Offline state ───────────────────────────────────────────────────────────
export const isOnline = writable(typeof navigator !== 'undefined' ? navigator.onLine : true);
export const pendingSyncCount = writable(0);
export const syncStatus = writable<'idle' | 'syncing' | 'error'>('idle');

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