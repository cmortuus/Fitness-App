<script lang="ts">
  import { onMount } from 'svelte';
  import {
    getNutritionEntries, addNutritionEntry, deleteNutritionEntry,
    getDailySummary, setMacroGoals,
    searchFoods, lookupBarcode, getCustomFoods, createCustomFood,
  } from '$lib/api';
  import type {
    NutritionEntry, DailySummary, DailyEntries,
    FoodSearchResult, FoodItem,
  } from '$lib/api';

  // ─── State ────────────────────────────────────────────────────────────────
  let selectedDate = $state(new Date().toISOString().slice(0, 10));
  let entries = $state<DailyEntries | null>(null);
  let summary = $state<DailySummary | null>(null);
  let loading = $state(true);

  // Add food modal
  let showAddModal = $state(false);
  let activeTab = $state<'search' | 'scan' | 'manual' | 'custom'>('search');

  // Search tab
  let searchQuery = $state('');
  let searchResults = $state<FoodSearchResult[]>([]);
  let searching = $state(false);
  let searchTimeout: ReturnType<typeof setTimeout> | null = null;

  // Manual tab
  let manualName = $state('');
  let manualCal = $state<number | null>(null);
  let manualProtein = $state<number | null>(null);
  let manualCarbs = $state<number | null>(null);
  let manualFat = $state<number | null>(null);
  let manualQty = $state(100);
  let saveAsCustom = $state(false);
  let showFullMacros = $state(false);

  // Custom foods tab
  let customFoods = $state<FoodItem[]>([]);
  let customQuery = $state('');

  // Log entry sub-view (from search/custom)
  let selectedFood = $state<FoodSearchResult | null>(null);
  let selectedQty = $state(100);

  // Goals modal
  let showGoalsModal = $state(false);
  let goalCal = $state(2000);
  let goalProtein = $state(150);
  let goalCarbs = $state(250);
  let goalFat = $state(65);

  // Barcode scanner
  let scannerActive = $state(false);
  let scanError = $state('');

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  onMount(() => { loadDay(); });

  async function loadDay() {
    loading = true;
    try {
      const [e, s] = await Promise.all([
        getNutritionEntries(selectedDate),
        getDailySummary(selectedDate),
      ]);
      entries = e;
      summary = s;
      if (s.goals) {
        goalCal = s.goals.calories;
        goalProtein = s.goals.protein;
        goalCarbs = s.goals.carbs;
        goalFat = s.goals.fat;
      }
    } catch (e) {
      console.error('Failed to load nutrition data:', e);
    }
    loading = false;
  }

  function changeDate(delta: number) {
    const d = new Date(selectedDate);
    d.setDate(d.getDate() + delta);
    selectedDate = d.toISOString().slice(0, 10);
    loadDay();
  }

  function formatDate(iso: string): string {
    const d = new Date(iso + 'T00:00:00');
    const today = new Date().toISOString().slice(0, 10);
    if (iso === today) return 'Today';
    const yesterday = new Date();
    yesterday.setDate(yesterday.getDate() - 1);
    if (iso === yesterday.toISOString().slice(0, 10)) return 'Yesterday';
    return d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
  }

  // ─── Progress ring helpers ────────────────────────────────────────────────
  const RING_R = 54;
  const RING_C = 2 * Math.PI * RING_R;
  function ringOffset(consumed: number, goal: number): number {
    if (goal <= 0) return RING_C;
    return RING_C * (1 - Math.min(consumed / goal, 1));
  }

  // ─── All entries flat ─────────────────────────────────────────────────────
  let allEntries = $derived(
    entries ? Object.values(entries.meals).flat().sort((a, b) =>
      new Date(b.logged_at).getTime() - new Date(a.logged_at).getTime()
    ) : []
  );

  // ─── Add entry ────────────────────────────────────────────────────────────
  function openAddModal() {
    activeTab = 'search';
    searchQuery = '';
    searchResults = [];
    selectedFood = null;
    manualName = '';
    manualCal = null;
    manualProtein = null;
    manualCarbs = null;
    manualFat = null;
    manualQty = 100;
    saveAsCustom = false;
    showFullMacros = false;
    showAddModal = true;
  }

  // Debounced search
  function onSearchInput() {
    if (searchTimeout) clearTimeout(searchTimeout);
    if (!searchQuery.trim()) { searchResults = []; return; }
    searching = true;
    searchTimeout = setTimeout(async () => {
      try {
        searchResults = await searchFoods(searchQuery.trim());
      } catch { searchResults = []; }
      searching = false;
    }, 500);
  }

  function selectFood(food: FoodSearchResult) {
    selectedFood = food;
    selectedQty = food.serving_size_g || 100;
  }

  function macrosForQty(food: FoodSearchResult, qty: number) {
    const scale = qty / 100;
    return {
      calories: Math.round((food.calories_per_100g ?? 0) * scale),
      protein: Math.round((food.protein_per_100g ?? 0) * scale * 10) / 10,
      carbs: Math.round((food.carbs_per_100g ?? 0) * scale * 10) / 10,
      fat: Math.round((food.fat_per_100g ?? 0) * scale * 10) / 10,
    };
  }

  async function logSelectedFood() {
    if (!selectedFood) return;
    const m = macrosForQty(selectedFood, selectedQty);
    await addNutritionEntry({
      name: selectedFood.name + (selectedFood.brand ? ` (${selectedFood.brand})` : ''),
      date: selectedDate,
      quantity_g: selectedQty,
      ...m,
    });
    showAddModal = false;
    selectedFood = null;
    await loadDay();
  }

  async function logManualEntry() {
    if (!manualName.trim()) return;
    const qty = manualQty || 100;
    await addNutritionEntry({
      name: manualName.trim(),
      date: selectedDate,
      quantity_g: qty,
      calories: manualCal ?? 0,
      protein: manualProtein ?? 0,
      carbs: manualCarbs ?? 0,
      fat: manualFat ?? 0,
    });

    if (saveAsCustom) {
      const scale = 100 / qty;
      await createCustomFood({
        name: manualName.trim(),
        calories_per_100g: (manualCal ?? 0) * scale,
        protein_per_100g: (manualProtein ?? 0) * scale,
        carbs_per_100g: (manualCarbs ?? 0) * scale,
        fat_per_100g: (manualFat ?? 0) * scale,
        serving_size_g: qty,
      });
    }
    showAddModal = false;
    await loadDay();
  }

  async function removeEntry(id: number) {
    await deleteNutritionEntry(id);
    await loadDay();
  }

  // Custom foods
  async function loadCustomFoods() {
    try { customFoods = await getCustomFoods(customQuery); } catch { customFoods = []; }
  }

  // Goals
  async function saveGoals() {
    await setMacroGoals({ calories: goalCal, protein: goalProtein, carbs: goalCarbs, fat: goalFat });
    showGoalsModal = false;
    await loadDay();
  }

  // Barcode scanning
  async function startScanner() {
    scannerActive = true;
    scanError = '';
    try {
      const { Html5Qrcode } = await import('html5-qrcode');
      const scanner = new Html5Qrcode('barcode-reader');
      await scanner.start(
        { facingMode: 'environment' },
        { fps: 10, qrbox: { width: 250, height: 150 } },
        async (decodedText) => {
          await scanner.stop();
          scannerActive = false;
          try {
            const result = await lookupBarcode(decodedText);
            selectedFood = result;
            selectedQty = result.serving_size_g || 100;
          } catch {
            scanError = `Barcode ${decodedText} not found. Try manual entry.`;
          }
        },
        () => {}
      );
    } catch {
      scanError = 'Camera access denied or not available.';
      scannerActive = false;
    }
  }
