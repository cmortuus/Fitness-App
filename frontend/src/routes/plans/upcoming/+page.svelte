<script lang="ts">
  import { onMount } from 'svelte';
  import { getExercises, getNextWorkout, getPlan } from '$lib/api';
  import type { Exercise, NextWorkoutResolution, PlannedDay, WorkoutPlan } from '$lib/api';

  type UpcomingProgramDay = {
    offset: number;
    cyclePosition: number;
    weekNumber: number;
    day: PlannedDay;
    isNext: boolean;
  };

  let loading = $state(true);
  let error = $state<string | null>(null);
  let nextWorkout = $state<NextWorkoutResolution | null>(null);
  let plan = $state<WorkoutPlan | null>(null);
  let allExercises = $state<Exercise[]>([]);
  let upcomingDays = $state<UpcomingProgramDay[]>([]);

  function getExerciseName(exerciseId: number): string {
    return allExercises.find((exercise) => exercise.id === exerciseId)?.display_name ?? `Exercise ${exerciseId}`;
  }

  function getSetSummary(day: PlannedDay): string {
    const setCount = day.exercises.reduce((sum, exercise) => sum + (exercise.sets ?? 0), 0);
    return `${setCount} set${setCount === 1 ? '' : 's'}`;
  }

  function getExerciseSummary(day: PlannedDay): string {
    return day.exercises
      .slice(0, 4)
      .map((exercise) => getExerciseName(exercise.exercise_id))
      .join(' · ');
  }

  function buildUpcomingDays(activePlan: WorkoutPlan, next: NextWorkoutResolution): UpcomingProgramDay[] {
    const cycleLength = activePlan.number_of_days || activePlan.days.length || 0;
    if (cycleLength <= 0) return [];

    return Array.from({ length: cycleLength }, (_, offset) => {
      const absoluteIndex = (next.day_number - 1) + offset;
      const dayIndex = absoluteIndex % cycleLength;
      const weekOffset = Math.floor(absoluteIndex / cycleLength);
      return {
        offset,
        cyclePosition: offset + 1,
        weekNumber: next.week_number + weekOffset,
        day: activePlan.days[dayIndex],
        isNext: offset === 0,
      };
    });
  }

  onMount(async () => {
    loading = true;
    error = null;
    try {
      const [next, exercises] = await Promise.all([
        getNextWorkout(),
        getExercises(),
      ]);
      allExercises = exercises;
      nextWorkout = next;

      if (!next || next.is_complete) {
        upcomingDays = [];
        plan = next?.plan ?? null;
        return;
      }

      const activePlan = await getPlan(next.plan.id);
      plan = activePlan;
      upcomingDays = buildUpcomingDays(activePlan, next);
    } catch (err) {
      console.error(err);
      error = 'Failed to load upcoming program days.';
    } finally {
      loading = false;
    }
  });
</script>

<svelte:head>
  <title>Upcoming Program Days</title>
</svelte:head>

