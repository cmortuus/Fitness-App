<script lang="ts">
  import { onMount } from 'svelte';
  import { getExercises, getPlan, updatePlan } from '$lib/api';
  import type { Exercise, PlannedDay, PlannedExercise, WorkoutPlan } from '$lib/api';

  let loading = $state(true);
  let saving = $state(false);
  let error = $state<string | null>(null);
  let saveMessage = $state<string | null>(null);

  let plan = $state<WorkoutPlan | null>(null);
  let allExercises = $state<Exercise[]>([]);
  let dayDraft = $state<PlannedDay | null>(null);

  let planId = $state<number | null>(null);
  let dayNumber = $state<number | null>(null);

  let showAddExercise = $state(false);
  let searchQuery = $state('');

  function cloneDay(day: PlannedDay): PlannedDay {
    return {
      day_number: day.day_number,
      day_name: day.day_name,
      exercises: day.exercises.map((exercise) => ({ ...exercise })),
    };
  }

  function getExerciseName(exerciseId: number): string {
    return allExercises.find((exercise) => exercise.id === exerciseId)?.display_name ?? `Exercise ${exerciseId}`;
  }

  function getExercise(exerciseId: number): Exercise | undefined {
    return allExercises.find((exercise) => exercise.id === exerciseId);
  }

  function repLabel(exercise: PlannedExercise): string {
    if (exercise.rep_range_top && exercise.rep_range_top > exercise.reps) {
      return `${exercise.reps}-${exercise.rep_range_top} reps`;
    }
    return `${exercise.reps} reps`;
  }

  function updateExercise(index: number, updater: (exercise: PlannedExercise) => PlannedExercise) {
    if (!dayDraft) return;
    dayDraft = {
      ...dayDraft,
      exercises: dayDraft.exercises.map((exercise, exerciseIndex) =>
        exerciseIndex === index ? updater(exercise) : exercise
      ),
    };
  }

  function moveExercise(index: number, direction: -1 | 1) {
    if (!dayDraft) return;
    const targetIndex = index + direction;
    if (targetIndex < 0 || targetIndex >= dayDraft.exercises.length) return;
    const exercises = [...dayDraft.exercises];
    const [moved] = exercises.splice(index, 1);
    exercises.splice(targetIndex, 0, moved);
    dayDraft = { ...dayDraft, exercises };
  }

  function removeExercise(index: number) {
    if (!dayDraft) return;
    dayDraft = {
      ...dayDraft,
      exercises: dayDraft.exercises.filter((_, exerciseIndex) => exerciseIndex !== index),
    };
  }

  function addExercise(exercise: Exercise) {
    if (!dayDraft) return;
    const nextExercise: PlannedExercise = {
      exercise_id: exercise.id,
      sets: 3,
      reps: 8,
      rep_range_top: 12,
      starting_weight_kg: 0,
      progression_type: 'linear',
      rest_seconds: 90,
      notes: null,
      set_type: 'standard',
      drops: null,
      group_id: null,
      group_type: null,
    };
    dayDraft = {
      ...dayDraft,
      exercises: [...dayDraft.exercises, nextExercise],
    };
    searchQuery = '';
    showAddExercise = false;
  }

  function dismissSaveMessageSoon() {
    setTimeout(() => {
      saveMessage = null;
    }, 2500);
  }

  async function saveDay() {
    if (!plan || !dayDraft) return;
    saving = true;
    error = null;
    saveMessage = null;
    try {
      const days = plan.days.map((day) =>
        day.day_number === dayDraft.day_number ? cloneDay(dayDraft) : cloneDay(day)
      );
      const updated = await updatePlan(plan.id, {
        name: plan.name,
        description: plan.description ?? undefined,
        block_type: plan.block_type,
        duration_weeks: plan.duration_weeks,
        number_of_days: plan.number_of_days,
        days,
        auto_progression: plan.auto_progression,
        is_draft: plan.is_draft,
      });
      plan = updated;
      const savedDay = updated.days.find((day) => day.day_number === dayDraft.day_number) ?? cloneDay(dayDraft);
      dayDraft = cloneDay(savedDay);
      saveMessage = 'Future day updated.';
      dismissSaveMessageSoon();
    } catch (err) {
      console.error(err);
      error = 'Failed to save future day changes.';
    } finally {
      saving = false;
    }
  }

  const filteredExercises = $derived.by(() => {
    const query = searchQuery.trim().toLowerCase();
    if (!query) return allExercises.slice(0, 30);
    return allExercises
      .filter((exercise) => exercise.display_name.toLowerCase().includes(query))
      .slice(0, 30);
  });

  onMount(async () => {
    loading = true;
    error = null;
    try {
      const params = new URLSearchParams(window.location.search);
      const requestedPlan = Number.parseInt(params.get('plan') ?? '', 10);
      const requestedDay = Number.parseInt(params.get('day') ?? '', 10);

      if (!Number.isInteger(requestedPlan) || requestedPlan <= 0 || !Number.isInteger(requestedDay) || requestedDay <= 0) {
        error = 'Missing future day context.';
        loading = false;
        return;
      }

      planId = requestedPlan;
      dayNumber = requestedDay;

      const [planData, exercises] = await Promise.all([
        getPlan(requestedPlan),
        getExercises(),
      ]);

      const day = planData.days.find((entry) => entry.day_number === requestedDay);
      if (!day) {
        error = 'That future day could not be found in the current plan.';
        loading = false;
        return;
      }

      plan = planData;
      allExercises = exercises;
      dayDraft = cloneDay(day);
    } catch (err) {
      console.error(err);
      error = 'Failed to load the future day.';
    } finally {
      loading = false;
    }
  });
