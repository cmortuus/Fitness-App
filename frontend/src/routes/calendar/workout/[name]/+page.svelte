<script lang="ts">
  import { onMount } from 'svelte';
  import { getSession, getSessions, updateSet } from '$lib/api';
  import { settings } from '$lib/stores';
  import type { Set as WorkoutSet, WorkoutSession } from '$lib/api';
  import type { PageData } from './$types';

  let { data }: { data: PageData } = $props();

  const KG_TO_LBS = 2.20462;

  let loading = $state(true);
  let matchedSessions = $state<WorkoutSession[]>([]);
  let expandedSessionIds = $state<Set<number>>(new Set());
  let detailedSessions = $state<Record<number, WorkoutSession>>({});
  let loadingSessionIds = $state<Set<number>>(new Set());
  let savingSetIds = $state<Set<number>>(new Set());
  let editDrafts = $state<Record<number, { weight: string; reps: string; notes: string }>>({});

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

  function setDraft(set: WorkoutSet) {
    editDrafts[set.id] = {
      weight: displayWeight(set.actual_weight_kg),
      reps: set.actual_reps != null ? String(set.actual_reps) : '',
      notes: set.notes ?? '',
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
          weight: displayWeight(set.actual_weight_kg),
          reps: set.actual_reps != null ? String(set.actual_reps) : '',
          notes: set.notes ?? '',
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

  async function saveSet(sessionId: number, set: WorkoutSet) {
    const draft = editDrafts[set.id];
    if (!draft) return;

    const reps = draft.reps.trim() === '' ? null : Number(draft.reps);
    const weight = draft.weight.trim() === '' ? null : Number(draft.weight);
    if ((reps != null && Number.isNaN(reps)) || (weight != null && Number.isNaN(weight))) return;

    savingSetIds.add(set.id);
    savingSetIds = new Set(savingSetIds);
    try {
      await updateSet(sessionId, set.id, {
        actual_reps: reps,
        actual_weight_kg: weight != null ? toKg(weight) : null,
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
      const sessions = await getSessions({ limit: 500 });
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

<div class="space-y-4 max-w-3xl mx-auto">
  <div class="flex items-center justify-between gap-3">
    <div>
      <a href="/" class="text-xs text-primary-400 hover:text-primary-300 transition-colors">← Back to Dashboard</a>
      <h2 class="text-2xl font-bold mt-1">{workoutName}</h2>
      <p class="text-sm text-zinc-500">Review past sessions and correct any logged set details.</p>
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
                    {expandedSessionIds.has(session.id) ? 'Hide set details' : 'View and edit sets'}
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
                      {#each detailedSessions[session.id].sets as set}
                        {@const draft = editDrafts[set.id]}
                        <div class="rounded-lg bg-zinc-950/70 border border-zinc-800 p-3 space-y-3">
                          <div class="flex items-start justify-between gap-4">
                            <div>
                              <p class="text-sm font-medium text-zinc-100">
                                {set.exercise_name ?? `Exercise #${set.exercise_id}`} · Set {set.set_number}
                              </p>
                              <p class="text-xs text-zinc-500 mt-1">
                                Current log: {displayWeight(set.actual_weight_kg) || '0'} {volUnit()} × {set.actual_reps ?? 0} reps
                              </p>
                            </div>
                            <button
                              onclick={() => saveSet(session.id, set)}
                              disabled={!draft || savingSetIds.has(set.id)}
                              class="px-3 py-1.5 rounded-lg bg-primary-600 text-white text-xs font-medium disabled:opacity-50"
                            >
                              {savingSetIds.has(set.id) ? 'Saving…' : 'Save'}
                            </button>
                          </div>

                          {#if draft}
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
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</div>
