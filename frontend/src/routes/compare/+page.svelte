<script lang="ts">
  import { onMount } from 'svelte';
  import { getSessions, getSession } from '$lib/api';
  import { settings } from '$lib/stores';

  const KG_TO_LBS = 2.20462;
  function dw(kg: number): number {
    return $settings.weightUnit === 'lbs' ? Math.round(kg * KG_TO_LBS * 10) / 10 : Math.round(kg * 10) / 10;
  }
  let unit = $derived($settings.weightUnit);

  interface SessionSummary {
    id: number;
    name: string;
    date: string;
    total_sets: number;
    total_reps: number;
    total_volume_kg: number;
    status: string;
  }

  interface SetDetail {
    id: number;
    exercise_id: number;
    set_number: number;
    actual_weight_kg: number | null;
    actual_reps: number | null;
    completed_at: string | null;
    set_type: string;
  }

  interface SessionDetail {
    id: number;
    name: string;
    date: string;
    total_sets: number;
    total_reps: number;
    total_volume_kg: number;
    sets: SetDetail[];
    started_at: string | null;
    completed_at: string | null;
  }

  let allSessions = $state<SessionSummary[]>([]);
  let loading = $state(true);
  let sessionA = $state<SessionDetail | null>(null);
  let sessionB = $state<SessionDetail | null>(null);
  let selectedA = $state<number | null>(null);
  let selectedB = $state<number | null>(null);
  let loadingDetail = $state(false);

  onMount(async () => {
    try {
      allSessions = (await getSessions({ limit: 100 })).filter(s => s.status === 'completed');
    } catch (e) {
      console.error('Failed to load sessions:', e);
    } finally {
      loading = false;
    }
  });

  async function loadSession(id: number, side: 'A' | 'B') {
    loadingDetail = true;
    try {
      const detail = await getSession(id);
      if (side === 'A') sessionA = detail;
      else sessionB = detail;
    } catch (e) {
      console.error('Failed to load session:', e);
    } finally {
      loadingDetail = false;
    }
  }

  $effect(() => {
    if (selectedA != null) loadSession(selectedA, 'A');
  });
  $effect(() => {
    if (selectedB != null) loadSession(selectedB, 'B');
  });

  // Group sets by exercise
  function groupByExercise(sets: SetDetail[]): Map<number, SetDetail[]> {
    const map = new Map<number, SetDetail[]>();
    for (const s of sets) {
      if (!map.has(s.exercise_id)) map.set(s.exercise_id, []);
      map.get(s.exercise_id)!.push(s);
    }
    return map;
  }

  // Get all unique exercise IDs across both sessions
  let exerciseIds = $derived(() => {
    const ids = new Set<number>();
    if (sessionA) sessionA.sets.forEach(s => ids.add(s.exercise_id));
    if (sessionB) sessionB.sets.forEach(s => ids.add(s.exercise_id));
    return [...ids];
  });

  // Best set per exercise (highest weight × reps)
  function bestSet(sets: SetDetail[]): SetDetail | null {
    return sets
      .filter(s => s.completed_at && s.actual_weight_kg != null && s.actual_reps != null)
      .sort((a, b) => (b.actual_weight_kg! * b.actual_reps!) - (a.actual_weight_kg! * a.actual_reps!))[0] ?? null;
  }

  function duration(s: SessionDetail): string {
    if (!s.started_at || !s.completed_at) return '—';
    const mins = Math.round((new Date(s.completed_at).getTime() - new Date(s.started_at).getTime()) / 60000);
    return mins < 60 ? `${mins}m` : `${Math.floor(mins / 60)}h ${mins % 60}m`;
  }

  function delta(a: number | null | undefined, b: number | null | undefined): string {
    if (a == null || b == null) return '';
    const d = b - a;
    if (d === 0) return '=';
    return d > 0 ? `+${dw(d)}` : `${dw(d)}`;
  }

  function deltaClass(a: number | null | undefined, b: number | null | undefined): string {
    if (a == null || b == null) return 'text-zinc-500';
    const d = b - a;
    return d > 0 ? 'text-green-400' : d < 0 ? 'text-red-400' : 'text-zinc-500';
  }
</script>

