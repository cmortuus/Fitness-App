<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { workoutPlans, exercises } from '$lib/stores';
  import { getPlans, deletePlan, getExercises, updatePlan, archivePlan, reusePlan } from '$lib/api';
  import type { Exercise, WorkoutPlan } from '$lib/api';

  let allExercises = $state<Exercise[]>([]);
  let localPlans   = $state<WorkoutPlan[]>([]);
  let errorMsg     = $state<string | null>(null);
  let expandedPlan = $state<number | null>(null);
  let expandedDays = $state<Record<string, boolean>>({});

  function showError(msg: string) {
    errorMsg = msg;
    setTimeout(() => { errorMsg = null; }, 5000);
  }

  onMount(async () => {
    try {
      const [plansData, exercisesData] = await Promise.all([getPlans(), getExercises()]);
      workoutPlans.set(plansData);
      exercises.set(exercisesData);
      allExercises = exercisesData;
      localPlans = JSON.parse(JSON.stringify(plansData));
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

  function totalExercises(plan: WorkoutPlan): number {
    return plan.days.reduce((sum, d) => sum + d.exercises.length, 0);
  }

  function togglePlan(planId: number) {
    expandedPlan = expandedPlan === planId ? null : planId;
  }

  function toggleDay(planId: number, dayNum: number) {
    const key = `${planId}-${dayNum}`;
    expandedDays = { ...expandedDays, [key]: !expandedDays[key] };
  }

  function isDayExpanded(planId: number, dayNum: number): boolean {
    return !!expandedDays[`${planId}-${dayNum}`];
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
    <button onclick={() => goto('/plans/create')} class="btn-primary">+ New Plan</button>
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
                    </div>
                  {/if}
                </div>
              {/each}

              <!-- Actions -->
              <div class="flex items-center gap-2 pt-2 border-t border-zinc-800">
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
</div>
