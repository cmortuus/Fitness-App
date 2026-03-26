<script lang="ts">
  import { onMount } from 'svelte';
  import { Line, Bar } from 'svelte-chartjs';
  import {
    Chart,
    CategoryScale,
    LinearScale,
    PointElement,
    LineElement,
    BarElement,
    Title,
    Tooltip,
    Legend,
    Filler,
  } from 'chart.js';
  import { getProgress, getRecommendations } from '$lib/api';
  import type { ProgressMetric, ProgressionRecommendation } from '$lib/api';
  import { settings } from '$lib/stores';

  // Register Chart.js components (required by svelte-chartjs)
  Chart.register(CategoryScale, LinearScale, PointElement, LineElement, BarElement, Title, Tooltip, Legend, Filler);

  // Weight conversion
  const KG_TO_LBS = 2.20462;

  function displayWeight(kg: number): number {
    return $settings.weightUnit === 'lbs'
      ? Math.round(kg * KG_TO_LBS * 10) / 10
      : Math.round(kg * 10) / 10;
  }

  let unit = $derived($settings.weightUnit);

  let progressData = $state<ProgressMetric[]>([]);
  let recommendations = $state<ProgressionRecommendation[]>([]);
  let selectedExercise = $state<string>('all');
  let timeRange = $state<string>('30d');
  let chartMode = $state<'1rm' | 'volume' | 'weight'>('1rm');
  let loading = $state(true);
  let error = $state<string | null>(null);

  onMount(async () => {
    await loadData();
  });

  async function loadData() {
    loading = true;
    error = null;
    try {
      const endDate = new Date().toISOString().split('T')[0];
      let startDate: string;

      switch (timeRange) {
        case '7d':
          startDate = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString().split('T')[0];
          break;
        case '90d':
          startDate = new Date(Date.now() - 90 * 24 * 60 * 60 * 1000).toISOString().split('T')[0];
          break;
        default:
          startDate = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0];
      }

      const daysBack = parseInt(timeRange.replace('d', ''));
      const [progress, recs] = await Promise.all([
        getProgress({ start_date: startDate, end_date: endDate }),
        getRecommendations(daysBack),
      ]);
      progressData = progress;
      recommendations = recs;
    } catch (e) {
      error = 'Failed to load progress data. Please try again.';
      console.error('Failed to load progress:', e);
    } finally {
      loading = false;
    }
  }

  // Filter data by exercise
  let filteredData = $derived(selectedExercise === 'all'
    ? progressData
    : progressData.filter(p => p.exercise_name === selectedExercise));

  // Get unique exercise names across all data (not just filtered)
  let exercises = $derived([...new Set(progressData.map(p => p.exercise_name))].sort());

  // Colour palette for chart lines
  const COLORS = ['#0ea5e9', '#22c55e', '#f59e0b', '#ef4444', '#8b5cf6', '#ec4899', '#14b8a6'];

  // Chart data
  let chartData = $derived(() => {
    const dates = [...new Set(filteredData.map(p => p.date))].sort();
    // Which exercises to plot depends on filter
    const exNames = selectedExercise === 'all'
      ? [...new Set(filteredData.map(p => p.exercise_name))].sort()
      : [selectedExercise];

    return {
      labels: dates,
      datasets: exNames.map((exercise, idx) => {
        const exerciseData = filteredData.filter(p => p.exercise_name === exercise);
        return {
          label: exercise,
          data: dates.map(date => {
            const point = exerciseData.find(p => p.date === date);
            return point?.estimated_1rm != null ? displayWeight(point.estimated_1rm) : null;
          }) as (number | null)[],
          borderColor: COLORS[idx % COLORS.length],
          backgroundColor: COLORS[idx % COLORS.length] + '20',
          tension: 0.3,
          spanGaps: true,
        };
      }),
    };
  });

  // Volume chart data — total volume per date (aggregated across exercises if "all")
  let volumeChartData = $derived(() => {
    const dates = [...new Set(filteredData.map(p => p.date))].sort();
    const exNames = selectedExercise === 'all'
      ? [...new Set(filteredData.map(p => p.exercise_name))].sort()
      : [selectedExercise];

    return {
      labels: dates,
      datasets: exNames.map((exercise, idx) => {
        const exerciseData = filteredData.filter(p => p.exercise_name === exercise);
        return {
          label: exercise,
          data: dates.map(date => {
            const point = exerciseData.find(p => p.date === date);
            return point?.volume_load ? displayWeight(point.volume_load) : null;
          }) as (number | null)[],
          backgroundColor: COLORS[idx % COLORS.length] + '80',
          borderColor: COLORS[idx % COLORS.length],
          borderWidth: 1,
        };
      }),
    };
  });

  // Best working weight per session (max actual_weight across sets)
  let weightChartData = $derived(() => {
    const dates = [...new Set(filteredData.map(p => p.date))].sort();
    const exNames = selectedExercise === 'all'
      ? [...new Set(filteredData.map(p => p.exercise_name))].sort()
      : [selectedExercise];

    return {
      labels: dates,
      datasets: exNames.map((exercise, idx) => {
        const exerciseData = filteredData.filter(p => p.exercise_name === exercise);
        return {
          label: exercise,
          data: dates.map(date => {
            const point = exerciseData.find(p => p.date === date);
            // Use the recommended_weight field as a proxy for top set weight, or 1RM
            return point?.estimated_1rm != null ? displayWeight(point.estimated_1rm) : null;
          }) as (number | null)[],
          borderColor: COLORS[idx % COLORS.length],
          backgroundColor: COLORS[idx % COLORS.length] + '20',
          tension: 0.3,
          spanGaps: true,
          fill: true,
        };
      }),
    };
  });

  let activeChartData = $derived(() => {
    switch (chartMode) {
      case 'volume': return volumeChartData();
      case 'weight': return weightChartData();
      default: return chartData();
    }
  });

  let chartTitle = $derived(
    chartMode === '1rm' ? `Estimated 1RM Progress (${unit})`
    : chartMode === 'volume' ? `Volume Load (${unit})`
    : `Weight Trend (${unit})`
  );

  let chartOptions = $derived({
    responsive: true,
    plugins: {
      legend: { position: 'top' as const },
      title: {
        display: true,
        text: chartTitle,
        color: '#d1d5db',
      },
      tooltip: {
        callbacks: {
          label: (ctx: any) => `${ctx.dataset.label}: ${ctx.parsed.y?.toFixed(1) ?? '–'} ${unit}`,
        },
      },
    },
    scales: {
      y: {
        beginAtZero: chartMode === 'volume',
        title: { display: true, text: `Weight (${unit})`, color: '#9ca3af' },
        ticks: { color: '#9ca3af' },
        grid: { color: '#374151' },
      },
      x: {
        title: { display: true, text: 'Date', color: '#9ca3af' },
        ticks: { color: '#9ca3af' },
        grid: { color: '#374151' },
      },
    },
  });
