<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { workoutPlans, exercises, settings } from '$lib/stores';
  import { getPlans, deletePlan, getExercises, updatePlan, archivePlan, reusePlan, getTemplates, cloneTemplate, getSessions, updatePlanRirOverrides, getPlanRecommendations } from '$lib/api';
  import type { Exercise, WorkoutPlan, WorkoutTemplate, WorkoutSession, PlannedDay, PlanRirOverrides, PlanRecommendation } from '$lib/api';

  let avgSetDuration = $state(30); // seconds per set from history, default 30s

  let allExercises = $state<Exercise[]>([]);
  let localPlans   = $state<WorkoutPlan[]>([]);
  let errorMsg     = $state<string | null>(null);
  let expandedPlan = $state<number | null>(null);
  let expandedDays = $state<Record<string, boolean>>({});
  let rirPlan = $state<WorkoutPlan | null>(null);
  let rirOverridesDraft = $state<PlanRirOverrides>({ plan: null, muscles: {}, exercises: {} });
  let savingRir = $state(false);
  let showGlobalRirModal = $state(false);
  let globalRirDelta = $state<1 | 2>(1);
  let applyingGlobalRir = $state(false);
  let recommendationsByPlan = $state<Record<number, PlanRecommendation[]>>({});
  let loadingRecommendations = $state<Record<number, boolean>>({});
  let applyingRecommendation = $state<string | null>(null);

  // Templates
  let templates = $state<WorkoutTemplate[]>([]);
  let splitFilter = $state<string | null>(null);
  let equipFilter = $state<string | null>(null);
  let previewTmpl = $state<WorkoutTemplate | null>(null);
  let cloning = $state(false);

  const SPLITS = [
    { key: 'full_body', label: 'Full Body' },
    { key: 'upper_lower', label: 'Upper/Lower' },
    { key: 'ppl', label: 'PPL' },
    { key: 'bro_split', label: 'Bro Split' },
  ];
  const EQUIP = [
    { key: 'minimal', label: 'Minimal' },
    { key: 'home', label: 'Home Gym' },
    { key: 'standard', label: 'Standard' },
    { key: 'well_equipped', label: 'Well-Equipped' },
    { key: 'fully_loaded', label: 'Fully Loaded' },
  ];

  function showError(msg: string) {
    errorMsg = msg;
    setTimeout(() => { errorMsg = null; }, 5000);
  }

  onMount(async () => {
    try {
      const [plansData, exercisesData, tmplData] = await Promise.all([getPlans(), getExercises(), getTemplates()]);
      workoutPlans.set(plansData);
      exercises.set(exercisesData);
      allExercises = exercisesData;
      localPlans = JSON.parse(JSON.stringify(plansData));
      templates = tmplData;

      // Compute average set duration from recent completed sessions
      try {
        const sessions = await getSessions({ limit: 10 });
        const completed = sessions.filter((s: WorkoutSession) => s.started_at && s.completed_at);
        if (completed.length > 0) {
          let totalSets = 0;
          let totalDurSecs = 0;
          for (const s of completed) {
            const durMs = new Date(s.completed_at!).getTime() - new Date(s.started_at!).getTime();
            const sets = s.sets?.length ?? s.total_sets ?? 0;
            if (sets > 0 && durMs > 0) {
              totalSets += sets;
              totalDurSecs += durMs / 1000;
            }
          }
          if (totalSets > 0) {
            // This includes rest time, so it's "time per set including rest"
            avgSetDuration = Math.round(totalDurSecs / totalSets);
          }
        }
      } catch { /* history not available yet */ }
    } catch (error) {
      showError('Failed to load plans.');
      console.error('Failed to load data:', error);
    }
  });

  let activePlans   = $derived(localPlans.filter(p => !p.is_archived));
  let archivedPlans = $derived(localPlans.filter(p =>  p.is_archived));

  async function handleDeletePlan(planId: number) {
    if (!confirm('Delete this plan? This cannot be undone.')) return;
    try {
      await deletePlan(planId);
      const plansData = await getPlans();
      workoutPlans.set(plansData);
      localPlans = JSON.parse(JSON.stringify(plansData));
      if (expandedPlan === planId) expandedPlan = null;
    } catch (error) {
      showError('Failed to delete plan. It may be in use.');
    }
  }

  async function handleArchivePlan(planId: number) {
    try {
      await archivePlan(planId);
      const plansData = await getPlans();
      workoutPlans.set(plansData);
      localPlans = JSON.parse(JSON.stringify(plansData));
      expandedPlan = null;
    } catch { showError('Failed to archive plan.'); }
  }

  async function handleReusePlan(planId: number) {
    try {
      await reusePlan(planId);
      const plansData = await getPlans();
      workoutPlans.set(plansData);
      localPlans = JSON.parse(JSON.stringify(plansData));
    } catch { showError('Failed to copy plan.'); }
  }

  function getExerciseName(exerciseId: number): string {
    return allExercises.find(e => e.id === exerciseId)?.display_name || `Exercise ${exerciseId}`;
  }

  function getExercise(exerciseId: number): Exercise | undefined {
    return allExercises.find(e => e.id === exerciseId);
  }

  function cloneOverrides(overrides?: PlanRirOverrides | null): PlanRirOverrides {
    return {
      plan: overrides?.plan ?? null,
      muscles: { ...(overrides?.muscles ?? {}) },
      exercises: { ...(overrides?.exercises ?? {}) },
    };
  }

  function openRirModal(plan: WorkoutPlan) {
    rirPlan = plan;
    rirOverridesDraft = cloneOverrides(plan.rir_overrides);
  }

  function closeRirModal() {
    rirPlan = null;
    rirOverridesDraft = { plan: null, muscles: {}, exercises: {} };
  }

  function openGlobalRirModal() {
    globalRirDelta = 1;
    showGlobalRirModal = true;
  }

  function closeGlobalRirModal() {
    showGlobalRirModal = false;
  }

  function getPlanMuscles(plan: WorkoutPlan): string[] {
    const muscles = new Set<string>();
    for (const day of plan.days) {
      for (const ex of day.exercises) {
        const exercise = getExercise(ex.exercise_id);
        for (const muscle of exercise?.primary_muscles ?? []) {
          muscles.add(muscle);
        }
      }
    }
    return [...muscles].sort();
  }

  function getPlanExerciseRows(plan: WorkoutPlan): { id: number; name: string; muscles: string[] }[] {
    const seen = new Set<number>();
    const rows: { id: number; name: string; muscles: string[] }[] = [];
    for (const day of plan.days) {
      for (const ex of day.exercises) {
        if (seen.has(ex.exercise_id)) continue;
        seen.add(ex.exercise_id);
        const exercise = getExercise(ex.exercise_id);
        rows.push({
          id: ex.exercise_id,
          name: exercise?.display_name ?? `Exercise ${ex.exercise_id}`,
          muscles: exercise?.primary_muscles ?? [],
        });
      }
    }
    return rows.sort((a, b) => a.name.localeCompare(b.name));
  }

  function setDraftPlanRir(value: string) {
    rirOverridesDraft = { ...rirOverridesDraft, plan: value === '' ? null : Number(value) };
  }

  function setDraftMuscleRir(muscle: string, value: string) {
    const muscles = { ...rirOverridesDraft.muscles };
    if (value === '') delete muscles[muscle];
    else muscles[muscle] = Number(value);
    rirOverridesDraft = { ...rirOverridesDraft, muscles };
  }

  function setDraftExerciseRir(exerciseId: number, value: string) {
    const exercises = { ...rirOverridesDraft.exercises };
    const key = String(exerciseId);
    if (value === '') delete exercises[key];
    else exercises[key] = Number(value);
    rirOverridesDraft = { ...rirOverridesDraft, exercises };
  }

  async function saveRirOverrides() {
    if (!rirPlan) return;
    savingRir = true;
    try {
      const updated = await updatePlanRirOverrides(rirPlan.id, rirOverridesDraft);
      localPlans = localPlans.map(plan => plan.id === updated.id ? updated : plan);
      workoutPlans.set(localPlans);
      closeRirModal();
    } catch (error) {
      showError('Failed to save RIR overrides.');
    } finally {
      savingRir = false;
    }
  }

  async function applyGlobalRirBackoff() {
    if (activePlans.length === 0) return;
    applyingGlobalRir = true;
    try {
      const updatedPlans = await Promise.all(
        activePlans.map(async (plan) => {
          const currentPlanRir = plan.rir_overrides?.plan ?? 0;
          const nextPlanRir = Math.min(5, Math.max(0, currentPlanRir + globalRirDelta));
          return updatePlanRirOverrides(plan.id, {
            plan: nextPlanRir,
            muscles: { ...(plan.rir_overrides?.muscles ?? {}) },
            exercises: { ...(plan.rir_overrides?.exercises ?? {}) },
          });
        })
      );

      const updatedById = new Map(updatedPlans.map((plan) => [plan.id, plan]));
      localPlans = localPlans.map((plan) => updatedById.get(plan.id) ?? plan);
      workoutPlans.set(localPlans);
      closeGlobalRirModal();
    } catch (error) {
      showError('Failed to apply the global RIR backoff.');
    } finally {
      applyingGlobalRir = false;
    }
  }

  let filteredTemplates = $derived(
    templates.filter(t => {
      if (splitFilter && t.split_type !== splitFilter) return false;
      if (equipFilter && t.equipment_tier !== equipFilter) return false;
      return true;
    })
  );

  async function handleClone(tmpl: WorkoutTemplate) {
    cloning = true;
    try {
      await cloneTemplate(tmpl.id);
      previewTmpl = null;
      const plansData = await getPlans();
      workoutPlans.set(plansData);
      localPlans = JSON.parse(JSON.stringify(plansData));
    } catch { showError('Failed to import template.'); }
    cloning = false;
  }

  function totalExercises(plan: WorkoutPlan): number {
    return plan.days.reduce((sum, d) => sum + d.exercises.length, 0);
  }

  /** Estimate workout duration for a given day in minutes */
  function estimateDayMinutes(day: PlannedDay): number {
    const rd = $settings.restDurations;
    let totalSecs = 0;
    for (const ex of day.exercises) {
      const exercise = allExercises.find(e => e.id === ex.exercise_id);
      const isCompound = exercise?.movement_type === 'compound';
      const isUpper = exercise?.body_region === 'upper';
      // Pick rest duration based on exercise type
      let restSec: number;
      if (isCompound) {
        restSec = isUpper ? rd.upperCompound : rd.lowerCompound;
      } else {
        restSec = isUpper ? rd.upperIsolation : rd.lowerIsolation;
      }
      const sets = ex.sets ?? 3;
      // Each set: time to perform + rest (no rest after last set)
      totalSecs += sets * avgSetDuration + (sets - 1) * restSec;
    }
    return Math.round(totalSecs / 60);
  }

  function formatDuration(mins: number): string {
    if (mins < 60) return `~${mins}m`;
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return m > 0 ? `~${h}h ${m}m` : `~${h}h`;
  }

  function togglePlan(planId: number) {
    expandedPlan = expandedPlan === planId ? null : planId;
    if (expandedPlan === planId) return;
    void loadRecommendations(planId);
  }

  function toggleDay(planId: number, dayNum: number) {
    const key = `${planId}-${dayNum}`;
    expandedDays = { ...expandedDays, [key]: !expandedDays[key] };
  }

  function isDayExpanded(planId: number, dayNum: number): boolean {
    return !!expandedDays[`${planId}-${dayNum}`];
  }

  async function loadRecommendations(planId: number) {
    if (recommendationsByPlan[planId] || loadingRecommendations[planId]) return;
    loadingRecommendations = { ...loadingRecommendations, [planId]: true };
    try {
      const recs = await getPlanRecommendations(planId);
      recommendationsByPlan = { ...recommendationsByPlan, [planId]: recs };
    } catch {
      showError('Failed to load plan recommendations.');
    } finally {
      loadingRecommendations = { ...loadingRecommendations, [planId]: false };
    }
  }

  async function applyRecommendation(plan: WorkoutPlan, recommendation: PlanRecommendation) {
    const applyKey = `${plan.id}-${recommendation.exercise_id}`;
    applyingRecommendation = applyKey;
    try {
      const nextOverrides = cloneOverrides(plan.rir_overrides);
      nextOverrides.exercises[String(recommendation.exercise_id)] = recommendation.recommended_rir;
      let nextPlan = await updatePlanRirOverrides(plan.id, nextOverrides);

      if (recommendation.add_set && recommendation.set_delta > 0) {
        const nextDays = nextPlan.days.map(day => ({
          ...day,
          exercises: day.exercises.map(ex => ex.exercise_id === recommendation.exercise_id
            ? { ...ex, sets: Math.min((ex.sets ?? 1) + recommendation.set_delta, 12) }
            : ex
          ),
        }));
        nextPlan = await updatePlan(plan.id, { days: nextDays, number_of_days: nextPlan.number_of_days });
      }

      localPlans = localPlans.map(existing => existing.id === nextPlan.id ? nextPlan : existing);
      workoutPlans.set(localPlans);
      recommendationsByPlan = {
        ...recommendationsByPlan,
        [plan.id]: (recommendationsByPlan[plan.id] ?? []).filter(rec => rec.exercise_id !== recommendation.exercise_id),
      };
    } catch {
      showError('Failed to apply recommendation.');
    } finally {
      applyingRecommendation = null;
    }
  }
