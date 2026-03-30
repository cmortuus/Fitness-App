<script lang="ts">
  import { onMount } from 'svelte';
  import { activeDietPhase, currentSession, settings, workoutPlans, nextWorkoutUrl } from '$lib/stores';
  import type { DashboardWidget } from '$lib/stores';
  import { getSessions, archivePlan, getPlans, getDailySummary, getInsights, saveSettings } from '$lib/api';
  import type { DailySummary, Insight, WorkoutPlan, PlannedDay, WorkoutSession } from '$lib/api';

  const KG_TO_LBS = 2.20462;
  function volDisplay(kg: number): number {
    return $settings.weightUnit === 'lbs' ? kg * KG_TO_LBS : kg;
  }
  function volUnit(): string {
    return $settings.weightUnit === 'lbs' ? 'lbs' : 'kg';
  }

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
        s.status === 'completed' &&
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

  // Week view: last 7 days
  let weekDays = $derived((() => {
    const days: { key: string; label: string; dayNum: number; isToday: boolean }[] = [];
    for (let i = 6; i >= 0; i--) {
      const d = new Date();
      d.setDate(d.getDate() - i);
      days.push({
        key: isoDate(d),
        label: d.toLocaleDateString('en-US', { weekday: 'short' }),
        dayNum: d.getDate(),
        isToday: i === 0,
      });
    }
    return days;
  })());

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
      .reduce((sum, s) => sum + volDisplay(s.total_volume_kg ?? 0), 0);
  })());

  let weeklyWorkouts = $derived((() => {
    const weekAgo = new Date(); weekAgo.setDate(weekAgo.getDate() - 7);
    return allSessions.filter(s => s.date >= isoDate(weekAgo) && s.status === 'completed').length;
  })());

  // Streak: consecutive completed sessions without a skip/miss
  // Counts backwards from the most recent session
  let streak = $derived((() => {
    const sorted = [...allSessions]
      .filter(s => s.status === 'completed' || s.status === 'skipped')
      .sort((a, b) => b.date.localeCompare(a.date));
    let count = 0;
    for (const s of sorted) {
      if (s.status === 'completed') count++;
      else break; // skipped session breaks the streak
    }
    return count;
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

  // Last completed session with a plan — for "Repeat Last" button
  // ── Dashboard customization (Apple-style widget editing) ─────────────
  let editMode = $state(false);
  let showAddPanel = $state(false);

  const REQUIRED_WIDGETS = new Set(['nextWorkout', 'plans']);

  const WIDGET_LABELS: Record<string, string> = {
    stats: 'Quick Stats',
    nextWorkout: 'Next Workout',
    nutrition: 'Nutrition',
    insights: 'Insights',
    calendar: 'Calendar',
    recentSessions: 'Recent Workouts',
    plans: 'Manage Plans',
    repeatLast: 'Repeat Last Workout',
    weekView: 'Week View',
    calculator: '1RM Calculator',
    pinnedCharts: 'Quick Charts',
    trainingLog: 'Training Log',
  };

  // ── Inline calculator state ────────────────────────────────────────
  let calcWeight = $state<number | null>(null);
  let calcReps = $state<number | null>(null);
  let calcResult = $derived(
    calcWeight && calcReps && calcReps > 0
      ? Math.round(calcWeight * (1 + calcReps / 30))
      : null
  );

  function removeWidget(id: string) {
    if (REQUIRED_WIDGETS.has(id)) return;
    const widgets = [...($settings.dashboardWidgets ?? [])];
    const idx = widgets.findIndex(w => w.id === id);
    if (idx >= 0) {
      widgets[idx] = { ...widgets[idx], enabled: false };
      settings.update(s => ({ ...s, dashboardWidgets: widgets }));
    }
  }

  function addWidget(id: string) {
    const widgets = [...($settings.dashboardWidgets ?? [])];
    const idx = widgets.findIndex(w => w.id === id);
    if (idx >= 0) {
      widgets[idx] = { ...widgets[idx], enabled: true };
      settings.update(s => ({ ...s, dashboardWidgets: widgets }));
    }
    showAddPanel = false;
  }

  let orderedWidgets = $derived($settings.dashboardWidgets ?? []);
  let hiddenWidgets = $derived(orderedWidgets.filter(w => !w.enabled && !REQUIRED_WIDGETS.has(w.id)));

  // Long-press to enter edit mode
  let longPressTimer: ReturnType<typeof setTimeout> | null = null;

  let longPressTriggered = false;

  function handleLongPressStart(e: TouchEvent) {
    // Don't trigger on form elements
    const tag = (e.target as HTMLElement).tagName;
    if (['INPUT', 'SELECT'].includes(tag)) return;
    if ((e.target as HTMLElement).closest('input, select')) return;
    if (editMode) return;

    longPressTriggered = false;
    longPressTimer = setTimeout(() => {
      longPressTriggered = true;
      editMode = true;
      if (navigator.vibrate) navigator.vibrate(50);
    }, 500);
  }

  function handlePointerDown(e: PointerEvent) {
    // Desktop fallback — touch devices use handleTouchStart
    if (e.pointerType === 'touch') return; // handled by touchstart
    const tag = (e.target as HTMLElement).tagName;
    if (['INPUT', 'SELECT'].includes(tag)) return;
    if (editMode) return;

    longPressTriggered = false;
    longPressTimer = setTimeout(() => {
      longPressTriggered = true;
      editMode = true;
    }, 500);
  }

  function handlePointerUp() {
    if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null; }
  }

  // ── Drag-to-reorder ────────────────────────────────────────────────
  let dragWidgetId = $state<string | null>(null);
  let dragOverWidgetId = $state<string | null>(null);

  function handleDragStart(e: DragEvent, widgetId: string) {
    if (!editMode) return;
    dragWidgetId = widgetId;
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', widgetId);
    }
  }

  function handleDragOver(e: DragEvent, widgetId: string) {
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
    dragOverWidgetId = widgetId;
  }

  function handleDragLeave() {
    dragOverWidgetId = null;
  }

  function handleDrop(e: DragEvent, targetId: string) {
    e.preventDefault();
    dragOverWidgetId = null;
    if (!dragWidgetId || dragWidgetId === targetId) { dragWidgetId = null; return; }

    const widgets = [...($settings.dashboardWidgets ?? [])];
    const fromIdx = widgets.findIndex(w => w.id === dragWidgetId);
    const toIdx = widgets.findIndex(w => w.id === targetId);
    if (fromIdx < 0 || toIdx < 0) { dragWidgetId = null; return; }

    const [moved] = widgets.splice(fromIdx, 1);
    widgets.splice(toIdx, 0, moved);
    settings.update(s => ({ ...s, dashboardWidgets: widgets }));
    dragWidgetId = null;
  }

  function handleDragEnd() {
    dragWidgetId = null;
    dragOverWidgetId = null;
  }

  // Touch drag (mobile)
  let touchDragId = $state<string | null>(null);
  let touchStartY = $state(0);
  let touchDragEl: HTMLElement | null = null;

  function handleTouchStart(e: TouchEvent, widgetId: string) {
    if (!editMode) return;
    touchDragId = widgetId;
    touchStartY = e.touches[0].clientY;
    touchDragEl = (e.currentTarget as HTMLElement);
    touchDragEl.style.zIndex = '50';
    touchDragEl.style.opacity = '0.8';
  }

  function handleTouchMove(e: TouchEvent) {
    if (!touchDragId || !touchDragEl) return;
    e.preventDefault();
    const dy = e.touches[0].clientY - touchStartY;
    touchDragEl.style.transform = `translateY(${dy}px)`;

    // Find which widget we're over
    const els = document.querySelectorAll('[data-widget-id]');
    const touchY = e.touches[0].clientY;
    for (const el of els) {
      const rect = el.getBoundingClientRect();
      if (touchY > rect.top && touchY < rect.bottom && el.getAttribute('data-widget-id') !== touchDragId) {
        dragOverWidgetId = el.getAttribute('data-widget-id');
        break;
      }
    }
  }

  function handleTouchEnd() {
    if (touchDragEl) {
      touchDragEl.style.zIndex = '';
      touchDragEl.style.opacity = '';
      touchDragEl.style.transform = '';
    }
    if (touchDragId && dragOverWidgetId) {
      // Reorder
      const widgets = [...($settings.dashboardWidgets ?? [])];
      const fromIdx = widgets.findIndex(w => w.id === touchDragId);
      const toIdx = widgets.findIndex(w => w.id === dragOverWidgetId);
      if (fromIdx >= 0 && toIdx >= 0) {
        const [moved] = widgets.splice(fromIdx, 1);
        widgets.splice(toIdx, 0, moved);
        settings.update(s => ({ ...s, dashboardWidgets: widgets }));
      }
    }
    touchDragId = null;
    dragOverWidgetId = null;
    touchDragEl = null;
  }

  let lastWorkout = $derived((() => {
    const last = allSessions.find(s => s.status === 'completed' && s.workout_plan_id);
    if (!last) return null;
    const plan = $workoutPlans.find(p => p.id === last.workout_plan_id);
    if (!plan) return null;
    // Find which day this was
    const dayName = last.name?.split(' - ').pop() ?? '';
    const day = plan.days.find(d => last.name?.includes(d.day_name)) ?? plan.days[0];
    return { plan, day, session: last };
  })());
</script>

<div class="page-content space-y-5 {editMode ? 'edit-mode' : ''}"
     ontouchstart={(e) => handleLongPressStart(e)}
     onpointerdown={handlePointerDown}
     onpointerup={handlePointerUp}
     onpointercancel={handlePointerUp}
     onclick={(e) => { if (longPressTriggered) { e.preventDefault(); e.stopPropagation(); longPressTriggered = false; } }}
     oncontextmenu={(e) => e.preventDefault()}
     ontouchmove={(e) => { handleTouchMove(e); if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null; } }}
     ontouchend={() => { handleTouchEnd(); if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null; } }}>

  <!-- ── Edit mode header ──────────────────────────────────────────── -->
  {#if editMode}
    <div class="flex items-center justify-between sticky top-0 z-40 bg-zinc-950/95 backdrop-blur-sm py-2 -mx-4 px-4 border-b border-zinc-800">
      <span class="text-sm font-semibold text-zinc-300">Editing Dashboard</span>
      <div class="flex items-center gap-3">
        {#if hiddenWidgets.length > 0}
          <button onclick={() => showAddPanel = !showAddPanel}
                  class="w-8 h-8 rounded-full bg-primary-600 text-white flex items-center justify-center text-lg font-bold hover:bg-primary-500 transition-colors">+</button>
        {/if}
        <button onclick={() => { editMode = false; showAddPanel = false; }}
                class="text-sm font-semibold text-primary-400 hover:text-primary-300 transition-colors">Done</button>
      </div>
    </div>

    <!-- Add widget panel -->
    {#if showAddPanel && hiddenWidgets.length > 0}
      <div class="card border border-zinc-700 add-widget-panel">
        <p class="text-xs text-zinc-500 mb-2">Add widgets</p>
        <div class="space-y-1">
          {#each hiddenWidgets as widget}
            <button onclick={() => addWidget(widget.id)}
                    class="w-full flex items-center gap-2 px-3 py-2 rounded-lg bg-zinc-800/50 hover:bg-zinc-700 transition-colors text-left">
              <span class="text-green-400 text-lg">+</span>
              <span class="text-sm text-zinc-300">{WIDGET_LABELS[widget.id] ?? widget.id}</span>
            </button>
          {/each}
        </div>
      </div>
    {/if}
  {/if}

  <!-- ── Widgets rendered in user-defined order ────────────────────── -->
  {#each orderedWidgets.filter(w => w.enabled || REQUIRED_WIDGETS.has(w.id)) as widget (widget.id)}
  <div class="widget-wrapper {editMode ? 'jiggle' : ''} {dragOverWidgetId === widget.id ? 'drag-over' : ''} relative"
       data-widget-id={widget.id}
       draggable={editMode ? 'true' : 'false'}
       ondragstart={(e) => handleDragStart(e, widget.id)}
       ondragover={(e) => handleDragOver(e, widget.id)}
       ondragleave={handleDragLeave}
       ondrop={(e) => handleDrop(e, widget.id)}
       ondragend={handleDragEnd}
       ontouchstart={(e) => handleTouchStart(e, widget.id)}>

    <!-- Remove button (edit mode only) -->
    {#if editMode && !REQUIRED_WIDGETS.has(widget.id)}
      <button onclick={() => removeWidget(widget.id)}
              class="absolute -top-2 -left-2 z-10 w-6 h-6 rounded-full bg-red-500 text-white text-xs font-bold
                     flex items-center justify-center shadow-lg hover:bg-red-400 transition-colors">−</button>
    {/if}

  {#if widget.id === 'stats'}
  <!-- ── Quick stats strip ───────────────────────────────────────────── -->
  {#if !loading && allSessions.length > 0}
    <div class="grid grid-cols-4 gap-2">
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-primary-400">{weeklyWorkouts}</p>
        <p class="text-xs text-zinc-500 mt-0.5">workouts</p>
      </div>
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-green-400">{weeklySets.completed}</p>
        <p class="text-xs text-zinc-500 mt-0.5">sets</p>
      </div>
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-accent-400">
          {weeklyVolume > 999 ? (weeklyVolume / 1000).toFixed(1) + 'k' : weeklyVolume.toFixed(0)}
        </p>
        <p class="text-xs text-zinc-500 mt-0.5">{volUnit()}</p>
      </div>
      <div class="card text-center py-3">
        <p class="text-2xl font-bold text-amber-400">{streak}</p>
        <p class="text-xs text-zinc-500 mt-0.5">streak</p>
      </div>
    </div>
  {/if}

  {:else if widget.id === 'nutrition'}
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

  {:else if widget.id === 'insights'}
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

  {:else if widget.id === 'nextWorkout'}
  <!-- ── Next / Active workout hero ─────────────────────────────────── -->
  {#if $currentSession}
    <a href="/workout/active"
       class="block rounded-2xl overflow-hidden border border-primary-500/40 hover:border-primary-400/60 transition-all group"
       style="background: linear-gradient(135deg, rgba(37,99,235,0.2), rgba(139,92,246,0.1));">
      <div class="p-5 flex items-center justify-between gap-4">
        <div>
          <p class="text-xs font-bold uppercase tracking-widest text-primary-400 mb-1">▶ Continue Workout</p>
          <h3 class="text-xl font-bold text-white">{$currentSession.name ?? 'Workout'}</h3>
          <p class="text-sm text-zinc-400 mt-1">Resume where you left off</p>
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
          <p class="text-xs font-bold uppercase tracking-widest text-amber-400 mb-1">Mesocycle Complete 🏆</p>
          <h3 class="text-xl font-bold truncate">{nextWorkout.plan.name}</h3>
          <p class="text-sm text-zinc-400 mt-1">
            All {nextWorkout.plan.duration_weeks} weeks done!
          </p>
        </div>
        <span class="text-4xl shrink-0">🏆</span>
      </div>

      <!-- Deload recommendation -->
      <div class="mt-3 px-3 py-2.5 rounded-xl bg-blue-500/10 border border-blue-500/20">
        <p class="text-xs text-blue-300 font-medium mb-1">Deload week recommended</p>
        <p class="text-[11px] text-zinc-400">A recovery week with reduced volume (~60%) and intensity (~70%) helps consolidate gains before your next cycle.</p>
      </div>

      <div class="flex flex-col gap-2 mt-4">
        <a href="/workout/active?plan={nextWorkout.plan.id}&day=1&deload=true"
           class="btn-primary text-sm !py-2.5 text-center">Start Deload Week</a>
        <div class="flex gap-2">
          <a href="/workout/active?plan={nextWorkout.plan.id}&day={nextWorkout.day.day_number}"
             class="btn-secondary flex-1 text-sm !py-2 text-center">Skip Deload</a>
          <button onclick={() => handleArchive(nextWorkout!.plan.id)} disabled={archiving}
                  class="flex-1 text-sm py-2 rounded-lg bg-zinc-800 text-zinc-400 hover:bg-zinc-700 transition-colors">
            {archiving ? 'Archiving…' : 'Archive'}
          </button>
        </div>
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

  {/if}

  {#if !nextWorkout && !$currentSession}
    <div class="card border-2 border-dashed border-zinc-700 text-center py-10">
      <p class="text-4xl mb-3">💪</p>
      <p class="text-zinc-400 mb-4">Create a plan to get started.</p>
      <a href="/plans/create" class="btn-primary">Create a Plan</a>
    </div>
  {/if}

  {:else if widget.id === 'repeatLast'}
  <!-- ── Repeat last workout ───────────────────────────────────────── -->
  {#if lastWorkout && !$currentSession}
    <button
      onclick={() => window.location.href = `/workout/active?plan=${lastWorkout!.plan.id}&day=${lastWorkout!.day.day_number}`}
      class="w-full text-left px-4 py-3 rounded-xl bg-zinc-800/60 hover:bg-zinc-800 border border-zinc-700/50 transition-colors">
      <div class="flex items-center justify-between">
        <div>
          <p class="text-[10px] text-zinc-500 uppercase tracking-wider">Repeat Last</p>
          <p class="text-sm font-medium text-zinc-300">{lastWorkout.session.name}</p>
        </div>
        <span class="text-zinc-600">→</span>
      </div>
    </button>
  {/if}

  {:else if widget.id === 'plans'}
  <!-- ── Quick link to Plans ────────────────────────────────────────── -->
  <a href="/plans" class="card !p-4 flex items-center gap-3 hover:bg-zinc-800/80 transition-colors group">
    <span class="text-2xl">📋</span>
    <div class="flex-1">
      <p class="text-sm font-semibold text-zinc-200 group-hover:text-primary-400 transition-colors">Manage Plans</p>
      <p class="text-xs text-zinc-500">Create, edit, and archive workout plans</p>
    </div>
    <span class="text-zinc-600 text-sm">›</span>
  </a>

  {:else if widget.id === 'weekView'}
  <!-- ── 7-Day Week View ───────────────────────────────────────────── -->
  <div class="card !py-3">
    <div class="flex items-center justify-between mb-2">
      <h3 class="font-semibold text-zinc-200 text-sm">This Week</h3>
      <a href="/calendar" class="text-xs text-primary-400 hover:text-primary-300 transition-colors">Full Calendar →</a>
    </div>
    <div class="grid grid-cols-7 gap-1">
      {#each weekDays as day}
        {@const hits = (sessionsByDate[day.key] ?? []).filter(s => s.status === 'completed')}
        {@const hasWorkout = hits.length > 0}
        <div class="flex flex-col items-center gap-0.5 py-1.5 rounded-lg {day.isToday ? 'ring-1 ring-primary-500 bg-primary-500/10' : hasWorkout ? 'bg-zinc-800/60' : ''}">
          <span class="text-[10px] text-zinc-500">{day.label}</span>
          <span class="text-sm font-medium {day.isToday ? 'text-primary-400' : hasWorkout ? 'text-white' : 'text-zinc-600'}">{day.dayNum}</span>
          {#if hasWorkout}
            <div class="w-1.5 h-1.5 rounded-full bg-green-500"></div>
          {:else if day.isToday}
            <div class="w-1.5 h-1.5 rounded-full bg-primary-500/30"></div>
          {:else}
            <div class="w-1.5 h-1.5"></div>
          {/if}
        </div>
      {/each}
    </div>
  </div>

  {:else if widget.id === 'calendar'}
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
              <p class="text-sm font-semibold text-primary-400">{volDisplay(s.total_volume_kg ?? 0).toFixed(0)} {volUnit()}</p>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  {:else if widget.id === 'calculator'}
  <!-- ── Inline 1RM Calculator ─────────────────────────────────────── -->
  <div class="card">
    <div class="flex items-center justify-between mb-2">
      <h3 class="font-semibold text-zinc-200 text-sm">1RM Calculator</h3>
      <a href="/calculator" class="text-xs text-primary-400 hover:text-primary-300 transition-colors">All Formulas →</a>
    </div>
    <div class="flex items-center gap-2">
      <input type="number" inputmode="decimal" bind:value={calcWeight}
             placeholder={$settings.weightUnit} min="1"
             class="input text-center text-sm flex-1 !py-1.5" style="font-size: 16px;" />
      <span class="text-zinc-500 text-xs">×</span>
      <input type="number" inputmode="numeric" bind:value={calcReps}
             placeholder="reps" min="1" max="30"
             class="input text-center text-sm w-16 !py-1.5" style="font-size: 16px;" />
      <span class="text-zinc-500 text-xs">=</span>
      <div class="text-center min-w-[60px]">
        {#if calcResult}
          <p class="text-lg font-bold text-primary-400">{calcResult}</p>
          <p class="text-[9px] text-zinc-500">{$settings.weightUnit}</p>
        {:else}
          <p class="text-sm text-zinc-600">—</p>
        {/if}
      </div>
    </div>
  </div>

  {:else if widget.id === 'pinnedCharts'}
  <!-- ── Pinned Charts ─────────────────────────────────────────────── -->
  <div class="card">
    <div class="flex items-center justify-between mb-3">
      <h3 class="font-semibold text-zinc-200">Quick Charts</h3>
      <a href="/progress" class="text-xs text-primary-400 hover:text-primary-300 transition-colors">
        Full Progress →
      </a>
    </div>
    <div class="grid grid-cols-2 gap-3">
      <a href="/body" class="bg-zinc-800/60 rounded-xl px-3 py-3 hover:bg-zinc-800 transition-colors">
        <p class="text-xs text-zinc-500">Body Weight</p>
        <p class="text-sm font-semibold text-primary-400 mt-0.5">Trend →</p>
      </a>
      <a href="/progress" class="bg-zinc-800/60 rounded-xl px-3 py-3 hover:bg-zinc-800 transition-colors">
        <p class="text-xs text-zinc-500">Est. 1RM</p>
        <p class="text-sm font-semibold text-green-400 mt-0.5">All Lifts →</p>
      </a>
      <a href="/volume" class="bg-zinc-800/60 rounded-xl px-3 py-3 hover:bg-zinc-800 transition-colors">
        <p class="text-xs text-zinc-500">Volume</p>
        <p class="text-sm font-semibold text-amber-400 mt-0.5">Weekly →</p>
      </a>
      <a href="/records" class="bg-zinc-800/60 rounded-xl px-3 py-3 hover:bg-zinc-800 transition-colors">
        <p class="text-xs text-zinc-500">Records</p>
        <p class="text-sm font-semibold text-purple-400 mt-0.5">PRs →</p>
      </a>
      <a href="/compare" class="bg-zinc-800/60 rounded-xl px-3 py-3 hover:bg-zinc-800 transition-colors">
        <p class="text-xs text-zinc-500">Compare</p>
        <p class="text-sm font-semibold text-cyan-400 mt-0.5">Side by Side →</p>
      </a>
      <a href="/calculator" class="bg-zinc-800/60 rounded-xl px-3 py-3 hover:bg-zinc-800 transition-colors">
        <p class="text-xs text-zinc-500">Calculator</p>
        <p class="text-sm font-semibold text-rose-400 mt-0.5">1RM →</p>
      </a>
    </div>
  </div>

  {:else if widget.id === 'trainingLog'}
  <!-- ── Training Log (streak + monthly stats) ─────────────────────── -->
  {#if !loading}
    <div class="card">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-zinc-200">Training Log</h3>
        <a href="/calendar" class="text-xs text-primary-400 hover:text-primary-300 transition-colors">Full Calendar →</a>
      </div>
      <div class="grid grid-cols-3 gap-3 mb-3">
        <div class="bg-zinc-800/50 rounded-lg px-3 py-2 text-center">
          <p class="text-xl font-bold text-primary-400">{streak}</p>
          <p class="text-[10px] text-zinc-500">Day Streak</p>
        </div>
        <div class="bg-zinc-800/50 rounded-lg px-3 py-2 text-center">
          <p class="text-xl font-bold text-green-400">{weeklyWorkouts}</p>
          <p class="text-[10px] text-zinc-500">This Week</p>
        </div>
        <div class="bg-zinc-800/50 rounded-lg px-3 py-2 text-center">
          <p class="text-xl font-bold text-amber-400">
            {weeklyVolume > 999 ? (weeklyVolume / 1000).toFixed(1) + 'k' : weeklyVolume.toFixed(0)}
          </p>
          <p class="text-[10px] text-zinc-500">{volUnit()} this wk</p>
        </div>
      </div>
      <!-- Last 5 workouts compact list -->
      {#if recentSessions.length > 0}
        <div class="space-y-1">
          {#each recentSessions.slice(0, 3) as s}
            <div class="flex items-center justify-between py-1.5 text-sm">
              <span class="text-zinc-300 truncate">{s.name ?? 'Workout'}</span>
              <span class="text-xs text-zinc-500 shrink-0 ml-2">{fmtDate(s.date)}</span>
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}

  {:else if widget.id === 'recentSessions'}
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
              <p class="text-xs text-zinc-500">{volDisplay(s.total_volume_kg ?? 0).toFixed(0)} {volUnit()}</p>
            </div>
          </div>
        {/each}
      </div>
    </div>
  {/if}

  {/if}
  </div>
  {/each}

</div>

<style>
  /* Apple-style jiggle animation — very subtle */
  @keyframes jiggle {
    0%, 100% { transform: rotate(-0.15deg); }
    50% { transform: rotate(0.15deg); }
  }
  :global(.jiggle) {
    animation: jiggle 0.3s ease-in-out infinite alternate;
  }
  :global(.jiggle:nth-child(even)) {
    animation-delay: 0.15s;
    animation-direction: alternate-reverse;
  }
  :global(.drag-over) {
    outline: 2px dashed rgba(59, 130, 246, 0.5);
    outline-offset: 4px;
    border-radius: 1rem;
  }
  :global(.edit-mode .widget-wrapper) {
    cursor: grab;
  }
  :global(.edit-mode .widget-wrapper:active) {
    cursor: grabbing;
  }
  /* Prevent iOS link preview on long-press (#282) */
  :global(.page-content) {
    -webkit-touch-callout: none;
  }
  :global(.edit-mode) {
    -webkit-user-select: none;
    user-select: none;
  }
  :global(.edit-mode a) {
    -webkit-touch-callout: none;
    pointer-events: none;
  }
  :global(.edit-mode button:not([class*="rounded-full"])) {
    pointer-events: none;
  }
  /* Re-enable the edit controls */
  :global(.edit-mode .widget-wrapper > button) {
    pointer-events: auto !important;
  }
  :global(.edit-mode [class*="sticky"] button) {
    pointer-events: auto !important;
  }
  :global(.edit-mode [class*="sticky"] a) {
    pointer-events: auto !important;
  }
  :global(.edit-mode .add-widget-panel button) {
    pointer-events: auto !important;
  }
</style>
