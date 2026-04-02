<script lang="ts">
  import { onMount } from 'svelte';
  import { daysAgoLocalDateString, localDateString } from '$lib/date';
  import { Line } from 'svelte-chartjs';
  import {
    Chart,
    CategoryScale,
    LinearScale,
    PointElement,
    LineElement,
    Title,
    Tooltip,
    Legend,
    Filler,
  } from 'chart.js';
  import { getProgress, getRecommendations, getExercises } from '$lib/api';
  import type { ProgressMetric, ProgressionRecommendation, Exercise } from '$lib/api';
  import { settings } from '$lib/stores';

  Chart.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Legend, Filler);

  const KG_TO_LBS = 2.20462;

  function displayWeight(kg: number): number {
    return $settings.weightUnit === 'lbs'
      ? Math.round(kg * KG_TO_LBS * 10) / 10
      : Math.round(kg * 10) / 10;
  }

  let unit = $derived($settings.weightUnit);

  let progressData = $state<ProgressMetric[]>([]);
  let recommendations = $state<ProgressionRecommendation[]>([]);
  let allExercises = $state<Exercise[]>([]);
  let timeRange = $state<string>('30d');
  let loading = $state(true);
  let error = $state<string | null>(null);
  let selectedGroup = $state<string | null>(null);

  // Muscle group definitions — order determines display order
  const MUSCLE_GROUPS: Record<string, string[]> = {
    Back:       ['lats', 'mid_back', 'traps'],
    Chest:      ['chest'],
    Shoulders:  ['shoulders'],
    Quads:      ['quadriceps'],
    Hamstrings: ['hamstrings'],
    Glutes:     ['glutes'],
    Calves:     ['calves'],
    Biceps:     ['biceps'],
    Triceps:    ['triceps'],
    Core:       ['abs', 'core', 'obliques'],
    Forearms:   ['forearms'],
    Neck:       ['neck'],
  };

  const COLORS = [
    '#0ea5e9', '#22c55e', '#f59e0b', '#ef4444', '#8b5cf6',
    '#ec4899', '#14b8a6', '#f97316', '#06b6d4', '#84cc16',
    '#a78bfa', '#fb7185',
  ];

  onMount(async () => {
    await loadData();
  });

  async function loadData() {
    loading = true;
    error = null;
    try {
      const endDate = localDateString();
      const daysBack = timeRange === 'all' ? 3650 : parseInt(timeRange.replace('d', ''));
      const startDate = timeRange === 'all' ? '2000-01-01' : daysAgoLocalDateString(daysBack);

      const [progress, recs, exList] = await Promise.all([
        getProgress({ start_date: startDate, end_date: endDate }),
        getRecommendations(daysBack),
        allExercises.length === 0 ? getExercises() : Promise.resolve(allExercises),
      ]);
      progressData = progress;
      recommendations = recs;
      allExercises = exList;
    } catch (e) {
      error = 'Failed to load progress data. Please try again.';
      console.error('Failed to load progress:', e);
    } finally {
      loading = false;
    }
  }

  // exercise_id → muscle group name (first match wins)
  let exerciseIdToGroup = $derived.by(() => {
    const map = new Map<number, string>();
    for (const ex of allExercises) {
      const muscles = ex.primary_muscles ?? [];
      for (const [group, groupMuscles] of Object.entries(MUSCLE_GROUPS)) {
        if (muscles.some(m => groupMuscles.includes(m))) {
          map.set(ex.id, group);
          break;
        }
      }
    }
    return map;
  });

  // exercise display name → group name (derived from exercise_id lookup)
  let exerciseNameToGroup = $derived.by(() => {
    const map = new Map<string, string>();
    for (const p of progressData) {
      if (p.exercise_id != null) {
        const group = exerciseIdToGroup.get(p.exercise_id);
        if (group) map.set(p.exercise_name, group);
      }
    }
    return map;
  });

  // Per-exercise % change time series: Map<exerciseName, Map<date, pctChange>>
  // All series start at 0% on the first data point.
  let exercisePctSeries = $derived.by(() => {
    const result = new Map<string, Map<string, number>>();
    const names = [...new Set(progressData.map(p => p.exercise_name))];
    for (const name of names) {
      const points = progressData
        .filter(p => p.exercise_name === name && p.estimated_1rm != null && p.estimated_1rm > 0)
        .sort((a, b) => a.date.localeCompare(b.date));
      if (points.length < 1) continue;
      const baseline = points[0].estimated_1rm!;
      const series = new Map<string, number>();
      for (const p of points) {
        series.set(p.date, ((p.estimated_1rm! - baseline) / baseline) * 100);
      }
      result.set(name, series);
    }
    return result;
  });

  // Trained muscle groups with data in the current time range (in MUSCLE_GROUPS order)
  let trainedGroups = $derived.by(() => {
    const present = new Set<string>();
    for (const [exName] of exercisePctSeries) {
      const g = exerciseNameToGroup.get(exName);
      if (g) present.add(g);
    }
    return Object.keys(MUSCLE_GROUPS).filter(g => present.has(g));
  });

  // Per-group aggregate % change series: for each date, average % change of exercises in group
  let groupPctSeries = $derived.by(() => {
    const result = new Map<string, Map<string, number>>();
    for (const group of trainedGroups) {
      const exNames = [...exercisePctSeries.keys()].filter(n => exerciseNameToGroup.get(n) === group);
      if (exNames.length === 0) continue;
      const allDates = new Set<string>();
      for (const n of exNames) for (const d of exercisePctSeries.get(n)!.keys()) allDates.add(d);
      const groupSeries = new Map<string, number>();
      for (const date of [...allDates].sort()) {
        const vals: number[] = [];
        for (const n of exNames) {
          const v = exercisePctSeries.get(n)?.get(date);
          if (v != null) vals.push(v);
        }
        if (vals.length > 0) groupSeries.set(date, vals.reduce((s, v) => s + v, 0) / vals.length);
      }
      result.set(group, groupSeries);
    }
    return result;
  });

  // Latest % change per group (for summary cards)
  let groupSummary = $derived.by(() => {
    const result = new Map<string, number>();
    for (const [group, series] of groupPctSeries) {
      const vals = [...series.values()];
      if (vals.length > 0) result.set(group, Math.round(vals[vals.length - 1] * 10) / 10);
    }
    return result;
  });

  // Overview chart: one line per trained group
  let overviewChartData = $derived.by(() => {
    if (trainedGroups.length === 0) return { labels: [], datasets: [] };
    const allDates = new Set<string>();
    for (const [, s] of groupPctSeries) for (const d of s.keys()) allDates.add(d);
    const dates = [...allDates].sort();
    return {
      labels: dates,
      datasets: trainedGroups.map((group, idx) => {
        const series = groupPctSeries.get(group)!;
        return {
          label: group,
          data: dates.map(d => series.has(d) ? Math.round(series.get(d)! * 10) / 10 : null) as (number | null)[],
          borderColor: COLORS[idx % COLORS.length],
          backgroundColor: COLORS[idx % COLORS.length] + '20',
          tension: 0.3,
          spanGaps: true,
          pointRadius: 3,
        };
      }),
    };
  });

  // Drill-down chart: one line per exercise within selected group
  let drilldownChartData = $derived.by(() => {
    if (!selectedGroup) return { labels: [], datasets: [] };
    const exNames = [...exercisePctSeries.keys()].filter(n => exerciseNameToGroup.get(n) === selectedGroup);
    if (exNames.length === 0) return { labels: [], datasets: [] };
    const allDates = new Set<string>();
    for (const n of exNames) for (const d of exercisePctSeries.get(n)!.keys()) allDates.add(d);
    const dates = [...allDates].sort();
    return {
      labels: dates,
      datasets: exNames.map((name, idx) => {
        const series = exercisePctSeries.get(name)!;
        return {
          label: name,
          data: dates.map(d => series.has(d) ? Math.round(series.get(d)! * 10) / 10 : null) as (number | null)[],
          borderColor: COLORS[idx % COLORS.length],
          backgroundColor: COLORS[idx % COLORS.length] + '20',
          tension: 0.3,
          spanGaps: true,
          pointRadius: 3,
        };
      }),
    };
  });

  let activeChartData = $derived(selectedGroup ? drilldownChartData : overviewChartData);

  let chartTitle = $derived(
    selectedGroup
      ? `${selectedGroup} — Est. 1RM % Change`
      : 'Muscle Group Strength Trends (Est. 1RM % Change)'
  );

  let chartOptions = $derived({
    responsive: true,
    plugins: {
      legend: {
        position: 'bottom' as const,
        labels: { color: '#d1d5db', boxWidth: 10, padding: 6, font: { size: 10 }, usePointStyle: true },
      },
      title: {
        display: true,
        text: chartTitle,
        color: '#d1d5db',
      },
      tooltip: {
        callbacks: {
          label: (ctx: any) => {
            const v = ctx.parsed.y;
            return `${ctx.dataset.label}: ${v != null ? (v > 0 ? '+' : '') + v.toFixed(1) + '%' : '–'}`;
          },
        },
      },
    },
    scales: {
      y: {
        title: { display: true, text: '% Change from Baseline', color: '#9ca3af' },
        ticks: {
          color: '#9ca3af',
          callback: (v: any) => (v > 0 ? '+' : '') + v + '%',
        },
        grid: { color: '#374151' },
      },
      x: {
        title: { display: true, text: 'Date', color: '#9ca3af' },
        ticks: { color: '#9ca3af' },
        grid: { color: '#374151' },
      },
    },
  });

  // Recommendations filtered to selected group in drill-down mode
  let filteredRecs = $derived.by(() => {
    if (!selectedGroup) return recommendations;
    const exNamesInGroup = new Set(
      [...exercisePctSeries.keys()].filter(n => exerciseNameToGroup.get(n) === selectedGroup)
    );
    return recommendations.filter(r => exNamesInGroup.has(r.exercise_name));
  });

  // Exercises in selected group (for drill-down cards)
  let drilldownExercises = $derived.by(() => {
    if (!selectedGroup) return [];
    return [...exercisePctSeries.keys()].filter(n => exerciseNameToGroup.get(n) === selectedGroup);
  });