</script>

<svelte:head>
  <title>Future Day Editor</title>
</svelte:head>

<div class="max-w-4xl mx-auto px-4 py-6 space-y-6">
  <div class="flex items-start justify-between gap-4 flex-wrap">
    <div>
      <p class="text-xs font-bold uppercase tracking-widest text-primary-400 mb-2">Future Day Editor</p>
      <h1 class="text-3xl font-bold text-white">Workout-Style Future Day View</h1>
      <p class="text-sm text-zinc-400 mt-2 max-w-2xl">
        Edit this future workout in the same general layout as the workout screen, without any completion checkboxes or logging controls.
      </p>
    </div>
    <div class="flex gap-2 flex-wrap">
      <a href="/plans/upcoming" class="btn-secondary text-sm">Back to Upcoming Days</a>
      {#if planId && dayNumber}
        <a href="/workout/active?plan={planId}&day={dayNumber}" class="btn-primary text-sm">Start This Workout</a>
      {/if}
    </div>
  </div>

  {#if loading}
    <div class="card h-40 animate-pulse bg-zinc-800/50"></div>
  {:else if error}
    <div class="card border border-red-500/30 text-red-200">{error}</div>
  {:else if !plan || !dayDraft}
    <div class="card border border-zinc-700/60 text-zinc-300">No future day loaded.</div>
  {:else}
    <div class="rounded-2xl border border-primary-600/20 bg-primary-950/20 p-4">
      <div class="flex items-start justify-between gap-4 flex-wrap">
        <div class="min-w-0 flex-1">
          <p class="text-xs font-bold uppercase tracking-widest text-primary-400 mb-2">{plan.name}</p>
          <input
            type="text"
            bind:value={dayDraft.day_name}
            class="w-full max-w-xl bg-zinc-900 border border-zinc-700 rounded-xl px-4 py-3 text-2xl font-bold text-white"
          />
          <p class="text-sm text-zinc-400 mt-2">
            Program day {dayDraft.day_number} · {dayDraft.exercises.length} exercise{dayDraft.exercises.length === 1 ? '' : 's'}
          </p>
        </div>
        <div class="flex gap-2 flex-wrap">
          <button onclick={() => showAddExercise = !showAddExercise} class="btn-secondary text-sm">
            {showAddExercise ? 'Close Add Exercise' : 'Add Exercise'}
          </button>
          <button onclick={saveDay} disabled={saving} class="btn-primary text-sm">
            {saving ? 'Saving…' : 'Save Future Day'}
          </button>
        </div>
      </div>
      {#if saveMessage}
        <p class="text-sm text-emerald-400 mt-3">{saveMessage}</p>
      {/if}
    </div>

    {#if showAddExercise}
      <div class="rounded-2xl border border-zinc-800 bg-zinc-900/80 p-4 space-y-3">
        <input
          type="text"
          bind:value={searchQuery}
          placeholder="Search exercises..."
          class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-4 py-3 text-white"
        />
        <div class="max-h-80 overflow-auto space-y-2 pr-1">
          {#each filteredExercises as exercise}
            <button
              onclick={() => addExercise(exercise)}
              class="w-full text-left rounded-xl border border-zinc-800 bg-zinc-950/80 px-4 py-3 hover:border-primary-500/40 hover:bg-zinc-900 transition-colors"
            >
              <p class="text-sm font-medium text-white">{exercise.display_name}</p>
              <p class="text-xs text-zinc-500 mt-1">
                {(exercise.primary_muscles ?? []).join(', ') || 'General'}
              </p>
            </button>
          {/each}
        </div>
      </div>
    {/if}

    <div class="space-y-4">
      {#each dayDraft.exercises as exercise, index}
        {@const exerciseMeta = getExercise(exercise.exercise_id)}
        <section class="rounded-2xl overflow-hidden border border-zinc-800 bg-zinc-900/70">
          <div class="p-5 flex items-start justify-between gap-4 flex-wrap">
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2 flex-wrap mb-2">
                <span class="badge bg-zinc-800 text-zinc-300">Exercise {index + 1}</span>
                {#if exercise.group_type}
                  <span class="badge bg-zinc-800 text-zinc-300">{exercise.group_type}</span>
                {/if}
              </div>
              <h3 class="text-2xl font-bold text-white truncate">{getExerciseName(exercise.exercise_id)}</h3>
              {#if exerciseMeta}
                <p class="text-xs text-zinc-500 mt-2">
                  {(exerciseMeta.primary_muscles ?? []).join(', ') || 'General'}
                </p>
              {/if}
            </div>

            <div class="flex items-center gap-1">
              <button onclick={() => moveExercise(index, -1)} disabled={index === 0} class="text-zinc-500 hover:text-white px-1 text-sm disabled:opacity-20">▲</button>
              <button onclick={() => moveExercise(index, 1)} disabled={index === dayDraft.exercises.length - 1} class="text-zinc-500 hover:text-white px-1 text-sm disabled:opacity-20">▼</button>
              <button onclick={() => removeExercise(index)} class="text-red-400 hover:text-red-300 text-xl leading-none" title="Remove exercise">✕</button>
            </div>
          </div>

          <div class="border-t border-zinc-800/90 px-5 py-4 grid gap-3 md:grid-cols-2">
            <label class="space-y-1">
              <span class="text-xs uppercase tracking-wide text-zinc-500">Sets</span>
              <input
                type="number"
                min="1"
                max="20"
                value={exercise.sets}
                oninput={(event) => {
                  const value = Number.parseInt((event.target as HTMLInputElement).value, 10);
                  if (Number.isInteger(value) && value > 0) {
                    updateExercise(index, (current) => ({ ...current, sets: value }));
                  }
                }}
                class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-3 py-2 text-white"
              />
            </label>

            <label class="space-y-1">
              <span class="text-xs uppercase tracking-wide text-zinc-500">Rep Target</span>
              <div class="grid grid-cols-2 gap-2">
                <input
                  type="number"
                  min="1"
                  value={exercise.reps}
                  oninput={(event) => {
                    const value = Number.parseInt((event.target as HTMLInputElement).value, 10);
                    if (Number.isInteger(value) && value > 0) {
                      updateExercise(index, (current) => {
                        const top = current.rep_range_top && current.rep_range_top < value ? value : current.rep_range_top;
                        return { ...current, reps: value, rep_range_top: top };
                      });
                    }
                  }}
                  class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-3 py-2 text-white"
                />
                <input
                  type="number"
                  min={exercise.reps}
                  value={exercise.rep_range_top ?? exercise.reps}
                  oninput={(event) => {
                    const value = Number.parseInt((event.target as HTMLInputElement).value, 10);
                    if (Number.isInteger(value) && value >= exercise.reps) {
                      updateExercise(index, (current) => ({ ...current, rep_range_top: value }));
                    }
                  }}
                  class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-3 py-2 text-white"
                />
              </div>
            </label>

            <label class="space-y-1">
              <span class="text-xs uppercase tracking-wide text-zinc-500">Set Type</span>
              <select
                value={exercise.set_type ?? 'standard'}
                onchange={(event) => updateExercise(index, (current) => ({ ...current, set_type: (event.target as HTMLSelectElement).value }))}
                class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-3 py-2 text-white"
              >
                <option value="standard">Straight</option>
                <option value="standard_partials">+ Partials</option>
                <option value="warmup">Warmup</option>
                <option value="myo_rep">Myo Rep</option>
                <option value="myo_rep_match">Myo Match</option>
                <option value="drop_set">Drop Set</option>
              </select>
            </label>

            <label class="space-y-1">
              <span class="text-xs uppercase tracking-wide text-zinc-500">Rest Seconds</span>
              <input
                type="number"
                min="0"
                value={exercise.rest_seconds ?? 90}
                oninput={(event) => {
                  const value = Number.parseInt((event.target as HTMLInputElement).value, 10);
                  if (Number.isInteger(value) && value >= 0) {
                    updateExercise(index, (current) => ({ ...current, rest_seconds: value }));
                  }
                }}
                class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-3 py-2 text-white"
              />
            </label>
          </div>

          <div class="px-5 pb-5 space-y-3">
            <label class="block space-y-1">
              <span class="text-xs uppercase tracking-wide text-zinc-500">Notes</span>
              <textarea
                rows="2"
                value={exercise.notes ?? ''}
                oninput={(event) => updateExercise(index, (current) => ({ ...current, notes: (event.target as HTMLTextAreaElement).value || null }))}
                class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-3 py-2 text-white"
                placeholder="Add context for this future exercise..."
              ></textarea>
            </label>

            <div class="rounded-xl border border-zinc-800 bg-zinc-950/70 px-4 py-3">
              <p class="text-xs uppercase tracking-wide text-zinc-500 mb-2">Workout-style preview</p>
              <div class="grid gap-2">
                {#each Array.from({ length: exercise.sets }, (_, setIndex) => setIndex + 1) as setNumber}
                  <div class="grid grid-cols-[4.5rem_1fr_5rem] gap-2 items-center">
                    <div class="rounded-lg border border-zinc-800 bg-zinc-900 px-3 py-2 text-xs text-zinc-400 text-center">
                      {exercise.set_type === 'standard' ? `Set ${setNumber}` : exercise.set_type.replaceAll('_', ' ')}
                    </div>
                    <div class="rounded-lg border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm text-zinc-200">
                      {repLabel(exercise)}
                    </div>
                    <div class="rounded-lg border border-zinc-800 bg-zinc-900 px-3 py-2 text-xs text-zinc-500 text-center">
                      No log
                    </div>
                  </div>
                {/each}
              </div>
            </div>
          </div>
        </section>
      {/each}
    </div>
  {/if}
</div>
