<script lang="ts">
  import { onMount } from 'svelte';
  import { deleteSession, getSessions, resetSessionToPlanned, type WorkoutSession } from '$lib/api';

  let sessions = $state<WorkoutSession[]>([]);
  let loading = $state(true);
  let error = $state('');
  let expandedSessionId = $state<number | null>(null);
  let workingSessionId = $state<number | null>(null);

  function fmtDate(iso: string): string {
    return new Date(`${iso}T00:00:00`).toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    });
  }

  function fmtTimestamp(value: string | null): string {
    if (!value) return '—';
    return new Date(value).toLocaleString('en-US', {
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
    });
  }

  function setCount(session: WorkoutSession): number {
    return session.sets?.length ?? 0;
  }

  function completedSetCount(session: WorkoutSession): number {
    return session.sets?.filter((set) => !!set.completed_at && !set.skipped_at).length ?? 0;
  }

  async function loadSessions() {
    loading = true;
    error = '';
    try {
      sessions = await getSessions({ limit: 50 });
    } catch (err) {
      console.error('Failed to load sessions for repair tool', err);
      error = 'Failed to load recent sessions.';
    } finally {
      loading = false;
    }
  }

  onMount(loadSessions);

  async function handleReset(sessionId: number) {
    if (!confirm(`Reset session ${sessionId} back to planned? This clears logged sets and draft values.`)) return;
    workingSessionId = sessionId;
    error = '';
    try {
      const updated = await resetSessionToPlanned(sessionId);
      sessions = sessions.map((session) => session.id === sessionId ? updated : session);
    } catch (err) {
      console.error('Failed to reset session', err);
      error = `Failed to reset session ${sessionId}.`;
    } finally {
      workingSessionId = null;
    }
  }

  async function handleDelete(sessionId: number) {
    if (!confirm(`Delete session ${sessionId}? This cannot be undone.`)) return;
    workingSessionId = sessionId;
    error = '';
    try {
      await deleteSession(sessionId);
      sessions = sessions.filter((session) => session.id !== sessionId);
      if (expandedSessionId === sessionId) expandedSessionId = null;
    } catch (err) {
      console.error('Failed to delete session', err);
      error = `Failed to delete session ${sessionId}.`;
    } finally {
      workingSessionId = null;
    }
  }
</script>

<svelte:head>
  <title>Session Repair</title>
</svelte:head>