</script>

<div class="page-content px-4 py-4 space-y-4">

  <!-- ─── Date selector ─────────────────────────────────────────────────── -->
  <div class="flex items-center justify-between">
    <button onclick={() => changeDate(-1)}
            class="w-10 h-10 flex items-center justify-center rounded-xl bg-zinc-800 hover:bg-zinc-700 text-zinc-300 transition-colors text-lg">
      ‹
    </button>
    <h2 class="text-lg font-semibold text-white">{formatDate(selectedDate)}</h2>
    <button onclick={() => changeDate(1)}
            class="w-10 h-10 flex items-center justify-center rounded-xl bg-zinc-800 hover:bg-zinc-700 text-zinc-300 transition-colors text-lg">
      ›
    </button>
  </div>

  {#if loading}
    <div class="flex items-center justify-center py-20">
      <div class="animate-spin rounded-full h-10 w-10 border-b-2 border-primary-500"></div>
    </div>
  {:else}

    <!-- ─── Progress rings ───────────────────────────────────────────────── -->
    <div class="card">
      {#if !summary?.goals}
        <button onclick={() => showGoalsModal = true}
                class="w-full py-6 text-center text-zinc-400 hover:text-primary-400 transition-colors">
          <p class="text-sm">No macro goals set</p>
          <p class="text-primary-400 font-semibold mt-1">Tap to set daily targets</p>
        </button>
      {:else}
        <div class="flex items-center justify-around py-2">
          <!-- Calories ring -->
          <div class="flex flex-col items-center">
            <div class="relative w-28 h-28">
              <svg viewBox="0 0 120 120" class="w-full h-full -rotate-90">
                <circle cx="60" cy="60" r={RING_R} fill="none" stroke="rgba(255,255,255,0.06)" stroke-width="10" />
                <circle cx="60" cy="60" r={RING_R} fill="none" stroke="#3b82f6" stroke-width="10"
                        stroke-dasharray={RING_C} stroke-dashoffset={ringOffset(summary.totals.calories, summary.goals.calories)}
                        stroke-linecap="round" class="transition-all duration-500" />
              </svg>
              <div class="absolute inset-0 flex flex-col items-center justify-center">
                <span class="text-xl font-bold text-white">{Math.round(summary.totals.calories)}</span>
                <span class="text-[10px] text-zinc-500">/ {Math.round(summary.goals.calories)}</span>
              </div>
            </div>
            <span class="text-xs font-medium text-zinc-400 mt-1">Calories</span>
          </div>

          <!-- Protein ring -->
          <div class="flex flex-col items-center">
            <div class="relative w-28 h-28">
              <svg viewBox="0 0 120 120" class="w-full h-full -rotate-90">
                <circle cx="60" cy="60" r={RING_R} fill="none" stroke="rgba(255,255,255,0.06)" stroke-width="10" />
                <circle cx="60" cy="60" r={RING_R} fill="none" stroke="#a855f7" stroke-width="10"
                        stroke-dasharray={RING_C} stroke-dashoffset={ringOffset(summary.totals.protein, summary.goals.protein)}
                        stroke-linecap="round" class="transition-all duration-500" />
              </svg>
              <div class="absolute inset-0 flex flex-col items-center justify-center">
                <span class="text-xl font-bold text-white">{Math.round(summary.totals.protein)}g</span>
                <span class="text-[10px] text-zinc-500">/ {Math.round(summary.goals.protein)}g</span>
              </div>
            </div>
            <span class="text-xs font-medium text-zinc-400 mt-1">Protein</span>
          </div>
        </div>

        <!-- Carbs + Fat bars -->
        <div class="flex gap-4 mt-3 px-2">
          <div class="flex-1">
            <div class="flex justify-between text-xs text-zinc-500 mb-1">
              <span>Carbs</span>
              <span>{Math.round(summary.totals.carbs)}g / {Math.round(summary.goals.carbs)}g</span>
            </div>
            <div class="h-2 bg-zinc-800 rounded-full overflow-hidden">
              <div class="h-full bg-amber-500 rounded-full transition-all duration-500"
                   style="width: {Math.min(100, (summary.totals.carbs / summary.goals.carbs) * 100)}%"></div>
            </div>
          </div>
          <div class="flex-1">
            <div class="flex justify-between text-xs text-zinc-500 mb-1">
              <span>Fat</span>
              <span>{Math.round(summary.totals.fat)}g / {Math.round(summary.goals.fat)}g</span>
            </div>
            <div class="h-2 bg-zinc-800 rounded-full overflow-hidden">
              <div class="h-full bg-rose-500 rounded-full transition-all duration-500"
                   style="width: {Math.min(100, (summary.totals.fat / summary.goals.fat) * 100)}%"></div>
            </div>
          </div>
        </div>

        <button onclick={() => showGoalsModal = true}
                class="w-full mt-3 text-center text-xs text-zinc-600 hover:text-zinc-400 transition-colors">
          Edit goals
        </button>
      {/if}
    </div>

    <!-- ─── Food log ─────────────────────────────────────────────────────── -->
    <div class="card !p-0 overflow-hidden">
      <div class="flex items-center justify-between px-4 py-3">
        <h3 class="font-semibold text-white">Food Log</h3>
        <span class="text-xs text-zinc-500">{allEntries.length} item{allEntries.length !== 1 ? 's' : ''}</span>
      </div>

      {#if allEntries.length > 0}
        <div class="border-t border-zinc-800/50">
          {#each allEntries as entry}
            <div class="flex items-center justify-between px-4 py-2.5 border-b border-zinc-800/30 last:border-b-0">
              <div class="flex-1 min-w-0">
                <p class="text-sm text-white truncate">{entry.name}</p>
                <p class="text-xs text-zinc-500">{entry.quantity_g}g</p>
              </div>
              <div class="flex items-center gap-4 shrink-0">
                <div class="text-right">
                  <p class="text-sm font-medium text-white">{Math.round(entry.calories)} cal</p>
                  <p class="text-[10px] text-zinc-500">{Math.round(entry.protein)}g P</p>
                </div>
                <button onclick={() => removeEntry(entry.id)}
                        class="w-7 h-7 flex items-center justify-center text-zinc-600 hover:text-red-400 hover:bg-zinc-800 rounded transition-colors text-xs">
                  ✕
                </button>
              </div>
            </div>
          {/each}
        </div>
      {/if}

      <button onclick={openAddModal}
              class="w-full py-3 text-sm text-zinc-500 hover:text-primary-400 hover:bg-zinc-800/30 transition-colors font-medium border-t border-zinc-800/50">
        + Add Food
      </button>
    </div>

  {/if}
</div>

<!-- ─── Add Food Modal ───────────────────────────────────────────────────── -->
{#if showAddModal}
  <div class="fixed inset-0 bg-black/80 flex items-end sm:items-center justify-center z-50">
    <div class="bg-zinc-900 w-full sm:max-w-md sm:rounded-2xl rounded-t-2xl max-h-[92vh] flex flex-col border border-zinc-800 shadow-2xl">

      <!-- Header -->
      <div class="flex items-center justify-between px-4 py-3 border-b border-zinc-800 shrink-0">
        {#if selectedFood}
          <button onclick={() => selectedFood = null} class="text-zinc-400 hover:text-white text-sm">← Back</button>
        {:else}
          <h3 class="font-semibold text-white">Add Food</h3>
        {/if}
        <button onclick={() => { showAddModal = false; selectedFood = null; }} class="text-zinc-400 hover:text-white text-xl">✕</button>
      </div>

      {#if selectedFood}
        <!-- Log entry sub-view -->
        <div class="p-4 space-y-4 overflow-y-auto">
          <div>
            <h4 class="font-semibold text-white">{selectedFood.name}</h4>
            {#if selectedFood.brand}
              <p class="text-xs text-zinc-500">{selectedFood.brand}</p>
            {/if}
          </div>

          <div>
            <label class="text-xs text-zinc-400 block mb-1">Quantity (grams)</label>
            <input type="number" bind:value={selectedQty} min="1" class="input" />
            {#if selectedFood.serving_label}
              <p class="text-xs text-zinc-500 mt-1">Serving: {selectedFood.serving_label}</p>
            {/if}
          </div>

          {#if selectedFood}
            {@const m = macrosForQty(selectedFood, selectedQty)}
            <div class="grid grid-cols-4 gap-2 text-center">
              <div class="bg-zinc-800 rounded-xl p-2">
                <p class="text-lg font-bold text-white">{m.calories}</p>
                <p class="text-[10px] text-zinc-500">cal</p>
              </div>
              <div class="bg-zinc-800 rounded-xl p-2">
                <p class="text-lg font-bold text-purple-400">{m.protein}</p>
                <p class="text-[10px] text-zinc-500">protein</p>
              </div>
              <div class="bg-zinc-800 rounded-xl p-2">
                <p class="text-lg font-bold text-amber-400">{m.carbs}</p>
                <p class="text-[10px] text-zinc-500">carbs</p>
              </div>
              <div class="bg-zinc-800 rounded-xl p-2">
                <p class="text-lg font-bold text-rose-400">{m.fat}</p>
                <p class="text-[10px] text-zinc-500">fat</p>
              </div>
            </div>
          {/if}

          <button onclick={logSelectedFood} class="btn-primary w-full">Log Food</button>
        </div>

      {:else}
        <!-- Tabs -->
        <div class="flex border-b border-zinc-800 shrink-0">
          {#each [['search', 'Search'], ['scan', 'Scan'], ['manual', 'Manual'], ['custom', 'Saved']] as [tab, label]}
            <button onclick={() => { activeTab = tab as any; if (tab === 'custom') loadCustomFoods(); }}
                    class="flex-1 py-2.5 text-xs font-medium transition-colors
                           {activeTab === tab ? 'text-primary-400 border-b-2 border-primary-400' : 'text-zinc-500 hover:text-zinc-300'}">
              {label}
            </button>
          {/each}
        </div>

        <div class="flex-1 overflow-y-auto min-h-[40vh]">
          <!-- Search tab -->
          {#if activeTab === 'search'}
            <div class="p-4">
              <input type="text" bind:value={searchQuery} oninput={onSearchInput}
                     placeholder="Search foods…" class="input" />
            </div>
            {#if searching}
              <div class="flex justify-center py-8">
                <div class="animate-spin rounded-full h-6 w-6 border-b-2 border-primary-500"></div>
              </div>
            {:else}
              <div class="px-2">
                {#each searchResults as food}
                  <button onclick={() => selectFood(food)}
                          class="w-full text-left px-3 py-2.5 hover:bg-zinc-800 rounded-lg transition-colors">
                    <p class="text-sm text-white truncate">{food.name}</p>
                    <p class="text-xs text-zinc-500">
                      {food.brand ?? food.source}
                      {#if food.calories_per_100g != null}
                        · {Math.round(food.calories_per_100g)} cal/100g
                        · {Math.round(food.protein_per_100g ?? 0)}g P
                      {/if}
                    </p>
                  </button>
                {/each}
                {#if searchQuery && !searching && searchResults.length === 0}
                  <p class="text-center text-zinc-500 text-sm py-8">No results found</p>
                {/if}
              </div>
            {/if}

          <!-- Scan tab -->
          {:else if activeTab === 'scan'}
            <div class="p-4 space-y-4">
              {#if !scannerActive}
                <button onclick={startScanner} class="btn-primary w-full">Open Camera</button>
              {/if}
              <div id="barcode-reader" class="rounded-xl overflow-hidden"></div>
              {#if scanError}
                <p class="text-sm text-amber-400 text-center">{scanError}</p>
              {/if}
              <p class="text-xs text-zinc-500 text-center">Point camera at a food barcode</p>
            </div>

          <!-- Manual tab -->
          {:else if activeTab === 'manual'}
            <div class="p-4 space-y-3">
              <div>
                <label class="text-xs text-zinc-400 block mb-1">Food name</label>
                <input type="text" bind:value={manualName} placeholder="e.g. Chicken breast" class="input" />
              </div>
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="text-xs text-zinc-400 block mb-1">Calories</label>
                  <input type="number" bind:value={manualCal} placeholder="0" class="input" />
                </div>
                <div>
                  <label class="text-xs text-zinc-400 block mb-1">Protein (g)</label>
                  <input type="number" bind:value={manualProtein} placeholder="0" class="input" />
                </div>
              </div>

              <!-- Toggle for full macros -->
              <button onclick={() => showFullMacros = !showFullMacros}
                      class="text-xs text-zinc-500 hover:text-zinc-300 transition-colors">
                {showFullMacros ? '▾ Hide' : '▸ Show'} carbs & fat
              </button>

              {#if showFullMacros}
                <div class="grid grid-cols-2 gap-3">
                  <div>
                    <label class="text-xs text-zinc-400 block mb-1">Carbs (g)</label>
                    <input type="number" bind:value={manualCarbs} placeholder="0" class="input" />
                  </div>
                  <div>
                    <label class="text-xs text-zinc-400 block mb-1">Fat (g)</label>
                    <input type="number" bind:value={manualFat} placeholder="0" class="input" />
                  </div>
                </div>
              {/if}

              <div>
                <label class="text-xs text-zinc-400 block mb-1">Quantity (g)</label>
                <input type="number" bind:value={manualQty} min="1" class="input" />
              </div>
              <label class="flex items-center gap-2 text-sm text-zinc-400">
                <input type="checkbox" bind:checked={saveAsCustom} class="rounded bg-zinc-800 border-zinc-700" />
                Save as custom food
              </label>
              <button onclick={logManualEntry} disabled={!manualName.trim()}
                      class="btn-primary w-full disabled:opacity-40 disabled:cursor-not-allowed">
                Log Food
              </button>
            </div>

          <!-- Custom/saved tab -->
          {:else if activeTab === 'custom'}
            <div class="p-4">
              <input type="text" bind:value={customQuery}
                     oninput={() => loadCustomFoods()}
                     placeholder="Search saved foods…" class="input" />
            </div>
            <div class="px-2">
              {#each customFoods as food}
                <button onclick={() => { selectedFood = food; selectedQty = food.serving_size_g || 100; }}
                        class="w-full text-left px-3 py-2.5 hover:bg-zinc-800 rounded-lg transition-colors">
                  <p class="text-sm text-white truncate">{food.name}</p>
                  <p class="text-xs text-zinc-500">
                    {food.brand ?? 'Custom'}
                    {#if food.calories_per_100g != null}
                      · {Math.round(food.calories_per_100g)} cal/100g
                    {/if}
                  </p>
                </button>
              {/each}
              {#if customFoods.length === 0}
                <p class="text-center text-zinc-500 text-sm py-8">No saved foods yet</p>
              {/if}
            </div>
          {/if}
        </div>
      {/if}
    </div>
  </div>
{/if}

<!-- ─── Goals Modal ──────────────────────────────────────────────────────── -->
{#if showGoalsModal}
  <div class="fixed inset-0 bg-black/80 flex items-center justify-center z-50 px-4">
    <div class="bg-zinc-900 w-full max-w-sm rounded-2xl border border-zinc-800 shadow-2xl p-5 space-y-4">
      <h3 class="font-semibold text-white text-lg">Daily Macro Goals</h3>
      <div class="space-y-3">
        <div>
          <label class="text-xs text-zinc-400 block mb-1">Calories</label>
          <input type="number" bind:value={goalCal} class="input" />
        </div>
        <div>
          <label class="text-xs text-zinc-400 block mb-1">Protein (g)</label>
          <input type="number" bind:value={goalProtein} class="input" />
        </div>
        <div>
          <label class="text-xs text-zinc-400 block mb-1">Carbs (g)</label>
          <input type="number" bind:value={goalCarbs} class="input" />
        </div>
        <div>
          <label class="text-xs text-zinc-400 block mb-1">Fat (g)</label>
          <input type="number" bind:value={goalFat} class="input" />
        </div>
      </div>
      <div class="flex gap-2">
        <button onclick={() => showGoalsModal = false} class="btn-ghost flex-1">Cancel</button>
        <button onclick={saveGoals} class="btn-primary flex-1">Save</button>
      </div>
    </div>
  </div>
{/if}
