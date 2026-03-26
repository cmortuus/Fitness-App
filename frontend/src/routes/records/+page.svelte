<script lang="ts">
  import { onMount } from 'svelte';
  import { settings } from '$lib/stores';
  import { getPersonalRecords } from '$lib/api';

  const KG_TO_LBS = 2.20462;

  interface PR {
    exercise_id: number;
    display_name: string;
    max_weight_kg: number;
    max_reps: number;
    best_1rm_kg: number;
    best_set_weight_kg: number;
    best_set_reps: number;
  }

  let records = $state<PR[]>([]);
  let loading = $state(true);
  let filter = $state('');

  function w(kg: number): string {
    const val = $settings.weightUnit === 'lbs' ? kg * KG_TO_LBS : kg;
    return Math.round(val).toLocaleString();
  }

  let unit = $derived($settings.weightUnit);

  let filtered = $derived(
    filter
      ? records.filter(r => r.display_name.toLowerCase().includes(filter.toLowerCase()))
      : records
  );

  onMount(async () => {
    try {
      records = await getPersonalRecords();
    } catch { /* no data yet */ }
    loading = false;
  });
</script>

<div class="space-y-4 max-w-2xl mx-auto p-6 pb-24">
  <h2 class="text-2xl font-bold">Personal Records</h2>

  {#if loading}
    <div class="flex justify-center py-12">
      <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-500"></div>
    </div>
  {:else if records.length === 0}
    <div class="card text-center py-12">
      <p class="text-zinc-400">No records yet. Complete some workouts to see your PRs!</p>
    </div>
  {:else}
    <input type="text" bind:value={filter} placeholder="Search exercises..."
           class="input w-full" style="font-size: 16px;" />

    <div class="space-y-2">
      {#each filtered as pr (pr.exercise_id)}
        <div class="card !py-3">
          <div class="flex items-start justify-between">
            <div>
              <p class="font-semibold text-sm">{pr.display_name}</p>
              <div class="flex gap-4 mt-1">
                <div>
                  <p class="text-xs text-zinc-500">Best Weight</p>
                  <p class="text-sm font-mono text-primary-400">{w(pr.max_weight_kg)} {unit}</p>
                </div>
                <div>
                  <p class="text-xs text-zinc-500">Most Reps</p>
                  <p class="text-sm font-mono text-green-400">{pr.max_reps}</p>
                </div>
                <div>
                  <p class="text-xs text-zinc-500">Est. 1RM</p>
                  <p class="text-sm font-mono text-amber-400">{w(pr.best_1rm_kg)} {unit}</p>
                </div>
              </div>
              <p class="text-[10px] text-zinc-600 mt-1">Best set: {w(pr.best_set_weight_kg)} × {pr.best_set_reps}</p>
            </div>
          </div>
        </div>
      {/each}
    </div>
  {/if}
</div>
