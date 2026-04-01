<script lang="ts">
  import { onMount } from 'svelte';
  import { getSessions } from '$lib/api';
  import { settings } from '$lib/stores';
  import type { WorkoutSession } from '$lib/api';
  import type { PageData } from './$types';

  let { data }: { data: PageData } = $props();

  const KG_TO_LBS = 2.20462;

  let loading = $state(true);
  let matchedSessions = $state<WorkoutSession[]>([]);

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

<div class="space-y-4 max-w-2xl mx-auto">
  <div class="flex items-center justify-between gap-3">
    <div>
      <a href="/" class="text-xs text-primary-400 hover:text-primary-300 transition-colors">← Back to Dashboard</a>
      <h2 class="text-2xl font-bold mt-1">{workoutName}</h2>
      <p class="text-sm text-zinc-500">Workout history for this workout name</p>
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
        <div class="space-y-2">
          {#each matchedSessions as session}
            <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 px-4 py-3">
              <div class="flex items-start justify-between gap-4">
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
                </div>
              </div>
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</div>