<div class="space-y-5 max-w-2xl mx-auto">
  <h2 class="text-2xl font-bold">Compare Workouts</h2>

  <!-- Session selectors -->
  <div class="grid grid-cols-2 gap-3">
    <div>
      <label class="label">Session A (older)</label>
      <select bind:value={selectedA} class="input text-sm">
        <option value={null}>Select...</option>
        {#each allSessions as s}
          <option value={s.id}>{s.date} — {s.name}</option>
        {/each}
      </select>
    </div>
    <div>
      <label class="label">Session B (newer)</label>
      <select bind:value={selectedB} class="input text-sm">
        <option value={null}>Select...</option>
        {#each allSessions as s}
          <option value={s.id}>{s.date} — {s.name}</option>
        {/each}
      </select>
    </div>
  </div>

  {#if loadingDetail}
    <div class="card animate-pulse bg-zinc-800/50 h-32"></div>
  {/if}

  <!-- Summary comparison -->
  {#if sessionA && sessionB}
    <div class="card">
      <h3 class="font-semibold mb-3">Overview</h3>
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-zinc-800 text-zinc-500 text-xs">
            <th class="py-1.5 text-left">Metric</th>
            <th class="py-1.5 text-right">A</th>
            <th class="py-1.5 text-right">B</th>
            <th class="py-1.5 text-right">Diff</th>
          </tr>
        </thead>
        <tbody>
          <tr class="border-b border-zinc-800/50">
            <td class="py-2 text-zinc-400">Duration</td>
            <td class="py-2 text-right font-mono">{duration(sessionA)}</td>
            <td class="py-2 text-right font-mono">{duration(sessionB)}</td>
            <td class="py-2 text-right text-zinc-500">—</td>
          </tr>
          <tr class="border-b border-zinc-800/50">
            <td class="py-2 text-zinc-400">Total Sets</td>
            <td class="py-2 text-right font-mono">{sessionA.total_sets}</td>
            <td class="py-2 text-right font-mono">{sessionB.total_sets}</td>
            <td class="py-2 text-right font-mono {deltaClass(sessionA.total_sets, sessionB.total_sets)}">
              {delta(sessionA.total_sets, sessionB.total_sets)}
            </td>
          </tr>
          <tr class="border-b border-zinc-800/50">
            <td class="py-2 text-zinc-400">Total Reps</td>
            <td class="py-2 text-right font-mono">{sessionA.total_reps}</td>
            <td class="py-2 text-right font-mono">{sessionB.total_reps}</td>
            <td class="py-2 text-right font-mono {deltaClass(sessionA.total_reps, sessionB.total_reps)}">
              {delta(sessionA.total_reps, sessionB.total_reps)}
            </td>
          </tr>
          <tr>
            <td class="py-2 text-zinc-400">Volume</td>
            <td class="py-2 text-right font-mono">{dw(sessionA.total_volume_kg)} {unit}</td>
            <td class="py-2 text-right font-mono">{dw(sessionB.total_volume_kg)} {unit}</td>
            <td class="py-2 text-right font-mono {deltaClass(sessionA.total_volume_kg, sessionB.total_volume_kg)}">
              {delta(sessionA.total_volume_kg, sessionB.total_volume_kg)} {unit}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Per-exercise comparison -->
    <div class="card">
      <h3 class="font-semibold mb-3">Exercise Breakdown</h3>

      <div class="space-y-3">
        {#each exerciseIds() as exId}
          {@const setsA = groupByExercise(sessionA.sets).get(exId) ?? []}
          {@const setsB = groupByExercise(sessionB.sets).get(exId) ?? []}
          {@const bestA = bestSet(setsA)}
          {@const bestB = bestSet(setsB)}

          <div class="bg-zinc-800/40 rounded-xl px-3 py-2.5">
            <p class="text-sm font-medium text-zinc-200 mb-1.5">Exercise #{exId}</p>
            <div class="grid grid-cols-3 gap-2 text-xs">
              <!-- Session A -->
              <div>
                {#if bestA}
                  <p class="font-mono">{dw(bestA.actual_weight_kg!)} {unit}</p>
                  <p class="text-zinc-500">{bestA.actual_reps} reps × {setsA.filter(s => s.completed_at).length} sets</p>
                {:else}
                  <p class="text-zinc-600">—</p>
                {/if}
              </div>
              <!-- Session B -->
              <div>
                {#if bestB}
                  <p class="font-mono">{dw(bestB.actual_weight_kg!)} {unit}</p>
                  <p class="text-zinc-500">{bestB.actual_reps} reps × {setsB.filter(s => s.completed_at).length} sets</p>
                {:else}
                  <p class="text-zinc-600">—</p>
                {/if}
              </div>
              <!-- Delta -->
              <div class="text-right">
                {#if bestA?.actual_weight_kg != null && bestB?.actual_weight_kg != null}
                  <p class="font-mono {deltaClass(bestA.actual_weight_kg, bestB.actual_weight_kg)}">
                    {delta(bestA.actual_weight_kg, bestB.actual_weight_kg)} {unit}
                  </p>
                {:else}
                  <p class="text-zinc-600">—</p>
                {/if}
              </div>
            </div>
          </div>
        {/each}
      </div>
    </div>
  {/if}
</div>
