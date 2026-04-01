<script lang="ts">
  import { onMount } from 'svelte';
  import PrimePegVisual from '$lib/components/PrimePegVisual.svelte';
  import { getExercises, getSession, getSessions, updateSet } from '$lib/api';
  import { settings } from '$lib/stores';
  import type { Exercise, Set as WorkoutSet, WorkoutSession } from '$lib/api';
  import type { PageData } from './$types';

  interface PegDraft {
    peg1: string;
    peg2: string;
    peg3: string;
  }

  interface SetDraft {
    exerciseId: number;
    weight: string;
    reps: string;
    notes: string;
    pegWeights: PegDraft;
  }

  interface ExerciseGroup {
    exerciseId: number;
    exerciseName: string;
    sets: WorkoutSet[];
    exercise: Exercise | null;
  }

  let { data }: { data: PageData } = $props();

  const KG_TO_LBS = 2.20462;

  let loading = $state(true);
  let matchedSessions = $state<WorkoutSession[]>([]);
  let allExercises = $state<Exercise[]>([]);
  let expandedSessionIds = $state<Set<number>>(new Set());
  let detailedSessions = $state<Record<number, WorkoutSession>>({});
  let loadingSessionIds = $state<Set<number>>(new Set());
  let savingSetIds = $state<Set<number>>(new Set());
  let editDrafts = $state<Record<number, SetDraft>>({});
  let expandedGroupKeys = $state<Set<string>>(new Set());
  let editingGroupKeys = $state<Set<string>>(new Set());

  const workoutName = data.name;

  function normalizeName(value: string | null | undefined): string {
    return (value ?? '').trim().toLowerCase();
  }

  function fmtDate(iso: string) {
    return new Date(iso + 'T12:00:00').toLocaleDateString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    });
  }

  function groupKey(sessionId: number, exerciseId: number): string {
    return `${sessionId}:${exerciseId}`;
  }

  function volDisplay(kg: number): number {
    return $settings.weightUnit === 'lbs'
      ? Math.round(kg * KG_TO_LBS)
      : Math.round(kg);
  }

  function volUnit(): string {
    return $settings.weightUnit === 'lbs' ? 'lbs' : 'kg';
  }

  function displayWeight(kg: number | null | undefined): string {
    if (kg == null) return '';
    const value = $settings.weightUnit === 'lbs'
      ? Math.round(kg * KG_TO_LBS * 10) / 10
      : Math.round(kg * 10) / 10;
    return value % 1 === 0 ? value.toFixed(0) : String(value);
  }

  function toKg(weight: number): number {
    return $settings.weightUnit === 'lbs' ? weight / KG_TO_LBS : weight;
  }

  function formatPrimeWeight(weight: number | undefined): string {
    if (!weight) return '';
    return weight % 1 === 0 ? weight.toFixed(0) : String(weight);
  }

  let exerciseMap = $derived.by(() => {
    const map = new Map<number, Exercise>();
    for (const exercise of allExercises) map.set(exercise.id, exercise);
    return map;
  });

  let exerciseOptions = $derived(
    [...allExercises].sort((a, b) => a.display_name.localeCompare(b.display_name))
  );

  function exerciseNameFor(set: WorkoutSet): string {
    return set.exercise_name
      ?? exerciseMap.get(set.exercise_id)?.display_name
      ?? `Exercise ${set.exercise_id}`;
  }

  function exerciseFor(set: WorkoutSet, draft?: SetDraft): Exercise | null {
    const draftExerciseId = draft?.exerciseId ?? set.exercise_id;
    return exerciseMap.get(draftExerciseId) ?? null;
  }

  function isPrimeExercise(set: WorkoutSet, draft?: SetDraft): boolean {
    return exerciseFor(set, draft)?.is_prime ?? false;
  }

  function setDraft(set: WorkoutSet) {
    const pegs = set.peg_weights ?? {};
    editDrafts[set.id] = {
      exerciseId: set.exercise_id,
      weight: displayWeight(set.actual_weight_kg),
      reps: set.actual_reps != null ? String(set.actual_reps) : '',
      notes: set.notes ?? '',
      pegWeights: {
        peg1: formatPrimeWeight(pegs.peg1),
        peg2: formatPrimeWeight(pegs.peg2),
        peg3: formatPrimeWeight(pegs.peg3),
      },
    };
  }

  function draftPegWeights(draft: SetDraft): { peg1: number; peg2: number; peg3: number } {
    return {
      peg1: Number(draft.pegWeights.peg1) || 0,
      peg2: Number(draft.pegWeights.peg2) || 0,
      peg3: Number(draft.pegWeights.peg3) || 0,
    };
  }

  async function loadSessionDetail(sessionId: number) {
    if (loadingSessionIds.has(sessionId)) return;
    loadingSessionIds.add(sessionId);
    loadingSessionIds = new Set(loadingSessionIds);
    try {
      const detail = await getSession(sessionId);
      detailedSessions = { ...detailedSessions, [sessionId]: detail };
      matchedSessions = matchedSessions.map((session) =>
        session.id === sessionId ? detail : session
      );

      const drafts = { ...editDrafts };
      for (const set of detail.sets) {
        drafts[set.id] = {
          exerciseId: set.exercise_id,
          weight: displayWeight(set.actual_weight_kg),
          reps: set.actual_reps != null ? String(set.actual_reps) : '',
          notes: set.notes ?? '',
          pegWeights: {
            peg1: formatPrimeWeight(set.peg_weights?.peg1),
            peg2: formatPrimeWeight(set.peg_weights?.peg2),
            peg3: formatPrimeWeight(set.peg_weights?.peg3),
          },
        };
      }
      editDrafts = drafts;
    } catch (e) {
      console.error('Failed to load workout detail:', e);
    } finally {
      loadingSessionIds.delete(sessionId);
      loadingSessionIds = new Set(loadingSessionIds);
    }
  }

  async function toggleSession(sessionId: number) {
    if (expandedSessionIds.has(sessionId)) {
      expandedSessionIds.delete(sessionId);
      expandedSessionIds = new Set(expandedSessionIds);
      return;
    }

    expandedSessionIds.add(sessionId);
    expandedSessionIds = new Set(expandedSessionIds);

    if (!detailedSessions[sessionId]) {
      await loadSessionDetail(sessionId);
    }
  }

  function toggleGroup(sessionId: number, exerciseId: number) {
    const key = groupKey(sessionId, exerciseId);
    if (expandedGroupKeys.has(key)) expandedGroupKeys.delete(key);
    else expandedGroupKeys.add(key);
    expandedGroupKeys = new Set(expandedGroupKeys);
  }

  function toggleGroupEdit(sessionId: number, exerciseId: number) {
    const key = groupKey(sessionId, exerciseId);
    if (editingGroupKeys.has(key)) editingGroupKeys.delete(key);
    else {
      editingGroupKeys.add(key);
      expandedGroupKeys.add(key);
    }
    editingGroupKeys = new Set(editingGroupKeys);
    expandedGroupKeys = new Set(expandedGroupKeys);
  }

  function groupsForSession(session: WorkoutSession): ExerciseGroup[] {
    const source = detailedSessions[session.id] ?? session;
    const grouped = new Map<number, ExerciseGroup>();
    for (const set of source.sets) {
      const existing = grouped.get(set.exercise_id);
      if (existing) {
        existing.sets.push(set);
        continue;
      }
      grouped.set(set.exercise_id, {
        exerciseId: set.exercise_id,
        exerciseName: exerciseNameFor(set),
        sets: [set],
        exercise: exerciseMap.get(set.exercise_id) ?? null,
      });
    }
    return [...grouped.values()];
  }

  async function saveSet(sessionId: number, set: WorkoutSet) {
    const draft = editDrafts[set.id];
    if (!draft) return;

    const reps = draft.reps.trim() === '' ? null : Number(draft.reps);
    const weight = draft.weight.trim() === '' ? null : Number(draft.weight);
    if ((reps != null && Number.isNaN(reps)) || (weight != null && Number.isNaN(weight))) return;

    const selectedExercise = exerciseMap.get(draft.exerciseId);
    const isPrime = selectedExercise?.is_prime ?? false;
    const pegWeights = draftPegWeights(draft);

    savingSetIds.add(set.id);
    savingSetIds = new Set(savingSetIds);
    try {
      await updateSet(sessionId, set.id, {
        exercise_id: draft.exerciseId,
        actual_reps: reps,
        actual_weight_kg: isPrime ? null : (weight != null ? toKg(weight) : null),
        peg_weights: isPrime ? pegWeights : null,
        notes: draft.notes.trim() || null,
      });
      await loadSessionDetail(sessionId);
    } catch (e) {
      console.error('Failed to update history set:', e);
      alert('Failed to save set changes. Please try again.');
    } finally {
      savingSetIds.delete(set.id);
      savingSetIds = new Set(savingSetIds);
    }
  }

  function updateDraftExercise(setId: number, exerciseId: number) {
    const current = editDrafts[setId];
    if (!current) return;
    const nextExercise = exerciseMap.get(exerciseId);
    const nextDraft: SetDraft = {
      ...current,
      exerciseId,
    };
    if (nextExercise?.is_prime && !exerciseMap.get(current.exerciseId)?.is_prime) {
      nextDraft.weight = '';
      nextDraft.pegWeights = { peg1: '', peg2: '', peg3: '' };
    }
    if (!nextExercise?.is_prime) {
      nextDraft.pegWeights = { peg1: '', peg2: '', peg3: '' };
    }
    editDrafts = { ...editDrafts, [setId]: nextDraft };
  }

  let totalVolume = $derived(
    matchedSessions.reduce((sum, session) => sum + (session.total_volume_kg ?? 0), 0)
  );
  let totalSets = $derived(
    matchedSessions.reduce((sum, session) => sum + (session.total_sets ?? 0), 0)
  );
  let totalReps = $derived(
    matchedSessions.reduce((sum, session) => sum + (session.total_reps ?? 0), 0)
  );

  onMount(async () => {
    try {
      const [sessions, exercises] = await Promise.all([
        getSessions({ limit: 500 }),
        getExercises().catch(() => []),
      ]);
      allExercises = exercises;
      const target = normalizeName(workoutName);
      matchedSessions = sessions.filter((session) =>
        session.status === 'completed' && normalizeName(session.name) === target
      );
    } catch (e) {
      console.error('Failed to load workout history:', e);
    } finally {
      loading = false;
    }
  });
