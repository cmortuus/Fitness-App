<script lang="ts">
  import { onMount } from 'svelte';
  import { getSessions } from '$lib/api';
  import { settings } from '$lib/stores';

  const KG_TO_LBS = 2.20462;
  function volDisplay(kg: number): number {
    return $settings.weightUnit === 'lbs' ? Math.round(kg * KG_TO_LBS) : Math.round(kg);
  }
  let volUnit = $derived($settings.weightUnit);

  interface Session {
    id: number;
    name: string | null;
    date: string;
    status: string;
    total_sets: number;
    total_reps: number;
    total_volume_kg: number;
    started_at: string | null;
    completed_at: string | null;
  }

  let allSessions = $state<Session[]>([]);
  let loading = $state(true);

  const today = new Date();
  let calYear = $state(today.getFullYear());
  let calMonth = $state(today.getMonth());
  let selectedDay = $state<string | null>(null);
  let viewMode = $state<'month' | 'week'>('month');

  const DAYS = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

  // Week view helpers
  function getWeekDates(): string[] {
    const d = new Date();
    const dayOfWeek = d.getDay();
    const start = new Date(d);
    start.setDate(d.getDate() - dayOfWeek);
    const dates: string[] = [];
    for (let i = 0; i < 7; i++) {
      const curr = new Date(start);
      curr.setDate(start.getDate() + i);
      dates.push(isoDate(curr));
    }
    return dates;
  }

  let weekDates = $derived(getWeekDates());
  const MUSCLE_COLORS: Record<string, string> = {
    'chest': '#ef4444', 'back': '#3b82f6', 'legs': '#22c55e', 'shoulders': '#f59e0b',
    'arms': '#8b5cf6', 'core': '#ec4899', 'full': '#0ea5e9', 'upper': '#14b8a6',
    'lower': '#22c55e', 'push': '#ef4444', 'pull': '#3b82f6',
  };

  onMount(async () => {
    try {
      allSessions = await getSessions({ limit: 500 });
    } catch (e) {
      console.error('Failed to load sessions:', e);
    } finally {
      loading = false;
    }
  });

  function isoDate(d: Date) { return d.toISOString().split('T')[0]; }
  function pad2(n: number) { return String(n).padStart(2, '0'); }
  function dayKey(y: number, m: number, d: number) {
    return `${y}-${pad2(m + 1)}-${pad2(d)}`;
  }

  let sessionsByDate = $derived(
    allSessions.reduce<Record<string, Session[]>>((acc, s) => {
      (acc[s.date] ??= []).push(s);
      return acc;
    }, {})
  );

  let firstDayOfMonth = $derived(new Date(calYear, calMonth, 1).getDay());
  let daysInMonth = $derived(new Date(calYear, calMonth + 1, 0).getDate());
  let monthLabel = $derived(
    new Date(calYear, calMonth, 1).toLocaleDateString('en-US', { month: 'long', year: 'numeric' })
  );

  let todayStr = isoDate(today);

  function prevMonth() {
    if (calMonth === 0) { calMonth = 11; calYear--; }
    else calMonth--;
    selectedDay = null;
  }
  function nextMonth() {
    if (calYear === today.getFullYear() && calMonth === today.getMonth()) return;
    if (calMonth === 11) { calMonth = 0; calYear++; }
    else calMonth++;
    selectedDay = null;
  }

  // Guess muscle group from session name
  function guessColor(name: string | null): string {
    if (!name) return '#6366f1';
    const lower = (name ?? '').toLowerCase();
    for (const [key, color] of Object.entries(MUSCLE_COLORS)) {
      if (lower.includes(key)) return color;
    }
    return '#6b7280';
  }

  // Monthly stats
  let monthSessions = $derived(() => {
    const completed: Session[] = [];
    for (let d = 1; d <= daysInMonth; d++) {
      const key = dayKey(calYear, calMonth, d);
      const hits = sessionsByDate[key] ?? [];
      hits.filter(s => s.status === 'completed').forEach(s => completed.push(s));
    }
    return completed;
  });

  let monthStats = $derived(() => {
    const sessions = monthSessions();
    return {
      workouts: sessions.length,
      totalSets: sessions.reduce((s, w) => s + (w.total_sets ?? 0), 0),
      totalReps: sessions.reduce((s, w) => s + (w.total_reps ?? 0), 0),
      totalVolume: sessions.reduce((s, w) => s + (w.total_volume_kg ?? 0), 0),
      uniqueDays: new Set(sessions.map(s => s.date)).size,
    };
  });

  // Current streak
  let streak = $derived(() => {
    const dates = new Set(allSessions.filter(s => s.status === 'completed').map(s => s.date));
    let count = 0;
    const d = new Date();
    // Check if worked out today
    if (!dates.has(isoDate(d))) {
      d.setDate(d.getDate() - 1);
      if (!dates.has(isoDate(d))) return 0;
    }
    while (dates.has(isoDate(d))) {
      count++;
      d.setDate(d.getDate() - 1);
    }
    return count;
  });

  function fmtDate(iso: string) {
    return new Date(iso + 'T12:00:00').toLocaleDateString('en-US', {
      weekday: 'long', month: 'short', day: 'numeric'
    });
  }

