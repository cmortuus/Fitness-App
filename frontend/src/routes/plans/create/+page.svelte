<script lang="ts">  import { onMount, untrack } from 'svelte';
  import { goto } from '$app/navigation';
  import { exercises } from '$lib/stores';
  import { getExercises, getRecentExercises, getExercisesGrouped, getTemplates, createPlan, createExercise, deleteExercise } from '$lib/api';
  import type { Exercise, RecentExercise, PlannedDay, PlannedExercise, WorkoutTemplate } from '$lib/api';

  // Plan basic info
  let newPlanName = $state('');
  let newPlanDescription = $state('');
  let numberOfDays = $state(3);
  let durationWeeks = $state(4);
  let blockType = $state('other');

  const blockTypes = [
    { value: 'hypertrophy', label: 'Hypertrophy' },
    { value: 'strength', label: 'Strength' },
    { value: 'powerlifting', label: 'Powerlifting' },
    { value: 'maintenance', label: 'Maintenance' },
    { value: 'cutting', label: 'Cutting' },
    { value: 'peaking', label: 'Peaking' },
    { value: 'deload', label: 'Deload' },
    { value: 'other', label: 'Other' },
  ];

  // Days configuration
  let days = $state<PlannedDay[]>([]);
  let initialized = $state(false);
  let currentStep = $state(1); // 0: Choose method, 1: Basic Info, 2: Configure Days
  let createMode = $state<'choose' | 'template' | 'custom'>('choose');

  // Template browser state
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
  const EQUIP_TIERS = [
    { key: 'minimal', label: 'Minimal' },
    { key: 'home', label: 'Home Gym' },
    { key: 'standard', label: 'Standard' },
    { key: 'well_equipped', label: 'Well-Equipped' },
    { key: 'fully_loaded', label: 'Fully Loaded' },
  ];

  // Exercise selection
  let searchQuery = $state('');
  let showExerciseSelector = $state(false);
  let selectingForDay = $state(1);
  let allExercises = $state<Exercise[]>([]);
  let recentExercises = $state<RecentExercise[]>([]);
  let groupedExercises = $state<Record<string, Exercise[]>>({});
  let viewMode = $state<'browse' | 'search'>('browse');

  // Muscle group expansion state
  let expandedMuscleGroups = $state<Record<string, boolean>>({});

  function toggleMuscleGroup(muscle: string) {
    expandedMuscleGroups = { ...expandedMuscleGroups, [muscle]: !expandedMuscleGroups[muscle] };
  }

  // Custom exercise
  let showCustomExerciseModal = $state(false);
  let customExerciseName = $state('');
  let customExerciseDisplayName = $state('');
  let customMovementType = $state('compound');
  let customBodyRegion = $state('upper');
  let customPrimaryMuscles = $state<string[]>([]);
  let customSecondaryMuscles = $state<string[]>([]);


  // Exercise being configured
  let configuringExercise = $state<{
    exercise_id: number;
    exercise: Exercise | null;
  } | null>(null);

  // Config values for the exercise being added (sets only — weight/reps set during workout)
  let configSets = $state(3);

  // Drag and drop state
  let draggedExercise = $state<{ dayNum: number; index: number; exercise: PlannedExercise } | null>(null);
  let dragOverDay = $state<number | null>(null);

  // Weight conversion helpers
  const LBS_TO_KG = 0.453592;
  const KG_TO_LBS = 2.20462;

  function lbsToKg(lbs: number): number {
    return Math.round(lbs * LBS_TO_KG * 10) / 10;
  }

  function kgToLbs(kg: number): number {
    return Math.round(kg * KG_TO_LBS * 10) / 10;
  }

  onMount(async () => {
    try {
      const [exercisesData, recentData, groupedData] = await Promise.all([
        getExercises(),
        getRecentExercises(15),
        getExercisesGrouped(),
      ]);

      exercises.set(exercisesData);
      allExercises = exercisesData;
      recentExercises = recentData;
      groupedExercises = groupedData;

      // Check for saved draft in localStorage
      const restored = restoreDraftFromStorage();
      if (!restored) {
        initializeDays();
      }
      initialized = true;

      // Auto-save to localStorage every 30s
      const autosaveInterval = setInterval(saveDraftToStorage, 30000);
      return () => clearInterval(autosaveInterval);
    } catch (error) {
      console.error('Failed to load data:', error);
      alert('Failed to load exercises: ' + (error instanceof Error ? error.message : String(error)));
    }
  });

  // Initialize days when numberOfDays changes
  function initializeDays() {
    const currentDays = untrack(() => days);
    const newDays: PlannedDay[] = [];
    for (let i = 1; i <= numberOfDays; i++) {
      const existingDay = currentDays.find(d => d.day_number === i);
      if (existingDay) {
        newDays.push(existingDay);
      } else {
        newDays.push({
          day_number: i,
          day_name: `Day ${i}`,
          exercises: []
        });
      }
    }
    days = newDays;
  }

  // Re-initialize when numberOfDays changes
  $effect(() => {
    if (initialized) {
      initializeDays();
    }
  });

  // Search functionality
  let searchResults = $state<Exercise[]>([]);

  function handleSearch() {
    if (searchQuery.trim() === '') {
      searchResults = [];
      viewMode = 'browse';
      return;
    }
    viewMode = 'search';
    const query = searchQuery.toLowerCase();
    searchResults = allExercises.filter(ex =>
      ex.display_name.toLowerCase().includes(query) ||
      ex.name.toLowerCase().includes(query) ||
      ex.primary_muscles.some(m => m.toLowerCase().includes(query))
    );
  }

  function clearSearch() {
    searchQuery = '';
    searchResults = [];
    viewMode = 'browse';
  }

  function openExerciseSelector(dayNum: number) {
    selectingForDay = dayNum;
    showExerciseSelector = true;
    searchQuery = '';
    searchResults = [];
    viewMode = 'browse';
    configuringExercise = null;
    console.log('Modal opened - allExercises:', allExercises.length);
    console.log('groupedExercises keys:', Object.keys(groupedExercises));
    console.log('recentExercises:', recentExercises.length);
  }

  function closeExerciseSelector() {
    showExerciseSelector = false;
    configuringExercise = null;
  }

  function selectExercise(exercise: Exercise) {
    configuringExercise = {
      exercise_id: exercise.id,
      exercise: exercise
    };
    configSets = 3;
  }

  function addExerciseToDay() {
    if (!configuringExercise) return;

    const dayIndex = days.findIndex(d => d.day_number === selectingForDay);
    if (dayIndex === -1) return;

    const newExercise: PlannedExercise = {
      exercise_id: configuringExercise.exercise_id,
      sets: configSets,
      reps: 0,
      starting_weight_kg: 0,
      progression_type: 'linear',
      rest_seconds: 90,
      notes: null
    };

    days[dayIndex].exercises = [...days[dayIndex].exercises, newExercise];
    days = [...days];
    closeExerciseSelector();
  }

  function removeExerciseFromDay(dayNum: number, exerciseIndex: number) {
    const dayIndex = days.findIndex(d => d.day_number === dayNum);
    if (dayIndex === -1) return;

    days[dayIndex].exercises = days[dayIndex].exercises.filter((_, i) => i !== exerciseIndex);
    days = [...days];
  }

  function updateDayName(dayNum: number, newName: string) {
    const dayIndex = days.findIndex(d => d.day_number === dayNum);
    if (dayIndex !== -1) {
      days[dayIndex].day_name = newName;
      days = [...days];
    }
  }

  // Drag and drop handlers
  function handleDragStart(dayNum: number, index: number, exercise: PlannedExercise) {
    draggedExercise = { dayNum, index, exercise };
  }

  function handleDragOver(dayNum: number, e: DragEvent) {
    e.preventDefault();
    dragOverDay = dayNum;
  }

  function handleDragLeave() {
    dragOverDay = null;
  }

  function handleDrop(targetDayNum: number, e: DragEvent) {
    e.preventDefault();
    dragOverDay = null;

    if (!draggedExercise) return;
    if (draggedExercise.dayNum === targetDayNum) return;

    const sourceDayIndex = days.findIndex(d => d.day_number === draggedExercise!.dayNum);
    const targetDayIndex = days.findIndex(d => d.day_number === targetDayNum);

    if (sourceDayIndex === -1 || targetDayIndex === -1) return;

    // Remove from source
    days[sourceDayIndex].exercises = days[sourceDayIndex].exercises.filter(
      (_, i) => i !== draggedExercise!.index
    );

    // Add to target
    days[targetDayIndex].exercises = [...days[targetDayIndex].exercises, draggedExercise.exercise];

    days = [...days];
    draggedExercise = null;
  }

  // Custom exercise
  function openCustomExerciseModal() {
    showCustomExerciseModal = true;
    customExerciseName = '';
    customExerciseDisplayName = '';
    customMovementType = 'compound';
    customBodyRegion = 'upper';
    customPrimaryMuscles = [];
    customSecondaryMuscles = [];
  }

  function closeCustomExerciseModal() {
    showCustomExerciseModal = false;
  }

  async function createCustomExercise() {
    if (!customExerciseDisplayName) return;
    if (customPrimaryMuscles.length === 0) {
      alert('Please select at least one primary muscle group');
      return;
    }

    // Capitalize first letter of each word for display name
    const capitalizeWords = (str: string) => str.replace(/\b\w/g, c => c.toUpperCase());
    const capitalizedDisplayName = capitalizeWords(customExerciseDisplayName);

    // Generate system name from display name
    const systemName = capitalizedDisplayName
      .toLowerCase()
      .replace(/[^\w\s]/g, '')
      .replace(/\s+/g, '_');

    try {
      console.log('Creating exercise:', { name: systemName, display_name: capitalizedDisplayName });
      const newExercise = await createExercise({
        name: systemName,
        display_name: capitalizedDisplayName,
        movement_type: customMovementType as 'compound' | 'isolation',
        body_region: customBodyRegion as 'upper' | 'lower' | 'full_body',
        primary_muscles: customPrimaryMuscles,
        secondary_muscles: customSecondaryMuscles,
      });
      console.log('Exercise created:', newExercise);

      // Refresh exercises
      const [exercisesData, groupedData] = await Promise.all([
        getExercises(),
        getExercisesGrouped(),
      ]);
      exercises.set(exercisesData);
      allExercises = exercisesData;
      groupedExercises = groupedData;

      // Select the new exercise
      selectExercise(newExercise);
      closeCustomExerciseModal();
    } catch (error) {
      console.error('Failed to create custom exercise:', error);
      alert('Failed to create exercise: ' + (error instanceof Error ? error.message : 'Unknown error'));
    }
  }

  function buildPlanData(isDraft: boolean = false) {
    return {
      name: newPlanName || (isDraft ? 'Untitled Draft' : ''),
      description: newPlanDescription,
      block_type: blockType,
      duration_weeks: durationWeeks,
      number_of_days: numberOfDays,
      days: days,
      auto_progression: true,
      is_draft: isDraft,
    };
  }

  async function handleCreatePlan() {
    try {
      await createPlan(buildPlanData(false));
      clearDraftFromStorage();
      goto('/plans');
    } catch (error) {
      console.error('Failed to create plan:', error);
      alert('Failed to create plan: ' + (error instanceof Error ? error.message : String(error)));
    }
  }

  async function handleSaveDraft() {
    try {
      await createPlan(buildPlanData(true));
      clearDraftFromStorage();
      goto('/plans');
    } catch (error) {
      console.error('Failed to save draft:', error);
      alert('Failed to save draft: ' + (error instanceof Error ? error.message : String(error)));
    }
  }

  // ── localStorage autosave ─────────────────────────────────────────────
  const DRAFT_KEY = 'hgt_plan_draft';

  function saveDraftToStorage() {
    if (typeof localStorage === 'undefined') return;
    const draft = {
      name: newPlanName, description: newPlanDescription, blockType, durationWeeks,
      numberOfDays, days, currentStep, savedAt: Date.now(),
    };
    localStorage.setItem(DRAFT_KEY, JSON.stringify(draft));
  }

  function clearDraftFromStorage() {
    if (typeof localStorage !== 'undefined') localStorage.removeItem(DRAFT_KEY);
  }

  function restoreDraftFromStorage(): boolean {
    if (typeof localStorage === 'undefined') return false;
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return false;
    try {
      const draft = JSON.parse(raw);
      if (Date.now() - draft.savedAt > 7 * 24 * 60 * 60 * 1000) {
        clearDraftFromStorage();
        return false; // Older than 7 days
      }
      newPlanName = draft.name || '';
      newPlanDescription = draft.description || '';
      blockType = draft.blockType || 'other';
      durationWeeks = draft.durationWeeks || 4;
      numberOfDays = draft.numberOfDays || 3;
      days = draft.days || [];
      currentStep = draft.currentStep || 1;
      return true;
    } catch { return false; }
  }

  function goToStep2() {
    if (!newPlanName.trim()) {
      alert('Please enter a plan name');
      return;
    }
    initializeDays();
    currentStep = 2;
  }

  function goBackToStep1() {
    currentStep = 1;
  }

  function cancel() {
    goto('/plans');
  }

  async function loadTemplates() {
    try {
      templates = await getTemplates();
    } catch { templates = []; }
  }

  let filteredTemplates = $derived(
    templates.filter(t => {
      if (splitFilter && t.split_type !== splitFilter) return false;
      if (equipFilter && t.equipment_tier !== equipFilter) return false;
      return true;
    })
  );

  function getExName(exId: number): string {
    return allExercises.find(e => e.id === exId)?.display_name || `Exercise #${exId}`;
  }

  async function importTemplate(tmpl: WorkoutTemplate) {
    cloning = true;
    try {
      const { cloneTemplate } = await import('$lib/api');
      const result = await cloneTemplate(tmpl.id);
      previewTmpl = null;
      goto('/plans');
    } catch (e) {
      alert('Failed to import template');
    }
    cloning = false;
  }

  function getExerciseName(exerciseId: number): string {
    const ex = allExercises.find(e => e.id === exerciseId);
    return ex?.display_name || `Exercise ${exerciseId}`;
  }

  const muscleGroupNames: Record<string, string> = {
    quadriceps: 'Quadriceps',
    hamstrings: 'Hamstrings',
    glutes: 'Glutes',
    chest: 'Chest',
    lats: 'Lats',
    upper_back: 'Upper Back',
    mid_back: 'Mid Back',
    lower_back: 'Lower Back',
    shoulders: 'Shoulders',
    biceps: 'Biceps',
    triceps: 'Triceps',
    core: 'Core',
    abs: 'Abs',
    obliques: 'Obliques',
    calves: 'Calves',
    traps: 'Traps',
    forearms: 'Forearms',
    neck: 'Neck',
    front_delts: 'Front Delts',
    side_delts: 'Side Delts',
    rear_delts: 'Rear Delts',
    adductors: 'Adductors',
  };

  const muscleGroups = [
    { value: 'chest', label: 'Chest' },
    { value: 'lats', label: 'Lats' },
    { value: 'upper_back', label: 'Upper Back' },
    { value: 'mid_back', label: 'Mid Back' },
    { value: 'lower_back', label: 'Lower Back' },
    { value: 'shoulders', label: 'Shoulders' },
    { value: 'traps', label: 'Traps' },
    { value: 'biceps', label: 'Biceps' },
    { value: 'triceps', label: 'Triceps' },
    { value: 'forearms', label: 'Forearms' },
    { value: 'quadriceps', label: 'Quadriceps' },
    { value: 'hamstrings', label: 'Hamstrings' },
    { value: 'glutes', label: 'Glutes' },
    { value: 'calves', label: 'Calves' },
    { value: 'abs', label: 'Abs' },
    { value: 'core', label: 'Core' },
    { value: 'obliques', label: 'Obliques' },
    { value: 'neck', label: 'Neck' },
    { value: 'front_delts', label: 'Front Delts' },
    { value: 'side_delts', label: 'Side Delts' },
    { value: 'rear_delts', label: 'Rear Delts' },
    { value: 'adductors', label: 'Adductors' },
  ];

  const movementTypes = [
    { value: 'compound', label: 'Compound' },
    { value: 'isolation', label: 'Isolation' },
  ];

  const bodyRegions = [
    { value: 'upper', label: 'Upper Body' },
    { value: 'lower', label: 'Lower Body' },
    { value: 'full_body', label: 'Full Body' },
  ];
