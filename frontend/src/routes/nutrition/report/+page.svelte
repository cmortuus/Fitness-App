<script lang="ts">
  import { onMount } from 'svelte';
  import { settings } from '$lib/stores';
  import { getWeeklyReport } from '$lib/api';
  import type { WeeklyReport } from '$lib/api';

  let report = $state<WeeklyReport | null>(null);
  let loading = $state(true);

  const KG_TO_LBS = 2.20462;
  function wt(kg: number): string {
    return $settings.weightUnit === 'lbs'
      ? (kg * KG_TO_LBS).toFixed(1) + ' lbs'
      : kg.toFixed(1) + ' kg';
  }

  function dayLabel(iso: string): string {
    return new Date(iso + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'short' });
  }

  onMount(async () => {
    try {
      report = await getWeeklyReport();
    } catch (e) {
      console.error('Failed to load weekly report:', e);
    }
    loading = false;
  });
</script>

<div class="page-content space-y-5">
  <div class="flex items-center justify-between">
    <h2 class="text-xl font-bold">Weekly Report</h2>
    <a href="/nutrition" class="text-sm text-primary-400 hover:text-primary-300">← Back</a>
  </div>

  {#if loading}
    <div class="flex justify-center py-16">
      <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-500"></div>
    </div>
  {:else if report}
    <!-- Summary cards -->
    <div class="grid grid-cols-3 gap-3">
      <div class="card text-center !py-3">
        <p class="text-lg font-bold text-primary-400">{report.days_logged}/7</p>
        <p class="text-[10px] text-zinc-500">Days Logged</p>
      </div>
      <div class="card text-center !py-3">
        <p class="text-lg font-bold text-accent-400">{report.workout_count}</p>
        <p class="text-[10px] text-zinc-500">Workouts</p>
      </div>
      <div class="card text-center !py-3">
        <p class="text-lg font-bold {report.weight_change_kg !== null && report.weight_change_kg < 0 ? 'text-green-400' : report.weight_change_kg !== null && report.weight_change_kg > 0 ? 'text-amber-400' : 'text-zinc-400'}">
          {report.weight_change_kg !== null ? (report.weight_change_kg > 0 ? '+' : '') + wt(report.weight_change_kg) : '—'}
        </p>
        <p class="text-[10px] text-zinc-500">Weight Change</p>
      </div>
    </div>

    <!-- Daily averages vs goals -->
    <div class="card space-y-3">
      <h3 class="text-sm font-semibold text-zinc-300">Daily Averages</h3>
      {#each [
        ['Calories', report.averages.calories, report.goals?.calories, 'bg-blue-500'],
        ['Protein', report.averages.protein, report.goals?.protein, 'bg-purple-500'],
        ['Carbs', report.averages.carbs, report.goals?.carbs, 'bg-emerald-500'],
        ['Fat', report.averages.fat, report.goals?.fat, 'bg-amber-500'],
      ] as [label, avg, goal, color]}
        <div>
          <div class="flex justify-between text-xs mb-1">
            <span class="text-zinc-400">{label}</span>
            <span class="text-white font-medium">
              {avg}{label === 'Calories' ? '' : 'g'}
              {#if goal}
                <span class="text-zinc-600">/ {goal}{label === 'Calories' ? '' : 'g'}</span>
              {/if}
            </span>
          </div>
          <div class="h-2 bg-zinc-800 rounded-full">
            <div class="{color} h-full rounded-full transition-all"
                 style="width: {goal ? Math.min((avg as number) / (goal as number) * 100, 100) : 0}%"></div>
          </div>
        </div>
      {/each}
    </div>

    <!-- Daily calorie chart (bars) -->
    <div class="card space-y-3">
      <h3 class="text-sm font-semibold text-zinc-300">Daily Calories</h3>
      {#if report.days.length > 0}
      {@const maxCal = Math.max(...report.days.map(d => d.calories), report.goals?.calories ?? 0, 1)}
      <div class="flex items-end gap-1" style="height: 120px">
        {#each report.days as day}
          <div class="flex-1 flex flex-col items-center justify-end h-full">
            <span class="text-[9px] text-zinc-500 mb-1">{day.calories > 0 ? day.calories : ''}</span>
            <div class="w-full rounded-t bg-blue-500/80 transition-all"
                 style="height: {day.calories > 0 ? (day.calories / maxCal * 100) : 0}%"></div>
            {#if report.goals}
              <div class="w-full border-t border-dashed border-zinc-600 absolute" style="bottom: {report.goals.calories / maxCal * 100}%"></div>
            {/if}
            <span class="text-[9px] text-zinc-600 mt-1">{dayLabel(day.date)}</span>
          </div>
        {/each}
      </div>
      {#if report.goals}
        <p class="text-[10px] text-zinc-600 text-right">Goal: {report.goals.calories} cal</p>
      {/if}
      {/if}
    </div>

    <!-- Body weight trend -->
    {#if report.weight_data.length > 0}
      <div class="card space-y-3">
        <h3 class="text-sm font-semibold text-zinc-300">Body Weight</h3>
        <div class="space-y-1">
          {#each report.weight_data as entry}
            <div class="flex items-center justify-between text-sm">
              <span class="text-zinc-500 text-xs">{dayLabel(entry.date)}</span>
              <div class="flex items-center gap-3">
                <span class="font-mono font-medium">{wt(entry.weight_kg)}</span>
                {#if entry.body_fat_pct}
                  <span class="text-xs text-primary-400">{entry.body_fat_pct}%</span>
                {/if}
                {#if entry.lean_mass_kg}
                  <span class="text-[10px] text-zinc-600">lean {wt(entry.lean_mass_kg)}</span>
                {/if}
              </div>
            </div>
          {/each}
        </div>
      </div>
    {/if}
  {:else}
    <div class="card py-10 text-center text-zinc-500">
      <p>No data available. Start logging food and weigh-ins!</p>
    </div>
  {/if}
</div>
