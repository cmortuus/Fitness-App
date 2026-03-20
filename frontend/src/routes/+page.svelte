<script lang="ts">
  import { onMount } from 'svelte';
  import { currentSession, workoutPlans } from '$lib/stores';
  import { getSessions, archivePlan, getPlans } from '$lib/api';
  import type { WorkoutPlan, PlannedDay, WorkoutSession } from '$lib/api';

  interface NextWorkout {
    plan: WorkoutPlan;
    day: PlannedDay;
    weekNumber: number;
    dayNumber: number;
    isComplete: boolean;  // true when all duration_weeks × days are done
  }

  let allSessions    = $state<WorkoutSession[]>([]);
  let nextWorkout    = $state<NextWorkout | null>(null);
  let loading        = $state(true);
  let archiving      = $state(false);

  // ── Calendar state ────────────────────────────────────────────────────
  const today      = new Date();
  let calYear      = $state(today.getFullYear());
  let calMonth     = $state(today.getMonth()); // 0-indexed
  let selectedDay  = $state<string | null>(null);

  const todayStr   = isoDate(today);

  const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

  onMount(async () => {
    try {
      // Pull enough sessions to fill several months of calendar
      const sessions = await getSessions({ limit: 200 });
      allSessions = sessions;
      nextWorkout = resolveNextWorkout(sessions, $workoutPlans);
    } catch (e) {
      console.error('Failed to load dashboard:', e);
    } finally {
      loading = false;
    }
  });

  // ── "Next workout" logic ──────────────────────────────────────────────
  function resolveNextWorkout(sessions: WorkoutSession[], plans: WorkoutPlan[]): NextWorkout | null {
    const activePlans = plans.filter(p => !p.is_archived);
    if (!activePlans.length) return null;

    // Count sessions that belong to a plan and have at least some volume logged.
    // Abandoned/empty sessions (0 sets, 0 reps) are not real "done" sessions.
    function sessionsForPlan(plan: WorkoutPlan) {
      return sessions.filter(s =>
        s.status !== 'skipped' &&
        (s.total_sets > 0 || s.total_reps > 0) &&
        (
          s.workout_plan_id === plan.id ||
          (s.name && s.name.startsWith(plan.name + ' - '))
        )
      );
    }

    // Use the active plan that was most recently trained
    let plan: WorkoutPlan;
    const recentWithPlan = sessions.find(s =>
      s.status !== 'skipped' && (
        activePlans.some(p => p.id === s.workout_plan_id) ||
        activePlans.some(p => s.name?.startsWith(p.name + ' - '))
      )
    );

    if (recentWithPlan) {
      plan = activePlans.find(p =>
        p.id === recentWithPlan.workout_plan_id ||
        recentWithPlan.name?.startsWith(p.name + ' - ')
      ) ?? activePlans[0];
    } else {
      plan = activePlans[0];
    }

    if (!plan.days.length) return null;

    const doneCount   = sessionsForPlan(plan).length;
    const totalNeeded = plan.duration_weeks * plan.days.length;
    const isComplete  = doneCount >= totalNeeded;
    // When complete, still show the last day so the banner has context
    const nextDayIdx  = isComplete ? 0 : doneCount % plan.days.length;
    const weekNumber  = isComplete ? plan.duration_weeks : Math.floor(doneCount / plan.days.length) + 1;
    const dayNumber   = nextDayIdx + 1;
    return { plan, day: plan.days[nextDayIdx], weekNumber, dayNumber, isComplete };
  }

  // ── Archive completed plan ────────────────────────────────────────────
  async function handleArchive(planId: number) {
    archiving = true;
    try {
      await archivePlan(planId);
      const [sessions, plans] = await Promise.all([getSessions({ limit: 200 }), getPlans()]);
      allSessions = sessions;
      workoutPlans.set(plans);
      nextWorkout = resolveNextWorkout(sessions, plans);
    } catch (e) {
      console.error('Failed to archive plan:', e);
    } finally {
      archiving = false;
    }
  }

  // ── Calendar helpers ──────────────────────────────────────────────────
  function isoDate(d: Date) {
    return d.toISOString().split('T')[0];
  }

  function pad2(n: number) { return String(n).padStart(2, '0'); }
  function dayKey(y: number, m: number, d: number) {
    return `${y}-${pad2(m + 1)}-${pad2(d)}`;
  }

  // Map date string → sessions on that date
  let sessionsByDate = $derived(
    allSessions.reduce<Record<string, WorkoutSession[]>>((acc, s) => {
      (acc[s.date] ??= []).push(s);
      return acc;
    }, {})
  );

  let firstDayOfMonth = $derived(new Date(calYear, calMonth, 1).getDay());
  let daysInMonth     = $derived(new Date(calYear, calMonth + 1, 0).getDate());

  let monthLabel = $derived(
    new Date(calYear, calMonth, 1).toLocaleDateString('en-US', { month: 'long', year: 'numeric' })
  );

  function prevMonth() {
    if (calMonth === 0) { calMonth = 11; calYear--; } else calMonth--;
    selectedDay = null;
  }
  function nextMonth() {
    if (calMonth === 11) { calMonth = 0; calYear++; } else calMonth++;
    selectedDay = null;
  }

  function selectDay(key: string) {
    selectedDay = selectedDay === key ? null : key;
  }

  function fmtDate(iso: string) {
    return new Date(iso + 'T00:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }

  let recentSessions = $derived(allSessions.slice(0, 5));
</script>

<div class="space-y-6">
  <h2 class="text-2xl font-bold">Dashboard</h2>

  <!-- ── Next Workout (hero) ─────────────────────────────────────────── -->
  {#if $currentSession}
    <a
      href="/workout/active"
      class="block card border-2 border-primary-500 hover:border-primary-400 transition-colors group"
    >
      <div class="flex items-center justify-between">
        <div>
          <p class="text-xs text-primary-400 font-semibold uppercase tracking-wider mb-1">In Progress</p>
          <h3 class="text-xl font-bold group-hover:text-primary-300 transition-colors">
            {$currentSession.name ?? 'Active Workout'}
          </h3>
          <p class="text-sm text-gray-400 mt-1">Tap to resume where you left off</p>
        </div>
        <div class="text-4xl">▶</div>
      </div>
    </a>

  {:else if loading}
    <div class="card animate-pulse h-28"></div>

  {:else if nextWorkout && nextWorkout.isComplete}
    <!-- ── Program complete banner ──────────────────────────────────── -->
    <div class="card border-2 border-amber-500/60">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <p class="text-xs text-amber-400 font-semibold uppercase tracking-wider mb-1">
            Program Complete 🏆
          </p>
          <h3 class="text-2xl font-bold truncate">{nextWorkout.plan.name}</h3>
          <p class="text-sm text-gray-400 mt-1">
            You finished all {nextWorkout.plan.duration_weeks} weeks. Archive it and start fresh — or keep going.
          </p>
        </div>
        <div class="shrink-0 text-4xl">🏆</div>
      </div>
      <div class="flex gap-3 mt-4">
        <button
          onclick={() => handleArchive(nextWorkout!.plan.id)}
          disabled={archiving}
          class="flex-1 py-2.5 rounded-lg bg-amber-600 hover:bg-amber-500 text-white font-semibold text-sm transition-colors disabled:opacity-50"
        >
          {archiving ? 'Archiving…' : 'Archive & Start New'}
        </button>
        <a
          href="/workout/active?plan={nextWorkout.plan.id}&day={nextWorkout.day.day_number}"
          class="flex-1 py-2.5 rounded-lg bg-gray-700 hover:bg-gray-600 text-white font-semibold text-sm transition-colors text-center"
        >
          Keep Going
        </a>
      </div>
    </div>

  {:else if nextWorkout}
    <a
      href="/workout/active?plan={nextWorkout.plan.id}&day={nextWorkout.day.day_number}"
      class="block card border-2 border-primary-600 hover:border-primary-400 transition-colors group"
    >
      <div class="flex items-center justify-between gap-4">
        <div class="min-w-0">
          <p class="text-xs text-primary-400 font-semibold uppercase tracking-wider mb-1">
            Next Workout · {nextWorkout.plan.name}
          </p>
          <h3 class="text-2xl font-bold group-hover:text-primary-300 transition-colors truncate">
            {nextWorkout.day.day_name}
          </h3>
          <div class="flex items-center gap-2 mt-1.5">
            <span class="text-xs font-semibold px-2 py-0.5 rounded-full bg-primary-900 text-primary-300 border border-primary-700">
              Week {nextWorkout.weekNumber}
            </span>
            <span class="text-xs font-semibold px-2 py-0.5 rounded-full bg-gray-700 text-gray-300">
              Day {nextWorkout.dayNumber}
            </span>
            <span class="text-xs text-gray-500">
              {nextWorkout.day.exercises.length} exercise{nextWorkout.day.exercises.length !== 1 ? 's' : ''}
            </span>
          </div>
        </div>
        <div class="shrink-0 w-14 h-14 rounded-full bg-primary-600 group-hover:bg-primary-500 flex items-center justify-center text-2xl transition-colors">
          🏋️
        </div>
      </div>
    </a>

  {:else}
    <div class="card border-2 border-dashed border-gray-700 text-center py-10">
      <p class="text-gray-400 mb-4">Create a plan to see your next workout here.</p>
      <a href="/plans/create" class="btn-primary">Create a Plan</a>
    </div>
  {/if}

  <!-- ── Workout Calendar ────────────────────────────────────────────── -->
  <div class="card">
    <!-- Month nav -->
    <div class="flex items-center justify-between mb-4">
      <h3 class="text-lg font-semibold">Workout History</h3>
      <div class="flex items-center gap-3">
        <button
          onclick={prevMonth}
          class="w-8 h-8 rounded-lg bg-gray-700 hover:bg-gray-600 flex items-center justify-center text-sm transition-colors"
        >←</button>
        <span class="text-sm font-medium w-36 text-center">{monthLabel}</span>
        <button
          onclick={nextMonth}
          class="w-8 h-8 rounded-lg bg-gray-700 hover:bg-gray-600 flex items-center justify-center text-sm transition-colors"
          disabled={calYear === today.getFullYear() && calMonth === today.getMonth()}
        >→</button>
      </div>
    </div>

    <!-- Day-of-week headers -->
    <div class="grid grid-cols-7 mb-1">
      {#each DAYS as d}
        <div class="text-center text-xs text-gray-500 py-1">{d}</div>
      {/each}
    </div>

    <!-- Calendar grid -->
    <div class="grid grid-cols-7 gap-1">
      <!-- Leading empty cells -->
      {#each { length: firstDayOfMonth } as _}
        <div></div>
      {/each}

      <!-- Day cells -->
      {#each { length: daysInMonth } as _, i}
        {@const day    = i + 1}
        {@const key    = dayKey(calYear, calMonth, day)}
        {@const hits   = sessionsByDate[key] ?? []}
        {@const isToday   = key === todayStr}
        {@const isSelected = key === selectedDay}
        {@const hasWorkout = hits.length > 0}

        <button
          onclick={() => hasWorkout && selectDay(key)}
          class="
            aspect-square rounded-lg flex flex-col items-center justify-center gap-0.5 text-sm transition-colors
            {isToday     ? 'ring-1 ring-primary-500' : ''}
            {isSelected  ? 'bg-primary-700'          : hasWorkout ? 'bg-gray-700 hover:bg-gray-600' : ''}
            {!hasWorkout ? 'cursor-default opacity-40' : 'cursor-pointer'}
          "
        >
          <span class="{isToday ? 'text-primary-400 font-bold' : ''}">{day}</span>
          {#if hasWorkout}
            <div class="flex gap-0.5">
              {#each { length: Math.min(hits.length, 3) } as _}
                <div class="w-1.5 h-1.5 rounded-full {isSelected ? 'bg-primary-300' : 'bg-primary-500'}"></div>
              {/each}
            </div>
          {/if}
        </button>
      {/each}
    </div>

    <!-- Selected day detail -->
    {#if selectedDay && sessionsByDate[selectedDay]}
      <div class="mt-4 pt-4 border-t border-gray-700 space-y-3">
        <p class="text-xs text-gray-500 uppercase tracking-wider">{fmtDate(selectedDay)}</p>
        {#each sessionsByDate[selectedDay] as s}
          <div class="flex items-center justify-between bg-gray-800 rounded-lg px-4 py-3">
            <div>
              <p class="font-medium text-sm">{s.name ?? 'Workout'}</p>
              <p class="text-xs text-gray-400 mt-0.5">
                {s.total_sets} sets · {s.total_reps} reps
              </p>
            </div>
            <div class="text-right shrink-0">
              <p class="text-sm font-mono text-primary-400">{s.total_volume_kg?.toFixed(0)} kg</p>
              <p class="text-xs text-gray-500 capitalize mt-0.5">{s.status}</p>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- ── Recent Sessions ────────────────────────────────────────────── -->
  {#if recentSessions.length > 0}
    <div class="card">
      <h3 class="text-lg font-semibold mb-3">Recent Workouts</h3>
      <div class="space-y-2">
        {#each recentSessions as s}
          <div class="flex items-center justify-between py-2 border-b border-gray-700 last:border-0">
            <div>
              <p class="text-sm font-medium">{s.name ?? 'Workout'}</p>
              <p class="text-xs text-gray-500 mt-0.5">{fmtDate(s.date)}</p>
            </div>
            <div class="text-right shrink-0">
              <p class="text-sm font-mono text-primary-400">{s.total_sets} sets</p>
              <p class="text-xs text-gray-500">{s.total_volume_kg?.toFixed(0)} kg vol</p>
            </div>
          </div>
        {/each}
      </div>
    </div>
  {/if}

  <!-- ── Plan quick-jump (only if multiple plans) ───────────────────── -->
  {#if $workoutPlans.length > 1}
    <div class="card">
      <h3 class="text-lg font-semibold mb-3">Your Plans</h3>
      <div class="space-y-2">
        {#each $workoutPlans as plan}
          <div class="flex items-center justify-between py-2 border-b border-gray-700 last:border-0">
            <div>
              <p class="text-sm font-medium">{plan.name}</p>
              <p class="text-xs text-gray-500">{plan.days.length} day{plan.days.length !== 1 ? 's' : ''}</p>
            </div>
            <div class="flex gap-2 shrink-0">
              {#each plan.days as day}
                <a
                  href="/workout/active?plan={plan.id}&day={day.day_number}"
                  class="text-xs px-2.5 py-1 bg-gray-700 hover:bg-primary-600 text-gray-300 hover:text-white rounded transition-colors"
                  title={day.day_name}
                >D{day.day_number}</a>
              {/each}
            </div>
          </div>
        {/each}
      </div>
    </div>
  {/if}

</div>