</script>

<div class="min-h-screen bg-gray-900">
  <!-- Header -->
  <div class="bg-zinc-900 border-b border-zinc-800 p-4">
    <div class="max-w-7xl mx-auto flex items-center justify-between">
      <div class="flex items-center gap-4">
        <button onclick={() => {
          if (createMode === 'template' || createMode === 'custom') { createMode = 'choose'; }
          else if (currentStep === 2) { goBackToStep1(); }
          else { cancel(); }
        }} class="text-zinc-400 hover:text-white">
          ← {createMode === 'choose' ? 'Back to Plans' : 'Back'}
        </button>
        <h1 class="text-xl font-bold">
          {createMode === 'choose' ? 'New Plan' : createMode === 'template' ? 'Choose Template' : 'Build Custom Plan'}
        </h1>
      </div>

      {#if currentStep === 2 && createMode === 'custom'}
        <button onclick={handleSaveDraft} class="btn-ghost">Save Draft</button>
        <button onclick={handleCreatePlan} class="btn-primary">Create Plan</button>
      {/if}
    </div>
  </div>

  <div class="p-6 max-w-7xl mx-auto space-y-6">

    <!-- Step 0: Choose method -->
    {#if createMode === 'choose'}
      <div class="max-w-md mx-auto space-y-4 pt-8">
        <button onclick={() => { createMode = 'template'; loadTemplates(); }}
                class="card !p-6 w-full text-left hover:bg-zinc-800/60 transition-colors">
          <h3 class="font-semibold text-white text-lg">Use a Template</h3>
          <p class="text-sm text-zinc-400 mt-1">65 pre-built programs across Full Body, Upper/Lower, PPL, and Bro splits. Choose your equipment level and days per week.</p>
        </button>

        <button onclick={() => { createMode = 'custom'; currentStep = 1; }}
                class="card !p-6 w-full text-left hover:bg-zinc-800/60 transition-colors">
          <h3 class="font-semibold text-white text-lg">Build from Scratch</h3>
          <p class="text-sm text-zinc-400 mt-1">Create a fully custom plan — pick exercises, set counts, and day splits yourself.</p>
        </button>
      </div>

    <!-- Template browser -->
    {:else if createMode === 'template'}
      <div class="max-w-2xl mx-auto space-y-4">
        <!-- Filters -->
        <div class="flex gap-2 overflow-x-auto pb-1">
          <button onclick={() => splitFilter = null}
                  class="shrink-0 px-3 py-1.5 rounded-full text-sm font-medium transition-colors
                         {!splitFilter ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
            All
          </button>
          {#each SPLITS as s}
            <button onclick={() => splitFilter = splitFilter === s.key ? null : s.key}
                    class="shrink-0 px-3 py-1.5 rounded-full text-sm font-medium transition-colors
                           {splitFilter === s.key ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
              {s.label}
            </button>
          {/each}
        </div>
        <div class="flex gap-2">
          <select bind:value={equipFilter}
                  class="flex-1 bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white">
            <option value={null}>All Equipment</option>
            {#each EQUIP_TIERS as e}
              <option value={e.key}>{e.label}</option>
            {/each}
          </select>
        </div>

        <!-- Template list -->
        {#if filteredTemplates.length === 0}
          <p class="text-center py-8 text-zinc-500">No templates match your filters.</p>
        {:else}
          <div class="space-y-2">
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
          </div>
          <p class="text-center text-xs text-zinc-600">{filteredTemplates.length} templates</p>
        {/if}
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
                      <span class="text-zinc-300">{getExName(ex.exercise_id)}</span>
                      <span class="text-xs text-zinc-500">{ex.sets}×{ex.reps}</span>
                    </div>
                  {/each}
                </div>
              {/each}
            </div>
            <div class="p-4 border-t border-zinc-800 shrink-0">
              <button onclick={() => importTemplate(previewTmpl!)} disabled={cloning}
                      class="btn-primary w-full !py-3 disabled:opacity-50">
                {cloning ? 'Importing...' : 'Use This Template'}
              </button>
            </div>
          </div>
        </div>
      {/if}

    <!-- Custom plan builder: Step 1 -->
    {:else if currentStep === 1}
      {#if !initialized}
        <div class="card max-w-2xl mx-auto text-center py-12">
          <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-primary-500 mx-auto mb-4"></div>
          <p class="text-zinc-400 mb-4">Loading exercises...</p>
          <button
            class="px-4 py-2 bg-primary-600 text-white rounded hover:bg-primary-500"
            onclick={async () => {
              try {
                allExercises = await getExercises();
                groupedExercises = await getExercisesGrouped();
                recentExercises = await getRecentExercises(15);
                initialized = true;
              } catch (e) {
                alert('Failed: ' + (e instanceof Error ? e.message : String(e)));
              }
            }}
          >
            Retry Load
          </button>
        </div>
      {:else}
      <div class="card max-w-2xl mx-auto">
        <h2 class="text-lg font-semibold mb-6">Basic Information</h2>
        <div class="space-y-4">
          <div>
            <label class="label">Plan Name *</label>
            <input
              type="text"
              bind:value={newPlanName}
              class="input"
              placeholder="e.g., Hypertrophy Block 1"
            />
          </div>

          <div>
            <label class="label">Description (optional)</label>
            <input
              type="text"
              bind:value={newPlanDescription}
              class="input"
              placeholder="Brief description of this plan..."
            />
          </div>

          <div class="grid grid-cols-3 gap-4">
            <div>
              <label class="label">Block Type</label>
              <select bind:value={blockType} class="input">
                {#each blockTypes as type}
                  <option value={type.value}>{type.label}</option>
                {/each}
              </select>
            </div>

            <div>
              <label class="label">Duration (weeks)</label>
              <input
                type="number"
                bind:value={durationWeeks}
                class="input"
                min="1"
                max="12"
              />
            </div>

            <div>
              <label class="label">Number of Days *</label>
              <select bind:value={numberOfDays} class="input">
                {#each [1, 2, 3, 4, 5, 6, 7] as n}
                  <option value={n}>{n} {n === 1 ? 'day' : 'days'}</option>
                {/each}
              </select>
            </div>
          </div>
        </div>

        <div class="flex justify-end gap-3 mt-8">
          <button onclick={cancel} class="btn-secondary">Cancel</button>
          <button onclick={goToStep2} class="btn-primary">Next Step</button>
        </div>
      </div>
      {/if}
    {/if}

    <!-- Step 2: Days Configuration -->
    {#if currentStep === 2}
      <div class="space-y-4">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-semibold">Configure Days</h2>
          <p class="text-sm text-zinc-400">Drag and drop exercises between days to reorganize</p>
        </div>

        <!-- Days grid - responsive columns -->
        <div class="grid gap-4" style="grid-template-columns: repeat({Math.min(numberOfDays, 7)}, minmax(280px, 1fr));">
          {#each days as day}
            <div
              class="border border-zinc-800 rounded-lg p-4 min-h-[400px] transition-colors {dragOverDay === day.day_number ? 'border-primary-500 bg-zinc-800/30' : 'bg-zinc-900'}"
              ondragover={(e) => handleDragOver(day.day_number, e)}
              ondragleave={handleDragLeave}
              ondrop={(e) => handleDrop(day.day_number, e)}
              role="region"
              aria-label="Day {day.day_number}"
            >
              <!-- Day header -->
              <div class="mb-4">
                <input
                  type="text"
                  value={day.day_name}
                  oninput={(e) => updateDayName(day.day_number, (e.target as HTMLInputElement).value)}
                  class="input text-sm font-medium bg-transparent border-0 px-0 py-1 focus:bg-zinc-800"
                  placeholder="Day name..."
                />
              </div>

              <!-- Add exercise button -->
              <button
                onclick={() => openExerciseSelector(day.day_number)}
                class="w-full py-2 border-2 border-dashed border-zinc-700 rounded-lg text-zinc-400 hover:border-primary-500 hover:text-primary-400 transition-colors text-sm mb-4"
              >
                + Add Exercise
              </button>

              <!-- Exercises list -->
              <div class="space-y-2">
                {#each day.exercises as ex, idx}
                  <div
                    class="bg-zinc-800 rounded-lg p-3 cursor-move hover:bg-gray-600 transition-colors"
                    draggable="true"
                    ondragstart={() => handleDragStart(day.day_number, idx, ex)}
                    role="button"
                    tabindex="0"
                    aria-grabbed="true"
                  >
                    <div class="flex items-start justify-between gap-2">
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2 mb-1.5">
                          <span class="text-zinc-400 text-xs shrink-0">#{idx + 1}</span>
                          <span class="font-medium text-sm truncate">{getExerciseName(ex.exercise_id)}</span>
                        </div>
                        <!-- Inline editable sets only -->
                        <div class="flex items-center gap-2">
                          <label class="text-xs text-zinc-500">Sets</label>
                          <input
                            type="number"
                            value={ex.sets}
                            oninput={(e) => {
                              const v = parseInt((e.target as HTMLInputElement).value);
                              if (!isNaN(v) && v > 0) {
                                days[days.findIndex(d => d.day_number === day.day_number)].exercises[idx].sets = v;
                                days = [...days];
                              }
                            }}
                            min="1" max="20"
                            class="w-16 bg-gray-600 border border-gray-500 rounded px-2 py-1 text-sm text-center focus:outline-none focus:border-primary-500"
                            onclick={(e) => e.stopPropagation()}
                          />
                        </div>
                      </div>
                      <button
                        onclick={() => removeExerciseFromDay(day.day_number, idx)}
                        class="text-red-400 hover:text-red-300 text-xs shrink-0 mt-1"
                        aria-label="Remove exercise"
                      >
                        ✕
                      </button>
                    </div>
                  </div>
                {/each}
              </div>

              {#if day.exercises.length === 0}
                <p class="text-zinc-500 text-sm text-center py-8">No exercises yet. Click "Add Exercise" to start.</p>
              {/if}
            </div>
          {/each}
        </div>
      </div>
    {/if}
  </div>
</div>

<!-- Exercise Selector Modal -->
{#if showExerciseSelector}
  <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-[60] p-4">
    <div class="card max-w-2xl w-full max-h-[80vh] overflow-y-auto">
      <div class="flex items-center justify-between mb-4">
        <h4 class="text-lg font-semibold">Add Exercise to {days.find(d => d.day_number === selectingForDay)?.day_name}</h4>
        <button onclick={closeExerciseSelector} class="text-zinc-400 hover:text-white">✕</button>
      </div>

      {#if configuringExercise}
        <!-- Exercise Configuration -->
        <div class="space-y-4">
          <!-- Exercise header -->
          <div class="bg-zinc-800 rounded-lg p-4">
            <h5 class="font-medium mb-1">{configuringExercise.exercise?.display_name}</h5>
            <p class="text-sm text-zinc-400">{configuringExercise.exercise?.primary_muscles.join(', ')}</p>
          </div>

          <!-- Sets only — weight & reps are set during the workout -->
          <div>
            <label class="label">Number of Sets</label>
            <input
              type="number"
              bind:value={configSets}
              min="1"
              max="20"
              class="input max-w-[120px]"
            />
            <p class="text-xs text-zinc-500 mt-1">Weight and reps are logged during the workout.</p>
          </div>

          <div class="flex justify-between gap-3">
            <button
              onclick={async () => {
                if (!configuringExercise?.exercise) return;
                if (!confirm(`Delete "${configuringExercise.exercise.display_name}"? This cannot be undone.`)) return;
                try {
                  await deleteExercise(configuringExercise.exercise.id);
                  const [exercisesData, groupedData] = await Promise.all([
                    getExercises(),
                    getExercisesGrouped(),
                  ]);
                  exercises.set(exercisesData);
                  allExercises = exercisesData;
                  groupedExercises = groupedData;
                  closeExerciseSelector();
                } catch (error) {
                  alert('Failed to delete: ' + (error instanceof Error ? error.message : String(error)));
                }
              }}
              class="px-4 py-2 rounded bg-red-600 text-white hover:bg-red-500 transition-colors text-sm"
            >
              Delete Exercise
            </button>
            <div class="flex gap-3">
              <button onclick={() => configuringExercise = null} class="btn-secondary">Back</button>
              <button onclick={addExerciseToDay} class="btn-primary">Add to Day</button>
            </div>
          </div>
        </div>
      {:else}
        <!-- Exercise Selection -->
        <div class="space-y-4">
          <!-- Search bar -->
          <div class="flex gap-2">
            <input
              type="text"
              bind:value={searchQuery}
              oninput={handleSearch}
              class="input flex-1"
              placeholder="Search exercises..."
              autofocus
            />
            {#if searchQuery}
              <button onclick={clearSearch} class="btn-secondary">Clear</button>
            {/if}
          </div>

          <!-- View toggle -->
          <div class="flex gap-2">
            <button
              onclick={() => viewMode = 'browse'}
              class="px-3 py-1.5 rounded text-sm font-medium transition-colors {viewMode === 'browse' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-gray-300 hover:bg-gray-600'}"
            >
              Browse by Muscle
            </button>
            <button
              onclick={() => viewMode = 'search'}
              class="px-3 py-1.5 rounded text-sm font-medium transition-colors {viewMode === 'search' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-gray-300 hover:bg-gray-600'}"
              disabled={searchResults.length === 0}
            >
              Search Results ({searchResults.length})
            </button>
            <button
              onclick={openCustomExerciseModal}
              class="ml-auto px-3 py-1.5 rounded text-sm font-medium bg-green-600 text-white hover:bg-green-500 transition-colors"
            >
              + Custom Exercise
            </button>
          </div>

          {#if viewMode === 'search'}
            <!-- Search Results -->
            <div>
              {#if searchResults.length === 0}
                <p class="text-zinc-500 text-sm text-center py-4">No exercises found. Try a different search or create a custom exercise.</p>
              {:else}
                <div class="space-y-1 max-h-64 overflow-y-auto">
                  {#each searchResults as exercise}
                    <div class="flex items-center justify-between gap-2">
                      <button
                        onclick={() => selectExercise(exercise)}
                        class="flex-1 text-left px-3 py-2 rounded hover:bg-zinc-800 transition-colors"
                      >
                        <div class="flex items-center justify-between">
                          <span class="font-medium">{exercise.display_name}</span>
                          <span class="text-xs text-zinc-400">{exercise.primary_muscles[0] || 'other'}</span>
                        </div>
                      </button>
                      <button
                        onclick={async (e) => {
                          e.stopPropagation();
                          if (!confirm(`Delete "${exercise.display_name}"? This cannot be undone.`)) return;
                          try {
                            await deleteExercise(exercise.id);
                            // Refresh exercises list
                            const [exercisesData, groupedData] = await Promise.all([
                              getExercises(),
                              getExercisesGrouped(),
                            ]);
                            exercises.set(exercisesData);
                            allExercises = exercisesData;
                            groupedExercises = groupedData;
                            handleSearch(); // Re-run search
                          } catch (error) {
                            alert('Failed to delete: ' + (error instanceof Error ? error.message : String(error)));
                          }
                        }}
                        class="px-2 py-2 text-red-400 hover:text-red-300 hover:bg-zinc-800 rounded transition-colors"
                        title="Delete exercise"
                      >
                        🗑️
                      </button>
                    </div>
                  {/each}
                </div>
              {/if}
            </div>
          {:else}
            <!-- Browse View -->
            <div class="space-y-4">
              <!-- Recently Used -->
              {#if recentExercises.length > 0 && searchQuery === ''}
                <div>
                  <h5 class="text-sm font-medium text-zinc-400 mb-2">Recently Used</h5>
                  <div class="space-y-1 max-h-40 overflow-y-auto">
                    {#each recentExercises as exercise}
                      <div class="flex items-center justify-between gap-2">
                        <button
                          onclick={() => selectExercise(exercise)}
                          class="flex-1 text-left px-3 py-2 rounded hover:bg-zinc-800 transition-colors"
                        >
                          <div class="flex items-center justify-between">
                            <span class="font-medium">{exercise.display_name}</span>
                            <span class="text-xs text-zinc-400">Used {exercise.usage_count} times</span>
                          </div>
                        </button>
                        <button
                          onclick={async (e) => {
                            e.stopPropagation();
                            if (!confirm(`Delete "${exercise.display_name}"? This cannot be undone.`)) return;
                            try {
                              await deleteExercise(exercise.id);
                              const [exercisesData, groupedData] = await Promise.all([
                                getExercises(),
                                getExercisesGrouped(),
                              ]);
                              exercises.set(exercisesData);
                              allExercises = exercisesData;
                              groupedExercises = groupedData;
                            } catch (error) {
                              alert('Failed to delete: ' + (error instanceof Error ? error.message : String(error)));
                            }
                          }}
                          class="px-2 py-2 text-red-400 hover:text-red-300 hover:bg-zinc-800 rounded transition-colors"
                          title="Delete exercise"
                        >
                          🗑️
                        </button>
                      </div>
                    {/each}
                  </div>
                </div>
              {/if}

              <!-- Grouped by Muscle -->
              <div>
                <h5 class="text-sm font-medium text-zinc-400 mb-2">Browse by Muscle Group</h5>
                {#if Object.keys(groupedExercises).length === 0}
                  <p class="text-zinc-500 text-sm text-center py-4">No exercises loaded. Check console for errors.</p>
                {:else}
                  <div class="space-y-2 max-h-64 overflow-y-auto">
                    {#each Object.entries(groupedExercises) as [muscle, muscleExercises]}
                      <div class="border border-zinc-800 rounded-lg overflow-hidden">
                        <button
                          onclick={() => toggleMuscleGroup(muscle)}
                          class="w-full flex items-center justify-between px-3 py-2 bg-zinc-800/50 hover:bg-zinc-800 transition-colors"
                        >
                          <span class="text-sm font-medium text-primary-400">
                            {muscleGroupNames[muscle] || muscle} ({muscleExercises.length})
                          </span>
                          <span class="text-zinc-400">
                            {expandedMuscleGroups[muscle] ? '−' : '+'}
                          </span>
                        </button>
                        {#if expandedMuscleGroups[muscle]}
                          <div class="space-y-1 px-3 py-2 bg-zinc-900">
                            {#each muscleExercises as exercise}
                              <div class="flex items-center justify-between gap-2">
                                <button
                                  onclick={() => selectExercise(exercise)}
                                  class="flex-1 text-left px-3 py-1.5 rounded hover:bg-zinc-800 transition-colors text-sm"
                                >
                                  {exercise.display_name}
                                </button>
                                <button
                                  onclick={async (e) => {
                                    e.stopPropagation();
                                    if (!confirm(`Delete "${exercise.display_name}"? This cannot be undone.`)) return;
                                    try {
                                      await deleteExercise(exercise.id);
                                      const [exercisesData, groupedData] = await Promise.all([
                                        getExercises(),
                                        getExercisesGrouped(),
                                      ]);
                                      exercises.set(exercisesData);
                                      allExercises = exercisesData;
                                      groupedExercises = groupedData;
                                    } catch (error) {
                                      alert('Failed to delete: ' + (error instanceof Error ? error.message : String(error)));
                                    }
                                  }}
                                  class="px-2 py-1.5 text-red-400 hover:text-red-300 hover:bg-zinc-800 rounded transition-colors text-sm"
                                  title="Delete exercise"
                                >
                                  🗑️
                                </button>
                              </div>
                            {/each}
                          </div>
                        {/if}
                      </div>
                    {/each}
                  </div>
                {/if}
              </div>
            </div>
          {/if}
        </div>
      {/if}
    </div>
  </div>
{/if}

<!-- Custom Exercise Modal -->
{#if showCustomExerciseModal}
  <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-[70] p-4">
    <div class="card max-w-md w-full">
      <div class="flex items-center justify-between mb-4">
        <h4 class="text-lg font-semibold">Create Custom Exercise</h4>
        <button onclick={closeCustomExerciseModal} class="text-zinc-400 hover:text-white">✕</button>
      </div>

      <div class="space-y-4">
        <div>
          <label class="label">Exercise Name *</label>
          <input
            type="text"
            bind:value={customExerciseDisplayName}
            class="input"
            placeholder="e.g., Incline Dumbbell Press"
          />
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="label">Movement Type</label>
            <select bind:value={customMovementType} class="input">
              {#each movementTypes as type}
                <option value={type.value}>{type.label}</option>
              {/each}
            </select>
          </div>
          <div>
            <label class="label">Body Region</label>
            <select bind:value={customBodyRegion} class="input">
              {#each bodyRegions as region}
                <option value={region.value}>{region.label}</option>
              {/each}
            </select>
          </div>
        </div>

        <div>
          <label class="label">Primary Muscle Groups *</label>
          <div class="flex flex-wrap gap-2">
            {#each muscleGroups as muscle}
              <button
                type="button"
                onclick={() => {
                  const idx = customPrimaryMuscles.indexOf(muscle.value);
                  if (idx >= 0) {
                    customPrimaryMuscles = customPrimaryMuscles.filter(m => m !== muscle.value);
                  } else {
                    customPrimaryMuscles = [...customPrimaryMuscles, muscle.value];
                  }
                }}
                class="px-3 py-2 rounded-lg text-sm font-medium transition-colors {customPrimaryMuscles.includes(muscle.value) ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-gray-300 hover:bg-gray-600'}"
              >
                {muscle.label}
              </button>
            {/each}
          </div>
        </div>

        <div>
          <label class="label">Secondary Muscle Groups</label>
          <div class="flex flex-wrap gap-2">
            {#each muscleGroups as muscle}
              <button
                type="button"
                onclick={() => {
                  const idx = customSecondaryMuscles.indexOf(muscle.value);
                  if (idx >= 0) {
                    customSecondaryMuscles = customSecondaryMuscles.filter(m => m !== muscle.value);
                  } else {
                    customSecondaryMuscles = [...customSecondaryMuscles, muscle.value];
                  }
                }}
                class="px-3 py-2 rounded-lg text-sm font-medium transition-colors {customSecondaryMuscles.includes(muscle.value) ? 'bg-purple-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-gray-600'}"
              >
                {muscle.label}
              </button>
            {/each}
          </div>
        </div>
      </div>

      <div class="flex justify-end gap-3 mt-6">
        <button onclick={closeCustomExerciseModal} class="btn-secondary">Cancel</button>
        <button
          onclick={createCustomExercise}
          class="btn-primary"
          disabled={!customExerciseDisplayName}
        >
          Create Exercise
        </button>
      </div>
    </div>
  </div>
{/if}
