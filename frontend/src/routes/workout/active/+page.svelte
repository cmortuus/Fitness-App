<script lang="ts">
  import { onMount, onDestroy, tick } from 'svelte';
  import { goto } from '$app/navigation';
  import { beforeNavigate } from '$app/navigation';
  import { currentSession, exercises as exerciseStore, latestBodyWeight, settings } from '$lib/stores';
  import {
    getExercises, getPlan, getPlans, getNextWorkout, getRecentExercises, getSession, getSessions,
    createSessionFromPlan, createSession,
    addSet, updateSet, deleteSet, completeSession, deleteSession,
    getExerciseHistory, getAllExerciseNotes, setExerciseNote, getPersonalRecords,
    saveExerciseFeedback, getExerciseFeedback, syncSessionToPlan, patchSession, createExercise,
    updatePlan,
  } from '$lib/api';
  import type { Exercise, WorkoutPlan, PlannedDay, PlannedExercise, ExerciseHistorySession, WorkoutSession, NextWorkoutResolution, PersonalRecord } from '$lib/api';
  import { swipeable } from '$lib/actions/swipeable';
  import PlateVisual from '$lib/components/PlateVisual.svelte';
  import PrimePegVisual from '$lib/components/PrimePegVisual.svelte';
  import html2canvas from 'html2canvas';
  import { writeWorkout } from '$lib/healthkit';

  // ─── Constants ────────────────────────────────────────────────────────────
  const LBS_TO_KG = 0.453592;

  function lbsToKg(lbs: number) { return Math.round(lbs * LBS_TO_KG * 100) / 100; }

  // Convert user-facing weight to kg for backend storage
  function toKg(val: number) {
    return $settings.weightUnit === 'lbs' ? lbsToKg(val) : Math.round(val * 100) / 100;
  }

  // Convert kg from backend to user's display unit — no rounding (preserves user input)
  const KG_TO_LBS = 2.20462;
  function fromKg(kg: number): number {
    const v = $settings.weightUnit === 'lbs' ? kg * KG_TO_LBS : kg;
    return Math.round(v * 100) / 100;  // 2 decimal places only
  }

  // Round weight to the nearest 0.5 lbs / 0.25 kg — precise enough for users
  // to see the ideal target and adjust to their available weights themselves.
  function roundWeight(w: number): number {
    return $settings.weightUnit === 'lbs'
      ? Math.round(w * 2) / 2
      : Math.round(w * 4) / 4;
  }

  // Round reps to nearest 5 (so suggestions are always 5, 10, 15, 20…)
  function roundReps(r: number): number {
    return Math.max(5, Math.round(r / 5) * 5);
  }

  // Body weight in the user's display unit (from latest weigh-in)
  let bodyWeightInUnit = $derived(
    $latestBodyWeight
      ? ($settings.weightUnit === 'lbs'
          ? Math.round($latestBodyWeight.weight_kg * KG_TO_LBS * 4) / 4
          : $latestBodyWeight.weight_kg)
      : 0
  );

  // For assisted exercises: net load = body weight − assist weight
  function effectiveWeightKg(assistVal: number): number {
    const bw = bodyWeightInUnit;
    const net = bw - assistVal;
    return toKg(Math.max(0, net));
  }

  // Display the net load for assisted exercises in user's unit
  function netDisplay(assistVal: number | null): string {
    if (assistVal === null) return '—';
    if (!$latestBodyWeight) return '? (log a weigh-in in Settings)';
    const net = roundWeight(Math.max(0, bodyWeightInUnit - assistVal));
    return `Net: ${net} ${unit}`;
  }

  // Derived label
  let unit = $derived($settings.weightUnit);

  // ─── UI types ─────────────────────────────────────────────────────────────
  interface UISet {
    localId: string;
    backendId: number | null;
    setNumber: number;
    weightLbs: number | null;  // null = blank until user types
    reps: number | null;       // bilateral reps (null = blank)
    repsLeft: number | null;   // unilateral left side
    repsRight: number | null;  // unilateral right side
    done: boolean;
    skipped: boolean;
    doneLeft: boolean;      // unilateral: left side completed
    doneRight: boolean;     // unilateral: right side completed
    saving: boolean;
    // Epley anchor — 1RM (in user's display unit) from prior session suggestion.
    // Enables bi-directional weight ↔ reps calculation.
    oneRM: number | null;
    // Original suggestions for deviation warning
    initWeight: number | null;
    initReps: number | null;
    isExtrapolated: boolean;  // weight adjusted for fatigue/freshness due to reorder
    setType: string;  // 'standard' | 'standard_partials' | 'myo_rep' | 'myo_rep_match' | 'drop_set'
    partialReps: number | null;  // for standard_partials — partial ROM reps after full ROM
    drops: { weightLbs: number | null; reps: number | null }[];  // for drop sets only
    pegWeights: { peg1: number; peg2: number; peg3: number } | null;  // Prime machines: per-side weight per peg
  }

  interface UIExercise {
    uiId: string;
    blockId: string | null;
    persistKey: string;
    exerciseId: number;
    sets: UISet[];
    isUnilateral: boolean;     // overrides exercise default; shows L/R inputs
    customRestSecs: number | null; // null = use category default
    groupId: string | null;    // shared ID for superset/circuit grouping
    groupType: 'superset' | 'circuit' | null;
  }

  interface PersistedSessionExerciseStructure {
    order: string[];
    groups: Record<string, { groupId: string | null; groupType: 'superset' | 'circuit' | null }>;
  }

  interface ExerciseGroup {
    groupId: string | null;
    groupType: 'superset' | 'circuit' | null;
    exercises: UIExercise[];
  }

  function makeBlockId(): string {
    return globalThis.crypto?.randomUUID?.() ?? `block-${Date.now()}-${Math.random()}`;
  }

  function makePersistKey(
    blockId: string | null,
    exerciseId: number,
    sets: { backendId: number | null; setNumber: number }[],
    fallback: string,
  ) {
    if (blockId) return `block-${blockId}`;
    const firstBackendId = sets.find((set) => set.backendId != null)?.backendId;
    if (firstBackendId != null) return `set-${firstBackendId}`;
    return `tmp-${exerciseId}-${fallback}`;
  }

  function getSessionSetBlockKey(set: Set): string {
    return set.exercise_block_id ? `block-${set.exercise_block_id}` : `legacy-${set.exercise_id}`;
  }

  type SessionSetBlock = {
    key: string;
    blockId: string | null;
    exerciseId: number;
    sets: Set[];
  };

  function groupSessionSetsByBlock(sets: Set[]): SessionSetBlock[] {
    const orderedBlocks: SessionSetBlock[] = [];
    const byKey = new Map<string, SessionSetBlock>();
    for (const set of [...sets].sort((a, b) => a.id - b.id)) {
      const key = getSessionSetBlockKey(set);
      let block = byKey.get(key);
      if (!block) {
        block = {
          key,
          blockId: set.exercise_block_id ?? null,
          exerciseId: set.exercise_id,
          sets: [],
        };
        byKey.set(key, block);
        orderedBlocks.push(block);
      }
      block.sets.push(set);
    }
    return orderedBlocks;
  }

  function computeGroups(exercises: UIExercise[]): ExerciseGroup[] {
    const groups: ExerciseGroup[] = [];
    for (const ex of exercises) {
      const last = groups[groups.length - 1];
      if (ex.groupId && last?.groupId === ex.groupId) {
        last.exercises.push(ex);
      } else {
        groups.push({ groupId: ex.groupId, groupType: ex.groupType, exercises: [ex] });
      }
    }
    return groups;
  }

  // ─── State ────────────────────────────────────────────────────────────────
  let loading = $state(true);
  let error = $state<string | null>(null);

  // Plan picker (shown when no ?plan= param)
  let showPicker = $state(false);
  let plans = $state<WorkoutPlan[]>([]);

  let sessionId = $state<number | null>(null);
  let workoutName = $state('Workout');
  let allExercises = $state<Exercise[]>([]);
  let personalRecordsByExercise = $state<Record<number, PersonalRecord>>({});
  let startingPersonalRecordsByExercise = $state<Record<number, PersonalRecord>>({});
  let uiExercises = $state<UIExercise[]>([]);

  let exerciseGroups = $derived(computeGroups(uiExercises));
  let exerciseNotes = $state<Record<number, string>>({});
  let editingNoteId = $state<number | null>(null);
  let editingNoteText = $state('');
  let focusedWeightSetId = $state<string | null>(null);
  let focusedExerciseId = $state<number | null>(null);
  let finished = $state(false);
  let finishing = $state(false);
  let syncToPlan = $state(true);
  let hasLinkedPlan = $state(false);
  let activePlan = $state<WorkoutPlan | null>(null);
  let activePlanDayNumber = $state<number | null>(null);
  let syncCount = $state<number | null>(null);
  let syncStructural = $state<number | null>(null);
  let summaryCardEl = $state<HTMLDivElement | undefined>(undefined);
  let sharing = $state(false);

  async function shareWorkout() {
    if (!summaryCardEl) return;
    sharing = true;
    try {
      const canvas = await html2canvas(summaryCardEl, {
        backgroundColor: '#18181b',
        scale: 2,
      });
      canvas.toBlob(async (blob) => {
        if (!blob) { sharing = false; return; }
        const file = new File([blob], 'workout-summary.png', { type: 'image/png' });
        if (navigator.canShare?.({ files: [file] })) {
          await navigator.share({ files: [file], title: 'Workout Summary' });
        } else {
          // Fallback: download
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url;
          a.download = 'workout-summary.png';
          a.click();
          URL.revokeObjectURL(url);
        }
        sharing = false;
      }, 'image/png');
    } catch {
      sharing = false;
    }
  }
  let showCancelConfirm = $state(false);
  let cancelling = $state(false);
  // (showFinishWarning removed — finish button is disabled until all sets done)

  // ─── PR celebration ──────────────────────────────────────────────────
  let prCelebration = $state<{ exercise: string; type: string; value: string } | null>(null);
  let prTimeout: ReturnType<typeof setTimeout> | null = null;

  function indexPersonalRecords(records: PersonalRecord[]): Record<number, PersonalRecord> {
    return Object.fromEntries(records.map((record) => [record.exercise_id, record]));
  }

  function emptyPersonalRecord(exercise: Exercise): PersonalRecord {
    return {
      exercise_id: exercise.id,
      display_name: exercise.display_name,
      name: exercise.name,
      max_weight_kg: 0,
      max_weight_date: null,
      max_reps: 0,
      max_reps_date: null,
      best_1rm_kg: 0,
      best_1rm_date: null,
      best_set_weight_kg: 0,
      best_set_reps: 0,
    };
  }

  function getSetRepCount(ex: UIExercise, set: UISet): number {
    return ex.isUnilateral
      ? Math.min(set.repsLeft ?? 0, set.repsRight ?? 0)
      : (set.reps ?? 0);
  }

  function getSetWeightKg(set: UISet): number {
    return set.weightLbs != null ? toKg(set.weightLbs) : 0;
  }

  function getEstimatedOneRmKg(weightKg: number, reps: number): number {
    return weightKg > 0 && reps > 0 ? weightKg * (1 + reps / 30) : 0;
  }

  function formatDisplayWeight(kg: number): string {
    return `${fromKg(kg)} ${unit}`;
  }

  type PRHit = {
    type: 'weight' | 'reps' | '1rm';
    value: string;
    rawValue: number;
  };

  function getPrHits(
    ex: UIExercise,
    set: UISet,
    recordMap: Record<number, PersonalRecord>,
  ): PRHit[] {
    const exercise = allExercises.find(e => e.id === ex.exerciseId);
    if (!exercise) return [];

    const baseline = recordMap[ex.exerciseId] ?? emptyPersonalRecord(exercise);
    const reps = getSetRepCount(ex, set);
    const weightKg = getSetWeightKg(set);
    const estOneRmKg = getEstimatedOneRmKg(weightKg, reps);
    const isAsst = exercise.is_assisted ?? false;

    const hits: PRHit[] = [];
    if (!isAsst && weightKg > baseline.max_weight_kg) {
      hits.push({ type: 'weight', value: formatDisplayWeight(weightKg), rawValue: weightKg });
    }
    if (reps > baseline.max_reps) {
      hits.push({ type: 'reps', value: `${reps} reps`, rawValue: reps });
    }
    if (!isAsst && estOneRmKg > baseline.best_1rm_kg) {
      hits.push({ type: '1rm', value: formatDisplayWeight(estOneRmKg), rawValue: estOneRmKg });
    }
    return hits;
  }

  function updateLivePersonalRecords(ex: UIExercise, set: UISet) {
    const exercise = allExercises.find(e => e.id === ex.exerciseId);
    if (!exercise) return;

    const current = personalRecordsByExercise[ex.exerciseId] ?? emptyPersonalRecord(exercise);
    const reps = getSetRepCount(ex, set);
    const weightKg = getSetWeightKg(set);
    const estOneRmKg = getEstimatedOneRmKg(weightKg, reps);
    const updated: PersonalRecord = { ...current };

    if (weightKg > updated.max_weight_kg) {
      updated.max_weight_kg = weightKg;
    }
    if (reps > updated.max_reps) {
      updated.max_reps = reps;
    }
    if (estOneRmKg > updated.best_1rm_kg) {
      updated.best_1rm_kg = estOneRmKg;
      updated.best_set_weight_kg = weightKg;
      updated.best_set_reps = reps;
    }

    personalRecordsByExercise = {
      ...personalRecordsByExercise,
      [ex.exerciseId]: updated,
    };
  }

  function checkForPR(ex: UIExercise, set: UISet) {
    const exercise = allExercises.find(e => e.id === ex.exerciseId);
    if (!exercise) return;

    const hits = getPrHits(ex, set, personalRecordsByExercise);
    if (hits.length > 0) {
      updateLivePersonalRecords(ex, set);
      const hit = hits.find((candidate) => candidate.type === '1rm');
      if (!hit) return;
      const label = '1RM PR';
      prCelebration = { exercise: exercise.display_name, type: label, value: hit.value };
      if (navigator.vibrate) navigator.vibrate([100, 50, 100]);
      fireConfetti();
      if (prTimeout) clearTimeout(prTimeout);
      prTimeout = setTimeout(() => { prCelebration = null; }, 4000);
    }
  }

  // ─── Autoregulation feedback ──────────────────────────────────────────
  // Track which muscle groups have been asked about recovery (only ask once per muscle per workout)
  let recoveryAskedMuscles = $state<Set<string>>(new Set());
  // Track which exercises have shown the recovery prompt (by uiId)
  let showRecoveryPrompt = $state<Record<string, boolean>>({});
  // Track which exercises have shown the effort prompt (by uiId)
  let showEffortPrompt = $state<Record<string, boolean>>({});
  // Track which exercises have had effort submitted (by exerciseId)
  let effortSubmitted = $state<Set<number>>(new Set());
  // Stored feedback per exercise (by exerciseId)
  let feedbackData = $state<Record<number, {
    recovery_rating?: string;
    rir?: number;
    pump_rating?: string;
    suggestion?: string;
    suggestion_detail?: string;
  }>>({});

  type PersistedFeedbackState = {
    recoveryAskedMuscles: string[];
    effortSubmitted: number[];
    feedbackData: Record<number, {
      recovery_rating?: string;
      rir?: number;
      pump_rating?: string;
      suggestion?: string;
      suggestion_detail?: string;
    }>;
    dismissedRecoveryExerciseIds: number[];
    dismissedEffortExerciseIds: number[];
  };

  function feedbackStorageKey(id: number): string {
    return `hgt_session_feedback_${id}`;
  }

  function saveFeedbackDraftState() {
    if (typeof localStorage === 'undefined' || !sessionId) return;
    const dismissedRecoveryExerciseIds = Object.entries(showRecoveryPrompt)
      .filter(([, visible]) => visible === false)
      .map(([uiId]) => uiExercises.find(ex => ex.uiId === uiId)?.exerciseId)
      .filter((exerciseId): exerciseId is number => exerciseId != null);
    const dismissedEffortExerciseIds = Object.entries(showEffortPrompt)
      .filter(([, visible]) => visible === false)
      .map(([uiId]) => uiExercises.find(ex => ex.uiId === uiId)?.exerciseId)
      .filter((exerciseId): exerciseId is number => exerciseId != null);

    const payload: PersistedFeedbackState = {
      recoveryAskedMuscles: [...recoveryAskedMuscles],
      effortSubmitted: [...effortSubmitted],
      feedbackData,
      dismissedRecoveryExerciseIds,
      dismissedEffortExerciseIds,
    };
    localStorage.setItem(feedbackStorageKey(sessionId), JSON.stringify(payload));
  }

  async function restoreFeedbackState(sessId: number) {
    let nextRecoveryAskedMuscles = new Set<string>();
    let nextEffortSubmitted = new Set<number>();
    let nextFeedbackData: Record<number, {
      recovery_rating?: string;
      rir?: number;
      pump_rating?: string;
      suggestion?: string;
      suggestion_detail?: string;
    }> = {};
    let dismissedRecoveryExerciseIds = new Set<number>();
    let dismissedEffortExerciseIds = new Set<number>();

    try {
      const saved = await getExerciseFeedback(sessId);
      for (const entry of saved) {
        nextFeedbackData[entry.exercise_id] = {
          recovery_rating: entry.recovery_rating ?? undefined,
          rir: entry.rir ?? undefined,
          pump_rating: entry.pump_rating ?? undefined,
          suggestion: entry.suggestion ?? undefined,
          suggestion_detail: entry.suggestion_detail ?? undefined,
        };
        if (entry.recovery_rating) {
          for (const muscle of getRecoveryMuscles(entry.exercise_id)) {
            nextRecoveryAskedMuscles.add(muscle);
          }
          dismissedRecoveryExerciseIds.add(entry.exercise_id);
        }
        if (entry.rir != null || entry.pump_rating || entry.suggestion) {
          nextEffortSubmitted.add(entry.exercise_id);
          dismissedEffortExerciseIds.add(entry.exercise_id);
        }
      }
    } catch (e) {
      console.error('Failed to load saved feedback:', e);
    }

    if (typeof localStorage !== 'undefined') {
      const raw = localStorage.getItem(feedbackStorageKey(sessId));
      if (raw) {
        try {
          const parsed: PersistedFeedbackState = JSON.parse(raw);
          nextRecoveryAskedMuscles = new Set([
            ...nextRecoveryAskedMuscles,
            ...(parsed.recoveryAskedMuscles ?? []),
          ]);
          nextEffortSubmitted = new Set([
            ...nextEffortSubmitted,
            ...(parsed.effortSubmitted ?? []),
          ]);
          nextFeedbackData = { ...nextFeedbackData, ...(parsed.feedbackData ?? {}) };
          dismissedRecoveryExerciseIds = new Set([
            ...dismissedRecoveryExerciseIds,
            ...(parsed.dismissedRecoveryExerciseIds ?? []),
          ]);
          dismissedEffortExerciseIds = new Set([
            ...dismissedEffortExerciseIds,
            ...(parsed.dismissedEffortExerciseIds ?? []),
          ]);
        } catch (e) {
          console.error('Failed to parse saved feedback draft:', e);
        }
      }
    }

    const nextShowRecoveryPrompt: Record<string, boolean> = {};
    const nextShowEffortPrompt: Record<string, boolean> = {};
    for (const ex of uiExercises) {
      if (dismissedRecoveryExerciseIds.has(ex.exerciseId)) nextShowRecoveryPrompt[ex.uiId] = false;
      if (dismissedEffortExerciseIds.has(ex.exerciseId)) nextShowEffortPrompt[ex.uiId] = false;
    }

    recoveryAskedMuscles = nextRecoveryAskedMuscles;
    effortSubmitted = nextEffortSubmitted;
    feedbackData = nextFeedbackData;
    showRecoveryPrompt = nextShowRecoveryPrompt;
    showEffortPrompt = nextShowEffortPrompt;
  }

  function clearFeedbackDraftState(id: number | null) {
    if (typeof localStorage === 'undefined' || !id) return;
    localStorage.removeItem(feedbackStorageKey(id));
  }

  function getRecoveryMuscles(exerciseId: number): string[] {
    const ex = allExercises.find(e => e.id === exerciseId);
    const muscles = ex?.primary_muscles?.filter(Boolean) ?? [];
    return muscles.length > 0 ? muscles : ['other'];
  }

  function formatMuscleLabel(muscle: string): string {
    return muscle.replace(/_/g, ' ');
  }

  function getRecoveryPromptMuscles(exerciseId: number): string[] {
    return getRecoveryMuscles(exerciseId).filter((muscle) => !recoveryAskedMuscles.has(muscle));
  }

  function getRecoveryPromptLabel(exerciseId: number): string {
    const muscles = getRecoveryPromptMuscles(exerciseId).map(formatMuscleLabel);
    if (muscles.length === 0) return 'muscles';
    if (muscles.length === 1) return muscles[0];
    if (muscles.length === 2) return `${muscles[0]} and ${muscles[1]}`;
    return `${muscles.slice(0, -1).join(', ')}, and ${muscles[muscles.length - 1]}`;
  }

  function getMuscleGroup(exerciseId: number): string {
    return getRecoveryMuscles(exerciseId)[0] ?? 'other';
  }

  function shouldShowRecovery(ex: UIExercise): boolean {
    const firstSetDone = ex.sets.length > 0 && ex.sets[0].done;
    const notYetAsked = getRecoveryPromptMuscles(ex.exerciseId).length > 0;
    return firstSetDone && notYetAsked && showRecoveryPrompt[ex.uiId] !== false;
  }

  function shouldShowEffort(ex: UIExercise): boolean {
    const allDone = ex.sets.length > 0 && ex.sets.every(s => s.done || s.skipped) && ex.sets.some(s => s.done);
    const alreadySubmitted = effortSubmitted.has(ex.exerciseId);
    return allDone && !alreadySubmitted && showEffortPrompt[ex.uiId] !== false;
  }

  async function submitRecovery(ex: UIExercise, rating: 'poor' | 'ok' | 'good' | 'fresh') {
    const muscles = getRecoveryPromptMuscles(ex.exerciseId);
    recoveryAskedMuscles = new Set([...recoveryAskedMuscles, ...muscles]);
    showRecoveryPrompt = { ...showRecoveryPrompt, [ex.uiId]: false };
    feedbackData = { ...feedbackData, [ex.exerciseId]: { ...feedbackData[ex.exerciseId], recovery_rating: rating } };
    if (sessionId) {
      try {
        await saveExerciseFeedback(sessionId, { exercise_id: ex.exerciseId, recovery_rating: rating });
      } catch (e) { console.error('Failed to save recovery feedback:', e); }
    }
  }

  function dismissRecovery(ex: UIExercise) {
    const muscles = getRecoveryPromptMuscles(ex.exerciseId);
    recoveryAskedMuscles = new Set([...recoveryAskedMuscles, ...muscles]);
    showRecoveryPrompt = { ...showRecoveryPrompt, [ex.uiId]: false };
  }

  async function submitEffort(ex: UIExercise, rir: number, pump: 'none' | 'mild' | 'good' | 'great') {
    effortSubmitted = new Set([...effortSubmitted, ex.exerciseId]);
    const progression = $settings.progression;

    // Calculate suggestion based on performance + feedback
    const recovery = feedbackData[ex.exerciseId]?.recovery_rating ?? 'good';
    let suggestion = 'normal';
    let detail = '';
    const increment = getMuscleGroup(ex.exerciseId).match(/quad|hamstring|glute|calf/)
      ? progression.lowerWeightIncrement
      : progression.upperWeightIncrement;

    if (rir >= 3 && (recovery === 'fresh' || recovery === 'good')) {
      suggestion = 'aggressive';
      detail = `Increase weight by ${increment} ${unit} and consider adding a set`;
    } else if (rir >= 2 && recovery !== 'poor') {
      suggestion = 'normal';
      detail = `Increase weight by ${increment} ${unit}`;
    } else if (rir >= 1 && recovery !== 'poor') {
      suggestion = 'conservative';
      detail = `Keep weight, aim for +1 rep next session`;
    } else if (recovery === 'poor' && rir <= 1) {
      suggestion = 'ease';
      detail = `Hold steady — recovery needs time`;
    } else {
      suggestion = 'hold';
      detail = `Repeat same prescription next session`;
    }

    feedbackData = {
      ...feedbackData,
      [ex.exerciseId]: { ...feedbackData[ex.exerciseId], rir, pump_rating: pump, suggestion, suggestion_detail: detail }
    };

    if (sessionId) {
      try {
        await saveExerciseFeedback(sessionId, {
          exercise_id: ex.exerciseId, rir, pump_rating: pump, suggestion, suggestion_detail: detail,
        });
      } catch (e) { console.error('Failed to save effort feedback:', e); }
    }
  }

  function dismissEffort(ex: UIExercise) {
    effortSubmitted = new Set([...effortSubmitted, ex.exerciseId]);
  }

  // Preserve the first-completed-set time for resume / export only.
  let startedAt = $state<number | null>(null);
  let clockInterval: ReturnType<typeof setInterval> | null = null;

  // ─── Plate calculator ──────────────────────────────────────────────────
  const PLATES_LBS = [45, 35, 25, 10, 5, 2.5];
  const PLATES_KG = [20, 15, 10, 5, 2.5, 1.25];

  function getExerciseSearchText(exercise: Exercise | undefined): string {
    if (!exercise) return '';
    return `${exercise.name ?? ''} ${exercise.display_name ?? ''}`.toLowerCase();
  }

  function isRackableEzBarExercise(exercise: Exercise | undefined): boolean {
    const text = getExerciseSearchText(exercise);
    return text.includes('rackable') && (text.includes('ez_bar') || text.includes('ez bar') || text.includes('curl_bar') || text.includes('curl bar'));
  }

  function isEzBarExercise(exercise: Exercise | undefined): boolean {
    const text = getExerciseSearchText(exercise);
    return text.includes('ez_bar') || text.includes('ez bar') || text.includes('curl_bar') || text.includes('curl bar');
  }

  function isAxleBarExercise(exercise: Exercise | undefined): boolean {
    const text = getExerciseSearchText(exercise);
    return text.includes('axle_bar') || text.includes('axle bar');
  }

  function isSwissBarExercise(exercise: Exercise | undefined): boolean {
    const text = getExerciseSearchText(exercise);
    return text.includes('swiss_bar') || text.includes('swiss bar');
  }

  function shouldShowPlates(exercise: Exercise | undefined): boolean {
    if (!exercise) return false;
    if (!$settings.showPlateMath) return false;
    if (exercise.equipment_type === 'barbell' || exercise.equipment_type === 'plate_loaded') return true;
    // Fallback: check name for plate-loaded exercises with wrong equipment_type
    const n = exercise.name?.toLowerCase() ?? '';
    const d = (exercise.display_name ?? '').toLowerCase();
    // Smith machine variants
    if (n.includes('smith') || d.includes('smith')) return true;
    // EZ bar / curl bar variants (plate-loaded bars)
    if (isEzBarExercise(exercise)) return true;
    if (isAxleBarExercise(exercise)) return true;
    if (isSwissBarExercise(exercise)) return true;
    if (n.includes('rackable') || d.includes('rackable')) return true;
    // T-bar row / landmine
    if (n.includes('t_bar') || n.includes('t-bar') || n.includes('t bar') || d.includes('t-bar') || d.includes('t bar')) return true;
    if (n.includes('landmine') || d.includes('landmine')) return true;
    // Belt squat, plate loaded prefix
    if (n.includes('belt_squat') || n.startsWith('plate_loaded') || d.includes('belt squat')) return true;
    return false;
  }

  function isNamedOneSidedPlateExercise(exercise: Exercise | undefined): boolean {
    if (!exercise) return false;
    const n = exercise.name?.toLowerCase() ?? '';
    const d = (exercise.display_name ?? '').toLowerCase();
    return (
      n.includes('t_bar') ||
      n.includes('t-bar') ||
      n.includes('t bar') ||
      d.includes('t-bar') ||
      d.includes('t bar') ||
      n.includes('landmine') ||
      d.includes('landmine')
    );
  }

  function isOneSidedPlateExercise(exercise: Exercise | undefined): boolean {
    return isNamedOneSidedPlateExercise(exercise);
  }

  /** True if exercise is a Prime plate-loaded machine (3-peg tracking) */
  function isPrimePlateLoaded(exercise: Exercise | undefined): boolean {
    if (!exercise) return false;
    return exercise.is_prime && exercise.equipment_type === 'plate_loaded';
  }

  /** Distribute total per-side weight across 3 pegs (peg3 first, then peg2, then peg1).
   *  Uses plate increments for clean distribution. */
  function distributeToPegs(totalPerSide: number): { peg1: number; peg2: number; peg3: number } {
    const increment = $settings.weightUnit === 'lbs' ? 5 : 2.5;
    // For now, unlimited peg capacity — fill peg3 first
    // Round total to increment
    const rounded = Math.round(totalPerSide / increment) * increment;
    // Simple strategy: put everything on peg3
    // In practice, users will adjust per-peg manually and overload will
    // suggest incrementing peg3 first
    return { peg1: 0, peg2: 0, peg3: Math.max(0, rounded) };
  }

  /** Update total weight from peg values */
  function syncWeightFromPegs(set: UISet) {
    if (!set.pegWeights) return;
    const perSide = set.pegWeights.peg1 + set.pegWeights.peg2 + set.pegWeights.peg3;
    set.weightLbs = roundWeight(perSide * 2);
  }

  function clearPlateBannerFocus() {
    focusedWeightSetId = null;
    focusedExerciseId = null;
    const active = document.activeElement;
    if (active instanceof HTMLInputElement) {
      active.blur();
    }
  }

  // Derived: plate banner data for the currently focused weight input
  let plateBanner = $derived.by(() => {
    if (!focusedWeightSetId || !focusedExerciseId) return null;
    for (const ex of uiExercises) {
      if (ex.exerciseId !== focusedExerciseId) continue;
      const exercise = allExercises.find((e: Exercise) => e.id === ex.exerciseId);
      if (!exercise || !shouldShowPlates(exercise)) return null;
      // Prime machines use PrimePegVisual instead
      if (isPrimePlateLoaded(exercise)) return null;
      for (let i = 0; i < ex.sets.length; i++) {
        const set = ex.sets[i];
        if (set.localId === focusedWeightSetId) {
          const bw = getBarWeight(exercise);
          const weight = set.weightLbs ?? 0;
          if (weight <= bw) return null;
          // Previous set weight for delta display
          const prevWeight = i > 0 ? (ex.sets[i - 1].weightLbs ?? null) : null;
          return {
            totalWeight: weight,
            barWeight: bw,
            isLbs: $settings.weightUnit === 'lbs',
            oneSided: isOneSidedPlateExercise(exercise),
            prevWeight: prevWeight && prevWeight > bw ? prevWeight : null,
          };
        }
      }
    }
    return null;
  });

  // Derived: Prime peg banner data for the currently focused weight input
  let primePegBanner = $derived.by(() => {
    if (!focusedWeightSetId || !focusedExerciseId) return null;
    for (const ex of uiExercises) {
      if (ex.exerciseId !== focusedExerciseId) continue;
      const exercise = allExercises.find((e: Exercise) => e.id === ex.exerciseId);
      if (!exercise || !isPrimePlateLoaded(exercise)) return null;
      for (let i = 0; i < ex.sets.length; i++) {
        const set = ex.sets[i];
        if (set.localId === focusedWeightSetId && set.pegWeights) {
          const prevPegs = i > 0 ? ex.sets[i - 1].pegWeights : null;
          return {
            pegWeights: set.pegWeights,
            isLbs: $settings.weightUnit === 'lbs',
            prevPegWeights: prevPegs,
          };
        }
      }
    }
    return null;
  });

  /** Get bar/sled weight for plate math. Uses display base if set, else actual weight. */
  function getBarWeight(exercise: Exercise | undefined): number {
    const mw = $settings.machineWeights;
    const defaultBar = $settings.weightUnit === 'lbs' ? 45 : 20;
    if (!exercise || !mw) return defaultBar;

    if (exercise.equipment_type === 'plate_loaded') {
      const n = exercise.name.toLowerCase();
      let key = 'barbell';
      if (n.includes('smith')) key = 'smithMachine';
      else if (n.includes('leg_press') || n.includes('leg press')) key = 'legPress';
      else if (n.includes('hack_squat') || n.includes('hack squat')) key = 'hackSquat';
      else if (isNamedOneSidedPlateExercise(exercise)) key = 'tBarRow';
      else if (n.includes('belt_squat') || n.includes('belt squat')) key = 'beltSquat';
      // Use display base for plate math if configured, otherwise actual weight
      return mw[`${key}_displayBase`] ?? mw[key] ?? defaultBar;
    }
    // Specialty bars
    const n = exercise.name.toLowerCase();
    if (isRackableEzBarExercise(exercise)) return mw.ezBarRackable ?? 35;
    if (isEzBarExercise(exercise)) return mw.ezBar ?? 25;
    if (n.includes('safety_squat') || n.includes('ssb')) return mw.safetySquatBar ?? 65;
    if (n.includes('trap_bar') || n.includes('hex_bar')) return mw.trapBar ?? 45;
    return mw.barbell ?? defaultBar;
  }

  function calcPlates(totalWeight: number, isLbs: boolean, barWeight?: number): string {
    const bar = barWeight ?? (isLbs ? 45 : 20);
    const plates = isLbs ? PLATES_LBS : PLATES_KG;
    const perSide = (totalWeight - bar) / 2;
    if (perSide <= 0) return totalWeight <= bar ? `${bar} only` : '';
    let remaining = perSide;
    const result: string[] = [];
    for (const plate of plates) {
      const count = Math.floor(remaining / plate);
      if (count > 0) {
        result.push(`${count}×${plate}`);
        remaining -= count * plate;
      }
    }
    if (remaining > 0.1) return '';
    return result.join(' + ') + ' /side';
  }

  // Rest timer
  let restActive = $state(false);
  let restSecs = $state($settings.restDurations.upperCompound);
  let restInterval: ReturnType<typeof setInterval> | null = null;

  // Add-exercise modal (also used for swap)
  let showAddModal    = $state(false);
  let searchQuery     = $state('');
  let searchInputEl   = $state<HTMLInputElement | null>(null);
  let pendingSets = $state(3);
  // Filters for the exercise picker
  let filterRegion = $state<'all' | 'upper' | 'lower' | 'full_body'>('all');
  let filterType = $state<'all' | 'compound' | 'isolation'>('all');
  let filterEquip = $state<string>('all');
  let pickingExercise = $state<Exercise | null>(null);
  let recentExercises = $state<Exercise[]>([]);
  // Swap mode: when set, the modal replaces this exercise instead of adding
  let swapTargetUiId = $state<string | null>(null);
  let showCustomExerciseModal = $state(false);
  let customExerciseDisplayName = $state('');
  let customMovementType = $state<'compound' | 'isolation'>('compound');
  let customBodyRegion = $state<'upper' | 'lower' | 'full_body'>('upper');
  let customPrimaryMuscles = $state<string[]>([]);
  let customSecondaryMuscles = $state<string[]>([]);

  const muscleGroups = [
    { value: 'chest', label: 'Chest' },
    { value: 'lats', label: 'Lats' },
    { value: 'upper_back', label: 'Upper Back' },
    { value: 'mid_back', label: 'Mid Back' },
    { value: 'lower_back', label: 'Lower Back' },
    { value: 'traps', label: 'Traps' },
    { value: 'biceps', label: 'Biceps' },
    { value: 'triceps', label: 'Triceps' },
    { value: 'forearms', label: 'Forearms' },
    { value: 'quadriceps', label: 'Quadriceps' },
    { value: 'hamstrings', label: 'Hamstrings' },
    { value: 'glutes', label: 'Glutes' },
    { value: 'calves', label: 'Calves' },
    { value: 'abs', label: 'Abs' },
    { value: 'core', label: 'Core' },
    { value: 'obliques', label: 'Obliques' },
    { value: 'neck', label: 'Neck' },
    { value: 'front_delts', label: 'Front Delts' },
    { value: 'side_delts', label: 'Side Delts' },
    { value: 'rear_delts', label: 'Rear Delts' },
    { value: 'adductors', label: 'Adductors' },
  ];

  const movementTypes = [
    { value: 'compound', label: 'Compound' },
    { value: 'isolation', label: 'Isolation' },
  ] as const;

  const bodyRegions = [
    { value: 'upper', label: 'Upper Body' },
    { value: 'lower', label: 'Lower Body' },
    { value: 'full_body', label: 'Full Body' },
  ] as const;

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  onMount(async () => {
    try {
      const params = new URLSearchParams(window.location.search);
      const planId = params.get('plan');
      const dayNumber = parseInt(params.get('day') || '1');
      const isDeload = params.get('deload') === 'true';

      const [exData, notesData, recordData] = await Promise.all([
        getExercises(),
        getAllExerciseNotes(),
        getPersonalRecords().catch(() => []),
      ]);
      allExercises = exData;
      exerciseStore.set(allExercises);
      personalRecordsByExercise = indexPersonalRecords(recordData);
      startingPersonalRecordsByExercise = indexPersonalRecords(recordData);
      // Convert string keys to numbers
      for (const [k, v] of Object.entries(notesData)) {
        exerciseNotes[Number(k)] = v.note;
      }

      try {
        const recent = await getRecentExercises(20);
        recentExercises = recent;
      } catch { /* first use – no history yet */ }

      if (planId) {
        // ── Plan-based mode ──────────────────────────────────────────────
        await startFromPlan(parseInt(planId), dayNumber);
        // Apply deload reductions using settings
        if (isDeload && uiExercises.length > 0) {
          const dl = $settings.deload;
          const weightMult = (dl.weightPercent ?? 70) / 100;
          const volumeMult = (dl.volumePercent ?? 60) / 100;
          workoutName = '🔄 Deload — ' + workoutName;
          for (const ex of uiExercises) {
            for (const set of ex.sets) {
              if (set.weightLbs != null) {
                set.weightLbs = Math.round(set.weightLbs * weightMult / 2.5) * 2.5;
              }
            }
            const targetSets = Math.max(2, Math.round(ex.sets.length * volumeMult));
            while (ex.sets.length > targetSets) {
              ex.sets.pop();
            }
          }
          uiExercises = [...uiExercises];
        }
      } else if ($currentSession) {
        // ── Resume in-progress session (store still set) ────────────────
        await resumeSession();
      } else {
        // ── Check API for in-progress session (navigated away & back) ───
        const recent = await getSessions({ limit: 5 });
        const inProgress = recent.find(s => s.started_at && !s.completed_at);
        if (inProgress) {
          currentSession.set(inProgress);
          await resumeSession();
        } else {
          // ── No active session: auto-start next scheduled workout if known ─
          try {
            const next = await getNextWorkout();
            if (next && next.plan && next.day && !next.is_complete) {
              // Update the URL bar so back-navigation works correctly.
              // NOTE: goto() with replaceState does NOT re-run onMount (same-route
              // navigation reuses the component), so we must call startFromPlan
              // directly here rather than relying on the URL change to trigger it.
              goto(`/workout/active?plan=${next.plan.id}&day=${next.day.day_number}`, { replaceState: true });
              await startFromPlan(next.plan.id, next.day.day_number);
              return;
            }
          } catch { /* fall through to picker if next-workout lookup fails */ }
          // ── Fall back to manual plan picker ───────────────────────────────
          plans = await getPlans();
          showPicker = true;
          loading = false;
        }
      }
    } catch (e) {
      error = 'Failed to start workout: ' + (e instanceof Error ? e.message : String(e));
      loading = false;
    }
  });

  onDestroy(() => {
    if (clockInterval) clearInterval(clockInterval);
    if (restInterval) clearInterval(restInterval);
    if (draftSaveInterval) clearInterval(draftSaveInterval);
  });

  // Save drafts when app goes to background; recalculate rest timer on foreground
  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        if (sessionId) {
          saveDrafts();
          saveFeedbackDraftState();
        }
      } else {
        // App came back to foreground — catch up the rest timer
        if (restActive && restEndTime > 0) {
          const remaining = Math.ceil((restEndTime - Date.now()) / 1000);
          if (remaining <= 0) {
            restSecs = 0;
            if (restInterval) { clearInterval(restInterval); restInterval = null; }
            restActive = false;
            playRestChime();
          } else {
            restSecs = remaining;
          }
        }
      }
    });
    window.addEventListener('beforeunload', () => {
      if (sessionId) {
        const anyDone = uiExercises.some(ex => ex.sets.some(s => s.done));
        if (!anyDone) {
          // No sets completed — silently delete the empty planned session
          const token = localStorage.getItem('hgt_access_token');
          fetch(`/api/sessions/${sessionId}`, {
            method: 'DELETE',
            keepalive: true,
            headers: token ? { Authorization: `Bearer ${token}` } : {},
          });
        } else {
          saveDrafts();
          saveFeedbackDraftState();
        }
      }
    });
  }

  // Auto-cancel empty sessions on navigation; save drafts for in-progress ones
  beforeNavigate(() => {
    if (sessionId) {
      const anyDone = uiExercises.some(ex => ex.sets.some(s => s.done));
      if (!anyDone) {
        // No sets completed — delete the empty planned session silently
        deleteSession(sessionId).catch(() => {});
        sessionId = null;
        currentSession.set(null);
      } else {
        saveDrafts();
        saveFeedbackDraftState();
      }
    }
  });

  // ─── Start helpers ────────────────────────────────────────────────────────
  function sessionMatchesRequestedDay(session: WorkoutSession, plan: WorkoutPlan, day: PlannedDay): boolean {
    if (session.workout_plan_id !== plan.id) return false;
    if (!session.name) return false;
    return session.name === `${plan.name} - ${day.day_name}`;
  }

  async function startFromPlan(planId: number, dayNumber: number) {
    loading = true;
    showPicker = false;
    try {
      const bodyWtKg = $latestBodyWeight?.weight_kg ?? 0;
      const plan = await getPlan(planId);
      activePlan = plan;
      activePlanDayNumber = dayNumber;
      const day = plan.days.find(d => d.day_number === dayNumber) ?? plan.days[0];
      if (!day) throw new Error(`Plan ${planId} has no day ${dayNumber}`);
      let raw;
      try {
        raw = await createSessionFromPlan(planId, dayNumber, $settings.progressionStyle, bodyWtKg);
      } catch (e: any) {
        if (e?.response?.status === 409) {
          // Only resume automatically when the in-progress session matches the requested day.
          const detail = e?.response?.data?.detail;
          const existingId: number | null =
            detail && typeof detail === 'object' ? detail.session_id ?? null : null;
          if (existingId != null) {
            const existing = await getSession(existingId);
            if (sessionMatchesRequestedDay(existing, plan, day)) {
              currentSession.set(existing);
              await resumeSession();
              return;
            }
            conflictSession = existing;
            conflictRetry = () => startFromPlan(planId, dayNumber);
            conflictRequestedName = `${plan.name} - ${day.day_name}`;
            loading = false;
            return;
          }

          // Fallback: only auto-resume a matching in-progress session.
          const sessions = await getSessions({ limit: 5 });
          const matching = sessions.find(s =>
            s.started_at && !s.completed_at && sessionMatchesRequestedDay(s, plan, day)
          );
          if (matching) {
            currentSession.set(matching);
            await resumeSession();
            return;
          }

          const inProgress = sessions.find(s => s.started_at && !s.completed_at);
          if (inProgress) {
            conflictSession = await getSession(inProgress.id);
            conflictRetry = () => startFromPlan(planId, dayNumber);
            conflictRequestedName = `${plan.name} - ${day.day_name}`;
            loading = false;
            return;
          }

          await handleConflict(e, () => startFromPlan(planId, dayNumber));
          return;
        }
        throw e;
      }
      sessionId = raw.id;
      workoutName = raw.name ?? 'Workout';
      hasLinkedPlan = true;
      currentSession.set(raw);

      if (day) {
        const sessionBlocks = groupSessionSetsByBlock(raw.sets);
        const unusedByExercise = new Map<number, SessionSetBlock[]>();
        for (const block of sessionBlocks) {
          const existing = unusedByExercise.get(block.exerciseId) ?? [];
          existing.push(block);
          unusedByExercise.set(block.exerciseId, existing);
        }
        const usedBlockKeys = new Set<string>();

        uiExercises = day.exercises.map(pe => {
          const exercise = allExercises.find(e => e.id === pe.exercise_id);
          const isUni = exercise?.is_unilateral ?? false;
          let matchedBlock =
            (pe.block_id
              ? sessionBlocks.find((block) => block.blockId === pe.block_id)
              : null) ?? null;
          if (!matchedBlock) {
            const candidates = unusedByExercise.get(pe.exercise_id) ?? [];
            matchedBlock = candidates.find((block) => !usedBlockKeys.has(block.key)) ?? null;
          }
          if (matchedBlock) usedBlockKeys.add(matchedBlock.key);
          const blockId = pe.block_id ?? matchedBlock?.blockId ?? makeBlockId();
          const sets: UISet[] = [];
          for (let i = 1; i <= pe.sets; i++) {
            const bset = matchedBlock?.sets.find((s) => s.set_number === i);
            // Pre-fill with progressive overload suggestions when available (0 = blank)
            // Round suggested weights to nearest increment — user inputs stay unrounded
            const suggestedWeight = bset?.planned_weight_kg != null && bset.planned_weight_kg > 0
              ? roundWeight(fromKg(bset.planned_weight_kg))
              : null;
            const suggestedReps = (bset?.planned_reps ?? 0) > 0 ? bset!.planned_reps : null;
            // Per-side planned reps for unilateral exercises (null for bilateral)
            const suggestedRepsLeft  = (bset?.planned_reps_left  ?? 0) > 0 ? bset!.planned_reps_left  : null;
            const suggestedRepsRight = (bset?.planned_reps_right ?? 0) > 0 ? bset!.planned_reps_right : null;

            // Compute 1RM anchor so the user can freely adjust weight or reps
            // and have the other field auto-fill via Epley.
            const refRepsForOneRM = suggestedRepsLeft ?? suggestedReps;
            const oneRM = (suggestedWeight != null && suggestedWeight > 0 &&
                           refRepsForOneRM != null && refRepsForOneRM > 0)
              ? suggestedWeight * (1 + refRepsForOneRM / 30)
              : null;

            // Restore draft values if the user was mid-workout (cross-device sync)
            const hasDraft = bset?.draft_weight_kg != null || bset?.draft_reps != null;
            const draftWeight = bset?.draft_weight_kg != null ? roundWeight(fromKg(bset.draft_weight_kg)) : null;
            const draftReps = bset?.draft_reps ?? null;
            const draftLeft = bset?.draft_reps_left ?? null;
            const draftRight = bset?.draft_reps_right ?? null;

            sets.push({
              localId: `${blockId}-${i}`,
              backendId: bset?.id ?? null,
              setNumber: i,
              weightLbs: hasDraft ? draftWeight : suggestedWeight,
              reps: hasDraft ? draftReps : suggestedReps,
              // Pre-fill L/R with draft values, then per-side planned reps,
              // falling back to the bilateral planned_reps.
              repsLeft:  (hasDraft && draftLeft != null) ? draftLeft : (suggestedRepsLeft ?? suggestedReps),
              repsRight: (hasDraft && draftRight != null) ? draftRight : (suggestedRepsRight ?? suggestedReps),
              done: !!bset?.completed_at,
              skipped: !!bset?.skipped_at,
              doneLeft: !!bset?.completed_at,
              doneRight: !!bset?.completed_at,
              saving: false,
              oneRM,
              initWeight: suggestedWeight,
              initReps:   suggestedReps,
              isExtrapolated: bset?.is_extrapolated ?? false,
              setType: bset?.set_type || 'standard',
              partialReps: bset?.sub_sets?.find((d: any) => d.type === 'partial')?.reps ?? null,
              drops: bset?.sub_sets ? bset.sub_sets.filter((d: any) => d.type !== 'partial').map((d: any) => ({
                weightLbs: d.weight_kg ? fromKg(d.weight_kg) : null,
                reps: d.reps ?? null,
              })) : [],
              pegWeights: bset?.peg_weights ? {
                peg1: fromKg(bset.peg_weights.peg1 ?? 0),
                peg2: fromKg(bset.peg_weights.peg2 ?? 0),
                peg3: fromKg(bset.peg_weights.peg3 ?? 0),
              } : null,
            });
          }
          return {
            uiId: `${pe.exercise_id}-${Date.now()}-${Math.random()}`,
            blockId,
            persistKey: makePersistKey(blockId, pe.exercise_id, sets, `${Date.now()}-${Math.random()}`),
            exerciseId: pe.exercise_id,
            sets,
            isUnilateral: isUni,
            customRestSecs: null,
            groupId: pe.group_id ?? null,
            groupType: pe.group_type ?? null,
          };
        });
      }

      // Clock starts on first set completion, not here (#524)
    } catch (e) {
      error = 'Failed to start workout: ' + (e instanceof Error ? e.message : String(e));
    } finally {
      loading = false;
    }
  }

  function startClockIfNeeded() {
    if (startedAt !== null) return;
    startedAt = Date.now();
  }

  async function startFreeSession() {
    loading = true;
    showPicker = false;
    try {
      let raw;
      try {
        raw = await createSession({
          date: new Date().toISOString().split('T')[0],
          name: `Workout – ${new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}`,
        });
      } catch (e: any) {
        if (e?.response?.status === 409) {
          await handleConflict(e, startFreeSession);
          return;
        }
        throw e;
      }
      sessionId = raw.id;
      workoutName = raw.name ?? 'Workout';
      currentSession.set(raw);

      // Clock starts on first set completion, not here (#524)
    } catch (e) {
      error = 'Failed to start workout: ' + (e instanceof Error ? e.message : String(e));
    } finally {
      loading = false;
    }
  }

  // ─── Resume in-progress session ───────────────────────────────────────────
  async function resumeSession() {
    loading = true;
    try {
      const sess = await getSession($currentSession!.id);
      sessionId = sess.id;
      workoutName = sess.name ?? 'Workout';
      hasLinkedPlan = sess.workout_plan_id != null;
      currentSession.set(sess);
      if (sess.workout_plan_id) {
        try {
          activePlan = await getPlan(sess.workout_plan_id);
          activePlanDayNumber = sess.plan_day_number ?? null;
        } catch { /* non-critical */ }
      }

      if (sess.started_at) {
        startedAt = parseUtcMs(sess.started_at);
      } else {
        startedAt = null;
      }

      const blocks = groupSessionSetsByBlock(sess.sets);

      const bwKg = $latestBodyWeight?.weight_kg ?? 0;

      uiExercises = blocks.map((block, blockIndex) => {
        const exerciseId = block.exerciseId;
        const exercise = allExercises.find(e => e.id === exerciseId);
        const isUni = exercise?.is_unilateral ?? false;
        const isAss = exercise?.is_assisted ?? false;
        const backendSets = block.sets;
        const blockIdentity = block.blockId ?? null;
        const blockLocalKey = blockIdentity ?? `legacy-${exerciseId}-${blockIndex}`;

        const sets: UISet[] = backendSets.map(bset => {
          const isDone = bset.completed_at != null;
          let weightVal: number | null = null;

          if (isDone) {
            // Completed: use actual values
            if (bset.actual_weight_kg != null && bset.actual_weight_kg > 0) {
              weightVal = fromKg(bset.actual_weight_kg);
            }
          } else if (bset.draft_weight_kg != null) {
            // Incomplete with draft: user was mid-edit before navigating away
            weightVal = roundWeight(fromKg(bset.draft_weight_kg));
          } else if (bset.planned_weight_kg != null && bset.planned_weight_kg > 0) {
            // Incomplete: use planned/suggested weight (rounded to nearest increment)
            weightVal = roundWeight(fromKg(bset.planned_weight_kg));
          }

          let repsVal: number | null;
          if (isDone) {
            repsVal = bset.actual_reps;
          } else {
            repsVal = bset.draft_reps ?? bset.planned_reps ?? null;
          }

          // Parse L/R from notes for completed unilateral sets
          let repsLeft  = isUni ? repsVal : null;
          let repsRight = isUni ? repsVal : null;
          if (isDone && isUni && bset.notes) {
            const lm = bset.notes.match(/L:(\d+)/);
            const rm = bset.notes.match(/R:(\d+)/);
            if (lm) repsLeft  = parseInt(lm[1]);
            if (rm) repsRight = parseInt(rm[1]);
          } else if (!isDone && isUni) {
            repsLeft = bset.draft_reps_left ?? repsVal;
            repsRight = bset.draft_reps_right ?? repsVal;
          }

          // Assisted exercises store the assist amount directly — no BW math needed.
          const sugW = bset.planned_weight_kg != null && bset.planned_weight_kg > 0
            ? roundWeight(fromKg(bset.planned_weight_kg))
            : null;
          const sugR = bset.planned_reps ?? null;
          const oneRM = sugW && sugW > 0 && sugR && sugR > 0 ? sugW * (1 + sugR / 30) : null;

          return {
            localId: `${blockLocalKey}-${bset.set_number}-resume`,
            backendId: bset.id,
            setNumber: bset.set_number,
            weightLbs: weightVal,
            reps: repsVal,
            repsLeft,
            repsRight,
            done: isDone,
            skipped: !!bset.skipped_at,
            doneLeft: isDone,
            doneRight: isDone,
            saving: false,
            oneRM,
            initWeight: sugW,
            initReps: sugR,
            isExtrapolated: bset.is_extrapolated ?? false,
            setType: bset.set_type || 'standard',
            partialReps: bset.sub_sets?.find((d: any) => d.type === 'partial')?.reps ?? null,
            drops: bset.sub_sets ? bset.sub_sets.filter((d: any) => d.type !== 'partial').map((d: any) => ({
              weightLbs: d.weight_kg ? fromKg(d.weight_kg) : null,
              reps: d.reps ?? null,
            })) : [],
            pegWeights: bset.peg_weights ? {
              peg1: fromKg(bset.peg_weights.peg1 ?? 0),
              peg2: fromKg(bset.peg_weights.peg2 ?? 0),
              peg3: fromKg(bset.peg_weights.peg3 ?? 0),
            } : null,
          };
        });

        return {
          uiId: `${exerciseId}-${Date.now()}-${Math.random()}`,
          blockId: blockIdentity,
          persistKey: makePersistKey(blockIdentity, exerciseId, sets, `${Date.now()}-${Math.random()}`),
          exerciseId,
          sets,
          isUnilateral: isUni,
          customRestSecs: null,
          groupId: null,
          groupType: null,
        };
      });

      // Restore user-defined planning-stage structure if they changed it during this session
      uiExercises = loadSessionStructure(uiExercises);

      await restoreFeedbackState(sess.id);
    } catch (e) {
      error = 'Failed to resume workout: ' + (e instanceof Error ? e.message : String(e));
    } finally {
      loading = false;
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────
  function getEx(id: number) { return allExercises.find(e => e.id === id); }

  /**
   * Parse a datetime string from the backend as UTC.
   * The backend stores naive datetimes (no tz suffix) that are always UTC.
   * JS's Date() treats strings without a tz suffix as LOCAL time, so we
   * must append 'Z' if no offset is already present.
   */
  function parseUtcMs(ts: string): number {
    if (!ts) return Date.now();
    const hasOffset = ts.endsWith('Z') || /[+-]\d{2}:\d{2}$/.test(ts);
    return new Date(hasOffset ? ts : ts + 'Z').getTime();
  }

  function formatRest(s: number) {
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  }

  // ─── Epley bi-directional helpers ────────────────────────────────────────
  function epleyReps(oneRM: number, weight: number): number {
    if (weight <= 0) return 0;
    // Round to nearest integer (not nearest 5) so small weight changes produce
    // smooth, proportional rep adjustments rather than large 5-rep jumps.
    return Math.max(1, Math.round((oneRM / weight - 1) * 30));
  }
  function epleyWeight(oneRM: number, reps: number): number {
    if (reps <= 0) return 0;
    return roundWeight(oneRM / (1 + reps / 30));
  }
  // Returns true if currentWeight is close enough to initWeight to show a rep
  // recommendation. Bounds: ±20% (compound) or ±15% (isolation), floor ±5 lbs.
  function withinWeightBounds(currentWeight: number | null, initWeight: number | null, isCompound: boolean): boolean {
    if (currentWeight == null || currentWeight <= 0) return false;
    if (initWeight == null || initWeight <= 0) return true;
    const pct = isCompound ? 0.20 : 0.15;
    const bound = Math.max(initWeight * pct, 5);
    return Math.abs(currentWeight - initWeight) <= bound;
  }

  // Sync myo_rep_match sets: copy weight/reps from set 1 to all match sets
  function syncMyoMatchSets(ex: typeof uiExercises[0]) {
    const set1 = ex.sets[0];
    if (!set1) return;
    for (let i = 1; i < ex.sets.length; i++) {
      const s = ex.sets[i];
      if (s.setType === 'myo_rep_match' && !s.done) {
        s.weightLbs = set1.weightLbs;
        s.reps = set1.reps;
        if (ex.isUnilateral) {
          s.repsLeft = set1.repsLeft;
          s.repsRight = set1.repsRight;
        }
      }
    }
  }

  function isMyoMatchLocked(ex: typeof uiExercises[0], set: typeof ex.sets[0]): boolean {
    const idx = ex.sets.indexOf(set);
    return set.setType === 'myo_rep_match' && idx > 0;
  }

  // Returns a warning string if the current values deviate significantly from
  // the initial Epley suggestion, null otherwise.
  function deviationWarning(set: UISet, currentWeight: number | null, currentReps: number | null, isAssisted = false): string | null {
    if (!set.oneRM || set.done) return null;
    const w = currentWeight ?? set.weightLbs;
    const r = currentReps ?? set.reps;
    if (w == null || r == null || w <= 0 || r <= 0) return null;
    const sugW = set.initWeight;
    const sugR = set.initReps;
    if (sugW == null || sugR == null) return null;
    if (isAssisted) {
      // For assisted exercises, lower assist = harder. Warn only when assist
      // drops dramatically (>20%), which would be a large difficulty spike.
      if (w < sugW && (sugW - w) / sugW > 0.20) {
        return `Large assist reduction — difficulty spike may be too aggressive.`;
      }
      return null;
    }
    // Only warn when weight is being pushed UP by more than 20%
    if (w > sugW && (w - sugW) / sugW > 0.20) {
      return `Large weight increase from last session — Epley estimate is less precise this far from baseline. Jumping weight rapidly increases injury risk.`;
    }
    return null;
  }

  function muscleLabel(id: number) {
    const ex = getEx(id);
    if (!ex) return '';
    return ex.primary_muscles.slice(0, 2).map(m => m.replace(/_/g, ' ')).join(', ');
  }

  // ─── Progress ─────────────────────────────────────────────────────────────
  let totalSets      = $derived(uiExercises.reduce((s, ex) => s + ex.sets.length, 0));
  let doneSets       = $derived(uiExercises.reduce((s, ex) => s + ex.sets.filter(st => st.done).length, 0));
  let skippedSets    = $derived(uiExercises.reduce((s, ex) => s + ex.sets.filter(st => st.skipped).length, 0));
  let incompleteSets = $derived(totalSets - doneSets - skippedSets);
  let pct = $derived(totalSets > 0 ? Math.round((doneSets / totalSets) * 100) : 0);

  // ─── Draft auto-save (cross-device sync) ─────────────────────────────────
  let draftSaveInterval: ReturnType<typeof setInterval> | null = null;

  // Save drafts every 5 seconds while a workout is active
  $effect(() => {
    if (sessionId && uiExercises.length > 0) {
      if (!draftSaveInterval) {
        draftSaveInterval = setInterval(() => saveDrafts(), 5000);
      }
    }
    return () => {
      if (draftSaveInterval) { clearInterval(draftSaveInterval); draftSaveInterval = null; }
    };
  });

  async function saveDrafts() {
    if (!sessionId) return;
    for (const ex of uiExercises) {
      for (const set of ex.sets) {
        if (set.done || !set.backendId) continue;
        // Only save if user has typed something
        if (set.weightLbs == null && set.reps == null) continue;
        try {
          await updateSet(sessionId, set.backendId, {
            draft_weight_kg: set.weightLbs != null ? toKg(set.weightLbs) : null,
            draft_reps: set.reps,
            ...(ex.isUnilateral && {
              draft_reps_left: set.repsLeft,
              draft_reps_right: set.repsRight,
            }),
            ...(set.pegWeights && { peg_weights: JSON.stringify({
              peg1: toKg(set.pegWeights.peg1),
              peg2: toKg(set.pegWeights.peg2),
              peg3: toKg(set.pegWeights.peg3),
            }) }),
          });
        } catch { /* ignore individual failures */ }
      }
    }
  }

  // ─── Set actions ──────────────────────────────────────────────────────────
  async function completeSet(exUiId: string, localId: string) {
    if (!sessionId) return;
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;
    const set = ex.sets.find(s => s.localId === localId);
    if (!set || set.done || set.saving) return;

    // Don't allow completing a set with 0 reps
    const effectiveRepsCheck = ex.isUnilateral
      ? Math.min(set.repsLeft ?? 0, set.repsRight ?? 0)
      : (set.reps ?? 0);
    if (effectiveRepsCheck <= 0) return;

    set.saving = true;
    uiExercises = [...uiExercises];

    try {
      let bId = set.backendId;

      const exercise    = getEx(ex.exerciseId);
      const isAssisted  = exercise?.is_assisted ?? false;
      const assistVal   = set.weightLbs ?? 0;
      // Store the assist amount directly (not net load) so the backend can
      // read it back without needing body weight, and progression reduces it.
      const weightKg    = toKg(assistVal);

      if (bId === null) {
        const created = await addSet(sessionId, {
          exercise_id: ex.exerciseId,
          exercise_block_id: ex.blockId ?? undefined,
          set_number: set.setNumber,
          planned_reps: set.reps ?? undefined,
          planned_weight_kg: weightKg,
          ...(set.setType !== 'standard' && { set_type: set.setType }),
        });
        bId = created.id;
        set.backendId = bId;
      }

      // For unilateral: weaker side is the limiting factor
      const effectiveReps = ex.isUnilateral
        ? Math.min(set.repsLeft ?? 0, set.repsRight ?? 0)
        : (set.reps ?? 0);

      const notes = [
        ex.isUnilateral ? `L:${set.repsLeft ?? 0} R:${set.repsRight ?? 0}` : '',
        isAssisted      ? `assist:${assistVal}${unit}` : '',
      ].filter(Boolean).join(' ') || undefined;

      const subSetsData = set.setType === 'drop_set' && set.drops.length > 0
        ? set.drops.filter(d => d.weightLbs || d.reps).map(d => ({
            weight_kg: d.weightLbs ? toKg(d.weightLbs) : 0,
            reps: d.reps ?? 0,
          }))
        : set.setType === 'standard_partials' && set.partialReps
        ? [{ weight_kg: weightKg, reps: set.partialReps, type: 'partial' }]
        : undefined;

      await updateSet(sessionId, bId, {
        actual_reps: effectiveReps,
        actual_weight_kg: weightKg,
        completed_at: new Date().toISOString(),
        ...(ex.isUnilateral && { reps_left: set.repsLeft ?? 0, reps_right: set.repsRight ?? 0 }),
        ...(notes && { notes }),
        ...(set.setType !== 'standard' && { set_type: set.setType }),
        ...(subSetsData && subSetsData.length > 0 && { sub_sets: subSetsData }),
        ...(set.pegWeights && { peg_weights: JSON.stringify({
          peg1: toKg(set.pegWeights.peg1),
          peg2: toKg(set.pegWeights.peg2),
          peg3: toKg(set.pegWeights.peg3),
        }) }),
      });

      set.reps = effectiveReps; // sync reps field for drop-off calc
      set.done = true;
      startClockIfNeeded(); // Start timer on first set completion (#524)

      // Sync myo match sets with set 1's final values
      syncMyoMatchSets(ex);

      // Weight: propagate to all subsequent undone sets that are still blank
      const pendingSets = ex.sets.filter(s => !s.done && s.localId !== localId);
      for (const s of pendingSets) {
        if (!s.weightLbs) s.weightLbs = set.weightLbs;
      }

      // ── Inter-set rep drop-off ────────────────────────────────────────
      // Weight stays constant each set; reps drop by bracket:
      //   4–9  reps → −1 per set
      //   10–16 reps → −2 per set
      //   17+   reps → −3 per set
      //
      // Floor rule: if the natural drop would go below 5 reps, keep reps
      // at 5 and reduce weight via Epley to maintain equivalent effort.
      // (Same 1RM as if you'd done the natural lower rep count at full weight.)
      const REP_FLOOR = 5;

      function repDrop(baseReps: number): number {
        if (baseReps >= 17) return 3;
        if (baseReps >= 10) return 2;
        return 1;
      }

      // Epley: weight to use for targetReps given prior weight × priorReps
      function epleyWeightForReps(w: number, doneReps: number, targetReps: number): number {
        if (doneReps <= 0) doneReps = 1; // guard: Epley invalid for 0/negative reps
        const oneRM = w * (1 + doneReps / 30);
        const raw   = oneRM / (1 + targetReps / 30);
        return roundWeight(raw); // respects lbs (nearest 5) vs kg (nearest 2.5)
      }

      function setForPosition(
        baseWeight: number, baseReps: number, position: number
      ): { weight: number; reps: number } {
        const drop        = repDrop(baseReps);
        const naturalReps = baseReps - drop * position;
        if (naturalReps >= REP_FLOOR) {
          return { weight: baseWeight, reps: naturalReps };
        }
        // Below the floor → keep 5 reps, reduce weight via Epley.
        // Clamp to at least 1 rep for valid Epley input.
        const clampedReps = Math.max(1, naturalReps);
        const w = epleyWeightForReps(baseWeight, clampedReps, REP_FLOOR);
        return { weight: Math.max(0, w), reps: REP_FLOOR };
      }

      const completedWeight = isAssisted
        ? Math.max(0, bodyWeightInUnit - assistVal)
        : (set.weightLbs ?? 0);

      // Drop-off only applies to sets with no backend-planned weight.
      // Week 2+ sets already have per-set planned values from the server
      // (initWeight !== null) — those should be left untouched.
      const week1PendingSets = pendingSets.filter(s => s.initWeight === null && s.setType !== 'myo_rep_match');

      if (ex.isUnilateral) {
        const leftReps  = set.repsLeft  ?? 0;
        const rightReps = set.repsRight ?? 0;
        const refReps   = leftReps > 0 && rightReps > 0
          ? Math.min(leftReps, rightReps)
          : (leftReps || rightReps);

        if (refReps > 0 && completedWeight > 0) {
          week1PendingSets.forEach((s, idx) => {
            const { weight, reps } = setForPosition(completedWeight, refReps, idx + 1);
            s.repsLeft  = reps;
            s.repsRight = reps;
            if (isAssisted) {
              if (weight < completedWeight) {
                const netDrop = completedWeight - weight;
                s.weightLbs = roundWeight((set.weightLbs ?? 0) + netDrop);
              } else {
                s.weightLbs = set.weightLbs;
              }
            } else {
              s.weightLbs = weight;
            }
          });
        }
      } else {
        if (effectiveReps > 0 && completedWeight > 0) {
          week1PendingSets.forEach((s, idx) => {
            const { weight, reps } = setForPosition(completedWeight, effectiveReps, idx + 1);
            s.reps = reps;
            if (isAssisted) {
              // For assisted: keep same assist amount unless Epley dropped the weight
              if (weight < completedWeight) {
                // Epley floor kicked in — increase assist to maintain equivalent effort
                const netDrop = completedWeight - weight;
                s.weightLbs = roundWeight((set.weightLbs ?? 0) + netDrop);
              } else {
                // Reps dropped but weight same — keep assist unchanged
                s.weightLbs = set.weightLbs;
              }
            } else {
              s.weightLbs = weight;
            }
          });
        }
      }
      // Check for PR before rest timer
      checkForPR(ex, set);
      // Start rest timer (group-aware for supersets/circuits)
      ensureNotificationPermission();
      handlePostSetCompletion(exUiId);
    } catch (e) {
      console.error('Failed to complete set:', e);
      alert('Failed to save set. Please try again.');
    } finally {
      set.saving = false;
      uiExercises = [...uiExercises];
    }
  }

  // ─── Per-side completion for unilateral exercises ───────────────────────
  async function completeSide(exUiId: string, localId: string, side: 'left' | 'right') {
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex || !ex.isUnilateral) return;
    const set = ex.sets.find(s => s.localId === localId);
    if (!set || set.done || set.skipped) return;

    const reps = side === 'left' ? (set.repsLeft ?? 0) : (set.repsRight ?? 0);
    if (reps <= 0) return;

    if (side === 'left') set.doneLeft = true;
    else set.doneRight = true;
    uiExercises = [...uiExercises];

    // Auto-complete when both sides done
    if (set.doneLeft && set.doneRight) {
      await completeSet(exUiId, localId);
    } else {
      // Only start rest timer, don't complete
      handlePostSetCompletion(exUiId);
    }
  }

  function undoSide(exUiId: string, localId: string, side: 'left' | 'right') {
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;
    const set = ex.sets.find(s => s.localId === localId);
    if (!set || set.done) return; // if fully done, use uncompleteSet instead

    if (side === 'left') set.doneLeft = false;
    else set.doneRight = false;
    uiExercises = [...uiExercises];
  }

  async function removeSet(exUiId: string, localId: string) {
    if (!sessionId) return;
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;
    const set = ex.sets.find(s => s.localId === localId);
    if (!set) return;

    if (set.backendId !== null) {
      try { await deleteSet(sessionId, set.backendId); } catch { /* ignore */ }
    }

    ex.sets = ex.sets.filter(s => s.localId !== localId);
    ex.sets.forEach((s, i) => { s.setNumber = i + 1; });
    uiExercises = [...uiExercises];

    // Reset timer if no sets are done anymore
    resetTimerIfNoDoneSets();
  }

  function addSetRow(exUiId: string) {
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;
    const last = ex.sets[ex.sets.length - 1];
    ex.sets = [...ex.sets, {
      localId: `${ex.blockId ?? ex.persistKey}-${ex.sets.length + 1}-${Date.now()}`,
      backendId: null,
      setNumber: ex.sets.length + 1,
      weightLbs: last?.weightLbs ?? null,
      reps: null, repsLeft: null, repsRight: null,
      done: false,
      skipped: false,
      doneLeft: false,
      doneRight: false,
      saving: false,
      oneRM: last?.oneRM ?? null,
      initWeight: null,
      initReps: null,
      setType: ex.sets[0]?.setType || 'standard',
      partialReps: null, drops: [], pegWeights: null,
    }];
    uiExercises = [...uiExercises];
  }

  function generateWarmups(exUiId: string) {
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;

    // Find the first working set's weight as the target
    const workingSet = ex.sets.find(s => s.setType !== 'warmup' && s.weightLbs != null && s.weightLbs > 0);
    if (!workingSet || !workingSet.weightLbs) return;
    const target = workingSet.weightLbs;

    const exercise = getEx(ex.exerciseId);
    const barWeight = getBarWeight(exercise);

    // Check if this muscle group was already warmed up by a prior exercise
    const myMuscles = exercise?.primary_muscles ?? [];
    const exIdx = uiExercises.indexOf(ex);
    const alreadyWarmed = exIdx > 0 && uiExercises.slice(0, exIdx).some(prev => {
      const prevEx = getEx(prev.exerciseId);
      const prevMuscles = prevEx?.primary_muscles ?? [];
      const overlap = myMuscles.some(m => prevMuscles.includes(m));
      const hasDoneSets = prev.sets.some(s => s.done || s.setType === 'warmup');
      return overlap && hasDoneSets;
    });

    // Standard warmup ramp
    const fullScheme = [
      { pct: 0, reps: 10 },    // empty bar
      { pct: 0.5, reps: 5 },
      { pct: 0.7, reps: 3 },
      { pct: 0.85, reps: 1 },
    ];

    // If muscles already warmed, just do 1 set at 70%
    if (alreadyWarmed) {
      const warmupScheme = [{ pct: 0.7, reps: 3 }];
      const warmupSets: typeof ex.sets = [];
      for (const w of warmupScheme) {
        const weight = roundWeight(target * w.pct);
        if (weight >= target) continue;
        warmupSets.push({
          localId: `${ex.exerciseId}-warmup-0-${Date.now()}`,
          backendId: null, setNumber: 1,
          weightLbs: weight, reps: w.reps,
          repsLeft: ex.isUnilateral ? w.reps : null,
          repsRight: ex.isUnilateral ? w.reps : null,
          done: false, skipped: false, doneLeft: false, doneRight: false,
          saving: false, oneRM: null, initWeight: null, initReps: null,
          setType: 'warmup', partialReps: null, drops: [], pegWeights: null,
        });
      }
      ex.sets = ex.sets.filter(s => s.setType !== 'warmup');
      ex.sets = [...warmupSets, ...ex.sets];
      ex.sets.forEach((s, i) => { s.setNumber = i + 1; });
      uiExercises = [...uiExercises];
      return;
    }

    // Trim to user's max warmup sets setting
    const maxSets = $settings.maxWarmupSets ?? 4;
    const warmupScheme = fullScheme.slice(-maxSets);

    const warmupSets: typeof ex.sets = [];
    for (const w of warmupScheme) {
      const rawWeight = w.pct === 0 ? barWeight : target * w.pct;
      const weight = roundWeight(rawWeight);
      // Skip if warmup weight is same as or more than working weight
      if (weight >= target) continue;
      // Skip duplicate weights
      if (warmupSets.some(s => s.weightLbs === weight)) continue;

      warmupSets.push({
        localId: `${ex.exerciseId}-warmup-${warmupSets.length}-${Date.now()}`,
        backendId: null,
        setNumber: warmupSets.length + 1,
        weightLbs: weight,
        reps: w.reps,
        repsLeft: ex.isUnilateral ? w.reps : null,
        repsRight: ex.isUnilateral ? w.reps : null,
        done: false,
        skipped: false,
        doneLeft: false,
        doneRight: false,
        saving: false,
        oneRM: null,
        initWeight: null,
        initReps: null,
        setType: 'warmup',
        partialReps: null, drops: [], pegWeights: null,
      });
    }

    if (warmupSets.length === 0) return;

    // Remove existing warmup sets
    ex.sets = ex.sets.filter(s => s.setType !== 'warmup');
    // Prepend warmups, then renumber all sets
    ex.sets = [...warmupSets, ...ex.sets];
    ex.sets.forEach((s, i) => { s.setNumber = i + 1; });
    uiExercises = [...uiExercises];
  }

  function exerciseOrderKey(sid: number | null) {
    return sid ? `hgt_exercise_order_${sid}` : null;
  }

  function exerciseStructureKey(sid: number | null) {
    return sid ? `hgt_session_structure_${sid}` : null;
  }

  function saveSessionStructure() {
    const key = exerciseStructureKey(sessionId);
    if (!key || typeof localStorage === 'undefined') return;
    const payload: PersistedSessionExerciseStructure = {
      order: uiExercises.map(e => e.persistKey),
      groups: Object.fromEntries(
        uiExercises.map(e => [
          e.persistKey,
          { groupId: e.groupId, groupType: e.groupType },
        ]),
      ),
    };
    localStorage.setItem(key, JSON.stringify(payload));
  }

  function loadSessionStructure(exercises: UIExercise[]): UIExercise[] {
    if (typeof localStorage === 'undefined') return exercises;
    const structureKey = exerciseStructureKey(sessionId);
    const legacyOrderKey = exerciseOrderKey(sessionId);
    try {
      const rawStructure = structureKey ? localStorage.getItem(structureKey) : null;
      if (rawStructure) {
        const saved: PersistedSessionExerciseStructure = JSON.parse(rawStructure);
        const order = Array.isArray(saved.order) ? saved.order : [];
        const groups = saved.groups ?? {};
        const ordered = order
          .map(key => exercises.find(e => e.persistKey === key))
          .filter((e): e is UIExercise => e != null)
          .map((exercise) => {
            const group = groups[exercise.persistKey];
            return group
              ? { ...exercise, groupId: group.groupId ?? null, groupType: group.groupType ?? null }
              : exercise;
          });
        const rest = exercises
          .filter(e => !order.includes(e.persistKey))
          .map((exercise) => {
            const group = groups[exercise.persistKey];
            return group
              ? { ...exercise, groupId: group.groupId ?? null, groupType: group.groupType ?? null }
              : exercise;
          });
        return [...ordered, ...rest];
      }

      const savedOrder = legacyOrderKey ? localStorage.getItem(legacyOrderKey) : null;
      if (!savedOrder) return exercises;
      const order: number[] = JSON.parse(savedOrder);
      const ordered = order
        .map(id => exercises.find(e => e.exerciseId === id))
        .filter((e): e is UIExercise => e != null);
      const rest = exercises.filter(e => !order.includes(e.exerciseId));
      return [...ordered, ...rest];
    } catch {
      return exercises;
    }
  }

  function moveExercise(idx: number, dir: -1 | 1) {
    const target = idx + dir;
    if (target < 0 || target >= uiExercises.length) return;
    const arr = [...uiExercises];
    [arr[idx], arr[target]] = [arr[target], arr[idx]];
    uiExercises = arr;
    saveSessionStructure();
    persistReorderToPlan();
  }

  async function persistReorderToPlan() {
    if (!activePlan || !activePlanDayNumber) return;
    const day = activePlan.days.find(d => d.day_number === activePlanDayNumber);
    if (!day) return;
    const byBlockId = new Map<string, PlannedExercise>(
      day.exercises.filter(e => e.block_id).map(e => [e.block_id!, e])
    );
    const newOrder = uiExercises
      .map(ue => (ue.blockId ? byBlockId.get(ue.blockId) : undefined))
      .filter((e): e is PlannedExercise => e != null);
    // Append any plan exercises not represented in uiExercises
    const included = new Set(newOrder.map(e => e.block_id));
    const missing = day.exercises.filter(e => !included.has(e.block_id ?? ''));
    const reordered = [...newOrder, ...missing];
    const updatedDays = activePlan.days.map(d =>
      d.day_number === activePlanDayNumber ? { ...d, exercises: reordered } : d
    );
    try {
      const updated = await updatePlan(activePlan.id, {
        name: activePlan.name,
        description: activePlan.description ?? undefined,
        block_type: activePlan.block_type,
        duration_weeks: activePlan.duration_weeks,
        number_of_days: activePlan.number_of_days,
        days: updatedDays,
        auto_progression: activePlan.auto_progression,
        is_draft: activePlan.is_draft,
      });
      activePlan = updated;
    } catch (err) {
      console.error('Failed to persist exercise reorder to plan:', err);
    }
  }

  async function removeExercise(exUiId: string) {
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (ex && sessionId) {
      // Delete any saved backend sets so they don't pollute history
      const backendIds = ex.sets.filter(s => s.backendId !== null).map(s => s.backendId!);
      await Promise.allSettled(backendIds.map(id => deleteSet(sessionId!, id)));
    }
    uiExercises = uiExercises.filter(e => e.uiId !== exUiId);
    saveSessionStructure();

    // Reset timer if no sets are done anymore
    resetTimerIfNoDoneSets();
  }

  function resetTimerIfNoDoneSets() {
    const anyDone = uiExercises.some(e => e.sets.some(s => s.done));
    if (!anyDone) {
      startedAt = null;
    }
  }

  // ─── Rest timer ───────────────────────────────────────────────────────────
  function restDurationForExercise(exUiId: string): number {
    const uiEx = uiExercises.find(e => e.uiId === exUiId);
    if (uiEx?.customRestSecs != null) return uiEx.customRestSecs;
    const exercise = uiEx ? getEx(uiEx.exerciseId) : null;
    const d = $settings.restDurations;
    if (!exercise) return d.upperCompound;
    const isLower = exercise.body_region === 'lower' || exercise.body_region === 'full_body';
    const isCompound = exercise.movement_type === 'compound';
    if (isLower && isCompound)  return d.lowerCompound;
    if (isLower && !isCompound) return d.lowerIsolation;
    if (!isLower && isCompound) return d.upperCompound;
    return d.upperIsolation;
  }

  // ─── Superset/Circuit grouping ──────────────────────────────────────────
  let highlightedExUiId = $state<string | null>(null);
  let highlightTimeout: ReturnType<typeof setTimeout> | null = null;

  function handlePostSetCompletion(exUiId: string) {
    clearPlateBannerFocus();
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex?.groupId) {
      startRestTimer(exUiId);
      return;
    }
    const group = uiExercises.filter(e => e.groupId === ex.groupId);
    const myDone = ex.sets.filter(s => s.done || s.skipped).length;
    const allCaughtUp = group.every(g => g.sets.filter(s => s.done || s.skipped).length >= myDone);
    if (allCaughtUp) {
      startRestTimer(exUiId);
    } else {
      // Highlight next exercise in group
      const myIdx = group.indexOf(ex);
      const next = group[(myIdx + 1) % group.length];
      highlightedExUiId = next.uiId;
      if (highlightTimeout) clearTimeout(highlightTimeout);
      highlightTimeout = setTimeout(() => { highlightedExUiId = null; }, 5000);
      const el = document.querySelector(`[data-ex-uid="${next.uiId}"]`);
      el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
  }

  function toggleLink(exUiId: string) {
    const idx = uiExercises.findIndex(e => e.uiId === exUiId);
    if (idx <= 0) return;
    const current = uiExercises[idx];
    const above = uiExercises[idx - 1];

    if (current.groupId && current.groupId === above.groupId) {
      // Unlink: remove current from group
      current.groupId = null;
      current.groupType = null;
      // If only 1 left in old group, clear it too
      const remaining = uiExercises.filter(e => e.groupId === above.groupId);
      if (remaining.length === 1) { remaining[0].groupId = null; remaining[0].groupType = null; }
      else { const t = remaining.length >= 3 ? 'circuit' : 'superset'; remaining.forEach(e => e.groupType = t); }
    } else {
      // Link: join current to above's group (or create new)
      const gid = above.groupId || `g-${Date.now().toString(36)}`;
      above.groupId = gid;
      current.groupId = gid;
      const group = uiExercises.filter(e => e.groupId === gid);
      const t: 'superset' | 'circuit' = group.length >= 3 ? 'circuit' : 'superset';
      group.forEach(e => e.groupType = t);
    }
    uiExercises = [...uiExercises];
    saveSessionStructure();
  }

  /** Play a short chime using Web Audio API (no audio file needed) */
  function playRestChime() {
    // Haptic feedback
    try { navigator.vibrate?.([200, 100, 200]); } catch {}
    try {
      const ctx = new AudioContext();
      // Two-tone chime: C5 then E5
      const notes = [523.25, 659.25]; // Hz
      notes.forEach((freq, i) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.value = freq;
        gain.gain.setValueAtTime(0.3, ctx.currentTime + i * 0.15);
        gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + i * 0.15 + 0.4);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(ctx.currentTime + i * 0.15);
        osc.stop(ctx.currentTime + i * 0.15 + 0.4);
      });
      // Clean up after sounds finish
      setTimeout(() => ctx.close(), 1000);
    } catch {
      // Audio not available (e.g. no user gesture yet) — silently ignore
    }
  }

  let restEndTime = $state<number>(0); // absolute ms timestamp when rest ends
  let restNotifTimeout: ReturnType<typeof setTimeout> | null = null;

  /** Request notification permission (called on first set completion) */
  async function ensureNotificationPermission() {
    if (typeof Notification === 'undefined') return;
    if (Notification.permission === 'default') {
      await Notification.requestPermission();
    }
  }

  function startRestTimer(exUiId: string) {
    restSecs = restDurationForExercise(exUiId);
    restEndTime = Date.now() + restSecs * 1000;
    restActive = true;
    if (restInterval) clearInterval(restInterval);
    if (restNotifTimeout) clearTimeout(restNotifTimeout);

    restInterval = setInterval(() => {
      const remaining = Math.ceil((restEndTime - Date.now()) / 1000);
      restSecs = Math.max(0, remaining);
      if (restSecs <= 0) {
        clearInterval(restInterval!);
        restInterval = null;
        restActive = false;
        playRestChime();
      }
    }, 1000);

    // Schedule notification for when rest ends (works when app is backgrounded)
    if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
      restNotifTimeout = setTimeout(() => {
        try {
          new Notification('Rest Complete', {
            body: 'Time for your next set!',
            icon: '/icons/icon-192.png',
            tag: 'rest-timer', // replaces previous notification
            requireInteraction: false,
          });
        } catch { /* notification not supported in this context */ }
      }, restSecs * 1000);
    }
  }

  function skipRest() {
    if (restInterval) { clearInterval(restInterval); restInterval = null; }
    if (restNotifTimeout) { clearTimeout(restNotifTimeout); restNotifTimeout = null; }
    restActive = false;
    restEndTime = 0;
  }

  // ─── Add exercise modal ───────────────────────────────────────────────────
  let filteredExercises = $derived(
    (() => {
      const q = searchQuery.trim().toLowerCase();

      // Apply region + type filters first
      let pool = allExercises.filter(e => {
        if (filterRegion !== 'all' && e.body_region !== filterRegion) return false;
        if (filterType !== 'all' && e.movement_type !== filterType) return false;
        if (filterEquip !== 'all') {
          const prefix = e.name?.split('_')[0] ?? '';
          if (filterEquip === 'barbell' && prefix !== 'barbell') return false;
          if (filterEquip === 'dumbbell' && prefix !== 'db') return false;
          if (filterEquip === 'cable' && prefix !== 'cable') return false;
          if (filterEquip === 'machine' && prefix !== 'machine') return false;
          if (filterEquip === 'bodyweight' && !['bodyweight', 'body', 'weighted'].includes(prefix)) return false;
          if (filterEquip === 'kettlebell' && prefix !== 'kb') return false;
          if (filterEquip === 'smith' && prefix !== 'smith') return false;
          if (filterEquip === 'band' && prefix !== 'band') return false;
        }
        return true;
      });

      // When swapping, sort by relevance to the exercise being replaced
      if (swapTargetUiId) {
        const swapEx = uiExercises.find(e => e.uiId === swapTargetUiId);
        const origExercise = swapEx ? getEx(swapEx.exerciseId) : null;
        if (origExercise) {
          const origMuscles = new Set(origExercise.primary_muscles);
          const origType = origExercise.movement_type;
          pool.sort((a, b) => {
            const aMusc = a.primary_muscles.some(m => origMuscles.has(m)) ? 1 : 0;
            const bMusc = b.primary_muscles.some(m => origMuscles.has(m)) ? 1 : 0;
            const aType = a.movement_type === origType ? 1 : 0;
            const bType = b.movement_type === origType ? 1 : 0;
            const aScore = aMusc * 2 + aType;
            const bScore = bMusc * 2 + bType;
            return bScore - aScore;
          });
        }
      }

      if (!q) {
        // Show recents (matching filters) first, or full sorted list for swaps
        if (swapTargetUiId) return pool.slice(0, 50);
        const recentIds = new Set(recentExercises.map(e => e.id));
        const poolIds = new Set(pool.map(e => e.id));
        const recent = recentExercises.filter(e => poolIds.has(e.id)).slice(0, 10);
        const rest = pool.filter(e => !recentIds.has(e.id)).slice(0, 40);
        return [...recent, ...rest];
      }

      return pool
        .filter(e =>
          e.display_name.toLowerCase().includes(q) ||
          e.name.toLowerCase().includes(q) ||
          e.primary_muscles.some(m => m.replace(/_/g, ' ').includes(q))
        )
        .slice(0, 50);
    })()
  );

  async function openAddModal() {
    searchQuery = '';
    pickingExercise = null;
    pendingSets = 3;
    filterRegion = 'all';
    filterType = 'all';
    showAddModal = true;
    // Wait for Svelte to flush DOM updates, then focus immediately — no setTimeout needed
    await tick();
    searchInputEl?.focus();
  }

  function resetCustomExerciseForm(prefill = '') {
    customExerciseDisplayName = prefill;
    customMovementType = 'compound';
    customBodyRegion = 'upper';
    customPrimaryMuscles = [];
    customSecondaryMuscles = [];
  }

  function openCustomExerciseModal(prefill = searchQuery.trim()) {
    resetCustomExerciseForm(prefill);
    showCustomExerciseModal = true;
  }

  function closeCustomExerciseModal() {
    showCustomExerciseModal = false;
  }

  async function createCustomExerciseForWorkout() {
    const rawName = customExerciseDisplayName.trim();
    if (!rawName) return;
    if (customPrimaryMuscles.length === 0) {
      alert('Please select at least one primary muscle group');
      return;
    }

    const capitalizedDisplayName = rawName.replace(/\b\w/g, c => c.toUpperCase());
    const systemName = capitalizedDisplayName
      .toLowerCase()
      .replace(/[^\w\s]/g, '')
      .replace(/\s+/g, '_');

    // Detect Prime machines and prompt for equipment type
    let equipmentType: string | undefined;
    let isPrime = false;
    if (systemName.includes('prime')) {
      const isPlateLoaded = confirm(
        'This looks like a Prime Fitness machine.\n\n' +
        'Is it plate-loaded (has weight pegs)?\n\n' +
        'OK = Plate-loaded (3-peg tracking)\n' +
        'Cancel = Selectorized (pin-loaded stack)'
      );
      isPrime = true;
      equipmentType = isPlateLoaded ? 'plate_loaded' : 'machine';
    }

    try {
      const newExercise = await createExercise({
        name: systemName,
        display_name: capitalizedDisplayName,
        movement_type: customMovementType,
        body_region: customBodyRegion,
        ...(equipmentType && { equipment_type: equipmentType }),
        ...(isPrime && { is_prime: true }),
        primary_muscles: customPrimaryMuscles,
        secondary_muscles: customSecondaryMuscles,
      });
      allExercises = await getExercises();
      pickingExercise = newExercise;
      showCustomExerciseModal = false;
    } catch (error) {
      alert('Failed to create exercise: ' + (error instanceof Error ? error.message : 'Unknown error'));
    }
  }

  function confirmAdd() {
    if (!pickingExercise) return;

    if (swapTargetUiId) {
      // ── Swap mode: replace exercise in-place, keeping set count ────
      const idx = uiExercises.findIndex(e => e.uiId === swapTargetUiId);
      if (idx >= 0) {
        const oldEx = uiExercises[idx];
        const numSets = Math.max(oldEx.sets.length, 1);
        const newSets: UISet[] = Array.from({ length: numSets }, (_, i) => ({
          localId: `${pickingExercise!.id}-${i + 1}-${Date.now()}`,
          backendId: null,
          setNumber: i + 1,
          weightLbs: null,
          reps: null, repsLeft: null, repsRight: null,
          done: false,
          skipped: false,
          doneLeft: false,
          doneRight: false,
          saving: false,
          oneRM: null, initWeight: null, initReps: null,
          setType: 'standard' as string,
          partialReps: null, drops: [] as { weightLbs: number | null; reps: number | null }[], pegWeights: null as { peg1: number; peg2: number; peg3: number } | null,
        }));
        // Delete old backend sets
        for (const s of oldEx.sets) {
          if (s.backendId && sessionId) {
            deleteSet(sessionId, s.backendId).catch(() => {});
          }
        }
        const preservedBlockId = oldEx.blockId ?? makeBlockId();
        uiExercises[idx] = {
          uiId: `${pickingExercise.id}-${Date.now()}-${Math.random()}`,
          blockId: preservedBlockId,
          persistKey: oldEx.persistKey,
          exerciseId: pickingExercise.id,
          sets: newSets,
          isUnilateral: pickingExercise.is_unilateral,
          customRestSecs: null,
          groupId: oldEx.groupId,
          groupType: oldEx.groupType,
        };
        uiExercises = [...uiExercises];
        saveSessionStructure();
      }
      swapTargetUiId = null;
    } else {
      // ── Normal add mode ────────────────────────────────────────────
      const sets: UISet[] = Array.from({ length: pendingSets }, (_, i) => ({
        localId: `${pickingExercise!.id}-${i + 1}-${Date.now()}`,
        backendId: null,
        setNumber: i + 1,
        weightLbs: null,
        reps: null, repsLeft: null, repsRight: null,
        done: false,
        skipped: false,
        doneLeft: false,
        doneRight: false,
        saving: false,
        oneRM: null, initWeight: null, initReps: null,
        setType: 'standard' as string,
        partialReps: null,
        drops: [] as { weightLbs: number | null; reps: number | null }[], pegWeights: null as { peg1: number; peg2: number; peg3: number } | null,
      }));
      const blockId = makeBlockId();
      uiExercises = [...uiExercises, {
        uiId: `${pickingExercise.id}-${Date.now()}-${Math.random()}`,
        blockId,
        persistKey: makePersistKey(blockId, pickingExercise.id, sets, `${Date.now()}-${Math.random()}`),
        exerciseId: pickingExercise.id,
        sets,
        isUnilateral: pickingExercise.is_unilateral,
        customRestSecs: null,
        groupId: null,
        groupType: null,
      }];
      saveSessionStructure();
    }
    showAddModal = false;
    pickingExercise = null;
    searchQuery = '';
  }

  // ─── Finish workout ───────────────────────────────────────────────────────
  async function doFinish() {
    if (!sessionId) { goto('/'); return; }
    const finishedSessionId = sessionId;
    finishing = true;
    try {
      await completeSession(sessionId);
      // Clean up any saved exercise order for this session
      const orderKey = exerciseOrderKey(sessionId);
      if (orderKey && typeof localStorage !== 'undefined') localStorage.removeItem(orderKey);
      const structureKey = exerciseStructureKey(sessionId);
      if (structureKey && typeof localStorage !== 'undefined') localStorage.removeItem(structureKey);
      // Persist any notes the user entered
      const noteKey = `hgt_session_note_${sessionId}`;
      const savedNote = localStorage.getItem(noteKey)?.trim();
      if (savedNote) {
        try {
          await patchSession(sessionId, { notes: savedNote });
          localStorage.removeItem(noteKey);
        } catch (e) {
          console.error('Failed to save session notes:', e);
        }
      }
      if (syncToPlan) {
        try {
          const data = await syncSessionToPlan(sessionId, {
            exercises: uiExercises.map((exercise) => ({
              exercise_id: exercise.exerciseId,
              exercise_block_id: exercise.blockId,
              group_id: exercise.groupId,
              group_type: exercise.groupType,
            })),
          });
          syncCount = data.updated;
          syncStructural = data.structural_changes ?? 0;
        } catch (e) {
          console.error('Failed to sync session to plan:', e);
        }
      }
    } catch (e) {
      console.error('Failed to complete session:', e);
    }
    if (clockInterval) { clearInterval(clockInterval); clockInterval = null; }
    if (restInterval)  { clearInterval(restInterval);  restInterval  = null; }
    currentSession.set(null);
    clearFeedbackDraftState(finishedSessionId);
    // Compute PRs before clearing UI state
    prs = detectPRs();
    // Write workout to HealthKit (no-op on web/PWA)
    writeWorkout({
      startDate: new Date(startedAt ?? Date.now()),
      endDate: new Date(),
      workoutName: workoutName,
    }).catch(() => {}); // fire and forget
    finished = true;
    finishing = false;
  }

  async function doDiscard() {
    if (!sessionId) { goto('/'); return; }
    const discardedSessionId = sessionId;
    const confirmed = confirm('Discard this workout? All progress will be permanently deleted.');
    if (!confirmed) return;
    try {
      await deleteSession(sessionId);
    } catch (e) {
      console.error('Failed to delete session:', e);
    }
    const orderKey = exerciseOrderKey(sessionId);
    if (orderKey && typeof localStorage !== 'undefined') localStorage.removeItem(orderKey);
    const structureKey = exerciseStructureKey(sessionId);
    if (structureKey && typeof localStorage !== 'undefined') localStorage.removeItem(structureKey);
    if (clockInterval) { clearInterval(clockInterval); clockInterval = null; }
    if (restInterval)  { clearInterval(restInterval);  restInterval  = null; }
    currentSession.set(null);
    clearFeedbackDraftState(discardedSessionId);
    goto('/');
  }

  // ─── PR detection ─────────────────────────────────────────────────────────
  interface PR { exerciseName: string; type: 'weight' | 'reps' | '1rm'; value: string; }
  let prs = $state<PR[]>([]);

  function detectPRs(): PR[] {
    const results: PR[] = [];
    for (const ex of uiExercises) {
      const exercise = getEx(ex.exerciseId);
      if (!exercise) continue;
      const doneSetsEx = ex.sets.filter(s => s.done);
      if (doneSetsEx.length === 0) continue;
      let bestOneRm: PRHit | null = null;
      for (const s of doneSetsEx) {
        for (const hit of getPrHits(ex, s, startingPersonalRecordsByExercise)) {
          if (hit.type === '1rm' && (!bestOneRm || hit.rawValue > bestOneRm.rawValue)) {
            bestOneRm = hit;
          }
        }
      }
      if (bestOneRm) results.push({ exerciseName: exercise.display_name, type: '1rm', value: bestOneRm.value });
    }
    return results;
  }


  // ─── Confetti animation for PR celebrations ─────────────────────────────
  function fireConfetti() {
    const colors = ['#ffd700', '#ff6b6b', '#4ecdc4', '#45b7d1', '#f9ca24', '#6c5ce7'];
    const container = document.createElement('div');
    container.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:9999;overflow:hidden';
    document.body.appendChild(container);

    for (let i = 0; i < 50; i++) {
      const piece = document.createElement('div');
      const color = colors[Math.floor(Math.random() * colors.length)];
      const left = Math.random() * 100;
      const delay = Math.random() * 0.5;
      const size = 6 + Math.random() * 6;
      const rotation = Math.random() * 360;
      piece.style.cssText = `
        position:absolute;
        left:${left}%;
        top:-10px;
        width:${size}px;
        height:${size}px;
        background:${color};
        border-radius:${Math.random() > 0.5 ? '50%' : '2px'};
        transform:rotate(${rotation}deg);
        animation:confettiFall ${1.5 + Math.random()}s ease-in ${delay}s forwards;
      `;
      container.appendChild(piece);
    }

    // Add keyframes if not already present
    if (!document.getElementById('confetti-style')) {
      const style = document.createElement('style');
      style.id = 'confetti-style';
      style.textContent = `
        @keyframes confettiFall {
          0% { transform: translateY(0) rotate(0deg); opacity: 1; }
          100% { transform: translateY(100vh) rotate(720deg); opacity: 0; }
        }
      `;
      document.head.appendChild(style);
    }

    setTimeout(() => container.remove(), 3000);
  }

  // ─── Cancel workout ───────────────────────────────────────────────────────
  async function cancelWorkout() {
    if (!sessionId) { goto('/'); return; }
    cancelling = true;
    try {
      await deleteSession(sessionId);
    } catch (e) {
      console.error('Failed to delete session:', e);
    }
    if (clockInterval) { clearInterval(clockInterval); clockInterval = null; }
    if (restInterval)  { clearInterval(restInterval);  restInterval  = null; }
    currentSession.set(null);
    goto('/');
  }

  // ─── Conflict state (existing in-progress session blocks starting a new one) ──
  let conflictSession = $state<WorkoutSession | null>(null);
  let conflictRetry = $state<(() => Promise<void>) | null>(null); // re-run after abandoning
  let conflictRequestedName = $state<string | null>(null);

  async function handleConflict(err: any, retry: () => Promise<void>) {
    // Prefer the structured session_id from the 409 response body; fall back
    // to scanning the sessions list if the backend returns a plain-text detail.
    const detail = err?.response?.data?.detail;
    const sessionId409: number | null =
      detail && typeof detail === 'object' ? detail.session_id ?? null : null;

    try {
      if (sessionId409 != null) {
        conflictSession = await getSession(sessionId409);
      } else {
        const sessions = await getSessions({ limit: 20 });
        conflictSession = sessions.find(s => s.status === 'in_progress') ?? null;
      }
    } catch { conflictSession = null; }
    conflictRetry = retry;
    loading = false;
  }

  async function continueExisting() {
    const sess = conflictSession;
    conflictSession = null;
    conflictRetry = null;
    conflictRequestedName = null;
    // Ensure the store is set so resumeSession() can look up the ID
    if (sess) currentSession.set(sess);
    await resumeSession();
  }

  async function abandonAndRetry() {
    if (!conflictSession) return;
    loading = true;
    // Delete ALL in-progress sessions so one orphaned session can't keep
    // blocking new starts. (Previously only the displayed session was deleted,
    // leaving any other orphans intact and causing repeated 409 loops.)
    try {
      const all = await getSessions({ limit: 500 });
      const inProgress = all.filter(s => s.status === 'in_progress');
      await Promise.allSettled(inProgress.map(s => deleteSession(s.id)));
    } catch { /* ignore individual delete failures */ }
    conflictSession = null;
    const retry = conflictRetry;
    conflictRetry = null;
    conflictRequestedName = null;
    if (retry) await retry();
  }

  function keepRequestedPlanned() {
    conflictSession = null;
    conflictRetry = null;
    conflictRequestedName = null;
    goto('/');
  }

  // ─── Exercise notes toggle ────────────────────────────────────────────────
  let expandedNotes = $state(new Set<string>());
  function toggleNotes(uiId: string) {
    const next = new Set(expandedNotes);
    if (next.has(uiId)) next.delete(uiId); else next.add(uiId);
    expandedNotes = next;
  }

  // ─── Exercise history modal ───────────────────────────────────────────────
  let historyExerciseId = $state<number | null>(null);
  let historyData = $state<ExerciseHistorySession[]>([]);
  let loadingHistory = $state(false);

  async function openHistory(exerciseId: number) {
    historyExerciseId = exerciseId;
    historyData = [];
    loadingHistory = true;
    try {
      historyData = await getExerciseHistory(exerciseId, 8);
    } catch { /* silently fail */ }
    loadingHistory = false;
  }

  function fmtHistDate(iso: string) {
    return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  }

  function historySetReps(set: ExerciseHistorySession['sets'][number]): string {
    if (set.actual_reps == null && (set.reps_left != null || set.reps_right != null)) {
      return `L:${set.reps_left ?? '—'}/R:${set.reps_right ?? '—'}`;
    }
    return `${set.actual_reps ?? '—'}`;
  }

  function historySetWeight(
    set: ExerciseHistorySession['sets'][number],
    isAssisted: boolean,
  ): string | null {
    if (set.actual_weight_kg == null) return null;
    const displayWeight = isAssisted ? -fromKg(set.actual_weight_kg) : fromKg(set.actual_weight_kg);
    return `${displayWeight}`;
  }

  function historySessionInlineSummary(
    session: ExerciseHistorySession,
    isAssisted: boolean,
  ): string {
    const parts: string[] = [];
    let currentWeight: string | null = null;
    let currentReps: string[] = [];

    const flush = () => {
      if (currentReps.length === 0) return;
      if (currentWeight != null) {
        parts.push(`${currentWeight}x${currentReps.join(', ')}`);
      } else {
        parts.push(`x${currentReps.join(', ')}`);
      }
      currentWeight = null;
      currentReps = [];
    };

    for (const set of session.sets) {
      const reps = historySetReps(set);
      const weight = historySetWeight(set, isAssisted);
      if (weight === currentWeight) {
        currentReps.push(reps);
      } else {
        flush();
        currentWeight = weight;
        currentReps = [reps];
      }
    }

    flush();
    return parts.join(', ');
  }

  // ─── Un-complete a set ────────────────────────────────────────────────────
  async function uncompleteSet(exUiId: string, localId: string) {
    if (!sessionId) return;
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;
    const set = ex.sets.find(s => s.localId === localId);
    if (!set || !set.done || set.backendId === null) return;

    set.saving = true;
    uiExercises = [...uiExercises];
    try {
      await updateSet(sessionId, set.backendId, {
        actual_reps: null,
        actual_weight_kg: null,
        completed_at: null,
      } as any);
      set.done = false;
      set.doneLeft = false;
      set.doneRight = false;

      // Reset timer if no sets are done anymore
      resetTimerIfNoDoneSets();
    } catch (e) {
      console.error('Failed to uncomplete set:', e);
    } finally {
      set.saving = false;
      uiExercises = [...uiExercises];
    }
  }

  // ─── Skip / unskip a set ─────────────────────────────────────────────────
  async function skipSet(exUiId: string, localId: string) {
    if (!sessionId) return;
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;
    const set = ex.sets.find(s => s.localId === localId);
    if (!set || set.done || set.skipped) return;

    set.saving = true;
    uiExercises = [...uiExercises];

    try {
      let bId = set.backendId;
      if (bId === null) {
        const created = await addSet(sessionId, {
          exercise_id: ex.exerciseId,
          exercise_block_id: ex.blockId ?? undefined,
          set_number: set.setNumber,
          planned_reps: set.reps ?? undefined,
          planned_weight_kg: set.weightLbs != null ? toKg(set.weightLbs) : undefined,
        });
        bId = created.id;
        set.backendId = bId;
      }
      await updateSet(sessionId, bId, {
        skipped_at: new Date().toISOString(),
      } as any);
      set.skipped = true;
    } catch (e) {
      console.error('Failed to skip set:', e);
    } finally {
      set.saving = false;
      uiExercises = [...uiExercises];
    }
  }

  async function unskipSet(exUiId: string, localId: string) {
    if (!sessionId) return;
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;
    const set = ex.sets.find(s => s.localId === localId);
    if (!set || !set.skipped || set.backendId === null) return;

    set.saving = true;
    uiExercises = [...uiExercises];
    try {
      await updateSet(sessionId, set.backendId, {
        skipped_at: null,
      } as any);
      set.skipped = false;
    } catch (e) {
      console.error('Failed to unskip set:', e);
    } finally {
      set.saving = false;
      uiExercises = [...uiExercises];
    }
  }

  let summaryVolumeLbs = $derived(
    uiExercises.reduce((total, ex) => {
      const exercise = getEx(ex.exerciseId);
      const isAsst = exercise?.is_assisted ?? false;
      return total + ex.sets.filter(s => s.done).reduce((s, set) => {
        const w = isAsst
          ? Math.max(0, bodyWeightInUnit - (set.weightLbs ?? 0)) // net load for assisted
          : (set.weightLbs ?? 0);
        const r = set.reps ?? 0;
        // Unilateral exercises work both sides
        const multiplier = ex.isUnilateral ? 2 : 1;
        return s + w * r * multiplier;
      }, 0);
    }, 0)
  );
  let summaryDoneSets = $derived(
    uiExercises.reduce((n, ex) => n + ex.sets.filter(s => s.done).length, 0)
  );
