<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { exercises } from '$lib/stores';
  import { getTemplates, cloneTemplate, getExercises } from '$lib/api';
  import type { WorkoutTemplate, Exercise } from '$lib/api';

  let templates = $state<WorkoutTemplate[]>([]);
  let loading = $state(true);
  let cloning = $state<number | null>(null);

  // Filters
  let splitFilter = $state<string | null>(null);
  let equipmentFilter = $state<string | null>(null);
  let daysFilter = $state<number | null>(null);

  // Preview
  let previewTemplate = $state<WorkoutTemplate | null>(null);

  const SPLITS = [
    { key: 'full_body', label: 'Full Body' },
    { key: 'upper_lower', label: 'Upper/Lower' },
    { key: 'ppl', label: 'PPL' },
    { key: 'bro_split', label: 'Bro Split' },
  ];

  const EQUIPMENT = [
    { key: 'minimal', label: 'Minimal', desc: 'BW + Dumbbells' },
    { key: 'home', label: 'Home Gym', desc: '+ Barbell & Rack' },
    { key: 'standard', label: 'Standard', desc: '+ Cables & Machines' },
    { key: 'well_equipped', label: 'Well-Equipped', desc: '+ Hammer Strength' },
    { key: 'elite', label: 'Elite', desc: 'Full Commercial' },
  ];

  let allExercises = $state<Exercise[]>([]);

  onMount(async () => {
    try {
      const [tmpl, exs] = await Promise.all([getTemplates(), getExercises()]);
      templates = tmpl;
      allExercises = exs;
      exercises.set(exs);
    } catch (e) {
      console.error('Failed to load templates:', e);
    }
    loading = false;
  });

  let filtered = $derived(
    templates.filter(t => {
      if (splitFilter && t.split_type !== splitFilter) return false;
      if (equipmentFilter && t.equipment_tier !== equipmentFilter) return false;
      if (daysFilter && t.days_per_week !== daysFilter) return false;
      return true;
    })
  );

  // Group filtered templates by split type for display
  let grouped = $derived(
    SPLITS.map(s => ({
      ...s,
      templates: filtered.filter(t => t.split_type === s.key),
    })).filter(g => g.templates.length > 0)
  );

  function getExName(exId: number): string {
    const ex = allExercises.find(e => e.id === exId);
    return ex?.display_name || `Exercise #${exId}`;
  }

  function tierLabel(tier: string): string {
    return EQUIPMENT.find(e => e.key === tier)?.label || tier;
  }

  async function handleClone(id: number) {
    cloning = id;
    try {
      const result = await cloneTemplate(id);
      await goto(`/plans`);
    } catch (e) {
      alert('Failed to clone template');
    }
    cloning = null;
  }
</script>

<div class="space-y-4 max-w-2xl mx-auto p-4 pb-24">
  <div class="flex items-center justify-between">
    <h2 class="text-xl font-bold">Workout Templates</h2>
    <a href="/plans/create" class="text-sm text-primary-400 hover:text-primary-300">Build Custom</a>
  </div>

  <!-- Filters -->
  <div class="space-y-3">
    <!-- Split type pills -->
    <div class="flex gap-2 overflow-x-auto pb-1">
      <button onclick={() => splitFilter = null}
              class="shrink-0 px-3 py-1.5 rounded-full text-sm font-medium transition-colors
                     {!splitFilter ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
        All Splits
      </button>
      {#each SPLITS as s}
        <button onclick={() => splitFilter = splitFilter === s.key ? null : s.key}
                class="shrink-0 px-3 py-1.5 rounded-full text-sm font-medium transition-colors
                       {splitFilter === s.key ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
          {s.label}
        </button>
      {/each}
    </div>

    <!-- Equipment + Days -->
    <div class="flex gap-2">
      <select bind:value={equipmentFilter}
              class="flex-1 bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white">
        <option value={null}>All Equipment</option>
        {#each EQUIPMENT as e}
          <option value={e.key}>{e.label} — {e.desc}</option>
        {/each}
      </select>

      <select bind:value={daysFilter}
              class="w-24 bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white">
        <option value={null}>Days</option>
        {#each [1,2,3,4,5,6] as d}
          <option value={d}>{d}/wk</option>
        {/each}
      </select>
    </div>
  </div>

  {#if loading}
    <div class="flex items-center justify-center py-20">
      <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-500"></div>
    </div>
  {:else if filtered.length === 0}
    <div class="text-center py-12 text-zinc-500">
      <p>No templates match your filters.</p>
      <button onclick={() => { splitFilter = null; equipmentFilter = null; daysFilter = null; }}
              class="text-primary-400 mt-2 text-sm">Clear filters</button>
    </div>
  {:else}
    {#each grouped as group}
      <div class="space-y-2">
        <h3 class="text-sm font-semibold text-zinc-400 uppercase tracking-wider">{group.label}</h3>
        {#each group.templates as tmpl}
          <button onclick={() => previewTemplate = tmpl}
                  class="card !p-3 w-full text-left hover:bg-zinc-800/60 transition-colors">
            <div class="flex items-center justify-between">
              <div>
                <p class="font-medium text-white text-sm">{tmpl.name}</p>
                <p class="text-xs text-zinc-500 mt-0.5">
                  {tmpl.days_per_week} days/wk · {tmpl.exercise_count} exercises · {tierLabel(tmpl.equipment_tier)}
                </p>
              </div>
              <span class="text-zinc-600 text-lg">›</span>
            </div>
          </button>
        {/each}
      </div>
    {/each}
    <p class="text-center text-xs text-zinc-600">{filtered.length} templates</p>
  {/if}
</div>

<!-- ─── Template Preview Modal ─────────────────────────────────────────────── -->
{#if previewTemplate}
  <div class="fixed inset-0 bg-black/80 flex items-end sm:items-center justify-center z-50">
    <div class="bg-zinc-900 w-full sm:max-w-lg sm:rounded-2xl rounded-t-2xl max-h-[90vh] flex flex-col border border-zinc-800 shadow-2xl">

      <div class="flex items-center justify-between px-4 py-3 border-b border-zinc-800 shrink-0">
        <div>
          <h3 class="font-semibold text-white">{previewTemplate.name}</h3>
          <p class="text-xs text-zinc-500">{previewTemplate.days_per_week} days/wk · {tierLabel(previewTemplate.equipment_tier)}</p>
        </div>
        <button onclick={() => previewTemplate = null} class="text-zinc-400 hover:text-white text-xl">✕</button>
      </div>

      <div class="p-4 overflow-y-auto space-y-4 flex-1">
        {#if previewTemplate.description}
          <p class="text-sm text-zinc-400">{previewTemplate.description}</p>
        {/if}

        {#each previewTemplate.days as day}
          <div class="space-y-1">
            <h4 class="text-sm font-semibold text-primary-400">{day.day_name}</h4>
            {#each day.exercises as ex}
              <div class="flex items-center justify-between text-sm px-2 py-1 rounded bg-zinc-800/50">
                <span class="text-zinc-300">{getExName(ex.exercise_id)}</span>
                <span class="text-xs text-zinc-500">{ex.sets}×{ex.reps}</span>
              </div>
            {/each}
          </div>
        {/each}
      </div>

      <div class="p-4 border-t border-zinc-800 shrink-0">
        <button onclick={() => handleClone(previewTemplate!.id)}
                disabled={cloning === previewTemplate.id}
                class="btn-primary w-full !py-3 disabled:opacity-50">
          {cloning === previewTemplate.id ? 'Cloning...' : 'Use This Template'}
        </button>
      </div>
    </div>
  </div>
{/if}
