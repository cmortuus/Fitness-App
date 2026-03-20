<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { workoutPlans, exercises } from '$lib/stores';
  import { getPlans, deletePlan, getExercises, updatePlan, archivePlan, reusePlan } from '$lib/api';
  import type { Exercise, WorkoutPlan } from '$lib/api';

  let allExercises = $state<Exercise[]>([]);
  let localPlans   = $state<WorkoutPlan[]>([]);
  let errorMsg     = $state<string | null>(null);

  function showError(msg: string) {
    errorMsg = msg;
    setTimeout(() => { errorMsg = null; }, 5000);
  }

  const saveTimers: Record<number, ReturnType<typeof setTimeout>> = {};

  onMount(async () => {
    try {
      const [plansData, exercisesData] = await Promise.all([
        getPlans(),
        getExercises(),
      ]);
      workoutPlans.set(plansData);
      exercises.set(exercisesData);
      allExercises = exercisesData;
      localPlans = JSON.parse(JSON.stringify(plansData));
    } catch (error) {
      showError('Failed to load plans. Please refresh the page.');
      console.error('Failed to load data:', error);
    }
  });

  let activePlans   = $derived(localPlans.filter(p => !p.is_archived));
  let archivedPlans = $derived(localPlans.filter(p =>  p.is_archived));

  function scheduleSave(planId: number) {
    clearTimeout(saveTimers[planId]);
    saveTimers[planId] = setTimeout(() => savePlan(planId), 800);
  }

  async function savePlan(planId: number) {
    const plan = localPlans.find(p => p.id === planId);
    if (!plan) return;
    try {
      await updatePlan(planId, { number_of_days: plan.number_of_days, days: plan.days });
    } catch (error) {
      showError('Failed to save plan changes.');
      console.error('Failed to save plan:', error);
    }
  }

  function updateSets(planId: number, dayNumber: number, exIdx: number, value: number) {
    const plan = localPlans.find(p => p.id === planId);
    if (!plan) return;
    const day = plan.days.find(d => d.day_number === dayNumber);
    if (!day) return;
    day.exercises[exIdx].sets = value;
    localPlans = [...localPlans];
    scheduleSave(planId);
  }

  function removeExercise(planId: number, dayNumber: number, exIdx: number) {
    const plan = localPlans.find(p => p.id === planId);
    if (!plan) return;
    const day = plan.days.find(d => d.day_number === dayNumber);
    if (!day) return;
    day.exercises = day.exercises.filter((_, i) => i !== exIdx);
    localPlans = [...localPlans];
    scheduleSave(planId);
  }

  async function handleDeletePlan(planId: number) {
    if (!confirm('Are you sure you want to delete this plan?')) return;
    try {
      await deletePlan(planId);
      const plansData = await getPlans();
      workoutPlans.set(plansData);
      localPlans = JSON.parse(JSON.stringify(plansData));
    } catch (error) {
      showError('Failed to delete plan. It may be in use by a workout session.');
      console.error('Failed to delete plan:', error);
    }
  }

  async function handleArchivePlan(planId: number) {
    try {
      await archivePlan(planId);
      const plansData = await getPlans();
      workoutPlans.set(plansData);
      localPlans = JSON.parse(JSON.stringify(plansData));
    } catch (error) {
      showError('Failed to archive plan.');
      console.error('Failed to archive plan:', error);
    }
  }

  async function handleReusePlan(planId: number) {
    try {
      await reusePlan(planId);
      const plansData = await getPlans();
      workoutPlans.set(plansData);
      localPlans = JSON.parse(JSON.stringify(plansData));
    } catch (error) {
      showError('Failed to create a copy of this plan.');
      console.error('Failed to reuse plan:', error);
    }
  }

  async function addDayToPlan(planId: number) {
    const plan = localPlans.find(p => p.id === planId);
    if (!plan) return;
    const newDayNumber = plan.days.length + 1;
    plan.days = [...plan.days, { day_number: newDayNumber, day_name: `Day ${newDayNumber}`, exercises: [] }];
    plan.number_of_days = newDayNumber;
    localPlans = [...localPlans];
    try {
      await updatePlan(planId, { number_of_days: newDayNumber, days: plan.days });
    } catch (error) {
      alert('Failed to add day: ' + (error instanceof Error ? error.message : String(error)));
    }
  }

  async function removeDayFromPlan(planId: number, dayNumber: number) {
    if (!confirm('Delete this day? This cannot be undone.')) return;
    const plan = localPlans.find(p => p.id === planId);
    if (!plan) return;
    const updatedDays = plan.days
      .filter(d => d.day_number !== dayNumber)
      .map((d, idx) => ({ ...d, day_number: idx + 1 }));
    plan.days = updatedDays;
    plan.number_of_days = updatedDays.length;
    localPlans = [...localPlans];
    try {
      await updatePlan(planId, { number_of_days: updatedDays.length, days: updatedDays });
    } catch (error) {
      alert('Failed to remove day: ' + (error instanceof Error ? error.message : String(error)));
    }
  }

  function getExerciseName(exerciseId: number): string {
    const ex = allExercises.find(e => e.id === exerciseId);
    return ex?.display_name || `Exercise ${exerciseId}`;
  }
</script>