</script>

<!-- ─── Loading ─────────────────────────────────────────────────────────── -->
{#if loading}
  <div class="flex items-center justify-center flex-1">
    <div class="text-center">
      <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-primary-500 mx-auto mb-4"></div>
      <p class="text-zinc-400">Starting workout…</p>
    </div>
  </div>

<!-- ─── Plan picker ───────────────────────────────────────────────────────── -->
{:else if showPicker}
  <div class="page-content space-y-5">

    <div>
      <h2 class="text-xl font-bold text-zinc-100">Start Workout</h2>
      <p class="text-sm text-zinc-500 mt-0.5">Choose a plan and day</p>
    </div>

    {#if plans.length > 0}
      {#each plans as plan}
        <div class="card">
          <h3 class="font-semibold text-zinc-200">{plan.name}</h3>
          {#if plan.description}
            <p class="text-zinc-500 text-xs mt-0.5 mb-3">{plan.description}</p>
          {/if}
          <div class="grid grid-cols-2 sm:grid-cols-3 gap-2 mt-3">
            {#each plan.days as day}
              <button onclick={() => startFromPlan(plan.id, day.day_number)}
                      class="flex flex-col items-start px-4 py-4 bg-zinc-800/80 hover:bg-primary-600/20
                             border border-zinc-700/60 hover:border-primary-500/50
                             rounded-2xl transition-all text-left group active:scale-[0.97]">
                <span class="text-sm font-semibold text-zinc-200 group-hover:text-primary-300">{day.day_name}</span>
                <span class="text-xs text-zinc-500 mt-0.5">
                  {day.exercises.length} exercise{day.exercises.length !== 1 ? 's' : ''}
                </span>
              </button>
            {:else}
              <p class="text-zinc-500 text-sm col-span-3 py-4 text-center">No days configured yet.</p>
            {/each}
          </div>
        </div>
      {/each}
    {:else}
      <div class="card text-center py-12">
        <p class="text-5xl mb-4">📋</p>
        <p class="text-zinc-400 mb-4">No workout plans yet.</p>
        <a href="/plans/create" class="btn-primary">Create a Plan</a>
      </div>
    {/if}

    <a href="/plans/templates"
       class="block w-full py-4 text-center text-sm text-primary-400 hover:text-primary-300
              hover:bg-primary-500/10 rounded-2xl transition-colors border border-primary-500/20">
      Browse Template Programs
    </a>

    <button onclick={startFreeSession}
            class="w-full py-4 text-sm text-zinc-500 hover:text-zinc-300
                   hover:bg-zinc-800/50 rounded-2xl transition-colors border border-zinc-800/60">
      Start free-form session (no plan)
    </button>

  </div>

<!-- ─── Conflict: existing active session ─────────────────────────────── -->
{:else if conflictSession}
  <div class="flex items-center justify-center flex-1 p-4">
    <div class="card max-w-md w-full text-center space-y-4">
      <div class="text-amber-400 text-4xl">⚠️</div>
      <h2 class="text-xl font-semibold">Workout conflict</h2>
      <p class="text-zinc-400 text-sm">
        You tried to start
        <span class="text-white font-medium">{conflictRequestedName ?? 'a new workout'}</span>,
        but another session is already in progress.
      </p>
      <div class="grid gap-3 text-left">
        <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
          <p class="text-[11px] uppercase tracking-wide text-zinc-500 mb-1">Requested workout</p>
          <p class="text-sm font-medium text-white">{conflictRequestedName ?? 'New workout'}</p>
          <p class="text-xs text-zinc-500 mt-1">This will stay planned unless you explicitly replace the active session.</p>
        </div>
        <div class="rounded-xl border border-amber-500/20 bg-amber-500/5 p-3">
          <p class="text-[11px] uppercase tracking-wide text-amber-400/80 mb-1">Active workout</p>
          <p class="text-sm font-medium text-white">{conflictSession.name}</p>
          <p class="text-xs text-zinc-500 mt-1">Status: in progress</p>
        </div>
      </div>
      <div class="flex flex-col gap-3 pt-1">
        <button onclick={continueExisting} class="btn-primary w-full">▶ Resume Active Workout</button>
        <button
          onclick={abandonAndRetry}
          class="w-full px-4 py-2 rounded-lg border border-red-700 text-red-400 hover:bg-red-900/20 transition-colors text-sm font-medium"
        >🗑 Abandon Active & Start Requested Workout</button>
        <button
          onclick={keepRequestedPlanned}
          class="w-full px-4 py-2 rounded-lg border border-zinc-700 text-zinc-300 hover:bg-zinc-800 transition-colors text-sm font-medium"
        >Keep Requested Workout Planned</button>
      </div>
    </div>
  </div>

<!-- ─── Error ──────────────────────────────────────────────────────────── -->
{:else if error}
  <div class="flex items-center justify-center flex-1 p-4">
    <div class="card max-w-md w-full text-center">
      <div class="text-red-400 text-4xl mb-4">⚠️</div>
      <h2 class="text-xl font-semibold mb-2">Couldn't start workout</h2>
      <p class="text-zinc-400 mb-6">{error}</p>
      <a href="/plans" class="btn-primary">Back to Plans</a>
    </div>
  </div>

<!-- ─── Finished screen ────────────────────────────────────────────────── -->
{:else if finished}
  <div class="flex-1 overflow-y-auto px-4 py-4">
    <div class="card max-w-lg w-full mx-auto mb-8" bind:this={summaryCardEl}>
      <div class="text-center mb-6">
        <div class="text-6xl mb-3">🎉</div>
        <h2 class="text-3xl font-bold">Workout done!</h2>
        <p class="text-zinc-400 mt-1">{workoutName}</p>
      </div>

      <!-- Stats -->
      <div class="grid grid-cols-2 gap-4 mb-6">
        <div class="bg-zinc-900 rounded-lg p-3 text-center">
          <p class="text-2xl font-bold text-primary-400">{summaryDoneSets}</p>
          <p class="text-xs text-zinc-400 mt-0.5">Sets done</p>
        </div>
        <div class="bg-zinc-900 rounded-lg p-3 text-center">
          <p class="text-2xl font-bold text-primary-400">{Math.round(summaryVolumeLbs).toLocaleString()}</p>
          <p class="text-xs text-zinc-400 mt-0.5">{unit} volume</p>
        </div>
      </div>

      <!-- PRs -->
      {#if prs.length > 0}
        <div class="mb-5">
          <p class="text-xs font-semibold text-amber-400 uppercase tracking-wide mb-2">🏆 Personal Records</p>
          <div class="space-y-1">
            {#each prs as pr}
              <div class="flex items-center justify-between bg-amber-900/20 border border-amber-700/40 rounded-lg px-3 py-2">
                <span class="text-sm font-medium">{pr.exerciseName}</span>
                <span class="text-sm text-amber-400 font-mono">{pr.value}</span>
              </div>
            {/each}
          </div>
        </div>
      {/if}

      <!-- Sync result -->
      {#if syncCount !== null}
        <div class="mb-4 flex items-center gap-2 text-sm text-green-400 bg-green-900/20 border border-green-700/40 rounded-lg px-3 py-2">
          <span>✓ Plan updated{syncCount ? ` — ${syncCount} weight/rep update${syncCount !== 1 ? 's' : ''}` : ''}{syncStructural ? ` — ${syncStructural} structural change${syncStructural !== 1 ? 's' : ''}` : ''}</span>
        </div>
      {/if}

      <!-- Exercise summary -->
      <div class="space-y-1 mb-6 max-h-48 overflow-y-auto">
        {#each uiExercises as ex}
          {@const exercise = getEx(ex.exerciseId)}
          {@const done = ex.sets.filter(s => s.done).length}
          {#if done > 0}
            <div class="flex items-center justify-between py-1.5 border-b border-zinc-800 last:border-0">
              <span class="text-sm font-medium">{exercise?.display_name ?? `Exercise ${ex.exerciseId}`}</span>
              <span class="text-sm text-zinc-400">{done}/{ex.sets.length} sets</span>
            </div>
          {/if}
        {/each}
      </div>

      <!-- Session notes -->
      <div class="mb-4">
        <label class="text-xs text-zinc-500 block mb-1">Workout notes (optional)</label>
        <textarea
          placeholder="How did it feel? Energy level, sleep, anything notable..."
          class="w-full bg-zinc-900 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white resize-none"
          style="font-size: 16px;"
          rows="2"
          oninput={(e) => {
            // Save to localStorage keyed by session ID
            const note = (e.target as HTMLTextAreaElement).value;
            if (sessionId) localStorage.setItem(`hgt_session_note_${sessionId}`, note);
          }}
        ></textarea>
      </div>

      <div class="flex gap-3">
        <button onclick={shareWorkout} disabled={sharing}
                class="flex-1 py-3 bg-zinc-800 hover:bg-zinc-700 text-white font-medium rounded-xl transition-colors disabled:opacity-50">
          {sharing ? 'Generating...' : '📤 Share'}
        </button>
        <a href="/" class="flex-1 py-3 bg-primary-600 hover:bg-primary-500 text-white font-medium rounded-xl text-center transition-colors">
          Dashboard
        </a>
      </div>
    </div>
  </div>

<!-- ─── Active Workout ─────────────────────────────────────────────────── -->
{:else}
  <div class="flex flex-col flex-1 overflow-hidden relative">

    <!-- Header -->
    <header class="shrink-0 bg-zinc-950/95 border-b border-white/5 px-4 py-3">
      <!-- Progress bar (full width, top of header) -->
      <div class="h-0.5 bg-zinc-800 rounded-full overflow-hidden -mx-4 -mt-3 mb-3">
        <div class="h-full bg-gradient-to-r from-primary-500 to-accent-500 rounded-full transition-all duration-500"
             style="width:{pct}%"></div>
      </div>

      <div class="flex items-center gap-3">
        <div class="flex-1 min-w-0">
          <h1 class="text-sm font-semibold truncate text-zinc-200">{workoutName}</h1>
          <div class="flex items-center gap-3 mt-0.5">
            <span class="text-xs text-zinc-500">{doneSets}/{totalSets} sets</span>
          </div>
        </div>

        <!-- Cancel button removed (#528) — discard via menu if needed -->
      </div>
    </header>

    <!-- Scrollable exercise list -->
    <div class="flex-1 overflow-y-auto pb-36">
      <div class="max-w-2xl mx-auto px-3 py-4 space-y-3">

        {#each exerciseGroups as group}
          <div class={group.groupId ? 'border-l-[3px] border-primary-500 rounded-l-lg pl-1 space-y-1' : 'space-y-3'}>
          {#if group.groupId}
            <div class="text-xs text-primary-400 font-semibold px-3 pt-1">
              {group.groupType === 'circuit' ? `Circuit (${group.exercises.length})` : 'Superset'}
            </div>
          {/if}
          {#each group.exercises as ex (ex.uiId)}
          {@const exercise = getEx(ex.exerciseId)}
          {@const allDone = ex.sets.length > 0 && ex.sets.every(s => s.done || s.skipped)}
          {@const isAssistedEx = exercise?.is_assisted ?? false}
          {@const exIdx = uiExercises.indexOf(ex)}

          <!-- Link/unlink button between exercises -->
          {#if exIdx > 0}
            <button
              onclick={() => toggleLink(ex.uiId)}
              class="w-full py-1 text-[10px] font-medium transition-colors rounded {ex.groupId && ex.groupId === uiExercises[exIdx - 1]?.groupId ? 'text-primary-400 bg-primary-500/10 hover:bg-primary-500/20' : 'text-zinc-600 hover:text-zinc-400 hover:bg-zinc-800/50'}"
            >{ex.groupId && ex.groupId === uiExercises[exIdx - 1]?.groupId ? 'Unlink' : 'Link as superset'}</button>
          {/if}

          <div class="exercise-card {allDone ? 'exercise-card-done' : ''} {highlightedExUiId === ex.uiId ? 'ring-2 ring-primary-400 ring-offset-1 ring-offset-zinc-900' : ''}"
               data-ex-uid={ex.uiId}>
            <!-- Exercise header -->
            <div class="flex items-start justify-between mb-3">
              <div>
                <h3 class="font-semibold">
                  {exercise?.display_name ?? `Exercise ${ex.exerciseId}`}
                  {#if allDone}
                    <span class="ml-2 text-green-400 text-sm">✓</span>
                  {/if}
                </h3>
                <div class="flex items-center gap-2 mt-0.5">
                  {#if exercise?.primary_muscles?.length}
                    <p class="text-xs text-zinc-500 capitalize">{muscleLabel(ex.exerciseId)}</p>
                  {/if}
                  <button
                    onclick={() => {
                      const current = restDurationForExercise(ex.uiId);
                      const input = prompt(`Rest time for this exercise (seconds):`, String(current));
                      if (input != null) {
                        const val = parseInt(input);
                        if (!isNaN(val) && val > 0) {
                          ex.customRestSecs = val;
                          uiExercises = [...uiExercises];
                        }
                      }
                    }}
                    class="text-[10px] text-zinc-600 hover:text-zinc-400 transition-colors"
                    title="Tap to override rest time for this exercise"
                  >⏱ {Math.floor(restDurationForExercise(ex.uiId) / 60)}:{String(restDurationForExercise(ex.uiId) % 60).padStart(2, '0')}{ex.customRestSecs != null ? ' ✎' : ''}</button>
                </div>
                <!-- Persistent exercise note -->
                {#if editingNoteId === ex.exerciseId}
                  <div class="flex gap-1 mt-1">
                    <input type="text" bind:value={editingNoteText}
                           class="flex-1 bg-zinc-800 border border-zinc-600 rounded-lg px-3 py-2 text-white"
                           style="font-size: 16px;"
                           placeholder="Add a note..." />
                    <button onclick={async () => {
                      await setExerciseNote(ex.exerciseId, editingNoteText);
                      if (editingNoteText.trim()) exerciseNotes[ex.exerciseId] = editingNoteText.trim();
                      else delete exerciseNotes[ex.exerciseId];
                      editingNoteId = null;
                    }} class="text-xs text-primary-400 px-2">Save</button>
                  </div>
                {:else if exerciseNotes[ex.exerciseId]}
                  <button onclick={() => { editingNoteId = ex.exerciseId; editingNoteText = exerciseNotes[ex.exerciseId] || ''; }}
                          class="text-xs text-amber-400 mt-1 px-2 py-1 rounded-lg bg-amber-500/10 border border-amber-500/20 text-left hover:bg-amber-500/20 transition-colors">
                    📝 {exerciseNotes[ex.exerciseId]}
                  </button>
                {:else}
                  <button onclick={() => { editingNoteId = ex.exerciseId; editingNoteText = ''; }}
                          class="text-[10px] text-zinc-600 mt-1 hover:text-zinc-400 transition-colors">
                    + note
                  </button>
                {/if}
                <!-- Set types are per-set, configured inline on each set row -->
              </div>
              <div class="flex items-center gap-1 ml-3 mt-0.5">
                <!-- Reorder buttons -->
                <button onclick={() => { const i = uiExercises.indexOf(ex); if (i > 0) moveExercise(i, -1); }}
                        class="text-zinc-500 hover:text-white px-1 text-sm">▲</button>
                <button onclick={() => { const i = uiExercises.indexOf(ex); if (i < uiExercises.length - 1) moveExercise(i, 1); }}
                        class="text-zinc-500 hover:text-white px-1 text-sm">▼</button>
                {#if exercise?.description}
                  <button
                    onclick={() => toggleNotes(ex.uiId)}
                    class="text-xs px-2 py-0.5 rounded transition-colors hover:bg-zinc-800 {expandedNotes.has(ex.uiId) ? 'text-primary-400' : 'text-zinc-500 hover:text-primary-400'}"
                    title="Toggle technique notes"
                  >📝 Notes</button>
                {/if}
                <button
                  onclick={() => openHistory(ex.exerciseId)}
                  class="text-xs text-zinc-500 hover:text-primary-400 px-2 py-0.5 rounded transition-colors hover:bg-zinc-800"
                  title="View history for this exercise"
                >History</button>
                <button
                  onclick={() => { swapTargetUiId = ex.uiId; showAddModal = true; searchQuery = ''; pickingExercise = null; }}
                  class="text-xs text-zinc-500 hover:text-amber-400 px-2 py-0.5 rounded transition-colors hover:bg-zinc-800"
                  title="Swap for a different exercise"
                >Swap</button>
                <button
                  onclick={() => {
                    if (confirm(`Remove ${exercise?.display_name ?? 'this exercise'} and all its sets?`)) {
                      removeExercise(ex.uiId);
                    }
                  }}
                  class="text-gray-600 hover:text-red-400 text-xl leading-none"
                  title="Remove exercise"
                >✕</button>
              </div>
            </div>

            <!-- Collapsible technique notes -->
            {#if exercise?.description && expandedNotes.has(ex.uiId)}
              <div class="text-xs text-zinc-300 bg-zinc-900 rounded-lg p-3 mb-3 leading-relaxed">
                {exercise.description}
              </div>
            {/if}

            <!-- Column headers — adapt to unilateral / assisted mode -->
            {#if ex.isUnilateral}
              <div class="grid gap-2 mb-2" style="grid-template-columns: 4.5rem 1fr 1fr 5.5rem 1.5rem">
                <span class="text-xs text-zinc-500 text-center">Type</span>
                <span class="text-xs text-zinc-500 text-center">{isAssistedEx ? `−Assist (${unit})` : `Weight (${unit})`}</span>
                <span class="text-xs text-zinc-500 text-center">Reps</span>
                <span></span>
                <span></span>
              </div>
            {:else}
              <div class="grid gap-2 mb-2" style="grid-template-columns: 4.5rem 1fr 1fr 2.5rem">
                <span class="text-xs text-zinc-500 text-center">Type</span>
                <span class="text-xs text-zinc-500 text-center">{isAssistedEx ? `−Assist (${unit})` : `Weight (${unit})`}</span>
                <span class="text-xs text-zinc-500 text-center">Reps</span>
                <span></span>
              </div>
            {/if}

            <!-- Set rows (with exercise-card internal padding) -->
            <div class="space-y-2 px-4 pb-4">
              {#each ex.sets as set (set.localId)}
                {#if ex.isUnilateral}
                  <!-- ── Unilateral row (two bilateral-style rows per set) ── -->
                  <div
                    use:swipeable={{
                      onSwipeLeft: () => { if (!set.done && !set.skipped) skipSet(ex.uiId, set.localId); },
                      onSwipeRight: () => { if (!set.done) removeSet(ex.uiId, set.localId); },
                      disabled: set.done || set.skipped,
                    }}
                    class="pb-2 mb-1 border-b border-zinc-800/30 last:border-0 space-y-1 {set.done ? 'opacity-50' : set.skipped ? 'opacity-30' : ''}"
                  >
                    {#each ['left', 'right'] as side}
                      {@const sideDone = side === 'left' ? set.doneLeft : set.doneRight}
                      {@const sideReps = side === 'left' ? set.repsLeft : set.repsRight}
                      <div class="grid gap-2 items-center {sideDone ? 'opacity-60' : ''}"
                           style="grid-template-columns: 4.5rem 1fr 1fr 5.5rem 1.5rem">

                        <!-- Type dropdown (synced between L/R) -->
                        <select
                          value={set.setType || 'standard'}
                          onchange={(e) => {
                            set.setType = (e.target as HTMLSelectElement).value;
                            syncMyoMatchSets(ex);
                            uiExercises = [...uiExercises];
                            if (set.backendId && sessionId) {
                              updateSet(sessionId, set.backendId, { set_type: set.setType }).catch(() => {});
                            }
                          }}
                          disabled={set.done || sideDone || isMyoMatchLocked(ex, set)}
                          class="set-type-select w-full
                                 {set.setType === 'warmup' ? '!bg-orange-500/15 !border-orange-500/30 text-orange-400' :
                                  set.setType === 'myo_rep' ? '!bg-purple-500/15 !border-purple-500/30 text-purple-400' :
                                  set.setType === 'myo_rep_match' ? '!bg-blue-500/15 !border-blue-500/30 text-blue-400' :
                                  set.setType === 'drop_set' ? '!bg-amber-500/15 !border-amber-500/30 text-amber-400' :
                                  set.setType === 'standard_partials' ? '!bg-teal-500/15 !border-teal-500/30 text-teal-400' :
                                  'text-zinc-400'}">
                          <option value="standard">Straight</option>
                          <option value="standard_partials">+ Partials</option>
                          <option value="warmup">Warmup</option>
                          <option value="myo_rep">Myo Rep</option>
                          {#if ex.sets.indexOf(set) > 0}
                            <option value="myo_rep_match">Myo Match</option>
                          {/if}
                          <option value="drop_set">Drop Set</option>
                        </select>

                        <!-- Weight (shared between L/R) -->
                        <div class="flex flex-col gap-0.5">
                          <input
                            type="number" inputmode="decimal"
                            value={isAssistedEx && set.weightLbs != null ? -set.weightLbs : (set.weightLbs ?? '')}
                            oninput={(e) => {
                              const raw = (e.target as HTMLInputElement).value;
                              const val = raw === '' ? null : Math.abs(parseFloat(raw));
                              const oldWeight = set.weightLbs;
                              set.weightLbs = val;
                              if (!isAssistedEx && val != null && val > 0 && set.oneRM != null) {
                                const r = epleyReps(set.oneRM, val);
                                if (r >= 4) { set.repsLeft = r; set.repsRight = r; }
                              }
                              const idx = ex.sets.indexOf(set);
                              for (let i = idx + 1; i < ex.sets.length; i++) {
                                const s = ex.sets[i];
                                if (!s.done && s.weightLbs === oldWeight) {
                                  s.weightLbs = val;
                                  if (!isAssistedEx && val != null && val > 0 && s.oneRM != null) {
                                    const r = epleyReps(s.oneRM, val);
                                    if (r >= 4) { s.repsLeft = r; s.repsRight = r; }
                                  }
                                } else { break; }
                              }
                              uiExercises = [...uiExercises];
                            }}
                            disabled={set.done || sideDone || isMyoMatchLocked(ex, set)} min={isAssistedEx ? undefined : 0}
                            placeholder={isAssistedEx ? `-assist` : unit}
                            class="set-input"
                            onfocus={() => { focusedWeightSetId = set.localId; focusedExerciseId = ex.exerciseId; }}
                            onblur={() => { setTimeout(() => { if (focusedWeightSetId === set.localId) { focusedWeightSetId = null; focusedExerciseId = null; } }, 200); }}
                          />
                          {#if side === 'left'}
                            {#if isAssistedEx && set.weightLbs !== null}
                              <span class="text-xs text-amber-400 text-center">{netDisplay(set.weightLbs)}</span>
                            {/if}
                            {#if set.isExtrapolated && !set.done}
                              <span class="text-[9px] text-violet-400 text-center leading-tight" title="Adjusted for exercise reorder — estimate only">≈ reorder adj.</span>
                            {/if}
                            {#if focusedWeightSetId === set.localId && !isAssistedEx && set.oneRM && set.weightLbs != null && set.weightLbs > 0 && !set.done && withinWeightBounds(set.weightLbs, set.initWeight, exercise?.movement_type === 'compound')}
                              {@const estReps = epleyReps(set.oneRM, set.weightLbs)}
                              {#if estReps < 5}
                                <span class="text-[10px] text-red-400 text-center leading-tight">~{estReps} reps (heavy)</span>
                              {:else if estReps > 30}
                                <span class="text-[10px] text-red-400 text-center leading-tight">~{estReps} reps (light)</span>
                              {:else}
                                <span class="text-[10px] text-zinc-500 text-center leading-tight">~{estReps} reps</span>
                              {/if}
                              {@const w5 = roundWeight(epleyWeight(set.oneRM, 5))}
                              {@const w30 = roundWeight(epleyWeight(set.oneRM, 30))}
                              <span class="text-[9px] text-zinc-600 text-center leading-tight">{w30}–{w5} {unit}</span>
                            {/if}
                          {/if}
                        </div>

                        <!-- Reps (side-specific) -->
                        <input
                          type="number" inputmode="decimal"
                          value={sideReps ?? ''}
                          oninput={(e) => {
                            const v = (e.target as HTMLInputElement).value;
                            const r = v === '' ? null : parseInt(v);
                            if (side === 'left') set.repsLeft = r;
                            else set.repsRight = r;
                            uiExercises = [...uiExercises];
                          }}
                          disabled={set.done || sideDone || isMyoMatchLocked(ex, set)} min="0"
                          placeholder={side === 'left' ? 'L' : 'R'}
                          class="set-input"
                        />

                        <!-- Complete/Skip buttons (per-side) -->
                        <div class="flex gap-1.5 justify-center">
                          {#if set.saving}
                            <span class="text-zinc-400 text-xs">…</span>
                          {:else if sideDone}
                            <button onclick={() => undoSide(ex.uiId, set.localId, side as 'left' | 'right')}
                                    title="Undo — mark as incomplete"
                                    class="h-10 w-10 rounded-xl bg-green-700/30 text-green-400 font-bold text-lg">✓</button>
                          {:else if set.skipped}
                            <button onclick={() => unskipSet(ex.uiId, set.localId)}
                                    class="h-10 px-2 rounded-xl bg-amber-600/20 text-amber-400 text-xs font-semibold">Undo</button>
                          {:else}
                            <button onclick={() => completeSide(ex.uiId, set.localId, side as 'left' | 'right')}
                                    disabled={(sideReps ?? 0) <= 0}
                                    title="Log this set"
                                    class="h-10 w-10 rounded-xl bg-primary-600 hover:bg-primary-500 text-white font-bold transition-colors disabled:opacity-30">✓</button>
                            <button onclick={() => skipSet(ex.uiId, set.localId)}
                                    class="h-10 px-2 rounded-xl bg-zinc-800 hover:bg-amber-600/20 text-zinc-500 hover:text-amber-400 text-xs font-medium">Skip</button>
                          {/if}
                        </div>

                        <!-- Side label -->
                        <span class="text-xs text-zinc-500 font-semibold text-center">{side === 'left' ? 'L' : 'R'}</span>
                      </div>
                    {/each}
                  </div>
                  <!-- Rep range advisories (unilateral) -->
                  {#if !set.done && !set.skipped && set.setType !== 'myo_rep' && set.setType !== 'myo_rep_match'}
                    {#if (set.repsLeft ?? 0) > 30 || (set.repsRight ?? 0) > 30}
                      <div class="px-1 mt-0.5">
                        <p class="text-[10px] text-amber-400/70">30+ reps — consider increasing weight</p>
                      </div>
                    {:else if (set.repsLeft ?? 0) > 0 && (set.repsLeft ?? 0) < 4}
                      <div class="px-1 mt-0.5">
                        <p class="text-[10px] text-amber-400/70">Under 4 reps — more strength than hypertrophy</p>
                      </div>
                    {/if}
                  {/if}
                  <!-- Deviation warning (unilateral) -->
                  {@const devWarnUni = deviationWarning(set, set.weightLbs, set.repsLeft ?? set.repsRight, isAssistedEx)}
                  {#if devWarnUni}
                    <div class="px-1 mt-0.5">
                      <p class="text-xs text-amber-400 leading-snug">
                        ⚠ {devWarnUni}
                      </p>
                    </div>
                  {/if}
                  <!-- Drop set sub-rows (unilateral) -->
                  {#if set.setType === 'drop_set' && set.done}
                    {#each set.drops as drop, di}
                      <div class="flex items-center gap-2 pl-8 py-1 bg-zinc-800/30 rounded">
                        <span class="text-[10px] text-zinc-600 w-5">↓{di+1}</span>
                        <input type="number" inputmode="decimal" bind:value={drop.weightLbs} class="input !py-1 !px-2 w-20 text-center text-sm" placeholder="lbs" />
                        <input type="number" bind:value={drop.reps} class="input !py-1 !px-2 w-16 text-center text-sm" placeholder="reps" />
                      </div>
                    {/each}
                    <button onclick={() => { set.drops = [...set.drops, { weightLbs: null, reps: null }]; uiExercises = [...uiExercises]; }}
                            class="ml-8 text-xs text-primary-400 hover:text-primary-300 py-1">
                      + Add Drop
                    </button>
                  {/if}

                {:else}
                  <!-- ── Bilateral row ──────────────────────────────── -->
                  <div
                    use:swipeable={{
                      onSwipeLeft: () => { if (!set.done && !set.skipped) skipSet(ex.uiId, set.localId); },
                      onSwipeRight: () => { if (!set.done) removeSet(ex.uiId, set.localId); },
                      disabled: set.done || set.skipped,
                    }}
                    class="grid gap-2 items-center {set.done ? 'opacity-50' : set.skipped ? 'opacity-30 line-through' : ''}"
                    style="grid-template-columns: 4.5rem 1fr 1fr 5.5rem"
                  >
                    <select
                      value={set.setType || 'standard'}
                      onchange={(e) => {
                        set.setType = (e.target as HTMLSelectElement).value;
                        syncMyoMatchSets(ex);
                        uiExercises = [...uiExercises];
                        if (set.backendId && sessionId) {
                          updateSet(sessionId, set.backendId, { set_type: set.setType }).catch(() => {});
                        }
                      }}
                      disabled={set.done || isMyoMatchLocked(ex, set)}
                      class="set-type-select w-full
                             {set.setType === 'warmup' ? '!bg-orange-500/15 !border-orange-500/30 text-orange-400' :
                              set.setType === 'myo_rep' ? '!bg-purple-500/15 !border-purple-500/30 text-purple-400' :
                              set.setType === 'myo_rep_match' ? '!bg-blue-500/15 !border-blue-500/30 text-blue-400' :
                              set.setType === 'drop_set' ? '!bg-amber-500/15 !border-amber-500/30 text-amber-400' :
                              set.setType === 'standard_partials' ? '!bg-teal-500/15 !border-teal-500/30 text-teal-400' :
                              'text-zinc-400'}">
                      <option value="standard">Straight</option>
                      <option value="standard_partials">+ Partials</option>
                      <option value="warmup">Warmup</option>
                      <option value="myo_rep">Myo Rep</option>
                      {#if ex.sets.indexOf(set) > 0}
                        <option value="myo_rep_match">Myo Match</option>
                      {/if}
                      <option value="drop_set">Drop Set</option>
                    </select>

                    <!-- Weight / Assist -->
                    <div class="flex flex-col gap-0.5">
                      <input
                        type="number" inputmode="decimal"
                        value={isAssistedEx && set.weightLbs != null ? -set.weightLbs : (set.weightLbs ?? '')}
                        oninput={(e) => {
                          const raw = (e.target as HTMLInputElement).value;
                          const val = raw === '' ? null : Math.abs(parseFloat(raw));
                          const oldWeight = set.weightLbs;
                          set.weightLbs = val;
                          // Epley: always update rep suggestion for this set
                          if (!isAssistedEx && val != null && val > 0 && set.oneRM != null) {
                            const newReps = epleyReps(set.oneRM, val);
                            if (newReps >= 4) set.reps = newReps;
                          }
                          // Auto-distribute to pegs for Prime machines
                          if (isPrimePlateLoaded(exercise) && val != null && val > 0) {
                            set.pegWeights = distributeToPegs(val / 2);
                          }
                          // Propagate to subsequent sets only while each next set
                          // had the same weight as the set just edited (chain stops at first mismatch)
                          const idx = ex.sets.indexOf(set);
                          for (let i = idx + 1; i < ex.sets.length; i++) {
                            const s = ex.sets[i];
                            if (!s.done && s.weightLbs === oldWeight) {
                              s.weightLbs = val;
                              if (isPrimePlateLoaded(exercise) && val != null && val > 0) {
                                s.pegWeights = distributeToPegs(val / 2);
                              }
                              if (!isAssistedEx && val != null && val > 0 && s.oneRM != null) {
                                const newReps = epleyReps(s.oneRM, val);
                                if (newReps >= 4) s.reps = newReps;
                              }
                            } else { break; }
                          }
                          uiExercises = [...uiExercises];
                        }}
                        disabled={set.done || isMyoMatchLocked(ex, set)} min={isAssistedEx ? undefined : 0}
                        placeholder={isAssistedEx ? `-assist` : unit}
                        class="set-input"
                        onfocus={() => { focusedWeightSetId = set.localId; focusedExerciseId = ex.exerciseId; }}
                        onblur={() => { setTimeout(() => { if (focusedWeightSetId === set.localId) { focusedWeightSetId = null; focusedExerciseId = null; } }, 200); }}
                      />
                      {#if isAssistedEx && set.weightLbs !== null}
                        <span class="text-xs text-amber-400 text-center">{netDisplay(set.weightLbs)}</span>
                      {/if}
                      {#if set.isExtrapolated && !set.done}
                        <span class="text-[9px] text-violet-400 text-center leading-tight" title="Adjusted for exercise reorder — estimate only">≈ reorder adj.</span>
                      {/if}
                      {#if focusedWeightSetId === set.localId && !isAssistedEx && set.oneRM && set.weightLbs != null && set.weightLbs > 0 && !set.done && withinWeightBounds(set.weightLbs, set.initWeight, exercise?.movement_type === 'compound')}
                        {@const estReps = epleyReps(set.oneRM, set.weightLbs)}
                        {#if estReps < 5}
                          <span class="text-[10px] text-red-400 text-center leading-tight">~{estReps} reps (heavy)</span>
                        {:else if estReps > 30}
                          <span class="text-[10px] text-red-400 text-center leading-tight">~{estReps} reps (light)</span>
                        {:else}
                          <span class="text-[10px] text-zinc-500 text-center leading-tight">~{estReps} reps</span>
                        {/if}
                        {@const w5 = roundWeight(epleyWeight(set.oneRM, 5))}
                        {@const w30 = roundWeight(epleyWeight(set.oneRM, 30))}
                        <span class="text-[9px] text-zinc-600 text-center leading-tight">{w30}–{w5} {unit}</span>
                      {/if}
                    </div>

                    <!-- Reps + optional partials -->
                    <div class="flex flex-col gap-0.5">
                      <input
                        type="number" inputmode="decimal"
                        value={set.reps ?? ''}
                        oninput={(e) => {
                          const v = (e.target as HTMLInputElement).value;
                          const r = v === '' ? null : parseInt(v);
                          set.reps = r;
                          uiExercises = [...uiExercises];
                        }}
                        disabled={set.done || isMyoMatchLocked(ex, set)} min="0" placeholder="reps"
                        class="set-input"
                      />
                      {#if set.setType === 'standard_partials'}
                        <input
                          type="number" inputmode="decimal"
                          value={set.partialReps ?? ''}
                          oninput={(e) => {
                            set.partialReps = (e.target as HTMLInputElement).value === '' ? null : parseInt((e.target as HTMLInputElement).value);
                            uiExercises = [...uiExercises];
                          }}
                          disabled={set.done} min="0" placeholder="partials"
                          class="set-input !text-teal-400 !border-teal-500/30 text-xs"
                        />
                      {/if}
                    </div>

                    <!-- Complete / Skip / Undo -->
                    {#if set.saving}
                      <div class="flex justify-center"><span class="text-zinc-400 text-xs">…</span></div>
                    {:else if set.skipped}
                      <button
                        onclick={() => unskipSet(ex.uiId, set.localId)}
                        class="h-12 w-12 rounded-xl bg-amber-700/20 hover:bg-zinc-700 text-amber-400 text-xs font-medium transition-colors"
                        title="Undo skip"
                      >Skip</button>
                    {:else if set.done}
                      <button
                        onclick={() => uncompleteSet(ex.uiId, set.localId)}
                        class="h-12 w-12 rounded-xl bg-green-700/30 hover:bg-zinc-700 text-green-400 font-bold text-lg transition-colors"
                        title="Undo — mark as incomplete"
                      >✓</button>
                    {:else}
                      {@const canComplete = (set.reps ?? 0) > 0}
                      <div class="flex gap-1.5">
                        <button
                          onclick={() => completeSet(ex.uiId, set.localId)}
                          disabled={!canComplete}
                          class="h-12 flex-1 rounded-xl bg-primary-600 hover:bg-primary-500 text-white font-bold text-base transition-colors disabled:opacity-30 disabled:cursor-not-allowed"
                          title={canComplete ? 'Log this set' : 'Enter reps first'}
                        >✓</button>
                        <button
                          onclick={() => skipSet(ex.uiId, set.localId)}
                          class="h-12 flex-1 rounded-xl bg-zinc-800 hover:bg-amber-600/20 text-zinc-500 hover:text-amber-400 text-xs font-medium transition-colors"
                          title="Skip this set"
                        >Skip</button>
                      </div>
                    {/if}
                  </div>
                  <!-- Rep range advisories (bilateral) -->
                  {#if !set.done && !set.skipped && set.setType !== 'myo_rep' && set.setType !== 'myo_rep_match'}
                    {#if (set.reps ?? 0) > 30}
                      <div class="col-span-full px-1 mt-0.5">
                        <p class="text-[10px] text-amber-400/70">30+ reps — consider increasing weight</p>
                      </div>
                    {:else if (set.reps ?? 0) > 0 && (set.reps ?? 0) < 4}
                      <div class="col-span-full px-1 mt-0.5">
                        <p class="text-[10px] text-amber-400/70">Under 4 reps — more strength than hypertrophy</p>
                      </div>
                    {/if}
                  {/if}
                  <!-- Deviation warning -->
                  {@const devWarnBi = deviationWarning(set, set.weightLbs, set.reps, isAssistedEx)}
                  {#if devWarnBi}
                    <div class="col-span-full px-1 mt-0.5">
                      <p class="text-xs text-amber-400 leading-snug">
                        ⚠ {devWarnBi}
                      </p>
                    </div>
                  {/if}
                  <!-- Drop set sub-rows -->
                  {#if set.setType === 'drop_set' && set.done}
                    {#each set.drops as drop, di}
                      <div class="flex items-center gap-2 pl-8 py-1 bg-zinc-800/30 rounded">
                        <span class="text-[10px] text-zinc-600 w-5">↓{di+1}</span>
                        <input type="number" inputmode="decimal" bind:value={drop.weightLbs} class="input !py-1 !px-2 w-20 text-center text-sm" placeholder="lbs" />
                        <input type="number" bind:value={drop.reps} class="input !py-1 !px-2 w-16 text-center text-sm" placeholder="reps" />
                      </div>
                    {/each}
                    <button onclick={() => { set.drops = [...set.drops, { weightLbs: null, reps: null }]; uiExercises = [...uiExercises]; }}
                            class="ml-8 text-xs text-primary-400 hover:text-primary-300 py-1">
                      + Add Drop
                    </button>
                  {/if}
                  <!-- Prime machine peg weight breakdown -->
                  {#if isPrimePlateLoaded(exercise) && !set.done && !set.skipped}
                    {@const pegs = set.pegWeights ?? { peg1: 0, peg2: 0, peg3: 0 }}
                    <div class="col-span-full px-2 mt-1 mb-1">
                      <div class="bg-zinc-800/50 rounded-lg px-3 py-2">
                        <p class="text-[10px] text-zinc-500 mb-1.5 font-medium">Per-side peg weights ({unit})</p>
                        <div class="flex items-center gap-2">
                          {#each ['peg1', 'peg2', 'peg3'] as pegKey, pi}
                            <div class="flex flex-col items-center gap-0.5 flex-1">
                              <span class="text-[9px] text-zinc-500">Peg {pi + 1}</span>
                              <input
                                type="number" inputmode="decimal"
                                value={pegs[pegKey as keyof typeof pegs] || ''}
                                oninput={(e) => {
                                  const v = (e.target as HTMLInputElement).value;
                                  const val = v === '' ? 0 : Math.abs(parseFloat(v));
                                  if (!set.pegWeights) set.pegWeights = { peg1: 0, peg2: 0, peg3: 0 };
                                  set.pegWeights[pegKey as keyof typeof set.pegWeights] = val;
                                  syncWeightFromPegs(set);
                                  uiExercises = [...uiExercises];
                                }}
                                disabled={set.done}
                                class="set-input !w-full !text-xs !py-1"
                                placeholder="0"
                                onfocus={() => { focusedWeightSetId = set.localId; focusedExerciseId = ex.exerciseId; }}
                              />
                            </div>
                          {/each}
                          <div class="flex flex-col items-center gap-0.5">
                            <span class="text-[9px] text-zinc-400">Total</span>
                            <span class="text-xs text-zinc-300 font-mono py-1">
                              {roundWeight((pegs.peg1 + pegs.peg2 + pegs.peg3) * 2)}
                            </span>
                          </div>
                        </div>
                        <button
                          class="text-[10px] text-primary-400 hover:text-primary-300 mt-1"
                          onclick={() => {
                            const totalPerSide = (set.weightLbs ?? 0) / 2;
                            set.pegWeights = distributeToPegs(totalPerSide);
                            uiExercises = [...uiExercises];
                          }}
                        >Auto-distribute from total</button>
                      </div>
                    </div>
                  {/if}
                {/if}
              {/each}
            </div>

            <!-- Add / remove set row -->
            <div class="flex gap-2 mt-4 px-4 pb-1">
              <button
                onclick={() => addSetRow(ex.uiId)}
                class="text-xs px-3 py-1.5 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded transition-colors"
              >+ Add Set</button>
              {#if shouldShowPlates(exercise) && ex.sets.some(s => s.setType !== 'warmup' && s.weightLbs != null && s.weightLbs > 0)}
                <button
                  onclick={() => generateWarmups(ex.uiId)}
                  class="text-xs px-3 py-1.5 bg-amber-600/20 hover:bg-amber-600/30 text-amber-400 rounded transition-colors"
                >{ex.sets.some(s => s.setType === 'warmup') ? 'Redo Warmups' : '+ Warmups'}</button>
              {/if}
              {#if ex.sets.length > 1 && !ex.sets[ex.sets.length - 1].done}
                <button
                  onclick={() => removeSet(ex.uiId, ex.sets[ex.sets.length - 1].localId)}
                  class="text-xs px-3 py-1.5 bg-zinc-800 hover:bg-zinc-700 text-red-400 rounded transition-colors"
                >− Remove Last</button>
              {/if}
            </div>
          </div>

          <!-- ── Recovery prompt (after first set of new muscle group) ── -->
          {#if shouldShowRecovery(ex)}
            {@const muscleLabel = getRecoveryPromptLabel(ex.exerciseId)}
            <div class="mx-1 mb-2 px-3 py-2.5 rounded-xl bg-blue-500/10 border border-blue-500/20">
              <p class="text-xs text-blue-300 mb-2">How recovered is your <span class="font-semibold capitalize">{muscleLabel}</span> from last session?</p>
              <div class="flex gap-2">
                {#each [['😩', 'poor', 'Poor'], ['😐', 'ok', 'OK'], ['💪', 'good', 'Good'], ['🔥', 'fresh', 'Fresh']] as [emoji, value, label]}
                  <button
                    onclick={() => submitRecovery(ex, value as 'poor' | 'ok' | 'good' | 'fresh')}
                    class="flex-1 py-1.5 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-xs text-center transition-colors">
                    <span class="text-base">{emoji}</span><br/>{label}
                  </button>
                {/each}
                <button onclick={() => dismissRecovery(ex)}
                        class="px-2 py-1.5 rounded-lg text-xs text-zinc-500 hover:text-zinc-300 transition-colors">✕</button>
              </div>
            </div>
          {/if}

          <!-- ── Effort prompt (after all sets complete) ── -->
          {#if shouldShowEffort(ex)}
            {@const exercise = getEx(ex.exerciseId)}
            <div class="mx-1 mb-2 px-3 py-3 rounded-xl bg-amber-500/10 border border-amber-500/20">
              <p class="text-sm font-medium text-amber-300 mb-2">How was {exercise?.display_name ?? 'this exercise'}?</p>

              <p class="text-xs text-zinc-400 mb-1.5">Reps in reserve (last set)?</p>
              <div class="flex gap-1.5 mb-3">
                {#each [0, 1, 2, 3, 4, 5] as rir}
                  <button
                    onclick={() => { feedbackData = { ...feedbackData, [ex.exerciseId]: { ...feedbackData[ex.exerciseId], rir } }; }}
                    class="flex-1 py-1.5 rounded-lg text-sm font-mono text-center transition-colors
                           {feedbackData[ex.exerciseId]?.rir === rir ? 'bg-amber-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
                    {rir === 5 ? '5+' : rir}
                  </button>
                {/each}
              </div>

              <p class="text-xs text-zinc-400 mb-1.5">How was the pump?</p>
              <div class="flex gap-1.5 mb-3">
                {#each [['😐', 'none', 'None'], ['🙂', 'mild', 'Mild'], ['💪', 'good', 'Good'], ['🔥', 'great', 'Great']] as [emoji, value, label]}
                  <button
                    onclick={() => { feedbackData = { ...feedbackData, [ex.exerciseId]: { ...feedbackData[ex.exerciseId], pump_rating: value } }; }}
                    class="flex-1 py-1.5 rounded-lg text-xs text-center transition-colors
                           {feedbackData[ex.exerciseId]?.pump_rating === value ? 'bg-amber-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
                    <span class="text-base">{emoji}</span><br/>{label}
                  </button>
                {/each}
              </div>

              {#if feedbackData[ex.exerciseId]?.rir != null && feedbackData[ex.exerciseId]?.pump_rating}
                <div class="flex gap-2">
                  <button
                    onclick={() => submitEffort(ex, feedbackData[ex.exerciseId]!.rir!, feedbackData[ex.exerciseId]!.pump_rating! as 'none' | 'mild' | 'good' | 'great')}
                    class="flex-1 btn-primary text-sm !py-2">Submit</button>
                  <button onclick={() => dismissEffort(ex)}
                          class="px-3 py-2 text-sm text-zinc-500 hover:text-zinc-300 transition-colors">Skip</button>
                </div>
              {:else}
                <div class="flex justify-end">
                  <button onclick={() => dismissEffort(ex)}
                          class="text-xs text-zinc-500 hover:text-zinc-300 transition-colors">Skip</button>
                </div>
              {/if}

              <!-- Show suggestion if already submitted -->
              {#if feedbackData[ex.exerciseId]?.suggestion_detail}
                <div class="mt-2 pt-2 border-t border-amber-500/20">
                  <p class="text-xs text-amber-200">{feedbackData[ex.exerciseId]!.suggestion_detail}</p>
                </div>
              {/if}
            </div>
          {/if}

          <!-- Show saved feedback badge if already submitted -->
          {#if feedbackData[ex.exerciseId]?.suggestion && effortSubmitted.has(ex.exerciseId)}
            <div class="mx-1 mb-1 px-3 py-1.5 rounded-lg bg-zinc-800/50 flex items-center justify-between text-xs">
              <span class="text-zinc-500">
                {#if feedbackData[ex.exerciseId]?.recovery_rating}
                  Recovery: <span class="capitalize">{feedbackData[ex.exerciseId]!.recovery_rating}</span> ·
                {/if}
                RIR: {feedbackData[ex.exerciseId]!.rir} · Pump: <span class="capitalize">{feedbackData[ex.exerciseId]!.pump_rating}</span>
              </span>
              <span class="text-amber-400">{feedbackData[ex.exerciseId]!.suggestion_detail}</span>
            </div>
          {/if}

        {/each}
          </div>
        {/each}

        <!-- Add exercise button -->
        <button onclick={openAddModal}
                class="w-full py-4 border-2 border-dashed border-zinc-800 hover:border-primary-500/60
                       text-zinc-500 hover:text-primary-400 rounded-2xl transition-all text-sm font-medium
                       hover:bg-primary-500/5 active:bg-primary-500/10">
          + Add Exercise
        </button>

        <!-- Finish / Discard buttons -->
        <div class="flex gap-3">
          <button onclick={doDiscard}
                  class="py-4 px-6 bg-zinc-800 hover:bg-zinc-700 text-zinc-400 hover:text-red-400
                         font-medium rounded-2xl transition-colors text-sm">
            Discard
          </button>
          {#if incompleteSets > 0}
            <button disabled
                    class="flex-1 py-4 bg-zinc-700 text-zinc-500 font-bold text-lg rounded-2xl
                           cursor-not-allowed opacity-60">
              {incompleteSets} set{incompleteSets !== 1 ? 's' : ''} remaining
            </button>
          {:else}
            <div class="flex-1 flex flex-col gap-2">
              {#if hasLinkedPlan}
                <label class="flex items-center gap-2 text-sm text-zinc-300 cursor-pointer px-1">
                  <input type="checkbox" bind:checked={syncToPlan} class="rounded" />
                  Update plan with today's changes
                </label>
              {/if}
              <button onclick={doFinish} disabled={finishing}
                      class="w-full py-4 bg-green-600 hover:bg-green-500 active:bg-green-700
                             text-white font-bold text-lg rounded-2xl transition-colors
                             disabled:opacity-50 shadow-sm">
                {finishing ? 'Saving…' : '✓ Finish Workout'}
              </button>
            </div>
          {/if}
        </div>

      </div>
    </div><!-- /scrollable -->

    <!-- ─── Rest timer banner (always visible) ──────────────────────────────── -->
    <div class="sticky bottom-0 z-30 flex items-center px-4 {restActive ? 'py-2.5' : 'py-2'} border-t transition-colors {restActive ? 'bg-zinc-900/95 backdrop-blur border-primary-500/30' : 'bg-zinc-900/80 backdrop-blur border-zinc-800'}"
         style="padding-bottom: max({restActive ? '0.625rem' : '0.5rem'}, env(safe-area-inset-bottom, 0px))">
      {#if restActive}
        <div class="flex items-center gap-3 flex-1">
          <div class="w-7 h-7 rounded-full bg-primary-500/20 flex items-center justify-center shrink-0">
            <span class="text-primary-400 text-xs font-bold">REST</span>
          </div>
          <span class="text-[1.65rem] font-mono font-bold tracking-tight text-white leading-none">{formatRest(restSecs)}</span>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <button onclick={() => { restEndTime = Math.max(Date.now() + 1000, restEndTime - 15000); restSecs = Math.max(1, Math.ceil((restEndTime - Date.now()) / 1000)); }}
                  class="px-3 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-xl text-xs font-medium transition-colors min-h-[38px]">−15s</button>
          <button onclick={() => { restEndTime += 15000; restSecs = Math.ceil((restEndTime - Date.now()) / 1000); }}
                  class="px-3 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-xl text-xs font-medium transition-colors min-h-[38px]">+15s</button>
          <button onclick={skipRest}
                  class="px-4 py-2 bg-primary-600 hover:bg-primary-500 text-white rounded-xl text-sm font-semibold transition-colors min-h-[38px]">Skip</button>
        </div>
      {:else}
        <div class="flex items-center gap-3 flex-1">
          <div class="w-7 h-7 rounded-full bg-zinc-700/50 flex items-center justify-center shrink-0">
            <span class="text-zinc-500 text-xs font-bold">REST</span>
          </div>
          <span class="text-xs text-zinc-500">Ready</span>
        </div>
      {/if}
    </div>

  </div><!-- /fixed inset-0 -->
{/if}

<!-- ─── Add Exercise Modal ────────────────────────────────────────────────── -->
{#if showAddModal}
  <div class="fixed inset-0 bg-black/80 flex items-end sm:items-center justify-center z-50">
    <div class="bg-zinc-900 w-full sm:max-w-md sm:rounded-2xl rounded-t-2xl max-h-[92vh] flex flex-col border border-white/8 shadow-2xl">

      <!-- Modal header -->
      <div class="flex items-center justify-between px-4 py-4 border-b border-white/5 shrink-0">
        <h3 class="font-semibold">
          {#if pickingExercise}
            {pickingExercise.display_name}
          {:else if swapTargetUiId}
            Swap Exercise
          {:else}
            Add Exercise
          {/if}
        </h3>
        <div class="flex items-center gap-3">
          {#if !pickingExercise}
            <button
              onclick={() => openCustomExerciseModal()}
              class="w-8 h-8 rounded-full bg-primary-600 hover:bg-primary-500 text-white text-lg leading-none flex items-center justify-center"
              aria-label="Create custom exercise"
              title="Create custom exercise"
            >+</button>
          {/if}
          <button onclick={() => { showAddModal = false; swapTargetUiId = null; showCustomExerciseModal = false; }} class="text-zinc-400 hover:text-white text-xl leading-none">✕</button>
        </div>
      </div>

      {#if !pickingExercise}
        <!-- Search + filters -->
        <div class="px-4 pt-3 pb-2 shrink-0 space-y-2">
          <input
            type="text"
            bind:value={searchQuery}
            bind:this={searchInputEl}
            placeholder="Search by name or muscle…"
            class="input w-full"
          />
          <!-- Filters: two rows -->
          <div class="space-y-1.5">
            <div class="flex items-center gap-1.5">
              <span class="text-xs text-zinc-500 w-12 shrink-0">Region</span>
              {#each [['all','All'], ['upper','Upper'], ['lower','Lower'], ['full_body','Full Body']] as [val, label]}
                <button
                  onclick={() => filterRegion = val as typeof filterRegion}
                  class="px-2.5 py-1 rounded text-xs font-medium transition-colors {
                    filterRegion === val
                      ? 'bg-primary-600 text-white'
                      : 'bg-zinc-800 hover:bg-zinc-700 text-zinc-300'
                  }"
                >{label}</button>
              {/each}
            </div>
            <div class="flex items-center gap-1.5">
              <span class="text-xs text-zinc-500 w-12 shrink-0">Type</span>
              {#each [['all','All'], ['compound','Compound'], ['isolation','Isolation']] as [val, label]}
                <button
                  onclick={() => filterType = val as typeof filterType}
                  class="px-2.5 py-1 rounded text-xs font-medium transition-colors {
                    filterType === val
                      ? 'bg-indigo-600 text-white'
                      : 'bg-zinc-800 hover:bg-zinc-700 text-zinc-300'
                  }"
                >{label}</button>
              {/each}
            </div>
            <div class="flex items-center gap-1.5 flex-wrap">
              <span class="text-xs text-zinc-500 w-12 shrink-0">Equip</span>
              {#each [['all','All'], ['barbell','Barbell'], ['dumbbell','DB'], ['cable','Cable'], ['machine','Machine'], ['bodyweight','BW'], ['smith','Smith'], ['kettlebell','KB']] as [val, label]}
                <button
                  onclick={() => filterEquip = val}
                  class="px-2.5 py-1 rounded text-xs font-medium transition-colors {
                    filterEquip === val
                      ? 'bg-green-600 text-white'
                      : 'bg-zinc-800 hover:bg-zinc-700 text-zinc-300'
                  }"
                >{label}</button>
              {/each}
            </div>
          </div>
          <p class="text-xs text-zinc-500">{filteredExercises.length} exercises</p>
        </div>

        <!-- List -->
        <div class="flex-1 overflow-y-auto px-2 pb-2">
          {#each filteredExercises as ex}
            <button
              onclick={() => pickingExercise = ex}
              class="w-full text-left px-3 py-2.5 rounded-lg hover:bg-zinc-800 transition-colors"
            >
              <div class="text-sm font-medium">{ex.display_name}</div>
              {#if ex.primary_muscles?.length}
                <div class="text-xs text-zinc-500 capitalize mt-0.5">
                  {ex.primary_muscles.slice(0, 2).map(m => m.replace(/_/g, ' ')).join(', ')}
                </div>
              {/if}
            </button>
          {/each}

          <button
            onclick={() => openCustomExerciseModal()}
            class="w-full text-left px-3 py-3 rounded-lg border border-dashed border-primary-500/40 bg-primary-500/5 hover:bg-primary-500/10 transition-colors mt-1"
          >
            <div class="text-sm font-medium text-primary-300">Create custom exercise</div>
            <div class="text-xs text-zinc-500 mt-0.5">
              {#if searchQuery.trim()}
                Add “{searchQuery.trim()}” if it is missing from the list
              {:else}
                Add a new exercise without leaving the workout
              {/if}
            </div>
          </button>

          {#if filteredExercises.length === 0}
            <p class="text-zinc-500 text-sm text-center py-6">No exercises found</p>
          {/if}
        </div>

      {:else}
        <!-- Set count -->
        <div class="p-6 flex-1 flex flex-col items-center justify-center">
          <p class="text-sm text-zinc-400 mb-6 capitalize">
            {pickingExercise.primary_muscles?.slice(0,2).map(m => m.replace(/_/g,' ')).join(', ')}
          </p>
          <label class="label mb-2">Number of sets</label>
          <div class="flex items-center gap-6 mt-2">
            <button
              onclick={() => pendingSets = Math.max(1, pendingSets - 1)}
              class="w-12 h-12 rounded-full bg-zinc-800 hover:bg-zinc-700 text-2xl font-bold"
            >−</button>
            <span class="text-4xl font-bold w-14 text-center">{pendingSets}</span>
            <button
              onclick={() => pendingSets = Math.min(10, pendingSets + 1)}
              class="w-12 h-12 rounded-full bg-zinc-800 hover:bg-zinc-700 text-2xl font-bold"
            >+</button>
          </div>
        </div>

        <div class="px-4 pb-5 flex gap-3 shrink-0">
          <button onclick={() => pickingExercise = null} class="btn-secondary flex-1">← Back</button>
          <button onclick={confirmAdd} class="btn-primary flex-1">{swapTargetUiId ? 'Swap Exercise' : 'Add to Workout'}</button>
        </div>
      {/if}
    </div>
  </div>
{/if}

{#if showCustomExerciseModal}
  <div class="fixed inset-0 bg-black/80 flex items-center justify-center z-[60] p-4">
    <div class="bg-zinc-900 w-full max-w-md rounded-2xl border border-white/8 shadow-2xl max-h-[92vh] overflow-y-auto">
      <div class="flex items-center justify-between px-4 py-4 border-b border-white/5">
        <h4 class="text-lg font-semibold">Create Custom Exercise</h4>
        <button onclick={closeCustomExerciseModal} class="text-zinc-400 hover:text-white text-xl leading-none">✕</button>
      </div>

      <div class="p-4 space-y-4">
        <div>
          <label class="label">Exercise Name *</label>
          <input
            type="text"
            bind:value={customExerciseDisplayName}
            class="input"
            placeholder="e.g. Incline Dumbbell Press"
          />
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="label">Movement Type</label>
            <select bind:value={customMovementType} class="input">
              {#each movementTypes as type}
                <option value={type.value}>{type.label}</option>
              {/each}
            </select>
          </div>
          <div>
            <label class="label">Body Region</label>
            <select bind:value={customBodyRegion} class="input">
              {#each bodyRegions as region}
                <option value={region.value}>{region.label}</option>
              {/each}
            </select>
          </div>
        </div>

        <div>
          <label class="label">Primary Muscle Groups *</label>
          <div class="flex flex-wrap gap-2">
            {#each muscleGroups as muscle}
              <button
                type="button"
                onclick={() => {
                  customPrimaryMuscles = customPrimaryMuscles.includes(muscle.value)
                    ? customPrimaryMuscles.filter(m => m !== muscle.value)
                    : [...customPrimaryMuscles, muscle.value];
                }}
                class="px-3 py-2 rounded-lg text-sm font-medium transition-colors {customPrimaryMuscles.includes(muscle.value) ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}"
              >
                {muscle.label}
              </button>
            {/each}
          </div>
        </div>

        <div>
          <label class="label">Secondary Muscle Groups</label>
          <div class="flex flex-wrap gap-2">
            {#each muscleGroups as muscle}
              <button
                type="button"
                onclick={() => {
                  customSecondaryMuscles = customSecondaryMuscles.includes(muscle.value)
                    ? customSecondaryMuscles.filter(m => m !== muscle.value)
                    : [...customSecondaryMuscles, muscle.value];
                }}
                class="px-3 py-2 rounded-lg text-sm font-medium transition-colors {customSecondaryMuscles.includes(muscle.value) ? 'bg-indigo-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}"
              >
                {muscle.label}
              </button>
            {/each}
          </div>
        </div>
      </div>

      <div class="flex justify-end gap-3 px-4 py-4 border-t border-white/5">
        <button onclick={closeCustomExerciseModal} class="btn-secondary">Cancel</button>
        <button
          onclick={createCustomExerciseForWorkout}
          class="btn-primary"
          disabled={!customExerciseDisplayName.trim()}
        >
          Create Exercise
        </button>
      </div>
    </div>
  </div>
{/if}

<!-- ─── Exercise History Modal ─────────────────────────────────────────────── -->
{#if historyExerciseId !== null}
  {@const histEx = getEx(historyExerciseId)}
  <div class="fixed inset-0 bg-black/80 flex items-end sm:items-center justify-center z-50">
    <div class="bg-zinc-900 w-full sm:max-w-md sm:rounded-2xl rounded-t-2xl max-h-[92vh] flex flex-col border border-white/8 shadow-2xl">

      <!-- Header -->
      <div class="flex items-center justify-between px-4 py-4 border-b border-white/5 shrink-0">
        <div>
          <h3 class="font-semibold">{histEx?.display_name ?? 'Exercise'}</h3>
          <p class="text-xs text-zinc-500 mt-0.5">Last 8 sessions</p>
        </div>
        <button onclick={() => historyExerciseId = null} class="text-zinc-400 hover:text-white text-xl leading-none">✕</button>
      </div>

      <!-- Body -->
      <div class="flex-1 overflow-y-auto px-4 py-3 space-y-4">
        {#if loadingHistory}
          <div class="flex justify-center py-10">
            <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-500"></div>
          </div>
        {:else if historyData.length === 0}
          <p class="text-zinc-500 text-sm text-center py-10">No history yet for this exercise.</p>
        {:else}
          {#each historyData as session}
            {@const sessionSummary = historySessionInlineSummary(session, histEx?.is_assisted ?? false)}
            <div class="bg-zinc-950 rounded-lg overflow-hidden border border-zinc-800">
              <div class="px-3 py-3">
                <div class="min-w-0">
                  <div class="flex items-baseline gap-2 flex-wrap">
                    {#if session.week_number != null && session.plan_name}
                      <span class="text-sm font-semibold text-primary-400">{session.plan_name} wk {session.week_number}</span>
                    {:else if session.session_name}
                      <span class="text-sm font-semibold text-zinc-300">{session.session_name}</span>
                    {/if}
                    <span class="text-xs text-zinc-500">{fmtHistDate(session.date)}</span>
                  </div>
                  <p class="text-sm text-zinc-300 mt-1 font-mono break-words">
                    {sessionSummary || 'No completed sets'}
                  </p>
                </div>
              </div>
            </div>
          {/each}
        {/if}
      </div>

    </div>
  </div>
{/if}

<!-- PR Celebration Toast -->
{#if prCelebration}
  <div class="fixed top-4 left-1/2 -translate-x-1/2 z-50">
    <div class="bg-amber-500/95 text-white px-4 py-2 rounded-xl shadow-xl shadow-amber-500/20 text-center backdrop-blur-sm min-w-[14rem]">
      <div class="text-[11px] font-semibold uppercase tracking-wide opacity-90">{prCelebration.type}</div>
      <div class="text-sm font-semibold truncate">{prCelebration.exercise}</div>
      <div class="text-base font-bold">{prCelebration.value}</div>
    </div>
  </div>
{/if}

<!-- Fixed plate math banner — sits above the on-screen keyboard -->
{#if plateBanner}
  <div class="fixed bottom-0 left-0 right-0 z-40 bg-zinc-900/95 border-t border-zinc-700 px-4 py-2 backdrop-blur-sm">
    <PlateVisual
      totalWeight={plateBanner.totalWeight}
      barWeight={plateBanner.barWeight}
      isLbs={plateBanner.isLbs}
      oneSided={plateBanner.oneSided}
      prevWeight={plateBanner.prevWeight}
    />
  </div>
{:else if primePegBanner}
  <div class="fixed bottom-0 left-0 right-0 z-40 bg-zinc-900/95 border-t border-zinc-700 px-4 py-2 backdrop-blur-sm">
    <PrimePegVisual
      pegWeights={primePegBanner.pegWeights}
      isLbs={primePegBanner.isLbs}
      prevPegWeights={primePegBanner.prevPegWeights}
    />
  </div>
{/if}
