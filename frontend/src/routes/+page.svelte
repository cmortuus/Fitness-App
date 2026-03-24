<script lang="ts">
  import { onMount } from 'svelte';
  import { activeDietPhase, currentSession, settings, workoutPlans, nextWorkoutUrl } from '$lib/stores';
  import { getSessions, archivePlan, getPlans, getDailySummary, getInsights } from '$lib/api';
  import type { DailySummary, Insight, WorkoutPlan, PlannedDay, WorkoutSession } from '$lib/api';

  interface NextWorkout {
    plan: WorkoutPlan;
    day: PlannedDay;
    weekNumber: number;
    dayNumber: number;
    isComplete: boolean;
  }

  let allSessions    = $state<WorkoutSession[]>([]);
  let loading        = $state(true);
  let archiving      = $state(false);
  let nutritionSummary = $state<DailySummary | null>(null);
  let insights = $state<Insight[]>([]);

  let nextWorkout = $derived(
    loading ? null : resolveNextWorkout(allSessions, $workoutPlans)
  );

  // Keep the global nextWorkoutUrl store in sync so the bottom nav Workout
  // tab deep-links straight to the right plan + day.
  $effect(() => {
    if ($currentSession) {
      nextWorkoutUrl.set('/workout/active');
    } else if (nextWorkout && !nextWorkout.isComplete) {
      nextWorkoutUrl.set(`/workout/active?plan=${nextWorkout.plan.id}&day=${nextWorkout.day.day_number}`);
    } else {
      nextWorkoutUrl.set('/workout/active');
    }
  });

  // ── Calendar state ─────────────────────────────────────────────────────
  const today      = new Date();
  let calYear      = $state(today.getFullYear());
  let calMonth     = $state(today.getMonth());
  let selectedDay  = $state<string | null>(null);

  const todayStr   = isoDate(today);
  const DAYS = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

  onMount(async () => {
    try {
      const [sessions, plans, nutrition, insightData] = await Promise.all([
        getSessions({ limit: 200 }),
        getPlans(),
        getDailySummary(new Date().toISOString().slice(0, 10)).catch(() => null),
        getInsights().catch(() => []),
      ]);
      allSessions = sessions;
      workoutPlans.set(plans);
      nutritionSummary = nutrition;
      insights = insightData;
    } catch (e) {
      console.error('Failed to load dashboard:', e);
    } finally {
      loading = false;
    }
  });

  function resolveNextWorkout(sessions: WorkoutSession[], plans: WorkoutPlan[]): NextWorkout | null {
    const activePlans = plans.filter(p => !p.is_archived);
    if (!activePlans.length) return null;

    function sessionsForPlan(plan: WorkoutPlan) {
      return sessions.filter(s =>
        s.status !== 'skipped' &&
        (s.total_sets > 0 || s.total_reps > 0) &&
        (s.workout_plan_id === plan.id || (s.name && s.name.startsWith(plan.name + ' - ')))
      );
    }

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
    const nextDayIdx  = isComplete ? 0 : doneCount % plan.days.length;
    const weekNumber  = isComplete ? plan.duration_weeks : Math.floor(doneCount / plan.days.length) + 1;
    const dayNumber   = nextDayIdx + 1;
    return { plan, day: plan.days[nextDayIdx], weekNumber, dayNumber, isComplete };
  }

  async function handleArchive(planId: number) {
    archiving = true;
    try {
      await archivePlan(planId);
      const [sessions, plans] = await Promise.all([getSessions({ limit: 200 }), getPlans()]);
      allSessions = sessions;
      workoutPlans.set(plans);
    } catch (e) {
      console.error('Failed to archive plan:', e);
    } finally {
      archiving = false;
    }
  }

  // ── Calendar helpers ───────────────────────────────────────────────────
  function isoDate(d: Date) { return d.toISOString().split('T')[0]; }
  function pad2(n: number) { return String(n).padStart(2, '0'); }
  function dayKey(y: number, m: number, d: number) {
    return `${y}-${pad2(m + 1)}-${pad2(d)}`;
  }

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

  function fmtDate(iso: string) {
    return new Date(iso + 'T00:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }

  // ── Quick stats ────────────────────────────────────────────────────────
  let weeklyVolume = $derived((() => {
    const weekAgo = new Date(); weekAgo.setDate(weekAgo.getDate() - 7);
    const weekStr = isoDate(weekAgo);
    return allSessions
      .filter(s => s.date >= weekStr && s.status === 'completed')
      .reduce((sum, s) => sum + (s.total_volume_kg ?? 0), 0);
  })());

  let weeklyWorkouts = $derived((() => {
    const weekAgo = new Date(); weekAgo.setDate(weekAgo.getDate() - 7);
    return allSessions.filter(s => s.date >= isoDate(weekAgo) && s.status === 'completed').length;
  })());

  let weeklySets = $derived((() => {
    const weekAgo = new Date(); weekAgo.setDate(weekAgo.getDate() - 7);
    const weekStr = isoDate(weekAgo);
    const weekSessions = allSessions.filter(s => s.date >= weekStr && s.status === 'completed');
    const planned = weekSessions.reduce((sum, s) => sum + (s.total_sets || 0), 0);
    const completed = weekSessions.reduce((sum, s) =>
      sum + (s.sets?.filter((st: any) => st.completed_at && !st.skipped_at).length || s.total_sets || 0), 0);
    return { planned, completed };
  })());

  let recentSessions = $derived(allSessions.filter(s => s.status === 'completed').slice(0, 5));
</script>

<div class="page-content space-y-5">

  <!-- ── Quick stats strip ───────────────────────────────────────────── -->
  {#if !loading && allSessions.length > 0}
    <div class="grid grid-cols-3 gap-3">
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-primary-400">{weeklyWorkouts}</p>
        <p class="text-xs text-zinc-500 mt-0.5">workouts</p>
      </div>
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-green-400">{weeklySets.completed}</p>
        <p class="text-xs text-zinc-500 mt-0.5">sets this week</p>
      </div>
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-accent-400">
          {weeklyVolume > 999 ? (weeklyVolume / 1000).toFixed(1) + 'k' : weeklyVolume.toFixed(0)}
        </p>
        <p class="text-xs text-zinc-500 mt-0.5">{$settings.weightUnit === 'lbs' ? 'lbs' : 'kg'} volume</p>
      </div>
    </div>
  {/if}

  <!-- ── Nutrition at-a-glance ──────────────────────────────────────── -->
  {#if nutritionSummary?.goals}
    {@const g = nutritionSummary.goals}
    {@const t = nutritionSummary.totals}
    {@const calPct = g.calories > 0 ? Math.min(t.calories / g.calories, 1) : 0}
    {@const proPct = g.protein > 0 ? Math.min(t.protein / g.protein, 1) : 0}
    <a href="/nutrition" class="card !py-3 block hover:bg-zinc-800/40 transition-colors">
      <div class="flex items-center justify-between mb-2">
        <span class="text-xs font-semibold text-zinc-400 uppercase tracking-wide">Today's Nutrition</span>
        {#if $activeDietPhase}
          <span class="text-[10px] text-primary-400 capitalize">{$activeDietPhase.phase_type} · Wk {$activeDietPhase.current_week}</span>
        {/if}
      </div>
      <div class="grid grid-cols-4 gap-2">
        <!-- Calories -->
        <div class="text-center">
          <div class="relative w-14 h-14 mx-auto">
            <svg viewBox="0 0 120 120" class="w-full h-full -rotate-90">
              <circle cx="60" cy="60" r="50" fill="none" stroke="rgba(255,255,255,0.06)" stroke-width="8" />
              <circle cx="60" cy="60" r="50" fill="none" stroke="#3b82f6" stroke-width="8"
                      stroke-dasharray={2 * Math.PI * 50} stroke-dashoffset={2 * Math.PI * 50 * (1 - calPct)}
                      stroke-linecap="round" />
            </svg>
            <div class="absolute inset-0 flex items-center justify-center">
              <span class="text-[10px] font-bold text-white">{Math.round(t.calories)}</span>
            </div>
          </div>
          <p class="text-[9px] text-zinc-500 mt-0.5">Cal</p>
        </div>
        <!-- Protein -->
        <div class="text-center">
          <div class="relative w-14 h-14 mx-auto">
            <svg viewBox="0 0 120 120" class="w-full h-full -rotate-90">
              <circle cx="60" cy="60" r="50" fill="none" stroke="rgba(255,255,255,0.06)" stroke-width="8" />
              <circle cx="60" cy="60" r="50" fill="none" stroke="#a855f7" stroke-width="8"
                      stroke-dasharray={2 * Math.PI * 50} stroke-dashoffset={2 * Math.PI * 50 * (1 - proPct)}
                      stroke-linecap="round" />
            </svg>
            <div class="absolute inset-0 flex items-center justify-center">
              <span class="text-[10px] font-bold text-white">{Math.round(t.protein)}g</span>
            </div>
          </div>
          <p class="text-[9px] text-zinc-500 mt-0.5">Protein</p>
        </div>
        <!-- Carbs bar -->
        <div class="flex flex-col items-center justify-center">
          <span class="text-xs font-semibold text-white">{Math.round(t.carbs)}g</span>
          <div class="w-full h-1.5 bg-zinc-800 rounded-full mt-1">
            <div class="h-full bg-emerald-500 rounded-full" style="width: {g.carbs > 0 ? Math.min(t.carbs / g.carbs * 100, 100) : 0}%"></div>
          </div>
          <p class="text-[9px] text-zinc-500 mt-0.5">Carbs</p>
        </div>
        <!-- Fat bar -->
        <div class="flex flex-col items-center justify-center">
          <span class="text-xs font-semibold text-white">{Math.round(t.fat)}g</span>
          <div class="w-full h-1.5 bg-zinc-800 rounded-full mt-1">
            <div class="h-full bg-amber-500 rounded-full" style="width: {g.fat > 0 ? Math.min(t.fat / g.fat * 100, 100) : 0}%"></div>
          </div>
          <p class="text-[9px] text-zinc-500 mt-0.5">Fat</p>
        </div>
      </div>
    </a>
  {/if}

  <!-- ── Insights ─────────────────────────────────────────────────────── -->
  {#if insights.length > 0}
    <div class="space-y-1.5">
      {#each insights as insight}
        <div class="flex items-center gap-2.5 px-3 py-2 rounded-xl transition-colors
                    {insight.type === 'success' ? 'bg-green-500/10' : insight.type === 'warning' ? 'bg-amber-500/10' : 'bg-zinc-800/60'}">
          <span class="text-base shrink-0">{insight.icon}</span>
          <p class="text-xs text-zinc-300">{insight.text}</p>
        </div>
      {/each}
    </div>
  {/if}

  <!-- ── Next / Active workout hero ─────────────────────────────────── -->
  {#if $currentSession}
    <a href="/workout/active"
       class="block rounded-2xl overflow-hidden border border-primary-500/40 hover:border-primary-400/60 transition-all group"
       style="background: linear-gradient(135deg, rgba(37,99,235,0.2), rgba(139,92,246,0.1));">
      <div class="p-5 flex items-center justify-between gap-4">
        <div>
          <p class="text-xs font-bold uppercase tracking-widest text-primary-400 mb-1">▶ In Progress</p>
          <h3 class="text-xl font-bold text-white">{$currentSession.name ?? 'Active Workout'}</h3>
          <p class="text-sm text-zinc-400 mt-1">Tap to continue</p>
        </div>
        <div class="w-14 h-14 rounded-2xl bg-primary-600/30 border border-primary-500/40
                    flex items-center justify-center text-2xl shrink-0
                    group-hover:bg-primary-600/50 transition-colors">🏋️</div>
      </div>
    </a>

  {:else if loading}
    <div class="card h-28 animate-pulse bg-zinc-800/50"></div>

  {:else if nextWorkout?.isComplete}
    <div class="card border border-amber-500/30"
         style="background: linear-gradient(135deg, rgba(217,119,6,0.15), rgba(0,0,0,0));">
      <div class="flex items-start justify-between gap-4">
        <div>
          <p class="text-xs font-bold uppercase tracking-widest text-amber-400 mb-1">Program Complete 🏆</p>
          <h3 class="text-xl font-bold truncate">{nextWorkout.plan.name}</h3>
          <p class="text-sm text-zinc-400 mt-1">
            All {nextWorkout.plan.duration_weeks} weeks done. What's next?
          </p>
        </div>
        <span class="text-4xl shrink-0">🏆</span>
      </div>
      <div class="flex gap-3 mt-4">
        <button onclick={() => handleArchive(nextWorkout!.plan.id)} disabled={archiving}
                class="btn-primary flex-1 text-sm !py-2">
          {archiving ? 'Archiving…' : 'Archive & Start New'}
        </button>
        <a href="/workout/active?plan={nextWorkout.plan.id}&day={nextWorkout.day.day_number}"
           class="btn-secondary flex-1 text-sm !py-2 text-center">Keep Going</a>
      </div>
    </div>

  {:else if nextWorkout}
    <a href="/workout/active?plan={nextWorkout.plan.id}&day={nextWorkout.day.day_number}"
       class="block rounded-2xl overflow-hidden border border-primary-600/30 hover:border-primary-500/50 transition-all group"
       style="background: linear-gradient(135deg, rgba(37,99,235,0.15), rgba(0,0,0,0));">
      <div class="p-5 flex items-center justify-between gap-4">
        <div class="min-w-0">
          <p class="text-xs font-bold uppercase tracking-widest text-primary-400 mb-1">
            Next · {nextWorkout.plan.name}
          </p>
          <h3 class="text-2xl font-bold truncate">{nextWorkout.day.day_name}</h3>
          <div class="flex items-center gap-2 mt-2 flex-wrap">
            <span class="badge bg-primary-900/60 text-primary-300 border border-primary-700/50">
              Week {nextWorkout.weekNumber}
            </span>
            <span class="badge bg-zinc-800 text-zinc-300">
              Day {nextWorkout.dayNumber}
            </span>
            <span class="text-xs text-zinc-500">
              {nextWorkout.day.exercises.length} exercise{nextWorkout.day.exercises.length !== 1 ? 's' : ''}
            </span>
          </div>
        </div>
        <div class="w-14 h-14 rounded-2xl bg-primary-600/20 border border-primary-600/30
                    flex items-center justify-center text-2xl shrink-0
                    group-hover:bg-primary-600/40 transition-colors">🏋️</div>
      </div>
    </a>

  {:else}
    <div class="card border-2 border-dashed border-zinc-700 text-center py-10">
      <p class="text-4xl mb-3">💪</p>
      <p class="text-zinc-400 mb-4">Create a plan to get started.</p>
      <a href="/plans/create" class="btn-primary">Create a Plan</a>
    </div>
  {/if}

  <!-- ── Quick link to Plans ────────────────────────────────────────── -->
  <a href="/plans" class="card !p-4 flex items-center gap-3 hover:bg-zinc-800/80 transition-colors group">
    <span class="text-2xl">📋</span>
    <div class="flex-1">
      <p class="text-sm font-semibold text-zinc-200 group-hover:text-primary-400 transition-colors">Manage Plans</p>
      <p class="text-xs text-zinc-500">Create, edit, and archive workout plans</p>
    </div>
    <span class="text-zinc-600 text-sm">›</span>
  </a>

  <!-- ── Calendar ────────────────────────────────────────────────────── -->
  <div class="card">
    <div class="flex items-center justify-between mb-4">
      <h3 class="font-semibold text-zinc-200">Workout History</h3>
      <div class="flex items-center gap-2">
        <button onclick={prevMonth}
                class="w-8 h-8 rounded-lg bg-zinc-800 hover:bg-zinc-700 flex items-center justify-center text-sm transition-colors">←</button>
        <span class="text-sm font-medium text-zinc-300 w-32 text-center">{monthLabel}</span>
        <button onclick={nextMonth}
                disabled={calYear === today.getFullYear() && calMonth === today.getMonth()}
                class="w-8 h-8 rounded-lg bg-zinc-800 hover:bg-zinc-700 flex items-center justify-center text-sm transition-colors disabled:opacity-30">→</button>
      </div>
    </div>

    <div class="grid grid-cols-7 mb-1">
      {#each DAYS as d}
        <div class="text-center text-xs text-zinc-600 py-1">{d}</div>
      {/each}
    </div>

    <div class="grid grid-cols-7 gap-1">
      {#each { length: firstDayOfMonth } as _}<div></div>{/each}

      {#each { length: daysInMonth } as _, i}
        {@const day = i + 1}
        {@const key = dayKey(calYear, calMonth, day)}
        {@const hits = sessionsByDate[key] ?? []}
        {@const isToday = key === todayStr}
        {@const isSelected = key === selectedDay}
        {@const hasWorkout = hits.some(s => s.status === 'completed')}

        <button onclick={() => hasWorkout && (selectedDay = selectedDay === key ? null : key)}
                class="aspect-square rounded-xl flex flex-col items-center justify-center gap-0.5 text-xs transition-all
                       {isToday ? 'ring-1 ring-primary-500' : ''}
                       {isSelected ? 'bg-primary-700/60' : hasWorkout ? 'bg-zinc-800 hover:bg-zinc-700 cursor-pointer' : 'cursor-default opacity-35'}">
          <span class="{isToday ? 'text-primary-400 font-bold' : 'text-zinc-300'}">{day}</span>
          {#if hasWorkout}
            <div class="w-1 h-1 rounded-full {isSelected ? 'bg-primary-300' : 'bg-green-500'}"></div>
          {/if}
        </button>
      {/each}
    </div>

    {#if selectedDay && sessionsByDate[selectedDay]}
      <div class="mt-4 pt-4 border-t border-zinc-800 space-y-2">
        <p class="text-xs text-zinc-500 uppercase tracking-wider font-medium">{fmtDate(selectedDay)}</p>
        {#each sessionsByDate[selectedDay].filter(s => s.status === 'completed') as s}
          <div class="flex items-center justify-between bg-zinc-800/60 rounded-xl px-4 py-3">
            <div>
              <p class="font-medium text-sm">{s.name ?? 'Workout'}</p>
              <p class="text-xs text-zinc-500 mt-0.5">{s.total_sets} sets · {s.total_reps} reps</p>
            </div>
            <div class="text-right">
              <p class="text-sm font-semibold text-primary-400">{s.total_volume_kg?.toFixed(0)} kg</p>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- ── Recent sessions ─────────────────────────────────────────────── -->
  {#if recentSessions.length > 0}
    <div class="card">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-zinc-200">Recent Workouts</h3>
        <a href="/progress" class="text-xs text-primary-400 hover:text-primary-300 transition-colors">
          View Progress →
        </a>
      </div>
      <div class="space-y-1">
        {#each recentSessions as s}
          <div class="flex items-center justify-between py-3 border-b border-zinc-800/60 last:border-0">
            <div>
              <p class="text-sm font-medium text-zinc-200">{s.name ?? 'Workout'}</p>
              <p class="text-xs text-zinc-500 mt-0.5">{fmtDate(s.date)}</p>
            </div>
            <div class="text-right shrink-0 ml-4">
              <p class="text-sm font-semibold text-primary-400">{s.total_sets} sets</p>
              <p class="text-xs text-zinc-500">{s.total_volume_kg?.toFixed(0)} kg</p>
            </div>
          </div>
        {/each}
      </div>
    </div>
  {/if}


</div>
