<script lang="ts">
  import { onMount } from 'svelte';
  import { getVolumeLandmarks } from '$lib/api';
  import type { VolumeLandmark } from '$lib/api';

  let muscles = $state<VolumeLandmark[]>([]);
  let totalSets = $state(0);
  let loading = $state(true);
  let days = $state(7);

  onMount(() => loadData());

  async function loadData() {
    loading = true;
    try {
      const data = await getVolumeLandmarks(days);
      muscles = data.muscles;
      totalSets = data.total_sets;
    } catch (e) {
      console.error('Failed to load volume data:', e);
    } finally {
      loading = false;
    }
  }

  function statusColor(status: string): string {
    switch (status) {
      case 'none': return 'text-zinc-600';
      case 'below_mev': return 'text-red-400';
      case 'in_range': return 'text-green-400';
      case 'above_mav': return 'text-amber-400';
      case 'above_mrv': return 'text-red-400';
      default: return 'text-zinc-400';
    }
  }

  function statusLabel(status: string): string {
    switch (status) {
      case 'none': return 'No sets';
      case 'below_mev': return 'Below MEV';
      case 'in_range': return 'Optimal';
      case 'above_mav': return 'High volume';
      case 'above_mrv': return 'Over MRV';
      default: return '';
    }
  }

  function barWidth(sets: number, mrv: number): number {
    return Math.min(100, (sets / Math.max(mrv, 1)) * 100);
  }

  function barColor(status: string): string {
    switch (status) {
      case 'none': return 'bg-zinc-700';
      case 'below_mev': return 'bg-red-500/60';
      case 'in_range': return 'bg-green-500/60';
      case 'above_mav': return 'bg-amber-500/60';
      case 'above_mrv': return 'bg-red-500/80';
      default: return 'bg-zinc-600';
    }
  }
</script>

<div class="space-y-5 max-w-lg mx-auto">
  <div class="flex items-center justify-between">
    <h2 class="text-2xl font-bold">Volume Landmarks</h2>
    <span class="text-sm text-zinc-500">{totalSets} total sets</span>
  </div>

  <p class="text-xs text-zinc-500">
    Weekly sets per muscle group vs evidence-based volume targets.
    MEV = minimum effective volume. MRV = maximum recoverable volume.
  </p>

  <!-- Time range -->
  <div class="flex gap-2">
    {#each [[7, '7d'], [14, '14d'], [21, '3wk']] as [val, label] (val)}
      <button onclick={() => { days = val as number; loadData(); }}
              class="px-3 py-1 text-sm rounded-lg {days === val ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}">
        {label}
      </button>
    {/each}
  </div>

  {#if loading}
    <div class="space-y-3">
      {#each { length: 6 } as _}
        <div class="animate-pulse bg-zinc-800 rounded-xl h-16"></div>
      {/each}
    </div>
  {:else}
    <!-- Legend -->
    <div class="flex flex-wrap gap-3 text-[10px] text-zinc-500">
      <span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-red-500/60"></span> Below MEV</span>
      <span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-green-500/60"></span> MEV–MAV (Optimal)</span>
      <span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-amber-500/60"></span> MAV–MRV (High)</span>
      <span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-red-500/80"></span> Over MRV</span>
    </div>

    <div class="space-y-2">
      {#each muscles as m}
        <div class="card !py-3 !px-4">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-sm font-medium capitalize">{m.muscle}</span>
            <div class="flex items-center gap-2">
              <span class="text-sm font-mono font-bold {statusColor(m.status)}">{m.sets}</span>
              <span class="text-[10px] {statusColor(m.status)}">{statusLabel(m.status)}</span>
            </div>
          </div>

          <!-- Volume bar -->
          <div class="relative h-3 bg-zinc-800 rounded-full overflow-hidden">
            <!-- MEV marker -->
            <div class="absolute top-0 bottom-0 w-px bg-zinc-600" style="left: {(m.mev / m.mrv) * 100}%"></div>
            <!-- MAV marker -->
            <div class="absolute top-0 bottom-0 w-px bg-zinc-500" style="left: {(m.mav / m.mrv) * 100}%"></div>
            <!-- MRV marker (end) -->
            <div class="absolute top-0 bottom-0 w-px bg-red-500/40 right-0"></div>
            <!-- Actual bar -->
            <div class="h-full rounded-full transition-all duration-300 {barColor(m.status)}"
                 style="width: {barWidth(m.sets, m.mrv)}%"></div>
          </div>

          <!-- Labels -->
          <div class="flex justify-between text-[9px] text-zinc-600 mt-0.5">
            <span>0</span>
            <span style="position:relative; left: {(m.mev / m.mrv) * 50 - 5}%">MEV {m.mev}</span>
            <span>MAV {m.mav}</span>
            <span>MRV {m.mrv}</span>
          </div>
        </div>
      {/each}
    </div>

    {#if muscles.every(m => m.sets === 0)}
      <div class="card text-center py-8">
        <p class="text-zinc-500">No completed sets in the last {days} days.</p>
        <p class="text-zinc-600 text-sm mt-1">Complete a workout to see your volume breakdown.</p>
      </div>
    {/if}
  {/if}
</div>