</script>

<div class="space-y-6 max-w-4xl mx-auto">
  <h2 class="text-2xl font-bold">Progress</h2>

  <!-- Filters -->
  <div class="card">
    <div class="flex flex-wrap gap-4">
      <div>
        <label class="label">Time Range</label>
        <select bind:value={timeRange} onchange={loadData} class="input">
          <option value="7d">Last 7 days</option>
          <option value="30d">Last 30 days</option>
          <option value="90d">Last 90 days</option>
        </select>
      </div>

      <div>
        <label class="label">Exercise</label>
        <select bind:value={selectedExercise} class="input">
          <option value="all">All Exercises</option>
          {#each exercises as exercise}
            <option value={exercise}>{exercise}</option>
          {/each}
        </select>
      </div>

      <div>
        <label class="label">Chart</label>
        <div class="flex rounded-lg overflow-hidden border border-zinc-700">
          <button
            class="px-3 py-1.5 text-sm {chartMode === '1rm' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}"
            onclick={() => chartMode = '1rm'}>1RM</button>
          <button
            class="px-3 py-1.5 text-sm {chartMode === 'volume' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}"
            onclick={() => chartMode = 'volume'}>Volume</button>
          <button
            class="px-3 py-1.5 text-sm {chartMode === 'weight' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}"
            onclick={() => chartMode = 'weight'}>Weight</button>
        </div>
      </div>
    </div>
  </div>

  <!-- Progress Chart -->
  <div class="card">
    <h3 class="text-lg font-semibold mb-4">{chartTitle}</h3>
    {#if loading}
      <div class="animate-pulse bg-zinc-800 rounded h-48"></div>
    {:else if error}
      <p class="text-red-400 text-center py-8">{error}</p>
    {:else if filteredData.length > 0}
      {#if chartMode === 'volume'}
        <Bar data={activeChartData()} options={chartOptions} />
      {:else}
        <Line data={activeChartData()} options={chartOptions} />
      {/if}
    {:else}
      <p class="text-zinc-400 text-center py-8">
        No data for the selected range. Complete a workout with logged sets to see your progress here.
      </p>
    {/if}
  </div>

  <!-- Recommendations -->
  <div class="card">
    <h3 class="text-lg font-semibold mb-4">Progression Recommendations</h3>
    {#if loading}
      <div class="space-y-2">
        {#each { length: 3 } as _}
          <div class="animate-pulse bg-zinc-800 rounded h-10"></div>
        {/each}
      </div>
    {:else if recommendations.length > 0}
      <div class="overflow-x-auto">
        <table class="w-full text-left text-sm">
          <thead>
            <tr class="border-b border-zinc-800 text-zinc-400">
              <th class="py-2 px-3">Exercise</th>
              <th class="py-2 px-3">Current best</th>
              <th class="py-2 px-3">Recommended</th>
              <th class="py-2 px-3">Reason</th>
            </tr>
          </thead>
          <tbody>
            {#each recommendations as rec}
              {@const delta = rec.recommended_weight - rec.current_weight}
              <tr class="border-b border-zinc-800/50 hover:bg-zinc-900">
                <td class="py-2 px-3 font-medium">{rec.exercise_name}</td>
                <td class="py-2 px-3 font-mono">{displayWeight(rec.current_weight).toFixed(1)} {unit}</td>
                <td class="py-2 px-3 font-mono {delta > 0 ? 'text-green-400' : delta < 0 ? 'text-red-400' : 'text-yellow-400'}">
                  {displayWeight(rec.recommended_weight).toFixed(1)} {unit}
                  {#if delta > 0}<span class="text-xs ml-1">↑</span>
                  {:else if delta < 0}<span class="text-xs ml-1">↓</span>
                  {:else}<span class="text-xs ml-1">→</span>{/if}
                </td>
                <td class="py-2 px-3 text-zinc-400">{rec.reason}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else}
      <p class="text-zinc-400 text-center py-6">
        No recommendations yet — complete at least one workout in the selected time range.
      </p>
    {/if}
  </div>

  <!-- Detailed Stats -->
  <div class="card">
    <h3 class="text-lg font-semibold mb-4">Session Log</h3>
    {#if loading}
      <div class="animate-pulse bg-zinc-800 rounded h-24"></div>
    {:else if filteredData.length > 0}
      <div class="overflow-x-auto">
        <table class="w-full text-left text-sm">
          <thead>
            <tr class="border-b border-zinc-800 text-zinc-400">
              <th class="py-2 px-3">Date</th>
              <th class="py-2 px-3">Exercise</th>
              <th class="py-2 px-3">Volume</th>
              <th class="py-2 px-3">Est. 1RM</th>
            </tr>
          </thead>
          <tbody>
            {#each [...filteredData].reverse() as row}
              <tr class="border-b border-zinc-800/50 hover:bg-zinc-900">
                <td class="py-2 px-3 text-zinc-400">{row.date}</td>
                <td class="py-2 px-3">{row.exercise_name}</td>
                <td class="py-2 px-3 font-mono">{displayWeight(row.volume_load).toFixed(0)} {unit}</td>
                <td class="py-2 px-3 font-mono">
                  {row.estimated_1rm != null ? displayWeight(row.estimated_1rm).toFixed(1) : '—'} {unit}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else}
      <p class="text-zinc-400 text-center py-4">No data for selected filters.</p>
    {/if}
  </div>
</div>