</script>

<div class="space-y-6 max-w-4xl mx-auto">
  <!-- Header row with back button + time range -->
  <div class="flex items-center justify-between gap-3">
    <div class="flex items-center gap-3">
      {#if selectedGroup}
        <button
          onclick={() => selectedGroup = null}
          class="text-zinc-400 hover:text-white transition-colors text-sm flex items-center gap-1"
        >
          ← All Muscles
        </button>
        <h2 class="text-2xl font-bold">{selectedGroup}</h2>
      {:else}
        <h2 class="text-2xl font-bold">Progress</h2>
      {/if}
    </div>
    <div>
      <select bind:value={timeRange} onchange={loadData} class="input">
        <option value="7d">Last 7 days</option>
        <option value="30d">Last 30 days</option>
        <option value="90d">Last 3 months</option>
        <option value="180d">Last 6 months</option>
        <option value="365d">Last year</option>
        <option value="all">All time</option>
      </select>
    </div>
  </div>

  <!-- Chart -->
  <div class="card">
    {#if loading}
      <div class="animate-pulse bg-zinc-800 rounded h-64"></div>
    {:else if error}
      <p class="text-red-400 text-center py-8">{error}</p>
    {:else if activeChartData.datasets.length > 0}
      <Line data={activeChartData} options={chartOptions} />
    {:else}
      <p class="text-zinc-400 text-center py-8">
        No data for the selected range. Complete a workout with logged sets to see your progress here.
      </p>
    {/if}
  </div>

  <!-- Overview: muscle group cards -->
  {#if !selectedGroup && trainedGroups.length > 0 && !loading}
    <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3">
      {#each trainedGroups as group, idx}
        {@const pct = groupSummary.get(group) ?? 0}
        <button
          class="card text-left hover:bg-zinc-700/60 transition-colors"
          onclick={() => selectedGroup = group}
        >
          <div class="flex items-center gap-2 mb-1">
            <div class="w-2.5 h-2.5 rounded-full flex-shrink-0" style="background:{COLORS[idx % COLORS.length]}"></div>
            <p class="text-sm font-medium truncate">{group}</p>
          </div>
          <p class="text-2xl font-bold {pct > 0 ? 'text-green-400' : pct < 0 ? 'text-red-400' : 'text-zinc-400'}">
            {pct > 0 ? '+' : ''}{pct}%
          </p>
          <p class="text-xs text-zinc-500 mt-1">Tap to explore →</p>
        </button>
      {/each}
    </div>
  {/if}

  <!-- Drill-down: individual exercise cards -->
  {#if selectedGroup && drilldownExercises.length > 0 && !loading}
    <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
      {#each drilldownExercises as name, idx}
        {@const vals = [...exercisePctSeries.get(name)!.values()]}
        {@const pct = vals.length > 0 ? Math.round(vals[vals.length - 1] * 10) / 10 : 0}
        <div class="card">
          <div class="flex items-center gap-2 mb-1">
            <div class="w-2.5 h-2.5 rounded-full flex-shrink-0" style="background:{COLORS[idx % COLORS.length]}"></div>
            <p class="text-xs text-zinc-400 truncate" title={name}>{name}</p>
          </div>
          <p class="text-xl font-bold {pct > 0 ? 'text-green-400' : pct < 0 ? 'text-red-400' : 'text-zinc-400'}">
            {pct > 0 ? '+' : ''}{pct}%
          </p>
        </div>
      {/each}
    </div>
  {/if}

  <!-- Recommendations -->
  <div class="card">
    <h3 class="text-lg font-semibold mb-4">
      Progression Recommendations{selectedGroup ? ` — ${selectedGroup}` : ''}
    </h3>
    {#if loading}
      <div class="space-y-2">
        {#each { length: 3 } as _}
          <div class="animate-pulse bg-zinc-800 rounded h-10"></div>
        {/each}
      </div>
    {:else if filteredRecs.length > 0}
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
            {#each filteredRecs as rec}
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
        {selectedGroup
          ? `No recommendations for ${selectedGroup} in this period.`
          : 'No recommendations yet — complete at least one workout in the selected time range.'}
      </p>
    {/if}
  </div>
</div>
