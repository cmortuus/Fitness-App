<script lang="ts">
  import { onMount, onDestroy, tick } from 'svelte';
  import { beforeNavigate } from '$app/navigation';
  import { currentSession, exercises as exerciseStore, latestBodyWeight, settings } from '$lib/stores';
  import {
    getExercises, getPlan, getPlans, getRecentExercises, getSession,
    createSessionFromPlan, createSession, startSession,
    addSet, updateSet, deleteSet, completeSession, deleteSession,
    getExerciseHistory,
  } from '$lib/api';
  import type { Exercise, WorkoutPlan, ExerciseHistorySession } from '$lib/api';

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
    saving: boolean;
    // Epley anchor — 1RM (in user's display unit) from prior session suggestion.
    // Enables bi-directional weight ↔ reps calculation.
    oneRM: number | null;
    // Original suggestions for deviation warning
    initWeight: number | null;
    initReps: number | null;
  }

  interface UIExercise {
    uiId: string;
    exerciseId: number;
    sets: UISet[];
    isUnilateral: boolean;     // overrides exercise default; shows L/R inputs
    customRestSecs: number | null; // null = use category default
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
  let finished = $state(false);
  let finishing = $state(false);
  let showCancelConfirm = $state(false);
  let cancelling = $state(false);
  let showFinishWarning = $state(false);

  // Workout clock
  let startedAt = $state<number>(0);
  let elapsed = $state(0);
  let clockInterval: ReturnType<typeof setInterval> | null = null;

  // Rest timer
  let restActive = $state(false);
  let restSecs = $state($settings.restDurations.upperCompound);
  let restInterval: ReturnType<typeof setInterval> | null = null;

  // Add-exercise modal
  let showAddModal    = $state(false);
  let searchQuery     = $state('');
  let searchInputEl   = $state<HTMLInputElement | null>(null);
  let pendingSets = $state(3);
  // Filters for the exercise picker
  let filterRegion = $state<'all' | 'upper' | 'lower' | 'full_body'>('all');
  let filterType = $state<'all' | 'compound' | 'isolation'>('all');
  let pickingExercise = $state<Exercise | null>(null);
  let recentExercises = $state<Exercise[]>([]);

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  onMount(async () => {
    try {
      const params = new URLSearchParams(window.location.search);
      const planId = params.get('plan');
      const dayNumber = parseInt(params.get('day') || '1');

      allExercises = await getExercises();
      exerciseStore.set(allExercises);

      try {
        const recent = await getRecentExercises(20);
        recentExercises = recent;
      } catch { /* first use – no history yet */ }

      if (planId) {
        // ── Plan-based mode ──────────────────────────────────────────────
        await startFromPlan(parseInt(planId), dayNumber);
      } else if ($currentSession) {
        // ── Resume in-progress session ───────────────────────────────────
        await resumeSession();
      } else {
        // ── No plan param: show plan picker ──────────────────────────────
        plans = await getPlans();
        showPicker = true;
        loading = false;
      }
    } catch (e) {
      error = 'Failed to start workout: ' + (e instanceof Error ? e.message : String(e));
      loading = false;
    }
  });

  onDestroy(() => {
    if (clockInterval) clearInterval(clockInterval);
    if (restInterval) clearInterval(restInterval);
  });

  // Warn before leaving the page if there's an active session with incomplete sets
  beforeNavigate(({ cancel }) => {
    if (!$currentSession) return;
    const hasUnsaved = uiExercises.some(ex => ex.sets.some(s => !s.done));
    if (hasUnsaved) {
      const confirmed = confirm(
        'You have an active workout with unfinished sets. Leave anyway? Your progress so far is saved.'
      );
      if (!confirmed) cancel();
    }
  });

  // ─── Start helpers ────────────────────────────────────────────────────────
  async function startFromPlan(planId: number, dayNumber: number) {
    loading = true;
    showPicker = false;
    try {
      const bodyWtKg = $latestBodyWeight?.weight_kg ?? 0;
      const raw = await createSessionFromPlan(planId, dayNumber, $settings.progressionStyle, bodyWtKg);
      const sess = await startSession(raw.id);
      sessionId = sess.id;
      workoutName = sess.name ?? 'Workout';
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

            // Compute 1RM anchor so the user can freely adjust weight or reps
            // and have the other field auto-fill via Epley.
            const oneRM = (suggestedWeight != null && suggestedWeight > 0 &&
                           suggestedReps   != null && suggestedReps   > 0)
              ? suggestedWeight * (1 + suggestedReps / 30)
              : null;

            sets.push({
              localId: `${pe.exercise_id}-${i}`,
              backendId: bset?.id ?? null,
              setNumber: i,
              weightLbs: suggestedWeight,
              // Reps always start blank — drop-off fills them after set 1 is logged.
              // initReps is kept for the Epley anchor, deviation warning, and PR detection.
              reps: null,
              repsLeft: null,
              repsRight: null,
              done: false,
              saving: false,
              oneRM,
              initWeight: suggestedWeight,
              initReps:   suggestedReps,
            });
          }
          return {
            uiId: `${pe.exercise_id}-${Date.now()}-${Math.random()}`,
            exerciseId: pe.exercise_id,
            sets,
            isUnilateral: isUni,
            customRestSecs: null,
          };
        });
      }

      startedAt = Date.now();
      clockInterval = setInterval(() => {
        elapsed = Math.floor((Date.now() - startedAt) / 1000);
      }, 1000);
    } catch (e) {
      error = 'Failed to start workout: ' + (e instanceof Error ? e.message : String(e));
    } finally {
      loading = false;
    }
  }

  async function startFreeSession() {
    loading = true;
    showPicker = false;
    try {
      const raw = await createSession({
        date: new Date().toISOString().split('T')[0],
        name: `Workout – ${new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}`,
      });
      const sess = await startSession(raw.id);
      sessionId = sess.id;
      workoutName = sess.name ?? 'Workout';
      currentSession.set(sess);

      startedAt = Date.now();
      clockInterval = setInterval(() => {
        elapsed = Math.floor((Date.now() - startedAt) / 1000);
      }, 1000);
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
      currentSession.set(sess);

      // Restore elapsed time from when the session started
      if (sess.started_at) {
        startedAt = new Date(sess.started_at).getTime();
        elapsed = Math.floor((Date.now() - startedAt) / 1000);
      } else {
        startedAt = Date.now();
      }
      clockInterval = setInterval(() => {
        elapsed = Math.floor((Date.now() - startedAt) / 1000);
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
          const srcWeightKg = isDone ? bset.actual_weight_kg : bset.planned_weight_kg;
          if (srcWeightKg != null && srcWeightKg > 0) {
            if (isAss) {
              // Convert net effective weight back to assist amount
              const assistKg = Math.max(0, bwKg - srcWeightKg);
              weightVal = assistKg > 0 ? fromKg(assistKg) : null;
            } else {
              weightVal = fromKg(srcWeightKg);
            }
          }
          const repsVal = isDone ? bset.actual_reps : (bset.planned_reps ?? null);

          // Parse L/R from notes for completed unilateral sets
          let repsLeft  = isUni ? repsVal : null;
          let repsRight = isUni ? repsVal : null;
          if (isDone && isUni && bset.notes) {
            const lm = bset.notes.match(/L:(\d+)/);
            const rm = bset.notes.match(/R:(\d+)/);
            if (lm) repsLeft  = parseInt(lm[1]);
            if (rm) repsRight = parseInt(rm[1]);
          }

          const sugW = bset.planned_weight_kg != null && bset.planned_weight_kg > 0
            ? (isAss ? fromKg(Math.max(0, bwKg - bset.planned_weight_kg)) : fromKg(bset.planned_weight_kg))
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
            saving: false,
            oneRM,
            initWeight: sugW,
            initReps: sugR,
          };
        });

        return {
          uiId: `${exerciseId}-${Date.now()}-${Math.random()}`,
          exerciseId,
          sets,
          isUnilateral: isUni,
          customRestSecs: null,
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

  // Returns a warning string if the current values deviate significantly from
  // the initial Epley suggestion, null otherwise.
  function deviationWarning(set: UISet, currentWeight: number | null, currentReps: number | null): string | null {
    if (!set.oneRM || set.done) return null;
    const w = currentWeight ?? set.weightLbs;
    const r = currentReps ?? set.reps;
    if (w == null || r == null || w <= 0 || r <= 0) return null;
    const sugW = set.initWeight;
    const sugR = set.initReps;
    if (sugW == null || sugR == null) return null;
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
  let incompleteSets = $derived(totalSets - doneSets);
  let pct = $derived(totalSets > 0 ? Math.round((doneSets / totalSets) * 100) : 0);

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
      const weightKg    = isAssisted
        ? effectiveWeightKg(assistVal)   // body weight − assist
        : toKg(assistVal);

      if (bId === null) {
        const created = await addSet(sessionId, {
          exercise_id: ex.exerciseId,
          set_number: set.setNumber,
          planned_reps: set.reps ?? undefined,
          planned_weight_kg: weightKg,
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

      await updateSet(sessionId, bId, {
        actual_reps: effectiveReps,
        actual_weight_kg: weightKg,
        completed_at: new Date().toISOString(),
        ...(notes && { notes }),
      });

      set.reps = effectiveReps; // sync reps field for drop-off calc
      set.done = true;

      // Weight: propagate to all subsequent undone sets that are still blank
      const pendingSets = ex.sets.filter(s => !s.done && s.localId !== localId);
      for (const s of pendingSets) {
        if (!s.weightLbs) s.weightLbs = set.weightLbs;
      }

      // ── Rep drop-off helpers ─────────────────────────────────────────
      function repDropoff(reps: number): number {
        if (reps >= 15) return 3;
        if (reps >= 10) return 2;
        if (reps >= 5)  return 1;
        return 0;
      }
      function epley1RM(w: number, r: number) { return w * (1 + r / 30); }
      function weightForReps(oneRM: number, r: number) { return oneRM / (1 + r / 30); }

      // Project reps for a single side at a given set position (floors at 1, no rounding)
      function projectReps(startReps: number, setNum: number): number {
        return Math.max(1, startReps - repDropoff(startReps) * setNum);
      }
      // True when the floor kicks in (reps would naturally go below 5)
      function isFloored(startReps: number, setNum: number): boolean {
        return (startReps - repDropoff(startReps) * setNum) < 5;
      }

      // Use effective weight for Epley/drop-off (net load, not assist amount)
      const completedWeight = isAssisted
        ? Math.max(0, bodyWeightInUnit - assistVal)
        : (set.weightLbs ?? 0);

      if (ex.isUnilateral) {
        const leftReps  = set.repsLeft  ?? 0;
        const rightReps = set.repsRight ?? 0;

        pendingSets.forEach((s, idx) => {
          const setNum = idx + 1;

          // Always apply drop-off to reps
          if (leftReps  > 0) s.repsLeft  = projectReps(leftReps,  setNum);
          if (rightReps > 0) s.repsRight = projectReps(rightReps, setNum);

          // Weight reduction only when reps hit the floor
          const weakerReps = leftReps > 0 && rightReps > 0
            ? Math.min(leftReps, rightReps)
            : (leftReps || rightReps);

          if (weakerReps > 0 && isFloored(weakerReps, setNum) && completedWeight > 0) {
            const fatigued1RM  = epley1RM(completedWeight, weakerReps) * Math.pow(0.97, setNum);
            const newEffective = Math.min(completedWeight, Math.round(weightForReps(fatigued1RM, 5) / 2.5) * 2.5);
            if (isAssisted) {
              const newAssist = Math.max(0, Math.round((bodyWeightInUnit - newEffective) / 2.5) * 2.5);
              if (newAssist > (s.weightLbs ?? 0)) s.weightLbs = newAssist;
            } else {
              if (newEffective < (s.weightLbs ?? completedWeight)) s.weightLbs = newEffective;
            }
          }
        });
      } else {
        if (effectiveReps > 0) {
          const oneRM = epley1RM(completedWeight, effectiveReps);
          pendingSets.forEach((s, idx) => {
            const setNum = idx + 1;

            // Always apply drop-off to reps
            s.reps = projectReps(effectiveReps, setNum);

            if (isFloored(effectiveReps, setNum) && completedWeight > 0) {
              const fatigued1RM  = oneRM * Math.pow(0.97, setNum);
              const newEffective = Math.min(completedWeight, Math.round(weightForReps(fatigued1RM, 5) / 2.5) * 2.5);
              if (isAssisted) {
                const newAssist = Math.max(0, Math.round((bodyWeightInUnit - newEffective) / 2.5) * 2.5);
                if (newAssist > (s.weightLbs ?? 0)) s.weightLbs = newAssist;
              } else {
                if (newEffective < (s.weightLbs ?? completedWeight)) s.weightLbs = newEffective;
              }
            }
          });
        }
      }
    } catch (e) {
      console.error('Failed to complete set:', e);
      alert('Failed to save set. Please try again.');
    } finally {
      set.saving = false;
      uiExercises = [...uiExercises];
    }

    startRestTimer(exUiId);
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
      saving: false,
      oneRM: last?.oneRM ?? null,
      initWeight: null,
      initReps: null,
    }];
    uiExercises = [...uiExercises];
  }

  function removeExercise(exUiId: string) {
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

  function startRestTimer(exUiId: string) {
    restSecs = restDurationForExercise(exUiId);
    restActive = true;
    if (restInterval) clearInterval(restInterval);
    restInterval = setInterval(() => {
      restSecs--;
      if (restSecs <= 0) {
        clearInterval(restInterval!);
        restInterval = null;
        restActive = false;
      }
    }, 1000);
  }

  function skipRest() {
    if (restInterval) { clearInterval(restInterval); restInterval = null; }
    restActive = false;
  }

  // ─── Add exercise modal ───────────────────────────────────────────────────
  let filteredExercises = $derived(
    (() => {
      const q = searchQuery.trim().toLowerCase();

      // Apply region + type filters first
      let pool = allExercises.filter(e => {
        if (filterRegion !== 'all' && e.body_region !== filterRegion) return false;
        if (filterType !== 'all' && e.movement_type !== filterType) return false;
        return true;
      });

      if (!q) {
        // Show recents (matching filters) first
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
    const sets: UISet[] = Array.from({ length: pendingSets }, (_, i) => ({
      localId: `${pickingExercise!.id}-${i + 1}-${Date.now()}`,
      backendId: null,
      setNumber: i + 1,
      weightLbs: null,
      reps: null, repsLeft: null, repsRight: null,
      done: false,
      saving: false,
      oneRM: null, initWeight: null, initReps: null,
    }));
    uiExercises = [...uiExercises, {
      uiId: `${pickingExercise.id}-${Date.now()}-${Math.random()}`,
      exerciseId: pickingExercise.id,
      sets,
      isUnilateral: pickingExercise.is_unilateral,
      customRestSecs: null,
    }];
    showAddModal = false;
    pickingExercise = null;
    searchQuery = '';
  }

  // ─── Finish workout ───────────────────────────────────────────────────────
  function requestFinish() {
    if (incompleteSets > 0) {
      showFinishWarning = true;
      showCancelConfirm = false;
    } else {
      doFinish();
    }
  }

  async function doFinish() {
    showFinishWarning = false;
    if (!sessionId) { window.location.href = '/'; return; }
    finishing = true;
    try {
      await completeSession(sessionId);
    } catch (e) {
      console.error('Failed to complete session:', e);
    }
    if (clockInterval) { clearInterval(clockInterval); clockInterval = null; }
    if (restInterval)  { clearInterval(restInterval);  restInterval  = null; }
    currentSession.set(null);
    // Compute PRs before clearing UI state
    prs = detectPRs();
    finished = true;
    finishing = false;
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
      for (const s of doneSetsEx) {
        const w = s.weightLbs ?? 0;
        const r = s.reps ?? (ex.isUnilateral ? Math.min(s.repsLeft ?? 0, s.repsRight ?? 0) : 0);
        if (!s.initWeight || !s.initReps) continue;
        // Weight PR: beat the suggested weight
        if (w > (s.initWeight ?? 0) && !(getEx(ex.exerciseId)?.is_assisted ?? false)) {
          results.push({
            exerciseName: exercise.display_name,
            type: 'weight',
            value: `${w} ${unit}`,
          });
          break;
        }
        // Rep PR: beat the suggested reps
        if (r > (s.initReps ?? 0)) {
          results.push({
            exerciseName: exercise.display_name,
            type: 'reps',
            value: `${r} reps`,
          });
          break;
        }
      }
    }
    return results;
  }


  // ─── Cancel workout ───────────────────────────────────────────────────────
  async function cancelWorkout() {
    if (!sessionId) { window.location.href = '/'; return; }
    cancelling = true;
    try {
      await deleteSession(sessionId);
    } catch (e) {
      console.error('Failed to delete session:', e);
    }
    if (clockInterval) { clearInterval(clockInterval); clockInterval = null; }
    if (restInterval)  { clearInterval(restInterval);  restInterval  = null; }
    currentSession.set(null);
    window.location.href = '/';
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
    } catch (e) {
      console.error('Failed to uncomplete set:', e);
    } finally {
      set.saving = false;
      uiExercises = [...uiExercises];
    }
  }

  let summaryVolumeLbs = $derived(
    uiExercises.reduce((total, ex) =>
      total + ex.sets.filter(s => s.done).reduce((s, set) => s + (set.weightLbs ?? 0) * (set.reps ?? 0), 0)
    , 0)
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
      <p class="text-gray-400">Starting workout…</p>
    </div>
  </div>

<!-- ─── Plan picker ───────────────────────────────────────────────────────── -->
{:else if showPicker}
  <div class="max-w-2xl mx-auto w-full px-4 py-6 space-y-6">

      {#if plans.length > 0}
        <p class="text-gray-400 text-sm">Pick a plan and day to begin:</p>

        {#each plans as plan}
          <div class="card">
            <h2 class="font-semibold text-base mb-1">{plan.name}</h2>
            {#if plan.description}
              <p class="text-gray-400 text-sm mb-3">{plan.description}</p>
            {/if}
            <div class="grid grid-cols-2 sm:grid-cols-3 gap-2 mt-3">
              {#each plan.days as day}
                <button
                  onclick={() => startFromPlan(plan.id, day.day_number)}
                  class="flex flex-col items-start px-4 py-3 bg-gray-700 hover:bg-primary-600 rounded-lg transition-colors text-left group"
                >
                  <span class="text-sm font-medium group-hover:text-white">{day.day_name}</span>
                  <span class="text-xs text-gray-400 group-hover:text-primary-200 mt-0.5">
                    {day.exercises.length} exercise{day.exercises.length !== 1 ? 's' : ''}
                  </span>
                </button>
              {:else}
                <p class="text-gray-500 text-sm col-span-3">No days configured yet.</p>
              {/each}
            </div>
          </div>
        {/each}
      {:else}
        <div class="card text-center py-10">
          <p class="text-gray-400 mb-4">You don't have any workout plans yet.</p>
          <a href="/plans/create" class="btn-primary">Create a Plan</a>
        </div>
      {/if}

      <!-- Free session fallback -->
      <div class="border-t border-gray-700 pt-4">
        <button
          onclick={startFreeSession}
          class="w-full py-3 text-sm text-gray-400 hover:text-gray-200 hover:bg-gray-800 rounded-lg transition-colors"
        >
          Or start a free-form session (no plan)
        </button>
      </div>

  </div>

<!-- ─── Error ──────────────────────────────────────────────────────────── -->
{:else if error}
  <div class="flex items-center justify-center flex-1 p-4">
    <div class="card max-w-md w-full text-center">
      <div class="text-red-400 text-4xl mb-4">⚠️</div>
      <h2 class="text-xl font-semibold mb-2">Couldn't start workout</h2>
      <p class="text-gray-400 mb-6">{error}</p>
      <a href="/plans" class="btn-primary">Back to Plans</a>
    </div>
  </div>

<!-- ─── Finished screen ────────────────────────────────────────────────── -->
{:else if finished}
  <div class="flex items-center justify-center flex-1 p-4">
    <div class="card max-w-lg w-full">
      <div class="text-center mb-6">
        <div class="text-6xl mb-3">🎉</div>
        <h2 class="text-3xl font-bold">Workout done!</h2>
        <p class="text-gray-400 mt-1">{workoutName}</p>
      </div>

      <!-- Stats -->
      <div class="grid grid-cols-3 gap-4 mb-6">
        <div class="bg-gray-800 rounded-lg p-3 text-center">
          <p class="text-2xl font-bold text-primary-400">{summaryDoneSets}</p>
          <p class="text-xs text-gray-400 mt-0.5">Sets done</p>
        </div>
        <div class="bg-gray-800 rounded-lg p-3 text-center">
          <p class="text-2xl font-bold text-primary-400">{formatClock(elapsed)}</p>
          <p class="text-xs text-gray-400 mt-0.5">Duration</p>
        </div>
        <div class="bg-gray-800 rounded-lg p-3 text-center">
          <p class="text-2xl font-bold text-primary-400">{Math.round(summaryVolumeLbs).toLocaleString()}</p>
          <p class="text-xs text-gray-400 mt-0.5">{unit} volume</p>
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

      <!-- Exercise summary -->
      <div class="space-y-1 mb-6 max-h-48 overflow-y-auto">
        {#each uiExercises as ex}
          {@const exercise = getEx(ex.exerciseId)}
          {@const done = ex.sets.filter(s => s.done).length}
          {#if done > 0}
            <div class="flex items-center justify-between py-1.5 border-b border-gray-700 last:border-0">
              <span class="text-sm font-medium">{exercise?.display_name ?? `Exercise ${ex.exerciseId}`}</span>
              <span class="text-sm text-gray-400">{done}/{ex.sets.length} sets</span>
            </div>
          {/if}
        {/each}
      </div>

      <a href="/" class="btn-primary w-full text-center block">Back to Dashboard</a>
    </div>
  </div>

<!-- ─── Active Workout ─────────────────────────────────────────────────── -->
{:else}
  <div class="flex flex-col flex-1 overflow-hidden relative">

    <!-- Header -->
    <header class="shrink-0 bg-gray-800 border-b border-gray-700 px-4 py-3">
      <div class="flex items-center gap-3">
        <div class="flex-1 min-w-0">
          <h1 class="text-base font-semibold truncate">{workoutName}</h1>
          <div class="flex items-center gap-3 mt-0.5">
            <span class="text-sm font-mono text-primary-400">{formatClock(elapsed)}</span>
            <span class="text-xs text-gray-500">{doneSets}/{totalSets} sets</span>
          </div>
        </div>

        <!-- Progress bar -->
        <div class="hidden sm:block flex-1 max-w-xs">
          <div class="h-1.5 bg-gray-700 rounded-full overflow-hidden">
            <div
              class="h-full bg-primary-500 rounded-full transition-all duration-300"
              style="width:{pct}%"
            ></div>
          </div>
        </div>

        {#if showCancelConfirm}
          <!-- Inline cancel confirmation -->
          <div class="flex items-center gap-2 shrink-0">
            <span class="text-xs text-gray-400 hidden sm:block">Cancel workout?</span>
            <button
              onclick={cancelWorkout}
              disabled={cancelling}
              class="px-3 py-1.5 bg-red-600 hover:bg-red-500 text-white text-xs font-medium rounded-lg transition-colors disabled:opacity-50"
            >{cancelling ? 'Cancelling…' : 'Yes, cancel'}</button>
            <button
              onclick={() => showCancelConfirm = false}
              class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-300 text-xs font-medium rounded-lg transition-colors"
            >Keep going</button>
          </div>
        {:else if showFinishWarning}
          <!-- Incomplete sets warning -->
          <div class="flex items-center gap-2 shrink-0">
            <span class="text-xs text-amber-400 hidden sm:block">{incompleteSets} set{incompleteSets !== 1 ? 's' : ''} incomplete</span>
            <button
              onclick={doFinish}
              disabled={finishing}
              class="px-3 py-1.5 bg-green-600 hover:bg-green-500 text-white text-xs font-medium rounded-lg transition-colors disabled:opacity-50"
            >Finish anyway</button>
            <button
              onclick={() => showFinishWarning = false}
              class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-300 text-xs font-medium rounded-lg transition-colors"
            >Keep going</button>
          </div>
        {:else}
          <button
            onclick={() => showCancelConfirm = true}
            class="shrink-0 p-1.5 text-gray-500 hover:text-red-400 transition-colors"
            title="Cancel workout"
          >✕</button>
          <button
            onclick={requestFinish}
            disabled={finishing}
            class="shrink-0 px-4 py-1.5 bg-green-600 hover:bg-green-500 text-white text-sm font-medium rounded-lg transition-colors disabled:opacity-50"
          >
            {finishing ? 'Saving…' : 'Finish'}
          </button>
        {/if}
      </div>
    </header>

    <!-- Scrollable exercise list -->
    <div class="flex-1 overflow-y-auto pb-28">
      <div class="max-w-2xl mx-auto px-3 py-4 space-y-4">

        {#each uiExercises as ex (ex.uiId)}
          {@const exercise = getEx(ex.exerciseId)}
          {@const allDone = ex.sets.length > 0 && ex.sets.every(s => s.done)}
          {@const isAssistedEx = exercise?.is_assisted ?? false}

          <div class="card {allDone ? 'opacity-60' : ''}">
            <!-- Exercise header -->
            <div class="flex items-start justify-between mb-3">
              <div>
                <h3 class="font-semibold">
                  {exercise?.display_name ?? `Exercise ${ex.exerciseId}`}
                  {#if allDone}
                    <span class="ml-2 text-green-400 text-sm">✓</span>
                  {/if}
                </h3>
                {#if exercise?.primary_muscles?.length}
                  <p class="text-xs text-gray-500 mt-0.5 capitalize">{muscleLabel(ex.exerciseId)}</p>
                {/if}
              </div>
              <div class="flex items-center gap-1 ml-3 mt-0.5">
                <button
                  onclick={() => openHistory(ex.exerciseId)}
                  class="text-xs text-gray-500 hover:text-primary-400 px-2 py-0.5 rounded transition-colors hover:bg-gray-700"
                  title="View history for this exercise"
                >History</button>
                <button
                  onclick={() => removeExercise(ex.uiId)}
                  class="text-gray-600 hover:text-red-400 text-xl leading-none"
                  title="Remove exercise"
                >✕</button>
              </div>
            </div>

            <!-- Column headers — adapt to unilateral / assisted mode -->
            {#if ex.isUnilateral}
              <div class="grid gap-1 mb-1 px-1" style="grid-template-columns: 1.5rem 1fr 1fr 1fr 2.25rem">
                <span class="text-xs text-gray-500 text-center">#</span>
                <span class="text-xs text-gray-500 text-center">{isAssistedEx ? `−Assist (${unit})` : `Wt (${unit})`}</span>
                <span class="text-xs text-gray-500 text-center">Left</span>
                <span class="text-xs text-gray-500 text-center">Right</span>
                <span></span>
              </div>
            {:else}
              <div class="grid gap-2 mb-1 px-1" style="grid-template-columns: 1.75rem 1fr 1fr 2.25rem">
                <span class="text-xs text-gray-500 text-center">#</span>
                <span class="text-xs text-gray-500 text-center">{isAssistedEx ? `−Assist (${unit})` : `Weight (${unit})`}</span>
                <span class="text-xs text-gray-500 text-center">Reps</span>
                <span></span>
              </div>
            {/if}

            <!-- Set rows -->
            <div class="space-y-2">
              {#each ex.sets as set (set.localId)}
                {#if ex.isUnilateral}
                  <!-- ── Unilateral row ─────────────────────────────── -->
                  <div
                    class="grid gap-1 items-center px-1 {set.done ? 'opacity-50' : ''}"
                    style="grid-template-columns: 1.5rem 1fr 1fr 1fr 2.25rem"
                  >
                    <span class="text-xs text-gray-400 text-center font-mono">{set.setNumber}</span>

                    <!-- Weight / Assist -->
                    <div class="flex flex-col gap-0.5">
                      <input
                        type="number"
                        value={isAssistedEx && set.weightLbs != null ? -set.weightLbs : (set.weightLbs ?? '')}
                        oninput={(e) => {
                          const raw = (e.target as HTMLInputElement).value;
                          const val = raw === '' ? null : Math.abs(parseFloat(raw));
                          const oldWeight = set.weightLbs;
                          set.weightLbs = val;
                          // Epley: always update rep suggestion for this set
                          if (!isAssistedEx && val != null && val > 0 && set.oneRM != null) {
                            const r = epleyReps(set.oneRM, val);
                            set.repsLeft = r;
                            set.repsRight = r;
                          }
                          // Propagate to subsequent sets only while each next set
                          // had the same weight as the set just edited (chain stops at first mismatch)
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
                        disabled={set.done} min={isAssistedEx ? undefined : 0}
                        placeholder={isAssistedEx ? `-assist` : unit}
                        class="w-full bg-gray-700 border border-gray-600 rounded py-1.5 text-sm text-center focus:outline-none focus:border-primary-500 disabled:opacity-50 px-1"
                      />
                      {#if isAssistedEx && set.weightLbs !== null}
                        <span class="text-xs text-amber-400 text-center">{netDisplay(set.weightLbs)}</span>
                      {/if}
                    </div>

                    <!-- Left reps -->
                    <input
                      type="number"
                      value={set.repsLeft ?? ''}
                      oninput={(e) => {
                        const v = (e.target as HTMLInputElement).value;
                        const r = v === '' ? null : parseInt(v);
                        set.repsLeft = r;
                        // Epley: auto-fill weight only if currently blank
                        if (!isAssistedEx && r != null && r > 0 && set.oneRM != null && set.weightLbs == null) {
                          const newW = epleyWeight(set.oneRM, r);
                          set.weightLbs = newW;
                          const idx = ex.sets.indexOf(set);
                          for (let i = idx + 1; i < ex.sets.length; i++) {
                            if (!ex.sets[i].done) ex.sets[i].weightLbs = newW;
                          }
                        }
                        uiExercises = [...uiExercises];
                      }}
                      disabled={set.done} min="0" placeholder="L"
                      class="w-full bg-gray-700 border border-gray-600 rounded px-1 py-1.5 text-sm text-center focus:outline-none focus:border-indigo-500 disabled:opacity-50"
                    />

                    <!-- Right reps -->
                    <input
                      type="number"
                      value={set.repsRight ?? ''}
                      oninput={(e) => {
                        const v = (e.target as HTMLInputElement).value;
                        const r = v === '' ? null : parseInt(v);
                        set.repsRight = r;
                        // Epley: auto-fill weight only if currently blank
                        if (!isAssistedEx && r != null && r > 0 && set.oneRM != null && set.weightLbs == null) {
                          const newW = epleyWeight(set.oneRM, r);
                          set.weightLbs = newW;
                          const idx = ex.sets.indexOf(set);
                          for (let i = idx + 1; i < ex.sets.length; i++) {
                            if (!ex.sets[i].done) ex.sets[i].weightLbs = newW;
                          }
                        }
                        uiExercises = [...uiExercises];
                      }}
                      disabled={set.done} min="0" placeholder="R"
                      class="w-full bg-gray-700 border border-gray-600 rounded px-1 py-1.5 text-sm text-center focus:outline-none focus:border-indigo-500 disabled:opacity-50"
                    />

                    <!-- Complete / Undo -->
                    {#if set.saving}
                      <div class="flex justify-center"><span class="text-gray-400 text-xs">…</span></div>
                    {:else if set.done}
                      <button
                        onclick={() => uncompleteSet(ex.uiId, set.localId)}
                        class="h-8 w-full rounded bg-green-700 hover:bg-gray-600 text-green-300 hover:text-gray-300 text-sm font-bold transition-colors"
                        title="Undo — mark as incomplete"
                      >✓</button>
                    {:else}
                      {@const canComplete = (set.repsLeft ?? 0) > 0 && (set.repsRight ?? 0) > 0}
                      <button
                        onclick={() => completeSet(ex.uiId, set.localId)}
                        disabled={!canComplete}
                        class="h-8 w-full rounded bg-primary-600 hover:bg-primary-500 text-white text-sm font-bold transition-colors disabled:opacity-30 disabled:cursor-not-allowed"
                        title={canComplete ? 'Log this set' : 'Enter reps for both sides first'}
                      >✓</button>
                    {/if}
                  </div>
                  <!-- Deviation warning (unilateral) -->
                  {#if deviationWarning(set, set.weightLbs, set.repsLeft ?? set.repsRight)}
                    <div class="px-1 mt-0.5">
                      <p class="text-xs text-amber-400 leading-snug">
                        ⚠ {deviationWarning(set, set.weightLbs, set.repsLeft ?? set.repsRight)}
                      </p>
                    </div>
                  {/if}

                {:else}
                  <!-- ── Bilateral row ──────────────────────────────── -->
                  <div
                    class="grid gap-2 items-center px-1 {set.done ? 'opacity-50' : ''}"
                    style="grid-template-columns: 1.75rem 1fr 1fr 2.25rem"
                  >
                    <span class="text-xs text-gray-400 text-center font-mono">{set.setNumber}</span>

                    <!-- Weight / Assist -->
                    <div class="flex flex-col gap-0.5">
                      <input
                        type="number"
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
                        disabled={set.done} min={isAssistedEx ? undefined : 0}
                        placeholder={isAssistedEx ? `-assist` : unit}
                        class="w-full bg-gray-700 border border-gray-600 rounded py-1.5 text-sm text-center focus:outline-none focus:border-primary-500 disabled:opacity-50 px-2"
                      />
                      {#if isAssistedEx && set.weightLbs !== null}
                        <span class="text-xs text-amber-400 text-center">{netDisplay(set.weightLbs)}</span>
                      {/if}
                    </div>

                    <!-- Reps -->
                    <input
                      type="number"
                      value={set.reps ?? ''}
                      oninput={(e) => {
                        const v = (e.target as HTMLInputElement).value;
                        const r = v === '' ? null : parseInt(v);
                        set.reps = r;
                        // Epley: auto-fill weight only if currently blank
                        if (!isAssistedEx && r != null && r > 0 && set.oneRM != null && set.weightLbs == null) {
                          const newW = epleyWeight(set.oneRM, r);
                          set.weightLbs = newW;
                          const idx = ex.sets.indexOf(set);
                          for (let i = idx + 1; i < ex.sets.length; i++) {
                            if (!ex.sets[i].done) ex.sets[i].weightLbs = newW;
                          }
                        }
                        uiExercises = [...uiExercises];
                      }}
                      disabled={set.done} min="0" placeholder="reps"
                      class="w-full bg-gray-700 border border-gray-600 rounded px-2 py-1.5 text-sm text-center focus:outline-none focus:border-primary-500 disabled:opacity-50"
                    />

                    <!-- Complete / Undo -->
                    {#if set.saving}
                      <div class="flex justify-center"><span class="text-gray-400 text-xs">…</span></div>
                    {:else if set.done}
                      <button
                        onclick={() => uncompleteSet(ex.uiId, set.localId)}
                        class="h-8 w-full rounded bg-green-700 hover:bg-gray-600 text-green-300 hover:text-gray-300 text-sm font-bold transition-colors"
                        title="Undo — mark as incomplete"
                      >✓</button>
                    {:else}
                      {@const canComplete = (set.reps ?? 0) > 0}
                      <button
                        onclick={() => completeSet(ex.uiId, set.localId)}
                        disabled={!canComplete}
                        class="h-8 w-full rounded bg-primary-600 hover:bg-primary-500 text-white text-sm font-bold transition-colors disabled:opacity-30 disabled:cursor-not-allowed"
                        title={canComplete ? 'Log this set' : 'Enter reps first'}
                      >✓</button>
                    {/if}
                  </div>
                  <!-- Deviation warning -->
                  {#if deviationWarning(set, set.weightLbs, set.reps)}
                    <div class="col-span-full px-1 mt-0.5">
                      <p class="text-xs text-amber-400 leading-snug">
                        ⚠ {deviationWarning(set, set.weightLbs, set.reps)}
                      </p>
                    </div>
                  {/if}
                {/if}
              {/each}
            </div>

            <!-- Add / remove set row -->
            <div class="flex gap-2 mt-3">
              <button
                onclick={() => addSetRow(ex.uiId)}
                class="text-xs px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-300 rounded transition-colors"
              >+ Add Set</button>
              {#if ex.sets.length > 1 && !ex.sets[ex.sets.length - 1].done}
                <button
                  onclick={() => removeSet(ex.uiId, ex.sets[ex.sets.length - 1].localId)}
                  class="text-xs px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-red-400 rounded transition-colors"
                >− Remove Last</button>
              {/if}
            </div>
          </div>
        {/each}

        <!-- Add exercise button -->
        <button
          onclick={openAddModal}
          class="w-full py-4 border-2 border-dashed border-gray-700 hover:border-primary-500 text-gray-400 hover:text-primary-400 rounded-xl transition-colors text-sm font-medium"
        >
          + Add Exercise
        </button>

      </div>
    </div><!-- /scrollable -->

    <!-- ─── Rest timer banner ──────────────────────────────────────────────── -->
    {#if restActive}
      <div class="absolute bottom-0 left-0 right-0 bg-gray-800 border-t-2 border-primary-600 px-4 py-3 flex items-center justify-between shadow-2xl">
        <div class="flex items-center gap-3">
          <span class="text-primary-400 font-semibold text-sm">REST</span>
          <span class="text-2xl font-mono font-bold">{formatRest(restSecs)}</span>
        </div>
        <div class="flex items-center gap-2">
          <button
            onclick={() => { restSecs = Math.max(1, restSecs - 15); }}
            class="text-xs px-2 py-1 bg-gray-700 hover:bg-gray-600 text-gray-300 rounded"
          >−15s</button>
          <button
            onclick={() => { restSecs += 15; }}
            class="text-xs px-2 py-1 bg-gray-700 hover:bg-gray-600 text-gray-300 rounded"
          >+15s</button>
          <button
            onclick={skipRest}
            class="text-sm px-4 py-1.5 bg-primary-600 hover:bg-primary-500 text-white rounded font-medium"
          >Skip</button>
        </div>
      </div>
    {/if}

  </div><!-- /fixed inset-0 -->
{/if}

<!-- ─── Add Exercise Modal ────────────────────────────────────────────────── -->
{#if showAddModal}
  <div class="fixed inset-0 bg-black/80 flex items-end sm:items-center justify-center z-50">
    <div class="bg-gray-800 w-full sm:max-w-md sm:rounded-xl rounded-t-xl max-h-[90vh] flex flex-col">

      <!-- Modal header -->
      <div class="flex items-center justify-between px-4 py-3 border-b border-gray-700 shrink-0">
        <h3 class="font-semibold">
          {#if pickingExercise}
            {pickingExercise.display_name}
          {:else}
            Add Exercise
          {/if}
        </h3>
        <button onclick={() => showAddModal = false} class="text-gray-400 hover:text-white text-xl leading-none">✕</button>
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
              <span class="text-xs text-gray-500 w-12 shrink-0">Region</span>
              {#each [['all','All'], ['upper','Upper'], ['lower','Lower'], ['full_body','Full Body']] as [val, label]}
                <button
                  onclick={() => filterRegion = val as typeof filterRegion}
                  class="px-2.5 py-1 rounded text-xs font-medium transition-colors {
                    filterRegion === val
                      ? 'bg-primary-600 text-white'
                      : 'bg-gray-700 hover:bg-gray-600 text-gray-300'
                  }"
                >{label}</button>
              {/each}
            </div>
            <div class="flex items-center gap-1.5">
              <span class="text-xs text-gray-500 w-12 shrink-0">Type</span>
              {#each [['all','All'], ['compound','Compound'], ['isolation','Isolation']] as [val, label]}
                <button
                  onclick={() => filterType = val as typeof filterType}
                  class="px-2.5 py-1 rounded text-xs font-medium transition-colors {
                    filterType === val
                      ? 'bg-indigo-600 text-white'
                      : 'bg-gray-700 hover:bg-gray-600 text-gray-300'
                  }"
                >{label}</button>
              {/each}
            </div>
          </div>
          <p class="text-xs text-gray-500">{filteredExercises.length} exercises</p>
        </div>

        <!-- List -->
        <div class="flex-1 overflow-y-auto px-2 pb-2">
          {#each filteredExercises as ex}
            <button
              onclick={() => pickingExercise = ex}
              class="w-full text-left px-3 py-2.5 rounded-lg hover:bg-gray-700 transition-colors"
            >
              <div class="text-sm font-medium">{ex.display_name}</div>
              {#if ex.primary_muscles?.length}
                <div class="text-xs text-gray-500 capitalize mt-0.5">
                  {ex.primary_muscles.slice(0, 2).map(m => m.replace(/_/g, ' ')).join(', ')}
                </div>
              {/if}
            </button>
          {:else}
            <p class="text-gray-500 text-sm text-center py-8">No exercises found</p>
          {/each}
        </div>

      {:else}
        <!-- Set count -->
        <div class="p-6 flex-1 flex flex-col items-center justify-center">
          <p class="text-sm text-gray-400 mb-6 capitalize">
            {pickingExercise.primary_muscles?.slice(0,2).map(m => m.replace(/_/g,' ')).join(', ')}
          </p>
          <label class="label mb-2">Number of sets</label>
          <div class="flex items-center gap-6 mt-2">
            <button
              onclick={() => pendingSets = Math.max(1, pendingSets - 1)}
              class="w-12 h-12 rounded-full bg-gray-700 hover:bg-gray-600 text-2xl font-bold"
            >−</button>
            <span class="text-4xl font-bold w-14 text-center">{pendingSets}</span>
            <button
              onclick={() => pendingSets = Math.min(10, pendingSets + 1)}
              class="w-12 h-12 rounded-full bg-gray-700 hover:bg-gray-600 text-2xl font-bold"
            >+</button>
          </div>
        </div>

        <div class="px-4 pb-5 flex gap-3 shrink-0">
          <button onclick={() => pickingExercise = null} class="btn-secondary flex-1">← Back</button>
          <button onclick={confirmAdd} class="btn-primary flex-1">Add to Workout</button>
        </div>
      {/if}
    </div>
  </div>
{/if}

<!-- ─── Exercise History Modal ─────────────────────────────────────────────── -->
{#if historyExerciseId !== null}
  {@const histEx = getEx(historyExerciseId)}
  <div class="fixed inset-0 bg-black/80 flex items-end sm:items-center justify-center z-50">
    <div class="bg-gray-800 w-full sm:max-w-md sm:rounded-xl rounded-t-xl max-h-[85vh] flex flex-col">

      <!-- Header -->
      <div class="flex items-center justify-between px-4 py-3 border-b border-gray-700 shrink-0">
        <div>
          <h3 class="font-semibold">{histEx?.display_name ?? 'Exercise'}</h3>
          <p class="text-xs text-gray-500 mt-0.5">Last 8 sessions</p>
        </div>
        <button onclick={() => historyExerciseId = null} class="text-gray-400 hover:text-white text-xl leading-none">✕</button>
      </div>

      <!-- Body -->
      <div class="flex-1 overflow-y-auto px-4 py-3 space-y-4">
        {#if loadingHistory}
          <div class="flex justify-center py-10">
            <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-500"></div>
          </div>
        {:else if historyData.length === 0}
          <p class="text-gray-500 text-sm text-center py-10">No history yet for this exercise.</p>
        {:else}
          {#each historyData as session}
            <div>
              <div class="flex items-baseline justify-between mb-1.5">
                <div class="flex items-baseline gap-2">
                  {#if session.week_number != null && session.plan_name}
                    <span class="text-sm font-semibold text-primary-400">{session.plan_name} wk {session.week_number}</span>
                  {:else if session.session_name}
                    <span class="text-sm font-semibold text-gray-300">{session.session_name}</span>
                  {/if}
                  <span class="text-xs text-gray-500">{fmtHistDate(session.date)}</span>
                </div>
              </div>
              <div class="bg-gray-900 rounded-lg overflow-hidden">
                <div class="grid px-3 py-1.5 border-b border-gray-700" style="grid-template-columns: 2rem 1fr 1fr">
                  <span class="text-xs text-gray-500">#</span>
                  <span class="text-xs text-gray-500 text-right">{histEx?.is_assisted ? '−Assist' : `Wt (${unit})`}</span>
                  <span class="text-xs text-gray-500 text-right">Reps</span>
                </div>
                {#each session.sets as s}
                  {@const dispW = s.actual_weight_kg != null
                    ? (histEx?.is_assisted
                        ? -fromKg(Math.max(0, ($latestBodyWeight?.weight_kg ?? 0) - s.actual_weight_kg))
                        : fromKg(s.actual_weight_kg))
                    : null}
                  <div class="grid px-3 py-1.5 border-b border-gray-800 last:border-0" style="grid-template-columns: 2rem 1fr 1fr">
                    <span class="text-xs text-gray-500 font-mono">{s.set_number}</span>
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
