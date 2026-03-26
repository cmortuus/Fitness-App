<script lang="ts">
  import { onMount } from 'svelte';
  import { Line } from 'svelte-chartjs';
  import {
    Chart, CategoryScale, LinearScale, PointElement, LineElement,
    Title, Tooltip, Legend, Filler,
  } from 'chart.js';
  import { getBodyWeights, addBodyWeight } from '$lib/api';
  import { settings } from '$lib/stores';

  Chart.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Legend, Filler);

  const KG_TO_LBS = 2.20462;
  function displayWeight(kg: number): number {
    return $settings.weightUnit === 'lbs'
      ? Math.round(kg * KG_TO_LBS * 10) / 10
      : Math.round(kg * 10) / 10;
  }
  let unit = $derived($settings.weightUnit);

  interface BodyEntry {
    id: number;
    weight_kg: number;
    body_fat_pct: number | null;
    fat_mass_kg?: number;
    lean_mass_kg?: number;
    recorded_at: string;
    notes: string | null;
  }

  let entries = $state<BodyEntry[]>([]);
  let loading = $state(true);
  let timeRange = $state<string>('90d');
  let showForm = $state(false);

  // Form state
  let formWeight = $state('');
  let formBf = $state('');
  let formNotes = $state('');
  let saving = $state(false);

  onMount(async () => {
    await loadData();
  });

  async function loadData() {
    loading = true;
    try {
      entries = await getBodyWeights(200);
    } catch (e) {
      console.error('Failed to load body weight:', e);
    } finally {
      loading = false;
    }
  }

  let filteredEntries = $derived(() => {
    const days = parseInt(timeRange.replace('d', ''));
    const cutoff = new Date(Date.now() - days * 86400000);
    return entries
      .filter(e => new Date(e.recorded_at) >= cutoff)
      .sort((a, b) => new Date(a.recorded_at).getTime() - new Date(b.recorded_at).getTime());
  });

  // Weight chart
  let weightChartData = $derived(() => {
    const data = filteredEntries();
    const labels = data.map(e => new Date(e.recorded_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }));

    const datasets: any[] = [{
      label: `Body Weight (${unit})`,
      data: data.map(e => displayWeight(e.weight_kg)),
      borderColor: '#3b82f6',
      backgroundColor: '#3b82f620',
      tension: 0.3,
      fill: true,
    }];

    // Add lean mass if body fat data exists
    const hasBodyFat = data.some(e => e.lean_mass_kg != null);
    if (hasBodyFat) {
      datasets.push({
        label: `Lean Mass (${unit})`,
        data: data.map(e => e.lean_mass_kg != null ? displayWeight(e.lean_mass_kg) : null),
        borderColor: '#22c55e',
        backgroundColor: '#22c55e20',
        tension: 0.3,
        spanGaps: true,
      });
      datasets.push({
        label: `Fat Mass (${unit})`,
        data: data.map(e => e.fat_mass_kg != null ? displayWeight(e.fat_mass_kg) : null),
        borderColor: '#ef4444',
        backgroundColor: '#ef444420',
        tension: 0.3,
        spanGaps: true,
      });
    }

    return { labels, datasets };
  });

  // Body fat % chart
  let bfChartData = $derived(() => {
    const data = filteredEntries().filter(e => e.body_fat_pct != null);
    return {
      labels: data.map(e => new Date(e.recorded_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })),
      datasets: [{
        label: 'Body Fat %',
        data: data.map(e => e.body_fat_pct),
        borderColor: '#f59e0b',
        backgroundColor: '#f59e0b20',
        tension: 0.3,
        fill: true,
      }],
    };
  });

  let chartOptions = $derived({
    responsive: true,
    plugins: {
      legend: { position: 'top' as const, labels: { color: '#d1d5db' } },
      tooltip: {
        callbacks: {
          label: (ctx: any) => `${ctx.dataset.label}: ${ctx.parsed.y?.toFixed(1) ?? '–'}`,
        },
      },
    },
    scales: {
      y: { beginAtZero: false, ticks: { color: '#9ca3af' }, grid: { color: '#374151' } },
      x: { ticks: { color: '#9ca3af', maxRotation: 45 }, grid: { color: '#374151' } },
    },
  });

  // Stats
  let stats = $derived(() => {
    const data = filteredEntries();
    if (data.length === 0) return null;
    const latest = data[data.length - 1];
    const first = data[0];
    const change = latest.weight_kg - first.weight_kg;
    return {
      current: latest.weight_kg,
      change,
      bf: latest.body_fat_pct,
      lean: latest.lean_mass_kg,
      fat: latest.fat_mass_kg,
      count: data.length,
    };
  });

  async function handleSubmit() {
    if (!formWeight) return;
    saving = true;
    try {
      const weightKg = $settings.weightUnit === 'lbs'
        ? parseFloat(formWeight) / KG_TO_LBS
        : parseFloat(formWeight);

      await addBodyWeight({
        weight_kg: weightKg,
        body_fat_pct: formBf ? parseFloat(formBf) : undefined,
        notes: formNotes || undefined,
      });
      formWeight = '';
      formBf = '';
      formNotes = '';
      showForm = false;
      await loadData();
    } catch (e) {
      console.error('Failed to save:', e);
    } finally {
      saving = false;
    }
  }
