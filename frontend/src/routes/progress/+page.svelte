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
  let selectedSubGroup = $state<string | null>(null);

  // Muscle group definitions — order determines display order
  const MUSCLE_GROUPS: Record<string, string[]> = {
    Back:       ['lats', 'mid_back', 'upper_back', 'lower_back', 'traps'],
    Chest:      ['chest'],
    Shoulders:  ['front_delts', 'side_delts', 'rear_delts'],
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

  // Groups with sub-groups (2-level drill before exercises)
  const SUB_GROUPS: Record<string, Record<string, string[]>> = {
    Back: {
      Lats:          ['lats'],
      'Upper Back':  ['upper_back'],
      'Mid Back':    ['mid_back'],
      'Lower Back':  ['lower_back'],
      Traps:         ['traps'],
    },
    Shoulders: {
      'Front Delts': ['front_delts'],
      'Side Delts':  ['side_delts'],
      'Rear Delts':  ['rear_delts'],
    },
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

  // exercise display name → primary muscles (for sub-group filtering)
  let exerciseNameToMuscles = $derived.by(() => {
    const idToMuscles = new Map<number, string[]>();
    for (const ex of allExercises) idToMuscles.set(ex.id, ex.primary_muscles ?? []);
    const map = new Map<string, string[]>();
    for (const p of progressData) {
      if (p.exercise_id != null) {
        const muscles = idToMuscles.get(p.exercise_id);
        if (muscles) map.set(p.exercise_name, muscles);
      }
    }
    return map;
  });

  // Per-exercise % change time series: Map<exerciseName, Map<date, pctChange>>
  // All series start at 0% on the first date.
  // Uses the highest estimated 1RM per date (best set, not first set).
  // For assisted exercises the backend returns estimated_1rm computed from
  // (bodyweight - assistance), so a decreasing assistance weight correctly
  // produces an increasing 1RM — no direction inversion needed here.
  let exercisePctSeries = $derived.by(() => {
    const result = new Map<string, Map<string, number>>();
    const names = [...new Set(progressData.map(p => p.exercise_name))];
    for (const name of names) {
      const points = progressData.filter(
        p => p.exercise_name === name && p.estimated_1rm != null && p.estimated_1rm > 0
      );
      if (points.length === 0) continue;

      // Group by date — keep max estimated_1rm per date (best set wins)
      const bestByDate = new Map<string, number>();
      for (const p of points) {
        const prev = bestByDate.get(p.date);
        bestByDate.set(p.date, prev == null ? p.estimated_1rm! : Math.max(prev, p.estimated_1rm!));
      }

      const sortedDates = [...bestByDate.keys()].sort();
      const baseline = bestByDate.get(sortedDates[0])!;
      const series = new Map<string, number>();
      for (const date of sortedDates) {
        const current = bestByDate.get(date)!;
        const pct = ((current - baseline) / baseline) * 100;
        series.set(date, pct);
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

  // Helper: build Chart.js datasets from a list of labels and a series map
  function buildChartDatasets(
    labels: string[],
    seriesMap: Map<string, Map<string, number>>,
    dates: string[],
  ) {
    return labels.map((label, idx) => {
      const s = seriesMap.get(label)!;
      return {
        label,
        data: dates.map(d => s.has(d) ? Math.round(s.get(d)! * 10) / 10 : null) as (number | null)[],
        borderColor: COLORS[idx % COLORS.length],
        backgroundColor: COLORS[idx % COLORS.length] + '20',
        tension: 0.3,
        spanGaps: true,
        pointRadius: 3,
      };
    });
  }

  // Sub-group aggregate % change series (one per sub-group of the selected group)
  let subGroupPctSeries = $derived.by(() => {
    if (!selectedGroup || !SUB_GROUPS[selectedGroup]) return new Map<string, Map<string, number>>();
    const result = new Map<string, Map<string, number>>();
    for (const [sgName, sgMuscles] of Object.entries(SUB_GROUPS[selectedGroup])) {
      const exNames = [...exercisePctSeries.keys()].filter(n =>
        exerciseNameToMuscles.get(n)?.some(m => sgMuscles.includes(m))
      );
      if (exNames.length === 0) continue;
      const allDates = new Set<string>();
      for (const n of exNames) for (const d of exercisePctSeries.get(n)!.keys()) allDates.add(d);
      const sgSeries = new Map<string, number>();
      for (const date of [...allDates].sort()) {
        const vals: number[] = [];
        for (const n of exNames) {
          const v = exercisePctSeries.get(n)?.get(date);
          if (v != null) vals.push(v);
        }
        if (vals.length > 0) sgSeries.set(date, vals.reduce((s, v) => s + v, 0) / vals.length);
      }
      result.set(sgName, sgSeries);
    }
    return result;
  });

  // Trained sub-groups with data (in SUB_GROUPS order)
  let trainedSubGroups = $derived.by(() => {
    if (!selectedGroup || !SUB_GROUPS[selectedGroup]) return [] as string[];
    return Object.keys(SUB_GROUPS[selectedGroup]).filter(sg => subGroupPctSeries.has(sg));
  });

  // Drill-down chart: 3-level logic
  let drilldownChartData = $derived.by(() => {
    if (!selectedGroup) return { labels: [], datasets: [] };
    const hasSubGroups = !!SUB_GROUPS[selectedGroup];

    if (selectedSubGroup) {
      // Level 3: exercises in the selected sub-group
      const subMuscles = SUB_GROUPS[selectedGroup]?.[selectedSubGroup] ?? MUSCLE_GROUPS[selectedGroup];
      const exNames = [...exercisePctSeries.keys()].filter(n =>
        exerciseNameToMuscles.get(n)?.some(m => subMuscles.includes(m))
      );
      if (exNames.length === 0) return { labels: [], datasets: [] };
      const allDates = new Set<string>();
      for (const n of exNames) for (const d of exercisePctSeries.get(n)!.keys()) allDates.add(d);
      const dates = [...allDates].sort();
      const seriesMap = new Map(exNames.map(n => [n, exercisePctSeries.get(n)!]));
      return { labels: dates, datasets: buildChartDatasets(exNames, seriesMap, dates) };
    } else if (hasSubGroups) {
      // Level 2: one line per sub-group
      const active = trainedSubGroups;
      if (active.length === 0) return { labels: [], datasets: [] };
      const allDates = new Set<string>();
      for (const sg of active) for (const d of subGroupPctSeries.get(sg)!.keys()) allDates.add(d);
      const dates = [...allDates].sort();
      return { labels: dates, datasets: buildChartDatasets(active, subGroupPctSeries, dates) };
    } else {
      // Level 2 flat: exercises directly in group
      const exNames = [...exercisePctSeries.keys()].filter(n => exerciseNameToGroup.get(n) === selectedGroup);
      if (exNames.length === 0) return { labels: [], datasets: [] };
      const allDates = new Set<string>();
      for (const n of exNames) for (const d of exercisePctSeries.get(n)!.keys()) allDates.add(d);
      const dates = [...allDates].sort();
      const seriesMap = new Map(exNames.map(n => [n, exercisePctSeries.get(n)!]));
      return { labels: dates, datasets: buildChartDatasets(exNames, seriesMap, dates) };
    }
  });

  let activeChartData = $derived(selectedGroup ? drilldownChartData : overviewChartData);

  let chartTitle = $derived(
    selectedSubGroup
      ? `${selectedGroup} › ${selectedSubGroup} — Est. 1RM % Change`
      : selectedGroup
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

  // Recommendations filtered to selected sub-group / group in drill-down mode
  let filteredRecs = $derived.by(() => {
    if (!selectedGroup) return recommendations;
    let exNames: string[];
    if (selectedSubGroup) {
      const subMuscles = SUB_GROUPS[selectedGroup]?.[selectedSubGroup] ?? MUSCLE_GROUPS[selectedGroup];
      exNames = [...exercisePctSeries.keys()].filter(n =>
        exerciseNameToMuscles.get(n)?.some(m => subMuscles.includes(m))
      );
    } else {
      exNames = [...exercisePctSeries.keys()].filter(n => exerciseNameToGroup.get(n) === selectedGroup);
    }
    const exSet = new Set(exNames);
    return recommendations.filter(r => exSet.has(r.exercise_name));
  });

  // Exercises to show as cards (level 3: sub-group selected, or flat group)
  let drilldownExercises = $derived.by(() => {
    if (!selectedGroup) return [] as string[];
    if (selectedSubGroup) {
      const subMuscles = SUB_GROUPS[selectedGroup]?.[selectedSubGroup] ?? MUSCLE_GROUPS[selectedGroup];
      return [...exercisePctSeries.keys()].filter(n =>
        exerciseNameToMuscles.get(n)?.some(m => subMuscles.includes(m))
      );
    }
    if (SUB_GROUPS[selectedGroup]) return [] as string[]; // show sub-group cards instead
    return [...exercisePctSeries.keys()].filter(n => exerciseNameToGroup.get(n) === selectedGroup);
  });
</script>

<div class="space-y-6 max-w-4xl mx-auto">
  <!-- Header row with back button + time range -->
  <div class="flex items-center justify-between gap-3">
    <div class="flex items-center gap-3 flex-wrap">
      {#if selectedSubGroup}
        <button
          onclick={() => { selectedSubGroup = null; }}
          class="text-zinc-400 hover:text-white transition-colors text-sm flex items-center gap-1"
        >
          ← {selectedGroup}
        </button>
        <h2 class="text-2xl font-bold">{selectedSubGroup}</h2>
      {:else if selectedGroup}
        <button
          onclick={() => { selectedGroup = null; selectedSubGroup = null; }}
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

  <!-- Sub-group cards (Back / Shoulders — level 2) -->
  {#if selectedGroup && !selectedSubGroup && trainedSubGroups.length > 0 && !loading}
    <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
      {#each trainedSubGroups as sg, idx}
        {@const sgSeries = subGroupPctSeries.get(sg)}
        {@const sgVals = sgSeries ? [...sgSeries.values()] : []}
        {@const pct = sgVals.length > 0 ? Math.round(sgVals[sgVals.length - 1] * 10) / 10 : 0}
        <button
          class="card text-left hover:bg-zinc-700/60 transition-colors"
          onclick={() => selectedSubGroup = sg}
        >
          <div class="flex items-center gap-2 mb-1">
            <div class="w-2.5 h-2.5 rounded-full flex-shrink-0" style="background:{COLORS[idx % COLORS.length]}"></div>
            <p class="text-sm font-medium truncate">{sg}</p>
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
    <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-3">
      {#each drilldownExercises as name, idx}
        {@const vals = [...exercisePctSeries.get(name)!.values()]}
        {@const pct = vals.length > 0 ? Math.round(vals[vals.length - 1] * 10) / 10 : 0}
        <div class="card flex items-center gap-3">
          <div class="w-2.5 h-2.5 rounded-full flex-shrink-0" style="background:{COLORS[idx % COLORS.length]}"></div>
          <div class="min-w-0 flex-1">
            <p class="text-sm text-zinc-300 truncate" title={name}>{name}</p>
            <p class="text-lg font-bold {pct > 0 ? 'text-green-400' : pct < 0 ? 'text-red-400' : 'text-zinc-400'}">
              {pct > 0 ? '+' : ''}{pct}%
            </p>
          </div>
        </div>
      {/each}
    </div>
  {/if}

  <!-- Recommendations -->
  <div class="card">
    <h3 class="text-lg font-semibold mb-4">
      Progression Recommendations{selectedSubGroup ? ` — ${selectedSubGroup}` : selectedGroup ? ` — ${selectedGroup}` : ''}
    </h3>
    {#if loading}
      <div class="space-y-2">
        {#each { length: 3 } as _}
          <div class="animate-pulse bg-zinc-800 rounded h-10"></div>
        {/each}
      </div>
    {:else if filteredRecs.length > 0}
      <div class="space-y-2">
        {#each filteredRecs as rec}
          {@const delta = rec.recommended_weight - rec.current_weight}
          <div class="flex items-center gap-3 py-3 border-b border-zinc-800/50 last:border-0">
            <div class="min-w-0 flex-1">
              <p class="text-sm font-medium truncate" title={rec.exercise_name}>{rec.exercise_name}</p>
              <p class="text-xs text-zinc-500 mt-0.5 line-clamp-2">{rec.reason}</p>
            </div>
            <div class="flex-shrink-0 text-right">
              <p class="text-xs text-zinc-400">{displayWeight(rec.current_weight).toFixed(1)} {unit}</p>
              <p class="text-sm font-mono font-bold {delta > 0 ? 'text-green-400' : delta < 0 ? 'text-red-400' : 'text-yellow-400'}">
                {displayWeight(rec.recommended_weight).toFixed(1)} {unit}
                {#if delta > 0}<span class="text-xs">↑</span>
                {:else if delta < 0}<span class="text-xs">↓</span>
                {:else}<span class="text-xs">→</span>{/if}
              </p>
            </div>
          </div>
        {/each}
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
