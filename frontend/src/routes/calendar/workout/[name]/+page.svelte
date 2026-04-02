<script lang="ts">
  import { onMount } from 'svelte';
  import { getExercises, getSession, getSessions, updateSet } from '$lib/api';
  import { settings } from '$lib/stores';
  import type { Exercise, Set as WorkoutSet, WorkoutSession } from '$lib/api';
  import type { PageData } from './$types';

  let { data }: { data: PageData } = $props();

  const KG_TO_LBS = 2.20462;

  type PegDraft = { peg1: string; peg2: string; peg3: string };
  type EditDraft = {
    exerciseId: number;
    weight: string;
    reps: string;
    notes: string;
    pegWeights: PegDraft;
  };
  type SetGroup = {
    key: string;
    exerciseId: number;
    exerciseName: string;
    exercise: Exercise | undefined;
    sets: WorkoutSet[];
  };

  let loading = $state(true);
  let matchedSessions = $state<WorkoutSession[]>([]);
  let detailedSessions = $state<Record<number, WorkoutSession>>({});
  let allExercises = $state<Exercise[]>([]);
  let expandedSessionIds = $state<Set<number>>(new Set());
  let expandedGroupKeys = $state<Set<string>>(new Set());
  let editingGroupKeys = $state<Set<string>>(new Set());
  let loadingSessionIds = $state<Set<number>>(new Set());
  let savingSetIds = $state<Set<number>>(new Set());
  let editDrafts = $state<Record<number, EditDraft>>({});

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
    return $settings.weightUnit === 'lbs'
      ? weight / KG_TO_LBS
      : weight;
  }

  function emptyPegDraft(pegs?: WorkoutSet['peg_weights']): PegDraft {
    return {
      peg1: pegs?.peg1 != null ? String(pegs.peg1) : '',
      peg2: pegs?.peg2 != null ? String(pegs.peg2) : '',
      peg3: pegs?.peg3 != null ? String(pegs.peg3) : '',
    };
  }

  function groupKey(sessionId: number, exerciseId: number): string {
    return `${sessionId}:${exerciseId}`;
  }

  function getExerciseById(exerciseId: number | null | undefined): Exercise | undefined {
    return allExercises.find((exercise) => exercise.id === exerciseId);
  }

  function displayExerciseName(set: WorkoutSet): string {
    return set.exercise_name
      ?? getExerciseById(set.exercise_id)?.display_name
      ?? `Exercise #${set.exercise_id}`;
  }

  function isPrimePlateLoaded(exercise: Exercise | undefined): boolean {
    return !!exercise && exercise.is_prime && exercise.equipment_type === 'plate_loaded';
  }

  function parseNumber(value: string): number | null {
    const trimmed = value.trim();
    if (trimmed === '') return null;
    const parsed = Number(trimmed);
    return Number.isNaN(parsed) ? null : parsed;
  }

  function sessionGroups(sessionId: number): SetGroup[] {
    const session = detailedSessions[sessionId];
    if (!session) return [];

    const grouped = new Map<number, WorkoutSet[]>();
    for (const set of session.sets) {
      const existing = grouped.get(set.exercise_id) ?? [];
      existing.push(set);
      grouped.set(set.exercise_id, existing);
    }

    return [...grouped.entries()].map(([exerciseId, sets]) => ({
      key: groupKey(sessionId, exerciseId),
      exerciseId,
      exerciseName: displayExerciseName(sets[0]),
      exercise: getExerciseById(exerciseId),
      sets,
    }));
  }

  function buildDraft(set: WorkoutSet): EditDraft {
    return {
      exerciseId: set.exercise_id,
      weight: displayWeight(set.actual_weight_kg),
      reps: set.actual_reps != null ? String(set.actual_reps) : '',
      notes: set.notes ?? '',
      pegWeights: emptyPegDraft(set.peg_weights),
    };
  }

  function resetDraftsFromSession(session: WorkoutSession) {
    const drafts = { ...editDrafts };
    for (const set of session.sets) {
      drafts[set.id] = buildDraft(set);
    }
    editDrafts = drafts;
  }

  async function loadSessionDetail(sessionId: number) {
    if (loadingSessionIds.has(sessionId)) return;
    loadingSessionIds.add(sessionId);
    loadingSessionIds = new Set(loadingSessionIds);
    try {
      const detail = await getSession(sessionId);
      detailedSessions = { ...detailedSessions, [sessionId]: detail };
      matchedSessions = matchedSessions.map((session) => session.id === sessionId ? detail : session);
      resetDraftsFromSession(detail);
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

  function toggleGroup(key: string) {
    if (expandedGroupKeys.has(key)) expandedGroupKeys.delete(key);
    else expandedGroupKeys.add(key);
    expandedGroupKeys = new Set(expandedGroupKeys);
  }

  async function startEditingGroup(sessionId: number, key: string) {
    if (!detailedSessions[sessionId]) {
      await loadSessionDetail(sessionId);
    }
    expandedGroupKeys.add(key);
    expandedGroupKeys = new Set(expandedGroupKeys);
    editingGroupKeys.add(key);
    editingGroupKeys = new Set(editingGroupKeys);
  }

  async function stopEditingGroup(sessionId: number, key: string) {
    editingGroupKeys.delete(key);
    editingGroupKeys = new Set(editingGroupKeys);
    if (detailedSessions[sessionId]) {
      resetDraftsFromSession(detailedSessions[sessionId]);
    } else {
      await loadSessionDetail(sessionId);
    }
  }

  async function saveSet(sessionId: number, set: WorkoutSet) {
    const draft = editDrafts[set.id];
    if (!draft) return;

    const exerciseId = Number(draft.exerciseId);
    const reps = parseNumber(draft.reps);
    const weight = parseNumber(draft.weight);
    const exercise = getExerciseById(exerciseId);
    const peg1 = parseNumber(draft.pegWeights.peg1);
    const peg2 = parseNumber(draft.pegWeights.peg2);
    const peg3 = parseNumber(draft.pegWeights.peg3);
    const hasPegValues = peg1 != null || peg2 != null || peg3 != null;

    savingSetIds.add(set.id);
    savingSetIds = new Set(savingSetIds);
    try {
      await updateSet(sessionId, set.id, {
        exercise_id: exerciseId,
        actual_reps: reps,
        actual_weight_kg: weight != null ? toKg(weight) : null,
        notes: draft.notes.trim() || null,
        peg_weights: isPrimePlateLoaded(exercise) && hasPegValues
          ? {
              peg1: peg1 ?? 0,
              peg2: peg2 ?? 0,
              peg3: peg3 ?? 0,
            }
          : null,
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

  let totalVolume = $derived(matchedSessions.reduce((sum, session) => sum + (session.total_volume_kg ?? 0), 0));
  let totalSets = $derived(matchedSessions.reduce((sum, session) => sum + (session.total_sets ?? 0), 0));
  let totalReps = $derived(matchedSessions.reduce((sum, session) => sum + (session.total_reps ?? 0), 0));

  onMount(async () => {
    try {
      const [sessions, exercises] = await Promise.all([
        getSessions({ limit: 500 }),
        getExercises(),
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
      <p class="text-sm text-zinc-500">Review past sessions, open each exercise group, and edit only when you need to correct a log.</p>
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
                  <p class="text-xs text-zinc-500 mt-1">{session.total_sets} sets · {session.total_reps} reps</p>
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
                      {new Date(session.completed_at).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })}
                    </p>
                  {/if}
                  <p class="text-xs text-zinc-500 mt-2">
                    {expandedSessionIds.has(session.id) ? 'Hide history' : 'View exercise history'}
                  </p>
                </div>
              </button>

              {#if expandedSessionIds.has(session.id)}
                <div class="mt-4 pt-4 border-t border-zinc-800">
                  {#if loadingSessionIds.has(session.id)}
                    <p class="text-sm text-zinc-500">Loading sets...</p>
                  {:else if !detailedSessions[session.id] || detailedSessions[session.id].sets.length === 0}
                    <p class="text-sm text-zinc-500">No set details found for this session.</p>
                  {:else}
                    <div class="space-y-3">
                      {#each sessionGroups(session.id) as group}
                        <div class="rounded-lg border border-zinc-800 bg-zinc-950/60">
                          <div class="flex items-center gap-3 px-4 py-3">
                            <button
                              class="flex-1 text-left"
                              onclick={() => toggleGroup(group.key)}
                            >
                              <p class="text-sm font-medium text-zinc-100">{group.exerciseName}</p>
                              <p class="text-xs text-zinc-500 mt-1">
                                {group.sets.length} {group.sets.length === 1 ? 'set' : 'sets'}
                                {#if group.exercise?.equipment_type}
                                  · {group.exercise.equipment_type.replace('_', ' ')}
                                {/if}
                              </p>
                            </button>
                            {#if editingGroupKeys.has(group.key)}
                              <button
                                class="px-3 py-1.5 rounded-lg border border-zinc-700 text-zinc-200 text-xs font-medium hover:border-zinc-500"
                                onclick={() => stopEditingGroup(session.id, group.key)}
                              >
                                Done Editing
                              </button>
                            {:else}
                              <button
                                class="px-3 py-1.5 rounded-lg bg-primary-600 text-white text-xs font-medium"
                                onclick={() => startEditingGroup(session.id, group.key)}
                              >
                                Edit
                              </button>
                            {/if}
                          </div>

                          {#if expandedGroupKeys.has(group.key)}
                            <div class="border-t border-zinc-800 px-4 py-3 space-y-3">
                              {#each group.sets as set}
                                {@const draft = editDrafts[set.id]}
                                {@const selectedExercise = draft ? getExerciseById(draft.exerciseId) : group.exercise}
                                <div class="rounded-lg border border-zinc-800 bg-zinc-900/60 p-3 space-y-3">
                                  <div class="flex items-start justify-between gap-4">
                                    <div>
                                      <p class="text-sm font-medium text-zinc-100">Set {set.set_number}</p>
                                      <p class="text-xs text-zinc-500 mt-1">
                                        Logged: {displayExerciseName(set)} · {displayWeight(set.actual_weight_kg) || '0'} {volUnit()} × {set.actual_reps ?? 0} reps
                                      </p>
                                      {#if set.notes}
                                        <p class="text-xs text-zinc-400 mt-2">{set.notes}</p>
                                      {/if}
                                    </div>
                                    {#if editingGroupKeys.has(group.key) && draft}
                                      <button
                                        onclick={() => saveSet(session.id, set)}
                                        disabled={savingSetIds.has(set.id)}
                                        class="px-3 py-1.5 rounded-lg bg-primary-600 text-white text-xs font-medium disabled:opacity-50"
                                      >
                                        {savingSetIds.has(set.id) ? 'Saving…' : 'Save'}
                                      </button>
                                    {/if}
                                  </div>

                                  {#if editingGroupKeys.has(group.key) && draft}
                                    <div>
                                      <label class="text-xs text-zinc-500 block mb-1">Exercise</label>
                                      <select bind:value={draft.exerciseId} class="input">
                                        {#each allExercises as exercise}
                                          <option value={exercise.id}>{exercise.display_name}</option>
                                        {/each}
                                      </select>
                                    </div>

                                    <div class="grid grid-cols-2 gap-3">
                                      <div>
                                        <label class="text-xs text-zinc-500 block mb-1">Weight ({volUnit()})</label>
                                        <input type="number" bind:value={draft.weight} class="input" min="0" step="0.5" />
                                      </div>
                                      <div>
                                        <label class="text-xs text-zinc-500 block mb-1">Reps</label>
                                        <input type="number" bind:value={draft.reps} class="input" min="0" step="1" />
                                      </div>
                                    </div>

                                    {#if isPrimePlateLoaded(selectedExercise)}
                                      <div class="rounded-lg border border-zinc-800 bg-zinc-950/80 p-3">
                                        <p class="text-xs font-medium text-zinc-300 mb-2">Prime peg weights per side</p>
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
                                      </div>
                                    {/if}

                                    <div>
                                      <label class="text-xs text-zinc-500 block mb-1">Notes / machine</label>
                                      <input
                                        type="text"
                                        bind:value={draft.notes}
                                        class="input"
                                        placeholder="Machine, setup, or correction note"
                                      />
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