</script>

<div class="space-y-5 max-w-lg mx-auto">
  <div class="flex items-center justify-between">
    <h2 class="text-2xl font-bold">Body Composition</h2>
    <button onclick={() => showForm = !showForm}
            class="btn-primary text-sm !py-1.5 !px-3">
      {showForm ? 'Cancel' : '+ Log'}
    </button>
  </div>

  <!-- Log form -->
  {#if showForm}
    <form onsubmit={(e) => { e.preventDefault(); handleSubmit(); }} class="card space-y-3">
      <div class="grid grid-cols-2 gap-3">
        <div>
          <label class="label">Weight ({unit})</label>
          <input type="number" step="0.1" bind:value={formWeight} class="input" placeholder="185.0" required />
        </div>
        <div>
          <label class="label">Body Fat % <span class="text-zinc-600">(optional)</span></label>
          <input type="number" step="0.1" bind:value={formBf} class="input" placeholder="15.0" />
        </div>
      </div>
      <div>
        <label class="label">Notes <span class="text-zinc-600">(optional)</span></label>
        <input type="text" bind:value={formNotes} class="input" placeholder="Morning, fasted" />
      </div>
      <button type="submit" disabled={saving} class="btn-primary w-full">
        {saving ? 'Saving...' : 'Log Weigh-In'}
      </button>
    </form>
  {/if}

  <!-- Time range -->
  <div class="flex gap-2">
    {#each [['30d', '30d'], ['90d', '90d'], ['180d', '6mo'], ['365d', '1yr']] as [val, label]}
      <button onclick={() => timeRange = val}
              class="px-3 py-1 text-sm rounded-lg {timeRange === val ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}">
        {label}
      </button>
    {/each}
  </div>

  <!-- Quick stats -->
  {#if stats()}
    {@const s = stats()!}
    <div class="grid grid-cols-3 gap-3">
      <div class="card text-center py-3">
        <p class="text-xl font-bold text-primary-400">{displayWeight(s.current)}</p>
        <p class="text-xs text-zinc-500">{unit}</p>
      </div>
      <div class="card text-center py-3">
        <p class="text-xl font-bold {s.change > 0 ? 'text-red-400' : s.change < 0 ? 'text-green-400' : 'text-zinc-400'}">
          {s.change > 0 ? '+' : ''}{displayWeight(s.change)}
        </p>
        <p class="text-xs text-zinc-500">change</p>
      </div>
      {#if s.bf != null}
        <div class="card text-center py-3">
          <p class="text-xl font-bold text-amber-400">{s.bf.toFixed(1)}%</p>
          <p class="text-xs text-zinc-500">body fat</p>
        </div>
      {:else}
        <div class="card text-center py-3">
          <p class="text-xl font-bold text-zinc-600">{s.count}</p>
          <p class="text-xs text-zinc-500">entries</p>
        </div>
      {/if}
    </div>
  {/if}

  <!-- Weight chart -->
  <div class="card">
    <h3 class="text-lg font-semibold mb-3">Weight Trend</h3>
    {#if loading}
      <div class="animate-pulse bg-zinc-800 rounded h-48"></div>
    {:else if filteredEntries().length > 1}
      <Line data={weightChartData()} options={chartOptions} />
    {:else}
      <p class="text-zinc-500 text-center py-8 text-sm">Log at least 2 weigh-ins to see your trend.</p>
    {/if}
  </div>

  <!-- Body fat chart (only if data exists) -->
  {#if filteredEntries().some(e => e.body_fat_pct != null)}
    <div class="card">
      <h3 class="text-lg font-semibold mb-3">Body Fat %</h3>
      <Line data={bfChartData()} options={chartOptions} />
    </div>
  {/if}

  <!-- Recent entries -->
  {#if entries.length > 0}
    <div class="card">
      <h3 class="text-lg font-semibold mb-3">Recent Entries</h3>
      <div class="space-y-1">
        {#each entries.slice(0, 10) as e}
          <div class="flex items-center justify-between py-2 border-b border-zinc-800/60 last:border-0 text-sm">
            <div>
              <span class="font-medium">{displayWeight(e.weight_kg)} {unit}</span>
              {#if e.body_fat_pct != null}
                <span class="text-amber-400 ml-2">{e.body_fat_pct}% BF</span>
              {/if}
            </div>
            <span class="text-xs text-zinc-500">
              {new Date(e.recorded_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
            </span>
          </div>
        {/each}
      </div>
    </div>
  {/if}
</div>