</script>

<div class="space-y-4 max-w-4xl mx-auto">
  <div class="flex items-center justify-between gap-3">
    <div>
      <a href="/" class="text-xs text-primary-400 hover:text-primary-300 transition-colors">← Back to Dashboard</a>
      <h2 class="text-2xl font-bold mt-1">{workoutName}</h2>
      <p class="text-sm text-zinc-500">History first, with optional edit mode when you need to correct a past log.</p>
    </div>
    <a href="/calendar" class="text-xs text-zinc-400 hover:text-zinc-200 transition-colors">Full Calendar</a>
  </div>

  {#if loading}
    <div class="card text-sm text-zinc-400">Loading workout history...</div>
  {:else}
    <div class="grid grid-cols-3 gap-3">
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-primary-400">{matchedSessions.length}</p>
        <p class="text-xs text-zinc-500">Completed Sessions</p>
      </div>
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-green-400">{totalSets}</p>
        <p class="text-xs text-zinc-500">Total Sets</p>
      </div>
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-amber-400">{volDisplay(totalVolume).toLocaleString()}</p>
        <p class="text-xs text-zinc-500">Volume ({volUnit()})</p>
      </div>
    </div>

    <div class="card">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-zinc-200">Sessions</h3>
        <p class="text-xs text-zinc-500">{totalReps} reps total</p>
      </div>

      {#if matchedSessions.length === 0}
        <p class="text-sm text-zinc-500">No completed sessions found for this workout yet.</p>
      {:else}
        <div class="space-y-3">
          {#each matchedSessions as session}
            <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 px-4 py-3">
              <button
                onclick={() => toggleSession(session.id)}
                class="w-full text-left flex items-start justify-between gap-4"
              >
                <div>
                  <p class="text-sm font-medium text-zinc-100">{fmtDate(session.date)}</p>
                  <p class="text-xs text-zinc-500 mt-1">
                    {session.total_sets} sets · {session.total_reps} reps
                  </p>
                  {#if session.notes}
                    <p class="text-xs text-zinc-400 mt-2 line-clamp-2">{session.notes}</p>
                  {/if}
                </div>
                <div class="text-right shrink-0">
                  <p class="text-sm font-semibold text-primary-400">
                    {volDisplay(session.total_volume_kg ?? 0).toLocaleString()} {volUnit()}
                  </p>
                  {#if session.completed_at}
                    <p class="text-xs text-zinc-500 mt-1">
                      {new Date(session.completed_at).toLocaleTimeString('en-US', {
                        hour: 'numeric',
                        minute: '2-digit',
                      })}
                    </p>
                  {/if}
                  <p class="text-xs text-zinc-500 mt-2">
                    {expandedSessionIds.has(session.id) ? 'Hide exercise history' : 'View exercise history'}
                  </p>
                </div>
              </button>

              {#if expandedSessionIds.has(session.id)}
                <div class="mt-4 pt-4 border-t border-zinc-800">
                  {#if loadingSessionIds.has(session.id)}
                    <p class="text-sm text-zinc-500">Loading sets...</p>
                  {:else if groupsForSession(session).length === 0}
                    <p class="text-sm text-zinc-500">No set details found for this session.</p>
                  {:else}
                    <div class="space-y-3">
                      {#each groupsForSession(session) as group}
                        {@const key = groupKey(session.id, group.exerciseId)}
                        <div class="rounded-lg border border-zinc-800 bg-zinc-950/60">
                          <div class="flex items-center gap-3 px-4 py-3">
                            <button
                              onclick={() => toggleGroup(session.id, group.exerciseId)}
                              class="flex-1 text-left"
                            >
                              <p class="text-sm font-medium text-zinc-100">{group.exerciseName}</p>
                              <p class="text-xs text-zinc-500 mt-1">
                                {group.sets.length} set{group.sets.length === 1 ? '' : 's'}
                                {#if group.exercise?.is_prime}
                                  · Prime machine
                                {:else if group.exercise?.equipment_type}
                                  · {group.exercise.equipment_type.replace('_', ' ')}
                                {/if}
                              </p>
                            </button>
                            <button
                              onclick={() => toggleGroupEdit(session.id, group.exerciseId)}
                              class="px-3 py-1.5 rounded-lg border border-zinc-700 text-xs text-zinc-300 hover:bg-zinc-800"
                            >
                              {editingGroupKeys.has(key) ? 'Done Editing' : 'Edit'}
                            </button>
                          </div>

                          {#if expandedGroupKeys.has(key)}
                            <div class="border-t border-zinc-800 px-4 py-3 space-y-3">
                              {#each group.sets as set}
                                {@const draft = editDrafts[set.id]}
                                {@const setExercise = exerciseFor(set, draft)}
                                {@const isPrime = isPrimeExercise(set, draft)}
                                <div class="rounded-lg bg-zinc-900/70 border border-zinc-800 p-3 space-y-3">
                                  <div class="flex items-start justify-between gap-4">
                                    <div>
                                      <p class="text-sm font-medium text-zinc-100">Set {set.set_number}</p>
                                      <p class="text-xs text-zinc-500 mt-1">
                                        {#if isPrime}
                                          Prime total: {displayWeight(set.actual_weight_kg) || '0'} {volUnit()}
                                        {:else}
                                          {displayWeight(set.actual_weight_kg) || '0'} {volUnit()} × {set.actual_reps ?? 0} reps
                                        {/if}
                                      </p>
                                    </div>
                                    {#if editingGroupKeys.has(key)}
                                      <button
                                        onclick={() => saveSet(session.id, set)}
                                        disabled={!draft || savingSetIds.has(set.id)}
                                        class="px-3 py-1.5 rounded-lg bg-primary-600 text-white text-xs font-medium disabled:opacity-50"
                                      >
                                        {savingSetIds.has(set.id) ? 'Saving…' : 'Save'}
                                      </button>
                                    {/if}
                                  </div>

                                  {#if !editingGroupKeys.has(key)}
                                    <div class="space-y-2 text-sm text-zinc-300">
                                      <div class="flex items-center justify-between">
                                        <span class="text-zinc-500">Exercise</span>
                                        <span>{exerciseNameFor(set)}</span>
                                      </div>
                                      {#if isPrime && draft}
                                        <PrimePegVisual
                                          pegWeights={draftPegWeights(draft)}
                                          isLbs={$settings.weightUnit === 'lbs'}
                                        />
                                      {:else}
                                        <div class="flex items-center justify-between">
                                          <span class="text-zinc-500">Load</span>
                                          <span>{displayWeight(set.actual_weight_kg) || '0'} {volUnit()}</span>
                                        </div>
                                        <div class="flex items-center justify-between">
                                          <span class="text-zinc-500">Reps</span>
                                          <span>{set.actual_reps ?? 0}</span>
                                        </div>
                                      {/if}
                                      {#if set.notes}
                                        <div class="pt-1">
                                          <p class="text-zinc-500 text-xs mb-1">Notes / machine</p>
                                          <p>{set.notes}</p>
                                        </div>
                                      {/if}
                                    </div>
                                  {:else if draft}
                                    <div class="space-y-3">
                                      <div>
                                        <label class="text-xs text-zinc-500 block mb-1">Exercise</label>
                                        <select
                                          bind:value={draft.exerciseId}
                                          onchange={() => updateDraftExercise(set.id, Number(draft.exerciseId))}
                                          class="input"
                                        >
                                          {#each exerciseOptions as exercise}
                                            <option value={exercise.id}>{exercise.display_name}</option>
                                          {/each}
                                        </select>
                                      </div>

                                      {#if isPrime}
                                        <div class="grid grid-cols-3 gap-3">
                                          {#each ['peg1', 'peg2', 'peg3'] as pegKey}
                                            <div>
                                              <label class="text-xs text-zinc-500 block mb-1">{pegKey.toUpperCase()}</label>
                                              <input
                                                type="number"
                                                bind:value={draft.pegWeights[pegKey as keyof PegDraft]}
                                                class="input"
                                                min="0"
                                                step="0.5"
                                              />
                                            </div>
                                          {/each}
                                        </div>
                                        <PrimePegVisual
                                          pegWeights={draftPegWeights(draft)}
                                          isLbs={$settings.weightUnit === 'lbs'}
                                        />
                                      {:else}
                                        <div class="grid grid-cols-2 gap-3">
                                          <div>
                                            <label class="text-xs text-zinc-500 block mb-1">Weight ({volUnit()})</label>
                                            <input
                                              type="number"
                                              bind:value={draft.weight}
                                              class="input"
                                              min="0"
                                              step="0.5"
                                            />
                                          </div>
                                          <div>
                                            <label class="text-xs text-zinc-500 block mb-1">Reps</label>
                                            <input
                                              type="number"
                                              bind:value={draft.reps}
                                              class="input"
                                              min="0"
                                              step="1"
                                            />
                                          </div>
                                        </div>
                                      {/if}

                                      <div>
                                        <label class="text-xs text-zinc-500 block mb-1">Notes / machine</label>
                                        <input
                                          type="text"
                                          bind:value={draft.notes}
                                          class="input"
                                          placeholder="Machine setup, handle choice, or correction note"
                                        />
                                      </div>
                                    </div>
                                  {/if}
                                </div>
                              {/each}
                            </div>
                          {/if}
                        </div>
                      {/each}
                    </div>
                  {/if}
                </div>
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</div>