<div class="space-y-4">
  <div class="card space-y-2">
    <div class="flex items-start justify-between gap-3">
      <div>
        <a href="/settings" class="text-xs text-zinc-500 hover:text-zinc-300 transition-colors">← Back to Settings</a>
        <h1 class="text-2xl font-bold mt-2">Session Repair</h1>
        <p class="text-sm text-zinc-400">
          Inspect recent workout sessions and repair bad state without direct SQL.
        </p>
      </div>
      <button
        onclick={loadSessions}
        class="px-3 py-2 rounded-lg text-sm font-medium bg-zinc-800 text-zinc-200 hover:bg-zinc-700 transition-colors"
      >
        Refresh
      </button>
    </div>
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 pt-2">
      <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
        <p class="text-xs uppercase tracking-wide text-zinc-500">Loaded</p>
        <p class="text-lg font-semibold">{sessions.length}</p>
      </div>
      <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
        <p class="text-xs uppercase tracking-wide text-zinc-500">In Progress</p>
        <p class="text-lg font-semibold">{sessions.filter((session) => session.status === 'in_progress').length}</p>
      </div>
      <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
        <p class="text-xs uppercase tracking-wide text-zinc-500">Planned With Data</p>
        <p class="text-lg font-semibold">{sessions.filter((session) => session.status === 'planned' && (session.total_sets > 0 || session.total_reps > 0)).length}</p>
      </div>
    </div>
    {#if error}
      <p class="text-sm text-red-400">{error}</p>
    {/if}
  </div>

  {#if loading}
    <div class="card text-sm text-zinc-400">Loading recent sessions...</div>
  {:else if !sessions.length}
    <div class="card text-sm text-zinc-400">No sessions found.</div>
  {:else}
    <div class="space-y-3">
      {#each sessions as session (session.id)}
        <div class="card space-y-3">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="space-y-1">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="text-lg font-semibold">{session.name || `Session ${session.id}`}</h2>
                <span class="px-2 py-0.5 rounded-full text-xs font-medium border border-zinc-700 bg-zinc-900/70 text-zinc-300">
                  {session.status}
                </span>
              </div>
              <p class="text-sm text-zinc-400">
                Session #{session.id} · {fmtDate(session.date)} · Plan {session.workout_plan_id ?? '—'}
              </p>
              <p class="text-xs text-zinc-500">
                {completedSetCount(session)}/{setCount(session)} completed sets · totals {session.total_sets} sets / {session.total_reps} reps
              </p>
              <p class="text-xs text-zinc-500">
                Started {fmtTimestamp(session.started_at)} · Completed {fmtTimestamp(session.completed_at)}
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                onclick={() => expandedSessionId = expandedSessionId === session.id ? null : session.id}
                class="px-3 py-2 rounded-lg text-sm font-medium bg-zinc-800 text-zinc-200 hover:bg-zinc-700 transition-colors"
              >
                {expandedSessionId === session.id ? 'Hide Details' : 'Inspect'}
              </button>
              <button
                onclick={() => handleReset(session.id)}
                disabled={workingSessionId === session.id}
                class="px-3 py-2 rounded-lg text-sm font-medium bg-amber-500/10 text-amber-300 border border-amber-500/20 hover:bg-amber-500/20 disabled:opacity-50 transition-colors"
              >
                Reset to Planned
              </button>
              <button
                onclick={() => handleDelete(session.id)}
                disabled={workingSessionId === session.id}
                class="px-3 py-2 rounded-lg text-sm font-medium bg-red-500/10 text-red-300 border border-red-500/20 hover:bg-red-500/20 disabled:opacity-50 transition-colors"
              >
                Delete
              </button>
            </div>
          </div>

          {#if expandedSessionId === session.id}
            <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 overflow-hidden">
              <div class="grid grid-cols-[64px_minmax(0,1fr)_100px_100px_100px] gap-3 px-4 py-2 text-xs uppercase tracking-wide text-zinc-500 border-b border-zinc-800">
                <div>Set</div>
                <div>Exercise</div>
                <div>Planned</div>
                <div>Actual</div>
                <div>State</div>
              </div>
              {#each session.sets as set}
                <div class="grid grid-cols-[64px_minmax(0,1fr)_100px_100px_100px] gap-3 px-4 py-3 text-sm border-b border-zinc-900 last:border-b-0">
                  <div class="text-zinc-400">#{set.set_number}</div>
                  <div class="min-w-0">
                    <p class="truncate">{set.exercise_name || `Exercise ${set.exercise_id}`}</p>
                    {#if set.draft_weight_kg !== null || set.draft_reps !== null || set.draft_reps_left !== null || set.draft_reps_right !== null}
                      <p class="text-xs text-amber-400">
                        Draft:
                        {#if set.draft_weight_kg !== null}{set.draft_weight_kg}kg {/if}
                        {#if set.draft_reps !== null}{set.draft_reps} reps{/if}
                        {#if set.draft_reps_left !== null || set.draft_reps_right !== null}
                          {set.draft_reps_left ?? 0}L/{set.draft_reps_right ?? 0}R
                        {/if}
                      </p>
                    {/if}
                  </div>
                  <div class="text-zinc-400">
                    {set.planned_weight_kg ?? '—'}kg
                    <br />
                    {set.planned_reps ?? '—'} reps
                  </div>
                  <div class="text-zinc-300">
                    {set.actual_weight_kg ?? '—'}kg
                    <br />
                    {set.actual_reps ?? (set.reps_left !== null || set.reps_right !== null ? `${set.reps_left ?? 0}/${set.reps_right ?? 0}` : '—')}
                  </div>
                  <div class="text-zinc-400">
                    {#if set.completed_at}
                      <span class="text-green-400">Completed</span>
                    {:else if set.started_at}
                      <span class="text-blue-400">Started</span>
                    {:else if set.skipped_at}
                      <span class="text-zinc-500">Skipped</span>
                    {:else}
                      <span>Planned</span>
                    {/if}
                  </div>
                </div>
              {/each}
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>