<div class="max-w-5xl mx-auto px-4 py-6 space-y-6">
  <div class="flex items-start justify-between gap-4 flex-wrap">
    <div>
      <p class="text-xs font-bold uppercase tracking-widest text-primary-400 mb-2">Future Programming</p>
      <h1 class="text-3xl font-bold text-white">Upcoming Program Days</h1>
      <p class="text-sm text-zinc-400 mt-2 max-w-2xl">
        Review the next cycle of your active program. Each card is a future day you can inspect now and edit without digging through the full plan builder.
      </p>
    </div>
    <a href="/" class="btn-secondary text-sm">Back to Dashboard</a>
  </div>

  {#if loading}
    <div class="card h-40 animate-pulse bg-zinc-800/50"></div>
  {:else if error}
    <div class="card border border-red-500/30 text-red-200">{error}</div>
  {:else if !nextWorkout || nextWorkout.is_complete || !plan}
    <div class="card border border-zinc-700/60">
      <p class="text-lg font-semibold text-white mb-2">No upcoming program cycle</p>
      <p class="text-sm text-zinc-400">
        There isn’t an active next workout to build this view from right now. Start or create a plan first, then come back here to edit upcoming days.
      </p>
    </div>
  {:else}
    <div class="rounded-2xl border border-primary-600/20 bg-primary-950/20 p-4">
      <p class="text-xs font-bold uppercase tracking-widest text-primary-400 mb-1">Active Plan</p>
      <div class="flex items-center justify-between gap-4 flex-wrap">
        <div>
          <h2 class="text-xl font-bold text-white">{plan.name}</h2>
          <p class="text-sm text-zinc-400 mt-1">
            Showing the next {upcomingDays.length} day{upcomingDays.length === 1 ? '' : 's'} in your rotation, starting from {nextWorkout.day.day_name}.
          </p>
        </div>
        <div class="flex items-center gap-2 flex-wrap">
          <span class="badge bg-zinc-800 text-zinc-300">{plan.number_of_days} day program</span>
          <span class="badge bg-primary-900/60 text-primary-300 border border-primary-700/50">Week {nextWorkout.week_number}</span>
        </div>
      </div>
    </div>

    <div class="grid gap-4">
      {#each upcomingDays as item}
        <section class="rounded-2xl overflow-hidden border border-zinc-800 bg-zinc-900/70">
          <div class="p-5 flex items-start justify-between gap-4 flex-wrap">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap mb-2">
                {#if item.isNext}
                  <span class="badge bg-primary-900/60 text-primary-300 border border-primary-700/50">Next session</span>
                {/if}
                <span class="badge bg-zinc-800 text-zinc-300">Cycle day {item.cyclePosition}</span>
                <span class="badge bg-zinc-800 text-zinc-300">Program day {item.day.day_number}</span>
                <span class="badge bg-zinc-800 text-zinc-300">Week {item.weekNumber}</span>
              </div>
              <h3 class="text-2xl font-bold text-white truncate">{item.day.day_name}</h3>
              <p class="text-sm text-zinc-400 mt-2">
                {item.day.exercises.length} exercise{item.day.exercises.length === 1 ? '' : 's'} · {getSetSummary(item.day)}
              </p>
              {#if item.day.exercises.length > 0}
                <p class="text-sm text-zinc-500 mt-2">{getExerciseSummary(item.day)}</p>
              {/if}
            </div>

            <div class="flex gap-2 flex-wrap">
              {#if item.isNext}
                <a
                  href="/workout/active?plan={plan.id}&day={item.day.day_number}"
                  class="btn-primary text-sm"
                >
                  Start Workout
                </a>
              {/if}
              <a
                href="/plans/create?edit={plan.id}&day={item.day.day_number}"
                class="btn-secondary text-sm"
              >
                Edit This Day
              </a>
            </div>
          </div>

          <div class="border-t border-zinc-800/90 px-5 py-4 space-y-3">
            {#each item.day.exercises as exercise, index}
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-sm font-medium text-zinc-100">
                    {index + 1}. {getExerciseName(exercise.exercise_id)}
                  </p>
                  <p class="text-xs text-zinc-500 mt-1">
                    {exercise.sets} set{exercise.sets === 1 ? '' : 's'}
                    {#if exercise.rep_range_top && exercise.rep_range_top > exercise.reps}
                      · {exercise.reps}-{exercise.rep_range_top} reps
                    {:else}
                      · {exercise.reps} reps
                    {/if}
                    {#if exercise.group_type}
                      · {exercise.group_type}
                    {/if}
                    {#if exercise.set_type && exercise.set_type !== 'standard'}
                      · {exercise.set_type.replaceAll('_', ' ')}
                    {/if}
                  </p>
                  {#if exercise.notes}
                    <p class="text-xs text-zinc-400 mt-1">{exercise.notes}</p>
                  {/if}
                </div>
              </div>
            {/each}
          </div>
        </section>
      {/each}
    </div>
  {/if}
</div>