</script>

<div class="space-y-4 max-w-lg mx-auto">
  <h2 class="text-2xl font-bold">Training Log</h2>

  <!-- Streak & Monthly Stats -->
  <div class="grid grid-cols-3 gap-3">
    <div class="card text-center py-3">
      <p class="text-2xl font-bold text-primary-400">{streak()}</p>
      <p class="text-xs text-zinc-500">Day Streak</p>
    </div>
    <div class="card text-center py-3">
      <p class="text-2xl font-bold text-green-400">{monthStats().workouts}</p>
      <p class="text-xs text-zinc-500">This Month</p>
    </div>
    <div class="card text-center py-3">
      <p class="text-2xl font-bold text-amber-400">{volDisplay(monthStats().totalVolume).toLocaleString()}</p>
      <p class="text-xs text-zinc-500">Volume ({volUnit})</p>
    </div>
  </div>

  <!-- Calendar -->
  <div class="card">
    <!-- View toggle + navigation -->
    <div class="flex items-center justify-between mb-4">
      {#if viewMode === 'month'}
        <button onclick={prevMonth}
                class="w-9 h-9 rounded-lg bg-zinc-800 hover:bg-zinc-700 flex items-center justify-center text-sm transition-colors">←</button>
        <div class="flex flex-col items-center gap-1">
          <span class="text-sm font-semibold text-zinc-200">{monthLabel}</span>
          <div class="flex rounded-lg overflow-hidden border border-zinc-700">
            <button class="px-2.5 py-0.5 text-xs bg-primary-600 text-white"
                    onclick={() => viewMode = 'month'}>Month</button>
            <button class="px-2.5 py-0.5 text-xs bg-zinc-800 text-zinc-400"
                    onclick={() => viewMode = 'week'}>Week</button>
          </div>
        </div>
        <button onclick={nextMonth}
                disabled={calYear === today.getFullYear() && calMonth === today.getMonth()}
                class="w-9 h-9 rounded-lg bg-zinc-800 hover:bg-zinc-700 flex items-center justify-center text-sm transition-colors disabled:opacity-30">→</button>
      {:else}
        <div class="w-9"></div>
        <div class="flex flex-col items-center gap-1">
          <span class="text-sm font-semibold text-zinc-200">This Week</span>
          <div class="flex rounded-lg overflow-hidden border border-zinc-700">
            <button class="px-2.5 py-0.5 text-xs bg-zinc-800 text-zinc-400"
                    onclick={() => viewMode = 'month'}>Month</button>
            <button class="px-2.5 py-0.5 text-xs bg-primary-600 text-white"
                    onclick={() => viewMode = 'week'}>Week</button>
          </div>
        </div>
        <div class="w-9"></div>
      {/if}
    </div>

    <!-- Day headers -->
    <div class="grid grid-cols-7 mb-1">
      {#each DAYS as d}
        <div class="text-center text-xs text-zinc-600 py-1 font-medium">{d}</div>
      {/each}
    </div>

    {#if viewMode === 'month'}
      <!-- Month view -->
      <div class="grid grid-cols-7 gap-1">
        {#each { length: firstDayOfMonth } as _}<div></div>{/each}

        {#each { length: daysInMonth } as _, i}
          {@const day = i + 1}
          {@const key = dayKey(calYear, calMonth, day)}
          {@const hits = (sessionsByDate[key] ?? []).filter(s => s.status === 'completed')}
          {@const isToday = key === todayStr}
          {@const isSelected = key === selectedDay}
          {@const hasWorkout = hits.length > 0}

          <button onclick={() => selectedDay = selectedDay === key ? null : key}
                  class="aspect-square rounded-xl flex flex-col items-center justify-center gap-0.5 text-xs transition-all
                         {isToday ? 'ring-1 ring-primary-500' : ''}
                         {isSelected ? 'bg-primary-700/60' : hasWorkout ? 'bg-zinc-800 hover:bg-zinc-700 cursor-pointer' : 'bg-zinc-900/30'}">
            <span class="{isToday ? 'text-primary-400 font-bold' : hasWorkout ? 'text-zinc-200' : 'text-zinc-600'}">{day}</span>
            {#if hasWorkout}
              <div class="flex gap-0.5">
                {#each hits.slice(0, 3) as s}
                  <div class="w-1.5 h-1.5 rounded-full" style="background-color: {guessColor(s.name)}"></div>
                {/each}
              </div>
            {/if}
          </button>
        {/each}
      </div>
    {:else}
      <!-- Week view — compact row with more detail per day -->
      <div class="grid grid-cols-7 gap-1">
        {#each weekDates as key}
          {@const hits = (sessionsByDate[key] ?? []).filter(s => s.status === 'completed')}
          {@const isToday = key === todayStr}
          {@const isSelected = key === selectedDay}
          {@const hasWorkout = hits.length > 0}
          {@const dayNum = parseInt(key.split('-')[2])}

          <button onclick={() => selectedDay = selectedDay === key ? null : key}
                  class="py-3 rounded-xl flex flex-col items-center justify-center gap-1 text-xs transition-all
                         {isToday ? 'ring-1 ring-primary-500' : ''}
                         {isSelected ? 'bg-primary-700/60' : hasWorkout ? 'bg-zinc-800 hover:bg-zinc-700 cursor-pointer' : 'bg-zinc-900/30'}">
            <span class="{isToday ? 'text-primary-400 font-bold' : hasWorkout ? 'text-zinc-200' : 'text-zinc-600'}">{dayNum}</span>
            {#if hasWorkout}
              <div class="flex gap-0.5">
                {#each hits.slice(0, 3) as s}
                  <div class="w-1.5 h-1.5 rounded-full" style="background-color: {guessColor(s.name)}"></div>
                {/each}
              </div>
              <span class="text-[10px] text-zinc-500">{hits.length}x</span>
            {/if}
          </button>
        {/each}
      </div>
    {/if}

    <!-- Selected day detail -->
    {#if selectedDay}
      {@const daySessions = (sessionsByDate[selectedDay] ?? []).filter(s => s.status === 'completed')}
      {#if daySessions.length > 0}
        <div class="mt-4 pt-4 border-t border-zinc-800 space-y-2">
          <p class="text-xs text-zinc-500 uppercase tracking-wider font-medium">{fmtDate(selectedDay)}</p>
          {#each daySessions as s}
            <div class="bg-zinc-800/60 rounded-xl px-4 py-3">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <div class="w-2 h-2 rounded-full" style="background-color: {guessColor(s.name)}"></div>
                  <p class="font-medium text-sm">{s.name ?? 'Workout'}</p>
                </div>
              </div>
              <div class="flex gap-4 mt-1.5 text-xs text-zinc-400">
                <span>{s.total_sets} sets</span>
                <span>{s.total_reps} reps</span>
                <span class="text-primary-400 font-medium">{volDisplay(s.total_volume_kg ?? 0).toLocaleString()} {volUnit}</span>
              </div>
            </div>
          {/each}
        </div>
      {:else}
        <div class="mt-4 pt-4 border-t border-zinc-800">
          <p class="text-xs text-zinc-500 text-center py-2">No workouts on {fmtDate(selectedDay)}</p>
        </div>
      {/if}
    {/if}
  </div>

  <!-- Monthly breakdown -->
  <div class="card">
    <h3 class="font-semibold text-zinc-200 mb-3">Monthly Summary</h3>
    <div class="grid grid-cols-2 gap-3 text-sm">
      <div class="bg-zinc-800/50 rounded-lg px-3 py-2">
        <p class="text-zinc-500 text-xs">Workouts</p>
        <p class="font-semibold">{monthStats().workouts}</p>
      </div>
      <div class="bg-zinc-800/50 rounded-lg px-3 py-2">
        <p class="text-zinc-500 text-xs">Active Days</p>
        <p class="font-semibold">{monthStats().uniqueDays}</p>
      </div>
      <div class="bg-zinc-800/50 rounded-lg px-3 py-2">
        <p class="text-zinc-500 text-xs">Total Sets</p>
        <p class="font-semibold">{monthStats().totalSets.toLocaleString()}</p>
      </div>
      <div class="bg-zinc-800/50 rounded-lg px-3 py-2">
        <p class="text-zinc-500 text-xs">Total Reps</p>
        <p class="font-semibold">{monthStats().totalReps.toLocaleString()}</p>
      </div>
    </div>
  </div>
</div>