<div class="space-y-6">
  <!-- Error banner (auto-dismisses after 5 s) -->
  {#if errorMsg}
    <div class="rounded-lg bg-red-900/40 border border-red-700 px-4 py-3 text-sm text-red-300 flex items-center justify-between gap-3">
      <span>⚠ {errorMsg}</span>
      <button onclick={() => errorMsg = null} class="text-red-400 hover:text-red-200 shrink-0">✕</button>
    </div>
  {/if}

  <div class="flex items-center justify-between">
    <h2 class="text-2xl font-bold">Workout Plans</h2>
    <button onclick={() => goto('/plans/create')} class="btn-primary">
      Create Plan
    </button>
  </div>

  <!-- ── Active Plans ─────────────────────────────────────────────────── -->
  {#if activePlans.length > 0}
    <div class="grid gap-6">
      {#each activePlans as plan (plan.id)}
        {@const localPlan = localPlans.find(p => p.id === plan.id)!}
        <div class="card">
          <!-- Plan header -->
          <div class="flex items-start justify-between">
            <div>
              <h3 class="text-lg font-semibold">{plan.name}</h3>
              {#if plan.description}
                <p class="text-gray-400 mt-1">{plan.description}</p>
              {/if}
              <div class="mt-2 flex items-center gap-4 text-sm text-gray-400">
                <span>{plan.number_of_days} {plan.number_of_days === 1 ? 'day' : 'days'}</span>
                {#if plan.block_type}
                  <span class="capitalize">{plan.block_type}</span>
                {/if}
                {#if plan.duration_weeks}
                  <span>{plan.duration_weeks} weeks</span>
                {/if}
              </div>
            </div>
            <div class="flex items-center gap-3 shrink-0">
              <button
                onclick={() => handleArchivePlan(plan.id)}
                class="text-gray-400 hover:text-amber-400 text-sm transition-colors"
                title="Archive this plan"
              >Archive</button>
              <button
                onclick={() => handleDeletePlan(plan.id)}
                class="text-red-400 hover:text-red-300 text-sm"
              >Delete</button>
            </div>
          </div>

          <!-- Days -->
          <div class="mt-4 space-y-3">
            <div class="flex items-center justify-between">
              <h4 class="font-medium text-gray-300 text-sm">Days ({localPlan.days.length})</h4>
              <button
                onclick={() => addDayToPlan(plan.id)}
                class="text-xs px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-white rounded transition-colors"
              >
                + Add Day
              </button>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
              {#each localPlan.days as day (day.day_number)}
                <div class="bg-gray-700/50 rounded-lg p-3">
                  <div class="flex items-center justify-between mb-3">
                    <span class="font-medium text-sm text-gray-200">{day.day_name}</span>
                    <button
                      onclick={() => removeDayFromPlan(plan.id, day.day_number)}
                      class="text-xs px-2 py-1 bg-red-600/80 hover:bg-red-500 text-white rounded transition-colors"
                      title="Remove day"
                    >−</button>
                  </div>

                  {#if day.exercises.length === 0}
                    <p class="text-gray-500 text-xs text-center py-4">No exercises</p>
                  {:else}
                    <div class="space-y-2">
                      {#each day.exercises as ex, exIdx (exIdx)}
                        <div class="bg-gray-800 rounded-lg px-3 py-2 flex items-center justify-between gap-2">
                          <span class="text-xs text-white truncate flex-1">{getExerciseName(ex.exercise_id)}</span>
                          <div class="flex items-center gap-1.5 shrink-0">
                            <input
                              type="number"
                              value={ex.sets}
                              min="1" max="20"
                              title="Sets"
                              oninput={(e) => {
                                const v = parseInt((e.target as HTMLInputElement).value);
                                if (!isNaN(v) && v > 0) updateSets(plan.id, day.day_number, exIdx, v);
                              }}
                              class="w-12 bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-xs text-center focus:outline-none focus:border-primary-500"
                            />
                            <span class="text-[10px] text-gray-500">sets</span>
                            <button
                              onclick={() => removeExercise(plan.id, day.day_number, exIdx)}
                              class="text-red-400 hover:text-red-300 text-xs ml-1"
                            >✕</button>
                          </div>
                        </div>
                      {/each}
                    </div>
                  {/if}

                  <button
                    onclick={() => goto(`/workout/active?plan=${plan.id}&day=${day.day_number}`)}
                    class="mt-3 w-full text-xs py-1.5 bg-primary-600 hover:bg-primary-500 text-white rounded transition-colors"
                  >
                    Start Day {day.day_number}
                  </button>
                </div>
              {/each}
            </div>
          </div>
        </div>
      {/each}
    </div>
  {:else}
    <div class="card text-center py-12">
      <p class="text-gray-400">No active plans. Create one or reuse an archived plan below.</p>
      <button onclick={() => goto('/plans/create')} class="btn-primary mt-4">Create Plan</button>
    </div>
  {/if}

  <!-- ── Archived Plans ───────────────────────────────────────────────── -->
  {#if archivedPlans.length > 0}
    <div>
      <h3 class="text-lg font-semibold text-gray-400 mb-3">Archived</h3>
      <div class="grid gap-4">
        {#each archivedPlans as plan (plan.id)}
          <div class="card border border-gray-700 opacity-80">
            <div class="flex items-center justify-between gap-4">
              <div class="min-w-0">
                <h4 class="font-semibold truncate">{plan.name}</h4>
                <div class="mt-1 flex items-center gap-3 text-xs text-gray-500">
                  <span>{plan.number_of_days} {plan.number_of_days === 1 ? 'day' : 'days'}</span>
                  <span class="capitalize">{plan.block_type}</span>
                  <span>{plan.duration_weeks} weeks</span>
                </div>
              </div>
              <div class="flex items-center gap-3 shrink-0">
                <button
                  onclick={() => handleReusePlan(plan.id)}
                  class="px-4 py-1.5 rounded-lg bg-primary-600 hover:bg-primary-500 text-white text-sm font-medium transition-colors"
                >
                  Reuse
                </button>
                <button
                  onclick={() => handleDeletePlan(plan.id)}
                  class="text-red-400 hover:text-red-300 text-sm"
                >Delete</button>
              </div>
            </div>
          </div>
        {/each}
      </div>
    </div>
  {/if}
</div>