</script>

<div class="page-content space-y-5">
  {#if errorMsg}
    <div class="rounded-lg bg-red-900/40 border border-red-700 px-4 py-3 text-sm text-red-300 flex items-center justify-between">
      <span>{errorMsg}</span>
      <button onclick={() => errorMsg = null} class="text-red-400 hover:text-red-200">✕</button>
    </div>
  {/if}

  <div class="flex items-center justify-between">
    <h2 class="text-2xl font-bold">Workout Plans</h2>
    <div class="flex items-center gap-2">
      {#if activePlans.length > 0}
        <button onclick={openGlobalRirModal} class="btn-secondary">Global RIR Backoff</button>
      {/if}
      <button onclick={() => goto('/plans/create')} class="btn-primary">+ New Plan</button>
    </div>
  </div>

  <!-- Active Plans -->
  {#if activePlans.length > 0}
    <div class="space-y-3">
      {#each activePlans as plan (plan.id)}
        <div class="card !p-0 overflow-hidden">
          <!-- Collapsed header — always visible -->
          <button onclick={() => togglePlan(plan.id)}
                  class="w-full text-left px-4 py-3 flex items-center justify-between hover:bg-zinc-800/40 transition-colors">
            <div class="min-w-0">
              <h3 class="font-semibold text-white truncate">{plan.name}</h3>
              <div class="flex items-center gap-3 text-xs text-zinc-500 mt-0.5">
                <span>{plan.number_of_days} {plan.number_of_days === 1 ? 'day' : 'days'}</span>
                <span>{totalExercises(plan)} exercises</span>
                {#if plan.block_type && plan.block_type !== 'other'}
                  <span class="capitalize">{plan.block_type}</span>
                {/if}
              </div>
            </div>
            <span class="text-zinc-500 text-lg shrink-0 ml-3 transition-transform duration-200"
                  class:rotate-180={expandedPlan === plan.id}>▾</span>
          </button>

          <!-- Expanded details -->
          {#if expandedPlan === plan.id}
            <div class="border-t border-zinc-800 px-4 py-3 space-y-3">
              {#if plan.description}
                <p class="text-sm text-zinc-400">{plan.description}</p>
              {/if}

              {#each plan.days as day}
                <div class="border border-zinc-800 rounded-lg overflow-hidden">
                  <button onclick={() => toggleDay(plan.id, day.day_number)}
                          class="w-full text-left px-3 py-2 flex items-center justify-between hover:bg-zinc-800/40 transition-colors">
                    <div class="flex items-center gap-2">
                      <span class="text-sm font-medium text-primary-400">{day.day_name}</span>
                      <span class="text-xs text-zinc-600">{day.exercises.length} exercises</span>
                      <span class="text-xs text-zinc-600">· {formatDuration(estimateDayMinutes(day))}</span>
                    </div>
                    <span class="text-zinc-600 text-sm transition-transform duration-200"
                          class:rotate-180={isDayExpanded(plan.id, day.day_number)}>▾</span>
                  </button>
                  {#if isDayExpanded(plan.id, day.day_number)}
                    <div class="border-t border-zinc-800 px-3 py-2 space-y-1">
                      {#if day.exercises.length === 0}
                        <p class="text-xs text-zinc-600">No exercises</p>
                      {:else}
                        {#each day.exercises as ex}
                          <div class="flex items-center justify-between text-sm px-2 py-1 rounded bg-zinc-800/50">
                            <span class="text-zinc-300 truncate">{getExerciseName(ex.exercise_id)}</span>
                            <span class="text-xs text-zinc-500 shrink-0 ml-2">{ex.sets} {ex.sets === 1 ? 'set' : 'sets'}{ex.reps ? ` × ${ex.reps}` : ''}</span>
                          </div>
                        {/each}
                      {/if}
                      <div class="pt-2">
                        <button
                          onclick={() => goto(`/plans/create?edit=${plan.id}&day=${day.day_number}`)}
                          class="text-xs text-primary-400 hover:text-primary-300"
                        >
                          Edit This Day
                        </button>
                      </div>
                    </div>
                  {/if}
                </div>
              {/each}

              <div class="space-y-2">
                <div class="flex items-center justify-between">
                  <h4 class="text-sm font-semibold text-zinc-300">Recommendations</h4>
                  {#if loadingRecommendations[plan.id]}
                    <span class="text-xs text-zinc-500">Loading…</span>
                  {/if}
                </div>
                {#if (recommendationsByPlan[plan.id]?.length ?? 0) > 0}
                  <div class="space-y-2">
                    {#each recommendationsByPlan[plan.id] as recommendation}
                      <div class="rounded-xl border border-amber-500/20 bg-amber-500/10 px-3 py-3">
                        <div class="flex items-start justify-between gap-3">
                          <div class="min-w-0">
                            <p class="text-sm font-medium text-amber-300">{recommendation.exercise_name}</p>
                            <p class="text-xs text-zinc-300 mt-1">{recommendation.reason}</p>
                            <p class="text-xs text-zinc-500 mt-1">{recommendation.detail}</p>
                            <p class="text-[11px] text-zinc-500 mt-2">
                              Apply: {recommendation.recommended_rir} RIR{recommendation.add_set ? ` and +${recommendation.set_delta} set` : ''}
                            </p>
                          </div>
                          <button
                            onclick={() => applyRecommendation(plan, recommendation)}
                            class="btn-primary text-sm shrink-0"
                            disabled={applyingRecommendation === `${plan.id}-${recommendation.exercise_id}`}
                          >
                            {applyingRecommendation === `${plan.id}-${recommendation.exercise_id}` ? 'Applying…' : 'Apply'}
                          </button>
                        </div>
                      </div>
                    {/each}
                  </div>
                {:else if !loadingRecommendations[plan.id]}
                  <p class="text-xs text-zinc-500">No autoregulation recommendations yet.</p>
                {/if}
              </div>

              <!-- Actions -->
              <div class="flex items-center gap-2 pt-2 border-t border-zinc-800">
                <button onclick={() => goto(`/plans/create?edit=${plan.id}`)}
                        class="btn-secondary text-sm">
                  Edit Future Days
                </button>
                <button onclick={() => openRirModal(plan)}
                        class="btn-secondary text-sm">
                  RIR Targets
                </button>
                <button onclick={() => goto(`/workout/active?plan=${plan.id}&day=1`)}
                        class="btn-primary text-sm flex-1">
                  Start Workout
                </button>
                <button onclick={() => handleArchivePlan(plan.id)}
                        class="px-3 py-2 text-sm text-zinc-400 hover:text-amber-400 bg-zinc-800 rounded-lg transition-colors">
                  Archive
                </button>
                <button onclick={() => handleDeletePlan(plan.id)}
                        class="px-3 py-2 text-sm text-red-400 hover:text-red-300 bg-zinc-800 rounded-lg transition-colors">
                  Delete
                </button>
              </div>
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {:else}
    <div class="card text-center py-12">
      <p class="text-zinc-400">No active plans yet.</p>
      <button onclick={() => goto('/plans/create')} class="btn-primary mt-4">Create Plan</button>
    </div>
  {/if}

  <!-- Archived Plans -->
  {#if archivedPlans.length > 0}
    <div>
      <h3 class="text-sm font-semibold text-zinc-500 uppercase tracking-wider mb-2">Archived</h3>
      <div class="space-y-2">
        {#each archivedPlans as plan (plan.id)}
          <div class="card !py-3 opacity-70">
            <div class="flex items-center justify-between">
              <div class="min-w-0">
                <h4 class="font-medium truncate">{plan.name}</h4>
                <p class="text-xs text-zinc-500">{plan.number_of_days} days · {totalExercises(plan)} exercises</p>
              </div>
              <div class="flex gap-2 shrink-0 ml-3">
                <button onclick={() => handleReusePlan(plan.id)}
                        class="px-3 py-1.5 text-sm bg-primary-600 hover:bg-primary-500 text-white rounded-lg transition-colors">
                  Reuse
                </button>
                <button onclick={() => handleDeletePlan(plan.id)}
                        class="text-red-400 hover:text-red-300 text-sm">Delete</button>
              </div>
            </div>
          </div>
        {/each}
      </div>
    </div>
  {/if}

  <!-- ── Template Browser ───────────────────────────────────────────────── -->
  <div class="border-t border-zinc-800 pt-5">
    <h3 class="text-lg font-bold mb-3">Program Templates</h3>

    <!-- Filters -->
    <div class="flex gap-2 overflow-x-auto pb-2">
      <button onclick={() => splitFilter = null}
              class="shrink-0 px-3 py-1.5 rounded-full text-xs font-medium transition-colors
                     {!splitFilter ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
        All
      </button>
      {#each SPLITS as s}
        <button onclick={() => splitFilter = splitFilter === s.key ? null : s.key}
                class="shrink-0 px-3 py-1.5 rounded-full text-xs font-medium transition-colors
                       {splitFilter === s.key ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
          {s.label}
        </button>
      {/each}
    </div>
    <select bind:value={equipFilter}
            class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white mb-3">
      <option value={null}>All Equipment Levels</option>
      {#each EQUIP as e}
        <option value={e.key}>{e.label}</option>
      {/each}
    </select>

    <!-- Template list -->
    <div class="space-y-2 max-h-[50vh] overflow-y-auto">
      {#each filteredTemplates as tmpl}
        <button onclick={() => previewTmpl = tmpl}
                class="card !p-3 w-full text-left hover:bg-zinc-800/60 transition-colors">
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium text-white text-sm">{tmpl.name}</p>
              <p class="text-xs text-zinc-500 mt-0.5">
                {tmpl.days_per_week} days/wk · {tmpl.exercise_count} exercises
              </p>
            </div>
            <span class="text-zinc-600">›</span>
          </div>
        </button>
      {/each}
      {#if filteredTemplates.length === 0}
        <p class="text-center py-4 text-zinc-500 text-sm">No templates match filters.</p>
      {/if}
    </div>
    <p class="text-center text-xs text-zinc-600 mt-2">{filteredTemplates.length} templates</p>
  </div>
</div>

<!-- Template preview modal -->
{#if previewTmpl}
  <div class="fixed inset-0 bg-black/80 flex items-end sm:items-center justify-center z-50">
    <div class="bg-zinc-900 w-full sm:max-w-lg sm:rounded-2xl rounded-t-2xl max-h-[90vh] flex flex-col border border-zinc-800 shadow-2xl">
      <div class="flex items-center justify-between px-4 py-3 border-b border-zinc-800 shrink-0">
        <div>
          <h3 class="font-semibold text-white">{previewTmpl.name}</h3>
          <p class="text-xs text-zinc-500">{previewTmpl.days_per_week} days/wk</p>
        </div>
        <button onclick={() => previewTmpl = null} class="text-zinc-400 hover:text-white text-xl">✕</button>
      </div>
      <div class="p-4 overflow-y-auto space-y-4 flex-1">
        {#if previewTmpl.description}
          <p class="text-sm text-zinc-400">{previewTmpl.description}</p>
        {/if}
        {#each previewTmpl.days as day}
          <div class="space-y-1">
            <h4 class="text-sm font-semibold text-primary-400">{day.day_name}</h4>
            {#each day.exercises as ex}
              <div class="flex items-center justify-between text-sm px-2 py-1 rounded bg-zinc-800/50">
                <span class="text-zinc-300 truncate">{ex.exercise_name || getExerciseName(ex.exercise_id)}</span>
                <span class="text-xs text-zinc-500 shrink-0 ml-2">{ex.sets} sets</span>
              </div>
            {/each}
          </div>
        {/each}
      </div>
      <div class="p-4 border-t border-zinc-800 shrink-0">
        <button onclick={() => handleClone(previewTmpl!)} disabled={cloning}
                class="btn-primary w-full !py-3 disabled:opacity-50">
          {cloning ? 'Importing...' : 'Use This Template'}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if rirPlan}
  <div class="fixed inset-0 bg-black/80 z-50 flex items-end sm:items-center justify-center">
    <div class="bg-zinc-900 w-full sm:max-w-2xl sm:rounded-2xl rounded-t-2xl max-h-[92vh] flex flex-col border border-white/8 shadow-2xl">
      <div class="flex items-center justify-between px-4 py-4 border-b border-zinc-800">
        <div>
          <h3 class="font-semibold text-white">RIR Targets</h3>
          <p class="text-xs text-zinc-500 mt-0.5">{rirPlan.name}</p>
        </div>
        <button onclick={closeRirModal} class="text-zinc-400 hover:text-white text-xl leading-none">✕</button>
      </div>

      <div class="flex-1 overflow-y-auto px-4 py-4 space-y-5">
        <div class="space-y-2">
          <div>
            <label class="label">Whole Plan</label>
            <p class="text-xs text-zinc-500">Fallback target for every exercise unless a muscle or exercise override is set.</p>
          </div>
          <select class="input" value={rirOverridesDraft.plan ?? ''} onchange={(e) => setDraftPlanRir((e.currentTarget as HTMLSelectElement).value)}>
            <option value="">Auto</option>
            {#each [0, 1, 2, 3, 4, 5] as rir}
              <option value={rir}>{rir === 5 ? '5+' : rir}</option>
            {/each}
          </select>
        </div>

        <div class="space-y-2">
          <div>
            <label class="label">Muscle Groups</label>
            <p class="text-xs text-zinc-500">Applies to all matching exercises in the plan unless a direct exercise override is set.</p>
          </div>
          <div class="space-y-2">
            {#each getPlanMuscles(rirPlan) as muscle}
              <div class="flex items-center justify-between gap-3 rounded-lg bg-zinc-800/50 px-3 py-2">
                <div class="text-sm text-zinc-300 capitalize">{muscle.replace(/_/g, ' ')}</div>
                <select class="input w-28" value={rirOverridesDraft.muscles[muscle] ?? ''} onchange={(e) => setDraftMuscleRir(muscle, (e.currentTarget as HTMLSelectElement).value)}>
                  <option value="">Auto</option>
                  {#each [0, 1, 2, 3, 4, 5] as rir}
                    <option value={rir}>{rir === 5 ? '5+' : rir}</option>
                  {/each}
                </select>
              </div>
            {/each}
          </div>
        </div>

        <div class="space-y-2">
          <div>
            <label class="label">Exercises</label>
            <p class="text-xs text-zinc-500">Highest priority override. Use this when only one lift needs to back off.</p>
          </div>
          <div class="space-y-2">
            {#each getPlanExerciseRows(rirPlan) as row}
              <div class="flex items-center justify-between gap-3 rounded-lg bg-zinc-800/50 px-3 py-2">
                <div class="min-w-0">
                  <div class="text-sm text-zinc-300 truncate">{row.name}</div>
                  <div class="text-xs text-zinc-500 capitalize">{row.muscles.map(m => m.replace(/_/g, ' ')).join(', ') || 'No primary muscles'}</div>
                </div>
                <select class="input w-28 shrink-0" value={rirOverridesDraft.exercises[String(row.id)] ?? ''} onchange={(e) => setDraftExerciseRir(row.id, (e.currentTarget as HTMLSelectElement).value)}>
                  <option value="">Auto</option>
                  {#each [0, 1, 2, 3, 4, 5] as rir}
                    <option value={rir}>{rir === 5 ? '5+' : rir}</option>
                  {/each}
                </select>
              </div>
            {/each}
          </div>
        </div>
      </div>

      <div class="flex items-center justify-end gap-3 px-4 py-4 border-t border-zinc-800">
        <button onclick={closeRirModal} class="btn-secondary">Cancel</button>
        <button onclick={saveRirOverrides} class="btn-primary" disabled={savingRir}>
          {savingRir ? 'Saving…' : 'Save RIR Targets'}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if showGlobalRirModal}
  <div class="fixed inset-0 bg-black/80 z-50 flex items-end sm:items-center justify-center">
    <div class="bg-zinc-900 w-full sm:max-w-lg sm:rounded-2xl rounded-t-2xl border border-white/8 shadow-2xl">
      <div class="flex items-center justify-between px-4 py-4 border-b border-zinc-800">
        <div>
          <h3 class="font-semibold text-white">Global RIR Backoff</h3>
          <p class="text-xs text-zinc-500 mt-0.5">Apply extra reps in reserve to every active plan at once.</p>
        </div>
        <button onclick={closeGlobalRirModal} class="text-zinc-400 hover:text-white text-xl leading-none">✕</button>
      </div>

      <div class="px-4 py-4 space-y-4">
        <p class="text-sm text-zinc-300">
          This raises the whole-plan RIR target across {activePlans.length} active {activePlans.length === 1 ? 'plan' : 'plans'} so next week keeps the same rep range but uses a lighter load.
        </p>

        <div class="grid grid-cols-2 gap-3">
          {#each [1, 2] as delta}
            <button
              onclick={() => globalRirDelta = delta as 1 | 2}
              class="rounded-xl border px-4 py-4 text-left transition-colors
                {globalRirDelta === delta
                  ? 'border-primary-500 bg-primary-500/15 text-white'
                  : 'border-zinc-800 bg-zinc-800/50 text-zinc-300 hover:border-zinc-700'}"
            >
              <p class="text-sm font-semibold">+{delta} RIR</p>
              <p class="text-xs text-zinc-500 mt-1">Back off effort across all active plans.</p>
            </button>
          {/each}
        </div>

        <div class="rounded-xl border border-zinc-800 bg-zinc-950/70 px-3 py-3">
          <p class="text-xs text-zinc-400">
            Existing muscle and exercise-specific overrides are preserved. This changes the whole-plan fallback target on each active plan.
          </p>
        </div>
      </div>

      <div class="flex items-center justify-end gap-3 px-4 py-4 border-t border-zinc-800">
        <button onclick={closeGlobalRirModal} class="btn-secondary">Cancel</button>
        <button onclick={applyGlobalRirBackoff} class="btn-primary" disabled={applyingGlobalRir}>
          {applyingGlobalRir ? 'Applying…' : `Apply +${globalRirDelta} RIR`}
        </button>
      </div>
    </div>
  </div>
{/if}
