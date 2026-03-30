<script lang="ts">
  import { onMount, onDestroy, tick } from 'svelte';
  import { goto } from '$app/navigation';
  import { beforeNavigate } from '$app/navigation';
  import { currentSession, exercises as exerciseStore, latestBodyWeight, settings } from '$lib/stores';
  import {
    getExercises, getPlan, getPlans, getRecentExercises, getSession, getSessions,
    createSessionFromPlan, createSession, startSession,
    addSet, updateSet, deleteSet, completeSession, deleteSession,
    getExerciseHistory, getAllExerciseNotes, setExerciseNote,
    saveExerciseFeedback, syncSessionToPlan, patchSession,
  } from '$lib/api';
  import type { Exercise, WorkoutPlan, ExerciseHistorySession, WorkoutSession } from '$lib/api';
  import { swipeable } from '$lib/actions/swipeable';
  import PlateVisual from '$lib/components/PlateVisual.svelte';
  import html2canvas from 'html2canvas';
  import { writeWorkout } from '$lib/healthkit';

  // ─── Constants ────────────────────────────────────────────────────────────
  const LBS_TO_KG = 0.453592;

  function lbsToKg(lbs: number) { return Math.round(lbs * LBS_TO_KG * 100) / 100; }

  // Convert user-facing weight to kg for backend storage
  function toKg(val: number) {
    return $settings.weightUnit === 'lbs' ? lbsToKg(val) : Math.round(val * 100) / 100;
  }

  // Convert kg from backend to user's display unit, rounded to nearest 5 lbs / 2.5 kg
  const KG_TO_LBS = 2.20462;
  function fromKg(kg: number): number {
    const v = $settings.weightUnit === 'lbs' ? kg * KG_TO_LBS : kg;
    return $settings.weightUnit === 'lbs'
      ? Math.round(v / 5) * 5
      : Math.round(v / 2.5) * 2.5;
  }

  // Round weight to the nearest 5 lbs / 2.5 kg increment
  function roundWeight(w: number): number {
    return $settings.weightUnit === 'lbs'
      ? Math.round(w / 5) * 5
      : Math.round(w / 2.5) * 2.5;
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
    setType: string;  // 'standard' | 'standard_partials' | 'myo_rep' | 'myo_rep_match' | 'drop_set'
    partialReps: number | null;  // for standard_partials — partial ROM reps after full ROM
    drops: { weightLbs: number | null; reps: number | null }[];  // for drop sets only
  }

  interface UIExercise {
    uiId: string;
    exerciseId: number;
    sets: UISet[];
    isUnilateral: boolean;     // overrides exercise default; shows L/R inputs
    customRestSecs: number | null; // null = use category default
    groupId: string | null;    // shared ID for superset/circuit grouping
    groupType: 'superset' | 'circuit' | null;
  }

  interface ExerciseGroup {
    groupId: string | null;
    groupType: 'superset' | 'circuit' | null;
    exercises: UIExercise[];
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

  function checkForPR(ex: UIExercise, set: UISet) {
    const exercise = allExercises.find(e => e.id === ex.exerciseId);
    if (!exercise || !set.initWeight || !set.initReps) return;
    const w = set.weightLbs ?? 0;
    const r = ex.isUnilateral ? Math.min(set.repsLeft ?? 0, set.repsRight ?? 0) : (set.reps ?? 0);
    const isAsst = exercise.is_assisted ?? false;

    let prType = '';
    let prValue = '';
    if (!isAsst && w > (set.initWeight ?? 0)) {
      prType = 'Weight PR';
      prValue = `${w} ${unit}`;
    } else if (r > (set.initReps ?? 0)) {
      prType = 'Rep PR';
      prValue = `${r} reps`;
    }

    if (prType) {
      prCelebration = { exercise: exercise.display_name, type: prType, value: prValue };
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

  function getMuscleGroup(exerciseId: number): string {
    const ex = allExercises.find(e => e.id === exerciseId);
    return ex?.primary_muscles?.[0] ?? 'other';
  }

  function shouldShowRecovery(ex: UIExercise): boolean {
    const muscle = getMuscleGroup(ex.exerciseId);
    const firstSetDone = ex.sets.length > 0 && (ex.sets[0].done || ex.sets[0].skipped);
    const notYetAsked = !recoveryAskedMuscles.has(muscle);
    return firstSetDone && notYetAsked && showRecoveryPrompt[ex.uiId] !== false;
  }

  function shouldShowEffort(ex: UIExercise): boolean {
    const allDone = ex.sets.length > 0 && ex.sets.every(s => s.done || s.skipped);
    const alreadySubmitted = effortSubmitted.has(ex.exerciseId);
    return allDone && !alreadySubmitted && showEffortPrompt[ex.uiId] !== false;
  }

  async function submitRecovery(ex: UIExercise, rating: 'poor' | 'ok' | 'good' | 'fresh') {
    const muscle = getMuscleGroup(ex.exerciseId);
    recoveryAskedMuscles = new Set([...recoveryAskedMuscles, muscle]);
    showRecoveryPrompt = { ...showRecoveryPrompt, [ex.uiId]: false };
    feedbackData = { ...feedbackData, [ex.exerciseId]: { ...feedbackData[ex.exerciseId], recovery_rating: rating } };
    if (sessionId) {
      try {
        await saveExerciseFeedback(sessionId, { exercise_id: ex.exerciseId, recovery_rating: rating });
      } catch (e) { console.error('Failed to save recovery feedback:', e); }
    }
  }

  function dismissRecovery(ex: UIExercise) {
    const muscle = getMuscleGroup(ex.exerciseId);
    recoveryAskedMuscles = new Set([...recoveryAskedMuscles, muscle]);
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

  // Workout clock — only starts on first set completion
  let startedAt = $state<number>(0);
  let elapsed = $state(0);
  let clockInterval: ReturnType<typeof setInterval> | null = null;
  let clockPaused = $state(false);
  let clockStarted = $state(false);
  let pauseOffset = $state(0); // accumulated pause time in ms

  // ─── Plate calculator ──────────────────────────────────────────────────
  const PLATES_LBS = [45, 35, 25, 10, 5, 2.5];
  const PLATES_KG = [20, 15, 10, 5, 2.5, 1.25];

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
    if (n.includes('ez_bar') || n.includes('ez bar') || d.includes('ez bar')) return true;
    if (n.includes('axle_bar') || d.includes('axle bar')) return true;
    if (n.includes('swiss_bar') || d.includes('swiss bar')) return true;
    if (n.includes('rackable') || d.includes('rackable')) return true;
    // T-bar row / landmine
    if (n.includes('t_bar') || n.includes('t-bar') || n.includes('t bar') || d.includes('t-bar') || d.includes('t bar')) return true;
    if (n.includes('landmine') || d.includes('landmine')) return true;
    // Belt squat, plate loaded prefix
    if (n.includes('belt_squat') || n.startsWith('plate_loaded') || d.includes('belt squat')) return true;
    return false;
  }

  function isOneSidedPlateExercise(exercise: Exercise | undefined): boolean {
    if (!exercise) return false;
    const n = exercise.name?.toLowerCase() ?? '';
    return n.includes('t_bar') || n.includes('t-bar') || n.includes('t bar') || n.includes('landmine');
  }

  // Derived: plate banner data for the currently focused weight input
  let plateBanner = $derived.by(() => {
    if (!focusedWeightSetId || !focusedExerciseId) return null;
    for (const ex of uiExercises) {
      if (ex.exerciseId !== focusedExerciseId) continue;
      const exercise = allExercises.find((e: Exercise) => e.id === ex.exerciseId);
      if (!exercise || !shouldShowPlates(exercise)) return null;
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
      else if (n.includes('t_bar') || n.includes('t-bar')) key = 'tBarRow';
      else if (n.includes('belt_squat') || n.includes('belt squat')) key = 'beltSquat';
      // Use display base for plate math if configured, otherwise actual weight
      return mw[`${key}_displayBase`] ?? mw[key] ?? defaultBar;
    }
    // Specialty bars
    const n = exercise.name.toLowerCase();
    if (n.includes('ez_bar') || n.includes('ez bar') || n.includes('curl_bar')) {
      return n.includes('rackable') ? (mw.ezBarRackable ?? 35) : (mw.ezBar ?? 25);
    }
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

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  onMount(async () => {
    try {
      const params = new URLSearchParams(window.location.search);
      const planId = params.get('plan');
      const dayNumber = parseInt(params.get('day') || '1');
      const isDeload = params.get('deload') === 'true';

      const [exData, notesData] = await Promise.all([getExercises(), getAllExerciseNotes()]);
      allExercises = exData;
      exerciseStore.set(allExercises);
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
          // ── No active session: show plan picker ────────────────────────
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
        if (sessionId) saveDrafts();
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
      if (sessionId) saveDrafts();
    });
  }

  // Save drafts before navigating away — session will auto-resume when you come back
  beforeNavigate(() => {
    if (sessionId) saveDrafts();
  });

  // ─── Start helpers ────────────────────────────────────────────────────────
  async function startFromPlan(planId: number, dayNumber: number) {
    loading = true;
    showPicker = false;
    try {
      const bodyWtKg = $latestBodyWeight?.weight_kg ?? 0;
      let raw;
      try {
        raw = await createSessionFromPlan(planId, dayNumber, $settings.progressionStyle, bodyWtKg);
      } catch (e: any) {
        if (e?.response?.status === 409) {
          // Session already in progress — resume it instead of showing conflict dialog
          const detail = e?.response?.data?.detail;
          const existingId: number | null =
            detail && typeof detail === 'object' ? detail.session_id ?? null : null;
          if (existingId != null) {
            currentSession.set(await getSession(existingId));
            await resumeSession();
            return;
          }
          // Fallback: check for any in-progress session
          const sessions = await getSessions({ limit: 5 });
          const inProgress = sessions.find(s => s.started_at && !s.completed_at);
          if (inProgress) {
            currentSession.set(inProgress);
            await resumeSession();
            return;
          }
          await handleConflict(e, () => startFromPlan(planId, dayNumber));
          return;
        }
        throw e;
      }
      const sess = await startSession(raw.id);
      sessionId = sess.id;
      workoutName = sess.name ?? 'Workout';
      hasLinkedPlan = true;
      currentSession.set(sess);

      const plan = await getPlan(planId);
      const day = plan.days.find(d => d.day_number === dayNumber) ?? plan.days[0];

      if (day) {
        uiExercises = day.exercises.map(pe => {
          const exercise = allExercises.find(e => e.id === pe.exercise_id);
          const isUni = exercise?.is_unilateral ?? false;
          const sets: UISet[] = [];
          for (let i = 1; i <= pe.sets; i++) {
            const bset = sess.sets.find(
              s => s.exercise_id === pe.exercise_id && s.set_number === i
            );
            // Pre-fill with progressive overload suggestions when available (0 = blank)
            const suggestedWeight = bset?.planned_weight_kg != null && bset.planned_weight_kg > 0
              ? fromKg(bset.planned_weight_kg)
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
            const draftWeight = bset?.draft_weight_kg != null ? fromKg(bset.draft_weight_kg) : null;
            const draftReps = bset?.draft_reps ?? null;
            const draftLeft = bset?.draft_reps_left ?? null;
            const draftRight = bset?.draft_reps_right ?? null;

            sets.push({
              localId: `${pe.exercise_id}-${i}`,
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
              setType: bset?.set_type || 'standard',
              partialReps: bset?.sub_sets?.find((d: any) => d.type === 'partial')?.reps ?? null,
              drops: bset?.sub_sets ? bset.sub_sets.filter((d: any) => d.type !== 'partial').map((d: any) => ({
                weightLbs: d.weight_kg ? fromKg(d.weight_kg) : null,
                reps: d.reps ?? null,
              })) : [],
            });
          }
          return {
            uiId: `${pe.exercise_id}-${Date.now()}-${Math.random()}`,
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
    if (clockStarted) return;
    clockStarted = true;
    startedAt = Date.now();
    clockInterval = setInterval(() => {
      elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    }, 1000);
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
      const sess = await startSession(raw.id);
      sessionId = sess.id;
      workoutName = sess.name ?? 'Workout';
      currentSession.set(sess);

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

      // Restore elapsed time from when the session started.
      // Use parseUtcMs so the naive datetime from the backend is treated as UTC.
      if (sess.started_at) {
        startedAt = parseUtcMs(sess.started_at);
        elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
      } else {
        startedAt = Date.now();
      }
      clockInterval = setInterval(() => {
        elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
      }, 1000);

      // Group sets by exercise, preserving insertion order
      const exerciseOrder: number[] = [];
      const setsByExercise = new Map<number, typeof sess.sets>();
      for (const s of [...sess.sets].sort((a, b) => a.id - b.id)) {
        if (!exerciseOrder.includes(s.exercise_id)) {
          exerciseOrder.push(s.exercise_id);
          setsByExercise.set(s.exercise_id, []);
        }
        setsByExercise.get(s.exercise_id)!.push(s);
      }

      const bwKg = $latestBodyWeight?.weight_kg ?? 0;

      uiExercises = exerciseOrder.map(exerciseId => {
        const exercise = allExercises.find(e => e.id === exerciseId);
        const isUni = exercise?.is_unilateral ?? false;
        const isAss = exercise?.is_assisted ?? false;
        const backendSets = setsByExercise.get(exerciseId)!;

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
            weightVal = fromKg(bset.draft_weight_kg);
          } else if (bset.planned_weight_kg != null && bset.planned_weight_kg > 0) {
            // Incomplete: use planned/suggested weight
            weightVal = fromKg(bset.planned_weight_kg);
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
            ? fromKg(bset.planned_weight_kg)
            : null;
          const sugR = bset.planned_reps ?? null;
          const oneRM = sugW && sugW > 0 && sugR && sugR > 0 ? sugW * (1 + sugR / 30) : null;

          return {
            localId: `${exerciseId}-${bset.set_number}-resume`,
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
            setType: bset.set_type || 'standard',
            partialReps: bset.sub_sets?.find((d: any) => d.type === 'partial')?.reps ?? null,
            drops: bset.sub_sets ? bset.sub_sets.filter((d: any) => d.type !== 'partial').map((d: any) => ({
              weightLbs: d.weight_kg ? fromKg(d.weight_kg) : null,
              reps: d.reps ?? null,
            })) : [],
          };
        });

        return {
          uiId: `${exerciseId}-${Date.now()}-${Math.random()}`,
          exerciseId,
          sets,
          isUnilateral: isUni,
          customRestSecs: null,
          groupId: null,
          groupType: null,
        };
      });
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

  function formatClock(s: number) {
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    return h > 0
      ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`
      : `${m}:${String(sec).padStart(2, '0')}`;
  }

  function formatRest(s: number) {
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  }

  // ─── Epley bi-directional helpers ────────────────────────────────────────
  function epleyReps(oneRM: number, weight: number): number {
    if (weight <= 0) return 0;
    return roundReps((oneRM / weight - 1) * 30);
  }
  function epleyWeight(oneRM: number, reps: number): number {
    if (reps <= 0) return 0;
    return roundWeight(oneRM / (1 + reps / 30));
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
    if (!set || set.done) return;

    if (set.backendId !== null) {
      try { await deleteSet(sessionId, set.backendId); } catch { /* ignore */ }
    }

    ex.sets = ex.sets.filter(s => s.localId !== localId);
    ex.sets.forEach((s, i) => { s.setNumber = i + 1; });
    uiExercises = [...uiExercises];
  }

  function addSetRow(exUiId: string) {
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (!ex) return;
    const last = ex.sets[ex.sets.length - 1];
    ex.sets = [...ex.sets, {
      localId: `${ex.exerciseId}-${ex.sets.length + 1}-${Date.now()}`,
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
      partialReps: null, drops: [],
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
          setType: 'warmup', partialReps: null, drops: [],
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
        partialReps: null, drops: [],
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

  function moveExercise(idx: number, dir: -1 | 1) {
    const target = idx + dir;
    if (target < 0 || target >= uiExercises.length) return;
    const arr = [...uiExercises];
    [arr[idx], arr[target]] = [arr[target], arr[idx]];
    uiExercises = arr;
  }

  async function removeExercise(exUiId: string) {
    const ex = uiExercises.find(e => e.uiId === exUiId);
    if (ex && sessionId) {
      // Delete any saved backend sets so they don't pollute history
      const backendIds = ex.sets.filter(s => s.backendId !== null).map(s => s.backendId!);
      await Promise.allSettled(backendIds.map(id => deleteSet(sessionId!, id)));
    }
    uiExercises = uiExercises.filter(e => e.uiId !== exUiId);
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
          partialReps: null, drops: [] as { weightLbs: number | null; reps: number | null }[],
        }));
        // Delete old backend sets
        for (const s of oldEx.sets) {
          if (s.backendId && sessionId) {
            deleteSet(sessionId, s.backendId).catch(() => {});
          }
        }
        uiExercises[idx] = {
          uiId: `${pickingExercise.id}-${Date.now()}-${Math.random()}`,
          exerciseId: pickingExercise.id,
          sets: newSets,
          isUnilateral: pickingExercise.is_unilateral,
          customRestSecs: null,
          groupId: oldEx.groupId,
          groupType: oldEx.groupType,
        };
        uiExercises = [...uiExercises];
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
        drops: [] as { weightLbs: number | null; reps: number | null }[],
      }));
      uiExercises = [...uiExercises, {
        uiId: `${pickingExercise.id}-${Date.now()}-${Math.random()}`,
        exerciseId: pickingExercise.id,
        sets,
        isUnilateral: pickingExercise.is_unilateral,
        customRestSecs: null,
        groupId: null,
        groupType: null,
      }];
    }
    showAddModal = false;
    pickingExercise = null;
    searchQuery = '';
  }

  // ─── Finish workout ───────────────────────────────────────────────────────
  async function doFinish() {
    if (!sessionId) { goto('/'); return; }
    finishing = true;
    try {
      await completeSession(sessionId);
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
          const data = await syncSessionToPlan(sessionId);
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
    // Compute PRs before clearing UI state
    prs = detectPRs();
    // Write workout to HealthKit (no-op on web/PWA)
    writeWorkout({
      startDate: new Date(Date.now() - elapsed * 1000),
      endDate: new Date(),
      workoutName: workoutName,
    }).catch(() => {}); // fire and forget
    finished = true;
    finishing = false;
  }

  async function doDiscard() {
    if (!sessionId) { goto('/'); return; }
    const confirmed = confirm('Discard this workout? All progress will be permanently deleted.');
    if (!confirmed) return;
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

  // ─── PR detection ─────────────────────────────────────────────────────────
  interface PR { exerciseName: string; type: 'weight' | 'reps' | '1rm'; value: string; }
  let prs = $state<PR[]>([]);

  function detectPRs(): PR[] {
    const results: PR[] = [];
    for (const ex of uiExercises) {
      const exercise = getEx(ex.exerciseId);
      if (!exercise) continue;
      const isAsst = exercise.is_assisted ?? false;
      const doneSetsEx = ex.sets.filter(s => s.done);
      if (doneSetsEx.length === 0) continue;
      let foundWeight = false;
      let foundReps = false;
      for (const s of doneSetsEx) {
        const w = s.weightLbs ?? 0;
        const r = s.reps ?? (ex.isUnilateral ? Math.min(s.repsLeft ?? 0, s.repsRight ?? 0) : 0);
        if (!s.initWeight || !s.initReps) continue;
        // Weight PR: beat the suggested weight (not applicable for assisted)
        if (!foundWeight && !isAsst && w > (s.initWeight ?? 0)) {
          results.push({ exerciseName: exercise.display_name, type: 'weight', value: `${w} ${unit}` });
          foundWeight = true;
        }
        // Rep PR: beat the suggested reps
        if (!foundReps && r > (s.initReps ?? 0)) {
          results.push({ exerciseName: exercise.display_name, type: 'reps', value: `${r} reps` });
          foundReps = true;
        }
      }
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
    if (retry) await retry();
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

<!-- ─── Conflict: existing in-progress session ────────────────────────── -->
{:else if conflictSession}
  <div class="flex items-center justify-center flex-1 p-4">
    <div class="card max-w-md w-full text-center space-y-4">
      <div class="text-amber-400 text-4xl">⚠️</div>
      <h2 class="text-xl font-semibold">Workout already in progress</h2>
      <p class="text-zinc-400 text-sm">
        <span class="text-white font-medium">{conflictSession.name}</span> is still active.
        Do you want to continue it or abandon it and start a new one?
      </p>
      <div class="flex flex-col gap-3 pt-1">
        <button onclick={continueExisting} class="btn-primary w-full">▶ Continue Existing Workout</button>
        <button
          onclick={abandonAndRetry}
          class="w-full px-4 py-2 rounded-lg border border-red-700 text-red-400 hover:bg-red-900/20 transition-colors text-sm font-medium"
        >🗑 Abandon & Start New</button>
      </div>
      <a href="/plans" class="block text-xs text-zinc-500 hover:text-zinc-300 transition-colors">← Back to Plans</a>
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
  <div class="flex items-center justify-center flex-1 p-4">
    <div class="card max-w-lg w-full" bind:this={summaryCardEl}>
      <div class="text-center mb-6">
        <div class="text-6xl mb-3">🎉</div>
        <h2 class="text-3xl font-bold">Workout done!</h2>
        <p class="text-zinc-400 mt-1">{workoutName}</p>
      </div>

      <!-- Stats -->
      <div class="grid grid-cols-3 gap-4 mb-6">
        <div class="bg-zinc-900 rounded-lg p-3 text-center">
          <p class="text-2xl font-bold text-primary-400">{summaryDoneSets}</p>
          <p class="text-xs text-zinc-400 mt-0.5">Sets done</p>
        </div>
        <div class="bg-zinc-900 rounded-lg p-3 text-center">
          <p class="text-2xl font-bold text-primary-400">{formatClock(elapsed)}</p>
          <p class="text-xs text-zinc-400 mt-0.5">Duration</p>
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
            <button
              onclick={() => {
                if (clockPaused) {
                  // Resume: add pause duration to offset
                  pauseOffset += Date.now() - (startedAt + (elapsed * 1000) + pauseOffset);
                  clockInterval = setInterval(() => {
                    elapsed = Math.max(0, Math.floor((Date.now() - startedAt - pauseOffset) / 1000));
                  }, 1000);
                } else {
                  // Pause: stop the clock
                  if (clockInterval) { clearInterval(clockInterval); clockInterval = null; }
                }
                clockPaused = !clockPaused;
              }}
              class="text-base font-mono font-bold {clockPaused ? 'text-amber-400 animate-pulse' : 'text-primary-400'}"
              title={clockPaused ? 'Resume timer' : 'Pause timer'}
            >{formatClock(elapsed)}{clockPaused ? ' ⏸' : ''}</button>
            <span class="text-xs text-zinc-500">{doneSets}/{totalSets} sets</span>
          </div>
        </div>

        {#if showCancelConfirm}
          <div class="flex items-center gap-2 shrink-0">
            <span class="text-xs text-zinc-400 hidden sm:block">Cancel workout?</span>
            <button onclick={cancelWorkout} disabled={cancelling}
                    class="px-3 py-2 bg-red-600 hover:bg-red-500 text-white text-xs font-semibold rounded-xl transition-colors disabled:opacity-50">
              {cancelling ? 'Cancelling…' : 'Yes, cancel'}
            </button>
            <button onclick={() => showCancelConfirm = false}
                    class="px-3 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 text-xs font-medium rounded-xl transition-colors">
              Keep going
            </button>
          </div>
        {:else}
          <button onclick={() => showCancelConfirm = true}
                  class="shrink-0 w-8 h-8 flex items-center justify-center text-zinc-500 hover:text-red-400 hover:bg-zinc-800 rounded-lg transition-colors"
                  title="Cancel workout">✕</button>
        {/if}
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
                <button onclick={() => { const i = uiExercises.indexOf(ex); if (i > 0) { [uiExercises[i-1], uiExercises[i]] = [uiExercises[i], uiExercises[i-1]]; uiExercises = [...uiExercises]; } }}
                        class="text-zinc-500 hover:text-white px-1 text-sm">▲</button>
                <button onclick={() => { const i = uiExercises.indexOf(ex); if (i < uiExercises.length - 1) { [uiExercises[i], uiExercises[i+1]] = [uiExercises[i+1], uiExercises[i]]; uiExercises = [...uiExercises]; } }}
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
                                set.repsLeft = r;
                                set.repsRight = r;
                              }
                              const idx = ex.sets.indexOf(set);
                              for (let i = idx + 1; i < ex.sets.length; i++) {
                                const s = ex.sets[i];
                                if (!s.done && s.weightLbs === oldWeight) {
                                  s.weightLbs = val;
                                  if (!isAssistedEx && val != null && val > 0 && s.oneRM != null) {
                                    const r = epleyReps(s.oneRM, val);
                                    s.repsLeft = r;
                                    s.repsRight = r;
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
                            {#if focusedWeightSetId === set.localId && !isAssistedEx && set.oneRM && set.weightLbs != null && set.weightLbs > 0 && !set.done}
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
                            if (!isAssistedEx && r != null && r > 0 && set.oneRM != null) {
                              const newW = epleyWeight(set.oneRM, r);
                              set.weightLbs = newW;
                              const idx = ex.sets.indexOf(set);
                              for (let i = idx + 1; i < ex.sets.length; i++) {
                                if (!ex.sets[i].done) ex.sets[i].weightLbs = newW;
                              }
                            }
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
                            set.reps = epleyReps(set.oneRM, val);
                          }
                          // Propagate to subsequent sets only while each next set
                          // had the same weight as the set just edited (chain stops at first mismatch)
                          const idx = ex.sets.indexOf(set);
                          for (let i = idx + 1; i < ex.sets.length; i++) {
                            const s = ex.sets[i];
                            if (!s.done && s.weightLbs === oldWeight) {
                              s.weightLbs = val;
                              if (!isAssistedEx && val != null && val > 0 && s.oneRM != null) {
                                s.reps = epleyReps(s.oneRM, val);
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
                      {#if focusedWeightSetId === set.localId && !isAssistedEx && set.oneRM && set.weightLbs != null && set.weightLbs > 0 && !set.done}
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
                          if (!isAssistedEx && r != null && r > 0 && set.oneRM != null) {
                            const newW = epleyWeight(set.oneRM, r);
                            set.weightLbs = newW;
                            const idx = ex.sets.indexOf(set);
                            for (let i = idx + 1; i < ex.sets.length; i++) {
                              if (!ex.sets[i].done) ex.sets[i].weightLbs = newW;
                            }
                          }
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
            {@const muscle = getMuscleGroup(ex.exerciseId)}
            <div class="mx-1 mb-2 px-3 py-2.5 rounded-xl bg-blue-500/10 border border-blue-500/20">
              <p class="text-xs text-blue-300 mb-2">How recovered is your <span class="font-semibold capitalize">{muscle}</span> from last session?</p>
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
    <div class="sticky bottom-0 z-30 flex items-center px-4 py-3 border-t transition-colors {restActive ? 'bg-zinc-900/95 backdrop-blur border-primary-500/30' : 'bg-zinc-900/80 backdrop-blur border-zinc-800'}">
      {#if restActive}
        <div class="flex items-center gap-3 flex-1">
          <div class="w-8 h-8 rounded-full bg-primary-500/20 flex items-center justify-center shrink-0">
            <span class="text-primary-400 text-xs font-bold">REST</span>
          </div>
          <span class="text-3xl font-mono font-bold tracking-tight text-white">{formatRest(restSecs)}</span>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <button onclick={() => { restEndTime = Math.max(Date.now() + 1000, restEndTime - 15000); restSecs = Math.max(1, Math.ceil((restEndTime - Date.now()) / 1000)); }}
                  class="px-3 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-xl text-xs font-medium transition-colors min-h-[40px]">−15s</button>
          <button onclick={() => { restEndTime += 15000; restSecs = Math.ceil((restEndTime - Date.now()) / 1000); }}
                  class="px-3 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-xl text-xs font-medium transition-colors min-h-[40px]">+15s</button>
          <button onclick={skipRest}
                  class="px-5 py-2 bg-primary-600 hover:bg-primary-500 text-white rounded-xl text-sm font-semibold transition-colors min-h-[40px]">Skip</button>
        </div>
      {:else}
        <div class="flex items-center gap-3 flex-1">
          <div class="w-8 h-8 rounded-full bg-zinc-700/50 flex items-center justify-center shrink-0">
            <span class="text-zinc-500 text-xs font-bold">REST</span>
          </div>
          <span class="text-sm text-zinc-500">Ready</span>
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
        <button onclick={() => { showAddModal = false; swapTargetUiId = null; }} class="text-zinc-400 hover:text-white text-xl leading-none">✕</button>
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
          {:else}
            <p class="text-zinc-500 text-sm text-center py-8">No exercises found</p>
          {/each}
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
            <div>
              <div class="flex items-baseline justify-between mb-1.5">
                <div class="flex items-baseline gap-2">
                  {#if session.week_number != null && session.plan_name}
                    <span class="text-sm font-semibold text-primary-400">{session.plan_name} wk {session.week_number}</span>
                  {:else if session.session_name}
                    <span class="text-sm font-semibold text-zinc-300">{session.session_name}</span>
                  {/if}
                  <span class="text-xs text-zinc-500">{fmtHistDate(session.date)}</span>
                </div>
              </div>
              <div class="bg-zinc-950 rounded-lg overflow-hidden">
                <div class="grid px-3 py-1.5 border-b border-zinc-800" style="grid-template-columns: 2rem 1fr 1fr">
                  <span class="text-xs text-zinc-500">#</span>
                  <span class="text-xs text-zinc-500 text-right">{histEx?.is_assisted ? '−Assist' : `Wt (${unit})`}</span>
                  <span class="text-xs text-zinc-500 text-right">Reps</span>
                </div>
                {#each session.sets as s}
                  {@const dispW = s.actual_weight_kg != null
                    ? (histEx?.is_assisted
                        ? -fromKg(s.actual_weight_kg)   // assist amount stored directly; show as negative
                        : fromKg(s.actual_weight_kg))
                    : null}
                  <div class="grid px-3 py-1.5 border-b border-gray-800 last:border-0" style="grid-template-columns: 2rem 1fr 1fr">
                    <span class="text-xs text-zinc-500 font-mono">{s.set_number}</span>
                    <span class="text-sm font-mono text-right {dispW != null ? 'text-white' : 'text-gray-600'}">
                      {dispW != null ? dispW : '—'}
                    </span>
                    <span class="text-sm font-mono text-right {(s.actual_reps != null || s.reps_left != null || s.reps_right != null) ? 'text-white' : 'text-gray-600'}">
                      {#if s.actual_reps == null && (s.reps_left != null || s.reps_right != null)}
                        L:{s.reps_left ?? '—'}/R:{s.reps_right ?? '—'}
                      {:else}
                        {s.actual_reps ?? '—'}
                      {/if}
                    </span>
                  </div>
                {/each}
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
  <div class="fixed top-4 left-4 right-4 z-50 animate-bounce">
    <div class="bg-gradient-to-r from-amber-600 to-yellow-500 rounded-2xl px-5 py-4 shadow-2xl text-center">
      <p class="text-2xl mb-1">🎉🏆🎉</p>
      <p class="text-lg font-bold text-white">{prCelebration.type}!</p>
      <p class="text-sm text-white/90">{prCelebration.exercise}</p>
      <p class="text-xl font-bold text-white mt-1">{prCelebration.value}</p>
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
{/if}

<!-- PR celebration overlay -->
{#if prCelebration}
  <div class="fixed top-20 left-1/2 -translate-x-1/2 z-50 animate-bounce">
    <div class="bg-gradient-to-r from-yellow-500/90 to-amber-500/90 text-white px-6 py-3 rounded-2xl shadow-2xl shadow-yellow-500/30 text-center backdrop-blur-sm">
      <div class="text-2xl font-black">🏆 NEW PR!</div>
      <div class="text-sm font-semibold opacity-90">{prCelebration.exercise}</div>
      <div class="text-lg font-bold">{prCelebration.type}: {prCelebration.value}</div>
    </div>
  </div>
{/if}
