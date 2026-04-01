<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { activeDietPhase, settings } from '$lib/stores';
  import {
    getNutritionEntries, addNutritionEntry, updateNutritionEntry, deleteNutritionEntry,
    getDailySummary, setMacroGoals,
    searchFoods, lookupBarcode, getCustomFoods, createCustomFood, updateCustomFood, deleteCustomFood, createCommunityFood,
    getActivePhase, createPhase, endPhase, recalculatePhase,
    getRecipes, logRecipe, createRecipe, deleteRecipe,
  } from '$lib/api';
  import type { Recipe } from '$lib/api';
  import { MICRO_META } from '$lib/api';
  import { localDateString, parseLocalDateString, shiftLocalDateString } from '$lib/date';
  import { writeNutrition } from '$lib/healthkit';
  import type {
    NutritionEntry, DietPhase, DailySummary, DailyEntries,
    FoodSearchResult, FoodItem, Micronutrients,
  } from '$lib/api';

  const KG_TO_LBS = 2.20462;
  function formatWeight(kg: number): string {
    return $settings.weightUnit === 'lbs'
      ? `${(kg * KG_TO_LBS).toFixed(1)} lbs`
      : `${kg.toFixed(1)} kg`;
  }

  // ─── State ────────────────────────────────────────────────────────────────
  let selectedDate = $state(localDateString());
  let entries = $state<DailyEntries | null>(null);
  let summary = $state<DailySummary | null>(null);
  let loading = $state(true);

  // Add food modal
  let showAddModal = $state(false);
  let activeTab = $state<'search' | 'scan' | 'label' | 'manual' | 'custom' | 'quick' | 'recipes' | 'alcohol'>('search');

  // Search tab
  let searchQuery = $state('');
  let searchResults = $state<FoodSearchResult[]>([]);
  let searching = $state(false);
  let searchTimeout: ReturnType<typeof setTimeout> | null = null;

  // Manual tab
  let manualName = $state('');
  let manualBrand = $state('');
  let manualCal = $state<number | null>(null);
  let manualProtein = $state<number | null>(null);
  let manualCarbs = $state<number | null>(null);
  let manualFat = $state<number | null>(null);
  let manualQty = $state(100);
  let manualServingLabel = $state('');
  let saveAsCustom = $state(false);
  let showFullMacros = $state(false);
  let editingFood = $state<FoodItem | null>(null);

  // Inline entry editing
  let editingEntry = $state<NutritionEntry | null>(null);
  let editEntryCal = $state<number | null>(null);
  let editEntryProtein = $state<number | null>(null);
  let editEntryCarbs = $state<number | null>(null);
  let editEntryFat = $state<number | null>(null);
  let editEntryQty = $state<number | null>(null);
  let editEntryCalPerG = 0;
  let editEntryProteinPerG = 0;
  let editEntryCarbsPerG = 0;
  let editEntryFatPerG = 0;

  // Quick-add tab
  let quickCal = $state<number | null>(null);
  let quickProtein = $state<number | null>(null);
  let quickLabel = $state('');
  let quickMeal = $state<string>('snack');
  let quickSaving = $state(false);

  async function logQuickAdd() {
    if (!quickCal || quickCal <= 0) return;
    quickSaving = true;
    try {
      await addNutritionEntry({
        name: quickLabel.trim() || 'Quick Add',
        date: selectedDate,
        quantity_g: 0,
        calories: quickCal,
        protein: quickProtein ?? 0,
        carbs: 0,
        fat: 0,
        meal: quickMeal,
      });
      quickCal = null; quickProtein = null; quickLabel = ''; quickMeal = 'snack';
      showAddModal = false;
      await loadDay();
    } catch (e) { console.error('Quick add error:', e); }
    quickSaving = false;
  }

  // Alcohol calculator tab
  let alcoholDrinkType = $state<'beer' | 'wine' | 'spirit' | 'custom'>('beer');
  const DRINK_PRESETS = {
    beer:   { name: 'Beer',    volumeMl: 355, abv: 5.0 },
    wine:   { name: 'Wine',    volumeMl: 148, abv: 12.5 },
    spirit: { name: 'Spirit',  volumeMl: 44,  abv: 40.0 },
    custom: { name: 'Custom',  volumeMl: 355, abv: 5.0 },
  };
  let alcoholVolumeMl = $state(355);
  let alcoholAbv = $state(5.0);
  let alcoholName = $state('Beer');
  let alcoholMeal = $state('snack');
  let alcoholLogging = $state(false);

  $effect(() => {
    const p = DRINK_PRESETS[alcoholDrinkType];
    alcoholVolumeMl = p.volumeMl;
    alcoholAbv = p.abv;
    if (alcoholDrinkType !== 'custom') alcoholName = p.name;
  });

  // calories = volume_ml × (abv/100) × 0.789 × 7
  let alcoholCalories = $derived(Math.round(alcoholVolumeMl * (alcoholAbv / 100) * 0.789 * 7));

  async function logAlcohol() {
    alcoholLogging = true;
    try {
      await addNutritionEntry({
        name: alcoholName || 'Alcoholic drink',
        date: selectedDate,
        quantity_g: 0,
        calories: alcoholCalories,
        protein: 0,
        carbs: Math.round(alcoholVolumeMl * 0.03), // rough carb estimate
        fat: 0,
        meal: alcoholMeal,
      });
      showAddModal = false;
      await loadDay();
    } catch (e) { console.error('Alcohol log error:', e); }
    alcoholLogging = false;
  }

  // Recipes tab
  let recipes = $state<Recipe[]>([]);
  let recipesLoaded = $state(false);
  let showRecipeBuilder = $state(false);
  let selectedRecipe = $state<Recipe | null>(null);
  let recipeServings = $state(1);
  let recipeMeal = $state('snack');
  let recipeLogging = $state(false);
  // Recipe builder state
  let newRecipeName = $state('');
  let newRecipeDesc = $state('');
  let newRecipeServings = $state(1);
  let newRecipeIngredients = $state<{name: string; quantity: string; unit: string; calories: string; protein: string; carbs: string; fat: string}[]>([]);
  let recipeSaving = $state(false);
  let recipeBuilderSource = $state<'manual' | 'selection'>('manual');
  let entrySelectionMode = $state(false);
  let selectedEntryIds = $state<Set<number>>(new Set());

  async function loadRecipes() {
    try { recipes = await getRecipes(); recipesLoaded = true; } catch { recipes = []; }
  }

  async function logSelectedRecipe() {
    if (!selectedRecipe) return;
    recipeLogging = true;
    try {
      await logRecipe(selectedRecipe.id, { date: selectedDate, servings: recipeServings, meal_type: recipeMeal });
      selectedRecipe = null;
      showAddModal = false;
      await loadDay();
    } catch (e) { console.error('Recipe log error:', e); }
    recipeLogging = false;
  }

  async function saveNewRecipe() {
    if (!newRecipeName.trim()) return;
    recipeSaving = true;
    try {
      await createRecipe({
        name: newRecipeName.trim(),
        description: newRecipeDesc || undefined,
        servings: newRecipeServings,
        ingredients: newRecipeIngredients.filter(i => i.name.trim()).map(i => ({
          name: i.name.trim(),
          quantity: parseFloat(i.quantity) || 1,
          unit: i.unit || 'serving',
          calories: parseFloat(i.calories) || 0,
          protein: parseFloat(i.protein) || 0,
          carbs: parseFloat(i.carbs) || 0,
          fat: parseFloat(i.fat) || 0,
        })),
      });
      newRecipeName = ''; newRecipeDesc = ''; newRecipeServings = 1; newRecipeIngredients = [];
      recipeBuilderSource = 'manual';
      entrySelectionMode = false;
      selectedEntryIds = new Set();
      showRecipeBuilder = false;
      await loadRecipes();
    } catch (e) { console.error('Recipe save error:', e); }
    recipeSaving = false;
  }

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
  let lastScannedBarcode = $state('');
  let scannerInstance: any = null;

  async function stopScanner() {
    if (scannerInstance) {
      try { await scannerInstance.stop(); } catch {}
      try { scannerInstance.clear(); } catch {}
      scannerInstance = null;
    }
    scannerActive = false;
  }

  // OCR Label scanner
  let ocrProcessing = $state(false);
  let ocrError = $state('');
  let ocrLiveActive = $state(false);
  let ocrLiveStatus = $state('');
  let ocrWorker: any = null;
  let ocrVideoEl: HTMLVideoElement | null = null;
  let ocrCanvasEl: HTMLCanvasElement | null = null;
  let ocrStream: MediaStream | null = null;
  let ocrInterval: ReturnType<typeof setInterval> | null = null;
  let ocrResult = $state<{
    name: string; brand: string; barcode: string;
    servingSize: number; servingLabel: string;
    calories: number; protein: number; carbs: number; fat: number;
    fiber: number; sodium: number; sugar: number;
  } | null>(null);
  let ocrSaving = $state(false);
  let ocrFieldsFound = $state(0);
  let ocrScanning = $state(false);  // true while a frame is being processed
  let ocrPartialValues = $state<{ calories: number; protein: number; carbs: number; fat: number } | null>(null);

  // Phase wizard
  let showPhaseWizard = $state(false);
  let wizardStep = $state(1);
  let wizPhaseType = $state<'cut' | 'bulk' | 'maintenance'>('cut');
  let wizRate = $state(0.7);
  let wizDuration = $state(8);
  let wizActivity = $state(1.4);
  let wizTdeeOverride = $state<number | null>(null);
  let wizShowTdee = $state(false);
  let wizCarb = $state<'high' | 'moderate' | 'low'>('moderate');
  let wizBodyFat = $state<number | null>(null);
  let wizProtein = $state<number | null>(null);  // g per lb
  let wizPreview = $state<DietPhase | null>(null);
  let wizCreating = $state(false);

  // Micronutrients
  let showMicros = $state(false);

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  onMount(() => {
    loadDay();
    // Release camera if user switches away or closes app
    const handleVisibility = () => {
      if (document.hidden) stopLabelScanner(false);
    };
    document.addEventListener('visibilitychange', handleVisibility);
    window.addEventListener('beforeunload', () => stopLabelScanner(true));
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility);
      stopLabelScanner(true);
    };
  });

  onDestroy(() => { stopLabelScanner(true); });

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
      entrySelectionMode = false;
      selectedEntryIds = new Set();
    } catch (e) {
      console.error('Failed to load nutrition data:', e);
    }
    loading = false;
  }

  function changeDate(delta: number) {
    selectedDate = shiftLocalDateString(selectedDate, delta);
    loadDay();
  }

  function formatDate(iso: string): string {
    const d = parseLocalDateString(iso);
    const today = localDateString();
    if (iso === today) return 'Today';
    if (iso === shiftLocalDateString(today, -1)) return 'Yesterday';
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

  let selectedEntries = $derived(
    allEntries.filter((entry) => selectedEntryIds.has(entry.id))
  );

  // ─── Add entry ────────────────────────────────────────────────────────────
  function openAddModal() {
    activeTab = 'search';
    searchQuery = '';
    searchResults = [];
    selectedFood = null;
    manualName = '';
    manualBrand = '';
    manualCal = null;
    manualProtein = null;
    manualCarbs = null;
    manualFat = null;
    manualQty = 100;
    manualServingLabel = '';
    saveAsCustom = false;
    showFullMacros = false;
    editingFood = null;
    showRecipeBuilder = false;
    selectedRecipe = null;
    recipeBuilderSource = 'manual';
    showAddModal = true;
  }

  function toggleEntrySelection(id: number) {
    const next = new Set(selectedEntryIds);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    selectedEntryIds = next;
  }

  function cancelEntrySelection() {
    entrySelectionMode = false;
    selectedEntryIds = new Set();
  }

  function startRecipeFromSelectedEntries() {
    if (selectedEntries.length === 0) return;
    const sameMeal = selectedEntries.every((entry) => entry.meal === selectedEntries[0].meal);
    const mealLabel = sameMeal
      ? `${selectedEntries[0].meal.charAt(0).toUpperCase()}${selectedEntries[0].meal.slice(1)}`
      : 'Mixed Meal';

    newRecipeName = `${mealLabel} Recipe`;
    newRecipeDesc = `Created from ${selectedEntries.length} logged food${selectedEntries.length === 1 ? '' : 's'} on ${formatDate(selectedDate)}`;
    newRecipeServings = 1;
    newRecipeIngredients = selectedEntries.map((entry) => ({
      name: entry.name,
      quantity: entry.quantity_g > 0 ? String(Math.round(entry.quantity_g * 100) / 100) : '1',
      unit: entry.quantity_g > 0 ? 'g' : 'serving',
      calories: String(Math.round(entry.calories * 100) / 100),
      protein: String(Math.round(entry.protein * 100) / 100),
      carbs: String(Math.round(entry.carbs * 100) / 100),
      fat: String(Math.round(entry.fat * 100) / 100),
    }));
    recipeBuilderSource = 'selection';
    activeTab = 'recipes';
    showRecipeBuilder = true;
    selectedRecipe = null;
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
    let micros: Record<string, number> | undefined;
    if (food.micronutrients) {
      micros = {};
      for (const [k, v] of Object.entries(food.micronutrients)) {
        micros[k] = Math.round(v * scale * 100) / 100;
      }
    }
    return {
      calories: Math.round((food.calories_per_100g ?? 0) * scale),
      protein: Math.round((food.protein_per_100g ?? 0) * scale * 10) / 10,
      carbs: Math.round((food.carbs_per_100g ?? 0) * scale * 10) / 10,
      fat: Math.round((food.fat_per_100g ?? 0) * scale * 10) / 10,
      micronutrients: micros,
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
    writeNutrition({ calories: m.calories ?? 0, proteinG: m.protein, carbsG: m.carbs, fatG: m.fat }).catch(() => {});
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
    writeNutrition({ calories: manualCal ?? 0, proteinG: manualProtein ?? 0, carbsG: manualCarbs ?? 0, fatG: manualFat ?? 0 }).catch(() => {});

    if (saveAsCustom) {
      const scale = 100 / qty;
      await createCustomFood({
        name: manualName.trim(),
        brand: manualBrand.trim() || undefined,
        calories_per_100g: (manualCal ?? 0) * scale,
        protein_per_100g: (manualProtein ?? 0) * scale,
        carbs_per_100g: (manualCarbs ?? 0) * scale,
        fat_per_100g: (manualFat ?? 0) * scale,
        serving_size_g: qty,
        serving_label: manualServingLabel.trim() || undefined,
      });
    }
    showAddModal = false;
    await loadDay();
  }

  function startEditingFood(food: FoodItem) {
    const qty = food.serving_size_g || 100;
    const scale = qty / 100;
    activeTab = 'manual';
    editingFood = food;
    selectedFood = null;
    manualName = food.name;
    manualBrand = food.brand ?? '';
    manualQty = qty;
    manualServingLabel = food.serving_label ?? '';
    manualCal = Math.round((food.calories_per_100g ?? 0) * scale);
    manualProtein = Math.round((food.protein_per_100g ?? 0) * scale * 10) / 10;
    manualCarbs = Math.round((food.carbs_per_100g ?? 0) * scale * 10) / 10;
    manualFat = Math.round((food.fat_per_100g ?? 0) * scale * 10) / 10;
    showFullMacros = !!((food.carbs_per_100g ?? 0) || (food.fat_per_100g ?? 0));
    saveAsCustom = false;
    showAddModal = true;
  }

  async function saveEditedFood() {
    if (!editingFood || !manualName.trim()) return;
    const qty = manualQty || 100;
    const scale = 100 / qty;
    const updated = await updateCustomFood(editingFood.id, {
      name: manualName.trim(),
      brand: manualBrand.trim() || undefined,
      barcode: editingFood.barcode ?? undefined,
      calories_per_100g: (manualCal ?? 0) * scale,
      protein_per_100g: (manualProtein ?? 0) * scale,
      carbs_per_100g: (manualCarbs ?? 0) * scale,
      fat_per_100g: (manualFat ?? 0) * scale,
      serving_size_g: qty,
      serving_label: manualServingLabel.trim() || undefined,
    });
    customFoods = customFoods.map((food) => food.id === updated.id ? updated : food);
    editingFood = null;
    showAddModal = false;
  }

  async function removeEntry(id: number) {
    await deleteNutritionEntry(id);
    await loadDay();
  }

  function startEditEntry(entry: NutritionEntry) {
    if (editingEntry?.id === entry.id) { editingEntry = null; return; }
    editingEntry = entry;
    editEntryCal = Math.round(entry.calories);
    editEntryProtein = Math.round(entry.protein * 10) / 10;
    editEntryCarbs = Math.round(entry.carbs * 10) / 10;
    editEntryFat = Math.round(entry.fat * 10) / 10;
    editEntryQty = entry.quantity_g;
    const g = entry.quantity_g || 1;
    editEntryCalPerG = entry.calories / g;
    editEntryProteinPerG = entry.protein / g;
    editEntryCarbsPerG = entry.carbs / g;
    editEntryFatPerG = entry.fat / g;
  }

  function onEditQtyChange() {
    if (!editingEntry || !editEntryQty) return;
    const g = editEntryQty;
    editEntryCal = Math.round(editEntryCalPerG * g);
    editEntryProtein = Math.round(editEntryProteinPerG * g * 10) / 10;
    editEntryCarbs = Math.round(editEntryCarbsPerG * g * 10) / 10;
    editEntryFat = Math.round(editEntryFatPerG * g * 10) / 10;
  }

  async function saveEditEntry() {
    if (!editingEntry) return;
    await updateNutritionEntry(editingEntry.id, {
      quantity_g: editEntryQty ?? undefined,
      calories: editEntryCal ?? undefined,
      protein: editEntryProtein ?? undefined,
      carbs: editEntryCarbs ?? undefined,
      fat: editEntryFat ?? undefined,
    });
    editingEntry = null;
    await loadDay();
  }

  // Custom foods
  // ─── OCR Label Scanner ──────────────────────────────────────────────────
  function parseNutritionLabel(text: string) {
    const num = (pattern: RegExp) => {
      const m = text.match(pattern);
      return m ? parseFloat(m[1]) : 0;
    };
    const servingMatch = text.match(/serving\s*size[:\s]*(.+?)(?:\n|$)/i);
    const servingText = servingMatch?.[1]?.trim() || '';
    const servingG = num(/(\d+\.?\d*)\s*g/i) || 100;

    return {
      name: '', brand: '', barcode: '',
      servingSize: servingG,
      servingLabel: servingText || `${servingG}g`,
      calories: num(/calories[:\s]*(\d+)/i),
      fat: num(/total\s*fat[:\s]*(\d+\.?\d*)\s*g/i),
      carbs: num(/total\s*carbohydrate[s]?[:\s]*(\d+\.?\d*)\s*g/i),
      protein: num(/protein[:\s]*(\d+\.?\d*)\s*g/i),
      fiber: num(/dietary\s*fiber[:\s]*(\d+\.?\d*)\s*g/i),
      sodium: num(/sodium[:\s]*(\d+)\s*mg/i),
      sugar: num(/(?:total\s*)?sugars?[:\s]*(\d+\.?\d*)\s*g/i),
    };
  }

  async function startLabelScanner() {
    ocrError = '';
    ocrResult = null;
    ocrFieldsFound = 0;
    ocrLiveStatus = 'Starting camera...';
    ocrLiveActive = true;

    try {
      // Start camera
      ocrStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } }
      });
      // Wait for DOM to render video element
      await new Promise(r => setTimeout(r, 100));
      if (ocrVideoEl) {
        ocrVideoEl.srcObject = ocrStream;
        await ocrVideoEl.play();
      }

      // Init Tesseract worker once
      ocrLiveStatus = 'Loading OCR engine...';
      const { createWorker } = await import('tesseract.js');
      ocrWorker = await createWorker('eng');
      ocrLiveStatus = 'Point at nutrition label...';

      // Scan every 2 seconds
      ocrInterval = setInterval(() => scanFrame(), 2000);
    } catch (e) {
      ocrError = 'Camera access failed. Check permissions.';
      ocrLiveActive = false;
      console.error('Camera error:', e);
    }
  }

  async function scanFrame() {
    if (!ocrVideoEl || !ocrCanvasEl || !ocrWorker) return;
    const ctx = ocrCanvasEl.getContext('2d');
    if (!ctx) return;

    // Capture frame
    ocrCanvasEl.width = ocrVideoEl.videoWidth;
    ocrCanvasEl.height = ocrVideoEl.videoHeight;
    ctx.drawImage(ocrVideoEl, 0, 0);

    // Enhance: grayscale + contrast boost
    const img = ctx.getImageData(0, 0, ocrCanvasEl.width, ocrCanvasEl.height);
    for (let i = 0; i < img.data.length; i += 4) {
      // Grayscale
      const gray = img.data[i] * 0.299 + img.data[i+1] * 0.587 + img.data[i+2] * 0.114;
      // Contrast boost
      const c = gray > 128 ? Math.min(255, gray * 1.3) : Math.max(0, gray * 0.7);
      img.data[i] = img.data[i+1] = img.data[i+2] = c;
    }
    ctx.putImageData(img, 0, 0);

    try {
      ocrScanning = true;
      const { data } = await ocrWorker.recognize(ocrCanvasEl);
      ocrScanning = false;
      const parsed = parseNutritionLabel(data.text);

      // Count how many fields we found
      const fields = [parsed.calories, parsed.protein, parsed.carbs, parsed.fat].filter(v => v > 0).length;
      ocrFieldsFound = fields;
      ocrPartialValues = { calories: parsed.calories, protein: parsed.protein, carbs: parsed.carbs, fat: parsed.fat };

      if (fields >= 3) {
        // Good enough — stop scanning and show results
        parsed.barcode = lastScannedBarcode || '';
        ocrResult = parsed;
        ocrLiveStatus = '';
        stopLabelScanner(false);
      } else if (fields > 0) {
        ocrLiveStatus = `Found ${fields}/4 — hold steady...`;
      } else {
        ocrLiveStatus = 'Point at nutrition label...';
        ocrPartialValues = null;
      }
    } catch {
      ocrScanning = false;
    }
  }

  function stopLabelScanner(clearResult = true) {
    if (ocrInterval) { clearInterval(ocrInterval); ocrInterval = null; }
    if (ocrWorker) { ocrWorker.terminate().catch(() => {}); ocrWorker = null; }
    if (ocrStream) { ocrStream.getTracks().forEach(t => t.stop()); ocrStream = null; }
    ocrLiveActive = false;
    if (clearResult) { ocrResult = null; ocrFieldsFound = 0; }
  }

  async function processLabelImage(file: File) {
    ocrProcessing = true;
    ocrError = '';
    ocrResult = null;
    try {
      const { createWorker } = await import('tesseract.js');
      const worker = await createWorker('eng');
      const { data } = await worker.recognize(file);
      await worker.terminate();

      const parsed = parseNutritionLabel(data.text);
      if (parsed.calories <= 0 && parsed.protein <= 0 && parsed.carbs <= 0) {
        ocrError = 'Could not read nutrition values. Try a clearer photo with good lighting.';
      } else {
        parsed.barcode = lastScannedBarcode || '';
        ocrResult = parsed;
      }
    } catch (e) {
      ocrError = 'OCR failed. Try again with a clearer image.';
      console.error('OCR error:', e);
    }
    ocrProcessing = false;
  }

  async function saveCommunityFood() {
    if (!ocrResult) return;
    ocrSaving = true;
    try {
      const srv = ocrResult.servingSize || 100;
      const scale = 100 / srv; // Convert per-serving to per-100g
      const micros: Record<string, number> = {};
      if (ocrResult.fiber > 0) micros.fiber_g = Math.round(ocrResult.fiber * scale * 10) / 10;
      if (ocrResult.sodium > 0) micros.sodium_mg = Math.round(ocrResult.sodium * scale);
      if (ocrResult.sugar > 0) micros.sugar_g = Math.round(ocrResult.sugar * scale * 10) / 10;

      const food = await createCommunityFood({
        name: ocrResult.name || 'Scanned Food',
        brand: ocrResult.brand || undefined,
        barcode: ocrResult.barcode || undefined,
        calories_per_100g: Math.round(ocrResult.calories * scale),
        protein_per_100g: Math.round(ocrResult.protein * scale * 10) / 10,
        carbs_per_100g: Math.round(ocrResult.carbs * scale * 10) / 10,
        fat_per_100g: Math.round(ocrResult.fat * scale * 10) / 10,
        serving_size_g: srv,
        serving_label: ocrResult.servingLabel,
        micronutrients: Object.keys(micros).length > 0 ? micros : undefined,
      });
      // Select it for logging
      selectedFood = food;
      selectedQty = srv;
      if (food.source === 'pending') {
        ocrError = `Saved! ${food.submission_count ?? 1} verification(s) so far.`;
      } else if (food.source === 'community') {
        ocrError = 'Added to community library!';
      }
      ocrResult = null;
    } catch (e) {
      ocrError = 'Failed to save food. Please try again.';
    }
    ocrSaving = false;
  }

  async function loadCustomFoods() {
    try { customFoods = await getCustomFoods(customQuery); } catch { customFoods = []; }
  }

  // Goals
  async function saveGoals() {
    await setMacroGoals({ calories: goalCal, protein: goalProtein, carbs: goalCarbs, fat: goalFat });
    showGoalsModal = false;
    await loadDay();
  }

  // ─── Phase wizard ──────────────────────────────────────────────────────
  function openPhaseWizard() {
    wizardStep = 1;
    wizPhaseType = 'cut';
    wizRate = 0.7;
    wizDuration = 8;
    wizActivity = 1.4;
    wizTdeeOverride = null;
    wizShowTdee = false;
    wizCarb = 'moderate';
    wizBodyFat = null;
    wizProtein = null;
    wizPreview = null;
    showPhaseWizard = true;
  }

  async function startPhase() {
    wizCreating = true;
    try {
      const phase = await createPhase({
        phase_type: wizPhaseType,
        duration_weeks: wizDuration,
        target_rate_pct: wizRate,
        activity_multiplier: wizActivity,
        tdee_override: wizTdeeOverride,
        carb_preset: wizCarb,
        body_fat_pct: wizBodyFat,
        protein_per_lb: wizProtein,
      });
      activeDietPhase.set(phase);
      showPhaseWizard = false;
      await loadDay();
    } catch (e) {
      alert('Failed to start phase. Make sure you have a body weight logged.');
    }
    wizCreating = false;
  }

  async function handleEndPhase() {
    if (!confirm('End the current diet phase?')) return;
    await endPhase();
    activeDietPhase.set(null);
    await loadDay();
  }

  async function handleRecalculate() {
    const phase = await recalculatePhase(true);
    activeDietPhase.set(phase);
    await loadDay();
  }

  const PHASE_ICONS: Record<string, string> = { cut: '✂️', bulk: '📈', maintenance: '⚖️' };
  const ACTIVITY_LABELS: [number, string][] = [
    [1.0, 'Sedentary'],
    [1.2, 'Light (1-2x/wk)'],
    [1.4, 'Moderate (3-4x/wk)'],
    [1.6, 'Active (5-6x/wk)'],
    [1.8, 'Very Active'],
  ];

  // Barcode scanning
  let manualBarcode = $state('');

  async function startScanner() {
    await stopScanner(); // Clean up any existing instance
    scannerActive = true;
    scanError = '';

    // Wait for DOM element to exist
    await new Promise(r => setTimeout(r, 100));

    const readerEl = document.getElementById('barcode-reader');
    if (!readerEl) {
      scanError = 'Scanner container not found. Please try again.';
      scannerActive = false;
      return;
    }

    try {
      const { Html5Qrcode, Html5QrcodeSupportedFormats } = await import('html5-qrcode');
      const scanner = new Html5Qrcode('barcode-reader', {
        verbose: false,
        formatsToSupport: [
          Html5QrcodeSupportedFormats.EAN_13,
          Html5QrcodeSupportedFormats.EAN_8,
          Html5QrcodeSupportedFormats.UPC_A,
          Html5QrcodeSupportedFormats.UPC_E,
          Html5QrcodeSupportedFormats.CODE_128,
          Html5QrcodeSupportedFormats.CODE_39,
          Html5QrcodeSupportedFormats.QR_CODE,
        ],
      });
      scannerInstance = scanner;

      // Try environment camera first, fall back to any camera
      let cameraConfig: any = { facingMode: 'environment' };
      try {
        await scanner.start(
          cameraConfig,
          { fps: 10, qrbox: { width: 280, height: 140 } },
          onBarcodeScanned,
          () => {}
        );
      } catch {
        // Environment camera failed — try any available camera
        try {
          cameraConfig = { facingMode: 'user' };
          await scanner.start(
            cameraConfig,
            { fps: 10, qrbox: { width: 280, height: 140 } },
            onBarcodeScanned,
            () => {}
          );
        } catch (innerErr: any) {
          throw innerErr; // Let outer catch handle it
        }
      }
    } catch (e: any) {
      const msg = e?.message || String(e);
      if (msg.includes('NotAllowed') || msg.includes('Permission')) {
        scanError = 'Camera permission denied. Please allow camera access in your browser settings.';
      } else if (msg.includes('NotFound') || msg.includes('DevicesNotFound')) {
        scanError = 'No camera found. Try entering the barcode manually below.';
      } else if (msg.includes('NotReadable') || msg.includes('TrackStartError')) {
        scanError = 'Camera is in use by another app. Close other camera apps and try again.';
      } else {
        scanError = `Camera error: ${msg}. Try entering the barcode manually.`;
      }
      await stopScanner();
    }
  }

  async function onBarcodeScanned(decodedText: string) {
    await stopScanner();
    await lookupAndHandleBarcode(decodedText);
  }

  async function lookupAndHandleBarcode(code: string) {
    try {
      const result = await lookupBarcode(code);
      selectedFood = result;
      selectedQty = result.serving_size_g || 100;
    } catch {
      lastScannedBarcode = code;
      scanError = '';
    }
  }

  async function submitManualBarcode() {
    const code = manualBarcode.trim();
    if (!code) return;
    await lookupAndHandleBarcode(code);
    manualBarcode = '';
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

    <!-- ─── Phase status card ────────────────────────────────────────────── -->
    {#if $activeDietPhase}
      <div class="card !py-3">
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2">
            <span class="text-lg">{PHASE_ICONS[$activeDietPhase.phase_type] ?? '🎯'}</span>
            <span class="font-semibold text-white capitalize">{$activeDietPhase.phase_type}</span>
            <span class="text-xs text-zinc-500">Week {$activeDietPhase.current_week} of {$activeDietPhase.duration_weeks}</span>
          </div>
          <button onclick={handleEndPhase}
                  class="text-xs text-zinc-600 hover:text-red-400 transition-colors">End Phase</button>
        </div>
        <!-- Progress bar -->
        <div class="relative h-1.5 bg-zinc-800 rounded-full mb-2">
          <div class="absolute h-full bg-primary-500 rounded-full transition-all duration-500"
               style="width: {($activeDietPhase.current_week / $activeDietPhase.duration_weeks) * 100}%"></div>
        </div>
        <div class="flex items-center justify-between text-xs text-zinc-500">
          <span>{formatWeight($activeDietPhase.starting_weight_kg)}</span>
          {#if $activeDietPhase.current_weight_kg}
            <span class="text-white font-medium">{formatWeight($activeDietPhase.current_weight_kg)}</span>
          {/if}
          <span>{formatWeight($activeDietPhase.target_weight_kg)}</span>
        </div>
        {#if $activeDietPhase.suggestion}
          <div class="mt-2 flex items-center justify-between bg-amber-500/10 border border-amber-500/20 rounded-lg px-3 py-2">
            <p class="text-xs text-amber-400 flex-1">{$activeDietPhase.suggestion}</p>
            <button onclick={handleRecalculate}
                    class="text-xs text-primary-400 hover:text-primary-300 font-medium ml-2 shrink-0">Adjust</button>
          </div>
        {/if}
      </div>
    {:else}
      <button onclick={openPhaseWizard}
              class="card !py-4 w-full text-center hover:bg-zinc-800/60 transition-colors">
        <p class="text-sm text-zinc-400">No active diet phase</p>
        <p class="text-primary-400 font-semibold mt-1">Start a Cut, Bulk, or Maintenance</p>
      </button>
    {/if}

    <!-- ─── Progress rings ───────────────────────────────────────────────── -->
    <div class="card">
      {#if !summary?.goals}
        <button onclick={$activeDietPhase ? () => showGoalsModal = true : openPhaseWizard}
                class="w-full py-6 text-center text-zinc-400 hover:text-primary-400 transition-colors">
          <p class="text-sm">No macro goals set</p>
          <p class="text-primary-400 font-semibold mt-1">{$activeDietPhase ? 'Set manual goals' : 'Start a diet phase to auto-calculate'}</p>
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

        <div class="flex items-center justify-center gap-4 mt-3">
          <button onclick={() => showGoalsModal = true}
                  class="text-xs text-zinc-600 hover:text-zinc-400 transition-colors">
            Edit goals
          </button>
          <a href="/nutrition/report"
             class="text-xs text-primary-500 hover:text-primary-400 transition-colors">
            Weekly Report →
          </a>
        </div>
      {/if}
    </div>

    <!-- ─── Micronutrients ──────────────────────────────────────────────── -->
    {#if summary?.micronutrient_totals && Object.keys(summary.micronutrient_totals).length > 0}
      <div class="card !p-0 overflow-hidden">
        <button onclick={() => showMicros = !showMicros}
                class="w-full flex items-center justify-between px-4 py-3 hover:bg-zinc-800/40 transition-colors">
          <span class="text-sm font-semibold text-white">Micronutrients</span>
          <span class="text-zinc-500 text-sm transition-transform duration-200" class:rotate-180={showMicros}>▾</span>
        </button>
        {#if showMicros}
          <div class="border-t border-zinc-800 px-4 py-3 space-y-2">
            {#each Object.entries(MICRO_META) as [key, meta]}
              {@const val = summary.micronutrient_totals[key] ?? 0}
              {@const goal = summary.micronutrient_goals?.[key] ?? meta.rda}
              {@const pct = goal ? Math.min(100, (val / goal) * 100) : 0}
              {@const color = !goal ? 'bg-zinc-600' : pct >= 80 ? 'bg-green-500' : pct >= 50 ? 'bg-amber-500' : 'bg-red-500'}
              <div class="flex items-center gap-3">
                <span class="text-xs text-zinc-400 w-24 shrink-0">{meta.label}</span>
                <div class="flex-1 h-1.5 bg-zinc-800 rounded-full overflow-hidden">
                  <div class="{color} h-full rounded-full transition-all duration-300" style="width: {pct}%"></div>
                </div>
                <span class="text-xs text-zinc-500 w-20 text-right shrink-0">
                  {val > 0 ? (val < 10 ? val.toFixed(1) : Math.round(val)) : '0'}{meta.unit}
                  {#if goal}
                    <span class="text-zinc-600">/ {goal}{meta.unit}</span>
                  {/if}
                </span>
              </div>
            {/each}
          </div>
        {/if}
      </div>
    {/if}

    <!-- ─── Food log ─────────────────────────────────────────────────────── -->
    <div class="card !p-0 overflow-hidden">
      <div class="flex items-center justify-between px-4 py-3">
        <div>
          <h3 class="font-semibold text-white">Food Log</h3>
          <span class="text-xs text-zinc-500">
            {allEntries.length} item{allEntries.length !== 1 ? 's' : ''}
            {#if entrySelectionMode}
              · {selectedEntries.length} selected
            {/if}
          </span>
        </div>
        <div class="flex items-center gap-2">
          {#if entrySelectionMode}
            <button onclick={cancelEntrySelection}
                    class="text-xs text-zinc-500 hover:text-zinc-300 transition-colors">
              Cancel
            </button>
            <button onclick={startRecipeFromSelectedEntries}
                    disabled={selectedEntries.length === 0}
                    class="rounded-lg px-3 py-1.5 text-xs font-medium transition-colors disabled:opacity-40 disabled:cursor-not-allowed bg-primary-600 text-white hover:bg-primary-500">
              Make Recipe
            </button>
          {:else if allEntries.length > 0}
            <button onclick={() => { entrySelectionMode = true; selectedEntryIds = new Set(); }}
                    class="text-xs text-primary-400 hover:text-primary-300 font-medium transition-colors">
              Select
            </button>
          {/if}
        </div>
      </div>

      {#if allEntries.length > 0}
        <div class="border-t border-zinc-800/50">
          {#each allEntries as entry}
            <div class="border-b border-zinc-800/30 last:border-b-0">
              <div class="flex items-center justify-between px-4 py-2.5">
                {#if entrySelectionMode}
                  <button
                    onclick={() => toggleEntrySelection(entry.id)}
                    class="flex flex-1 items-center gap-3 min-w-0 text-left"
                  >
                    <div class="w-5 h-5 rounded-md border flex items-center justify-center text-xs transition-colors {selectedEntryIds.has(entry.id) ? 'border-primary-500 bg-primary-500 text-white' : 'border-zinc-700 text-transparent'}">
                      ✓
                    </div>
                    <div class="min-w-0">
                      <p class="text-sm text-white truncate">{entry.name}</p>
                      <p class="text-xs text-zinc-500">{entry.quantity_g}g · {entry.meal}</p>
                    </div>
                  </button>
                {:else}
                  <button onclick={() => startEditEntry(entry)} class="flex-1 min-w-0 text-left">
                    <p class="text-sm text-white truncate">{entry.name}</p>
                    <p class="text-xs text-zinc-500">{entry.quantity_g}g</p>
                  </button>
                {/if}
                <div class="flex items-center gap-2 shrink-0">
                  <div class="text-right">
                    <p class="text-sm font-medium text-white">{Math.round(entry.calories)} cal</p>
                    <p class="text-[10px] text-zinc-500">{Math.round(entry.protein)}g P</p>
                  </div>
                  {#if !entrySelectionMode}
                    <button onclick={() => startEditEntry(entry)}
                            class="w-7 h-7 flex items-center justify-center text-zinc-500 hover:text-blue-400 hover:bg-zinc-800 rounded transition-colors text-xs"
                            title="Edit entry">
                      ✎
                    </button>
                    <button onclick={() => removeEntry(entry.id)}
                            class="w-7 h-7 flex items-center justify-center text-zinc-500 hover:text-red-400 hover:bg-zinc-800 rounded transition-colors text-xs"
                            title="Delete entry">
                      ✕
                    </button>
                  {/if}
                </div>
              </div>
              {#if !entrySelectionMode && editingEntry?.id === entry.id}
                <div class="px-4 pb-3 space-y-2 border-t border-zinc-800/30 bg-zinc-900/50">
                  <div class="grid grid-cols-4 gap-2 pt-2">
                    <div>
                      <label class="text-[10px] text-zinc-500 block">Cal</label>
                      <input type="number" bind:value={editEntryCal} class="input text-xs py-1" />
                    </div>
                    <div>
                      <label class="text-[10px] text-zinc-500 block">Protein</label>
                      <input type="number" bind:value={editEntryProtein} step="0.1" class="input text-xs py-1" />
                    </div>
                    <div>
                      <label class="text-[10px] text-zinc-500 block">Carbs</label>
                      <input type="number" bind:value={editEntryCarbs} step="0.1" class="input text-xs py-1" />
                    </div>
                    <div>
                      <label class="text-[10px] text-zinc-500 block">Fat</label>
                      <input type="number" bind:value={editEntryFat} step="0.1" class="input text-xs py-1" />
                    </div>
                  </div>
                  <div class="flex gap-2">
                    <div class="flex-1">
                      <label class="text-[10px] text-zinc-500 block">Qty (g)</label>
                      <input type="number" bind:value={editEntryQty} oninput={onEditQtyChange} class="input text-xs py-1" />
                    </div>
                    <button onclick={saveEditEntry} class="btn-primary text-xs px-4 self-end">Save</button>
                    <button onclick={() => editingEntry = null} class="text-xs text-zinc-500 hover:text-zinc-300 self-end px-2">Cancel</button>
                  </div>
                </div>
              {/if}
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
        <button onclick={() => { stopScanner(); showAddModal = false; selectedFood = null; editingFood = null; }} class="text-zinc-400 hover:text-white text-xl">✕</button>
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

          <div class="space-y-2">
            {#if selectedFood.serving_size_g && selectedFood.serving_size_g !== 100}
              {@const srvG = selectedFood.serving_size_g}
              <div>
                <label class="text-xs text-zinc-400 block mb-1">
                  Servings {selectedFood.serving_label ? `(${selectedFood.serving_label})` : `(${srvG}g each)`}
                </label>
                <div class="flex gap-2">
                  {#each [0.5, 1, 1.5, 2, 3] as n}
                    <button onclick={() => selectedQty = Math.round(srvG * n)}
                            class="flex-1 py-2 rounded-lg text-sm font-medium transition-colors
                                   {Math.abs(selectedQty - srvG * n) < 1 ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
                      {n}
                    </button>
                  {/each}
                </div>
              </div>
            {/if}
            <div>
              <label class="text-xs text-zinc-400 block mb-1">Grams</label>
              <input type="number" bind:value={selectedQty} min="1" class="input" />
            </div>
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
          {#each [['quick', '⚡'], ['search', 'Search'], ['scan', 'Scan'], ['manual', 'Manual'], ['custom', 'Saved'], ['recipes', '🍳'], ['alcohol', '🍺']] as [tab, label]}
            <button onclick={() => { if (activeTab === 'scan') stopScanner(); activeTab = tab as any; if (tab === 'custom') loadCustomFoods(); if (tab === 'recipes' && !recipesLoaded) loadRecipes(); }}
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
              {#if lastScannedBarcode}
                <!-- Barcode not found state -->
                <div class="bg-amber-500/10 border border-amber-500/20 rounded-lg px-3 py-2">
                  <p class="text-xs text-amber-400">Barcode {lastScannedBarcode} not found.</p>
                  <p class="text-xs text-zinc-400 mt-1">Scan the nutrition label to add it, or try another barcode.</p>
                </div>
                <div class="flex gap-2">
                  <button onclick={() => { lastScannedBarcode = ''; startScanner(); }} class="btn-primary flex-1">Scan Another</button>
                  <button onclick={() => { activeTab = 'label'; startLabelScanner(); }} class="btn-ghost flex-1">Scan Label</button>
                </div>
              {:else}
                {#if !scannerActive}
                  <button onclick={startScanner} class="btn-primary w-full">📸 Scan Barcode</button>
                {:else}
                  <button onclick={stopScanner} class="btn-ghost w-full text-sm">Close Camera</button>
                {/if}
                <div id="barcode-reader" class="rounded-xl overflow-hidden"></div>
                {#if scanError}
                  <p class="text-sm text-amber-400 text-center">{scanError}</p>
                {/if}
                {#if !scannerActive && !scanError}
                  <p class="text-xs text-zinc-500 text-center">Point camera at a food barcode</p>
                {/if}
              {/if}

              <!-- Manual barcode entry (always visible) -->
              <div class="border-t border-zinc-800 pt-3">
                <p class="text-xs text-zinc-500 mb-1.5">Or enter barcode manually:</p>
                <div class="flex gap-2">
                  <input type="text" inputmode="numeric" bind:value={manualBarcode}
                         placeholder="Enter barcode number"
                         onkeydown={(e) => { if (e.key === 'Enter') submitManualBarcode(); }}
                         class="input flex-1" style="font-size: 16px;" />
                  <button onclick={submitManualBarcode}
                          disabled={!manualBarcode.trim()}
                          class="btn-primary px-4 disabled:opacity-30">Look Up</button>
                </div>
              </div>
            </div>

          <!-- Label OCR tab -->
          {:else if activeTab === 'label'}
            <div class="p-4 space-y-3">
              {#if ocrResult}
                <!-- Show extracted values for editing -->
                <div class="space-y-3">
                  <p class="text-xs text-zinc-400">
                    {lastScannedBarcode ? `Barcode ${lastScannedBarcode} not in database.` : ''}
                    Edit values below, then save to the community library.
                  </p>
                  <div class="grid grid-cols-2 gap-2">
                    <div>
                      <label for="ocr-name" class="text-[10px] text-zinc-500">Name</label>
                      <input id="ocr-name" type="text" bind:value={ocrResult.name} placeholder="Product name" class="input !py-1.5 text-sm" />
                    </div>
                    <div>
                      <label for="ocr-brand" class="text-[10px] text-zinc-500">Brand</label>
                      <input id="ocr-brand" type="text" bind:value={ocrResult.brand} placeholder="Brand" class="input !py-1.5 text-sm" />
                    </div>
                  </div>
                  <div class="grid grid-cols-2 gap-2">
                    <div>
                      <label for="ocr-serving" class="text-[10px] text-zinc-500">Serving (g)</label>
                      <input id="ocr-serving" type="number" bind:value={ocrResult.servingSize} class="input !py-1.5 text-sm" />
                    </div>
                    <div>
                      <label for="ocr-barcode" class="text-[10px] text-zinc-500">Barcode</label>
                      <input id="ocr-barcode" type="text" bind:value={ocrResult.barcode} placeholder="Auto-linked" class="input !py-1.5 text-sm" />
                    </div>
                  </div>
                  <div class="grid grid-cols-4 gap-2">
                    {#each [['ocr-cal', 'Calories', 'calories'], ['ocr-pro', 'Protein', 'protein'], ['ocr-carb', 'Carbs', 'carbs'], ['ocr-fat', 'Fat', 'fat']] as [id, label, key]}
                      <div>
                        <label for={id} class="text-[10px] text-zinc-500">{label}</label>
                        <input {id} type="number" bind:value={(ocrResult as any)[key]} class="input !py-1.5 text-sm" />
                      </div>
                    {/each}
                  </div>
                  <div class="grid grid-cols-3 gap-2">
                    {#each [['ocr-fiber', 'Fiber (g)', 'fiber'], ['ocr-sodium', 'Sodium (mg)', 'sodium'], ['ocr-sugar', 'Sugar (g)', 'sugar']] as [id, label, key]}
                      <div>
                        <label for={id} class="text-[10px] text-zinc-500">{label}</label>
                        <input {id} type="number" bind:value={(ocrResult as any)[key]} class="input !py-1.5 text-sm" />
                      </div>
                    {/each}
                  </div>
                  <div class="flex gap-2">
                    <button onclick={() => { ocrResult = null; startLabelScanner(); }} class="btn-ghost flex-1">Rescan</button>
                    <button onclick={saveCommunityFood} disabled={ocrSaving}
                            class="btn-primary flex-1 disabled:opacity-50">
                      {ocrSaving ? 'Saving...' : 'Save & Log'}
                    </button>
                  </div>
                </div>

              {:else if ocrLiveActive}
                <!-- Live video scanner -->
                <div class="space-y-2">
                  <div class="relative rounded-xl overflow-hidden bg-black aspect-[4/3]">
                    <!-- svelte-ignore a11y_media_has_caption -->
                    <video bind:this={ocrVideoEl} autoplay playsinline muted
                           class="w-full h-full object-cover"></video>
                    <canvas bind:this={ocrCanvasEl} class="hidden"></canvas>
                    <!-- Scanning pulse overlay -->
                    <div class="absolute inset-0 pointer-events-none">
                      <div class="absolute inset-4 border-2 rounded-lg transition-colors
                                  {ocrScanning ? 'border-primary-400 animate-pulse' : 'border-zinc-600/40'}"></div>
                      {#if ocrScanning}
                        <div class="absolute top-2 right-2 flex items-center gap-1.5 bg-black/60 rounded-full px-2 py-1">
                          <div class="w-2 h-2 rounded-full bg-primary-400 animate-pulse"></div>
                          <span class="text-[10px] text-primary-300">Reading...</span>
                        </div>
                      {/if}
                    </div>
                    <!-- Status overlay -->
                    <div class="absolute bottom-0 inset-x-0 bg-gradient-to-t from-black/90 to-transparent p-3">
                      <div class="flex items-center justify-between mb-1">
                        <p class="text-xs text-white">{ocrLiveStatus}</p>
                        {#if ocrFieldsFound > 0}
                          <div class="flex gap-1">
                            {#each [0,1,2,3] as i}
                              <div class="w-2.5 h-2.5 rounded-full transition-colors {i < ocrFieldsFound ? 'bg-green-400' : 'bg-zinc-600'}"></div>
                            {/each}
                          </div>
                        {/if}
                      </div>
                      <!-- Show partial values as they're found -->
                      {#if ocrPartialValues && ocrFieldsFound > 0}
                        <div class="flex gap-3 text-[10px]">
                          <span class="{ocrPartialValues.calories > 0 ? 'text-green-400' : 'text-zinc-600'}">
                            Cal: {ocrPartialValues.calories > 0 ? ocrPartialValues.calories : '—'}
                          </span>
                          <span class="{ocrPartialValues.protein > 0 ? 'text-green-400' : 'text-zinc-600'}">
                            P: {ocrPartialValues.protein > 0 ? ocrPartialValues.protein + 'g' : '—'}
                          </span>
                          <span class="{ocrPartialValues.carbs > 0 ? 'text-green-400' : 'text-zinc-600'}">
                            C: {ocrPartialValues.carbs > 0 ? ocrPartialValues.carbs + 'g' : '—'}
                          </span>
                          <span class="{ocrPartialValues.fat > 0 ? 'text-green-400' : 'text-zinc-600'}">
                            F: {ocrPartialValues.fat > 0 ? ocrPartialValues.fat + 'g' : '—'}
                          </span>
                        </div>
                      {/if}
                    </div>
                  </div>
                  <button onclick={() => stopLabelScanner(true)} class="btn-ghost w-full">Cancel</button>
                </div>

              {:else}
                <!-- Start options -->
                <div class="text-center space-y-3">
                  {#if lastScannedBarcode}
                    <div class="bg-amber-500/10 border border-amber-500/20 rounded-lg px-3 py-2">
                      <p class="text-xs text-amber-400">Barcode {lastScannedBarcode} not found in any database.</p>
                      <p class="text-xs text-zinc-400 mt-1">Scan the nutrition label to add it to the community library.</p>
                    </div>
                  {:else}
                    <p class="text-sm text-zinc-400">Scan a nutrition facts label to add to the community library</p>
                  {/if}

                  <button onclick={startLabelScanner} class="btn-primary w-full !py-3">
                    Start Live Scanner
                  </button>

                  <div class="flex gap-2">
                    <label class="flex-1 py-2.5 text-xs text-zinc-400 hover:text-zinc-300 cursor-pointer border border-zinc-800 rounded-xl text-center transition-colors">
                      Take Photo
                      <input type="file" accept="image/*" capture="environment"
                             onchange={(e) => { const f = (e.target as HTMLInputElement).files?.[0]; if (f) processLabelImage(f); }}
                             class="hidden" />
                    </label>
                    <label class="flex-1 py-2.5 text-xs text-zinc-400 hover:text-zinc-300 cursor-pointer border border-zinc-800 rounded-xl text-center transition-colors">
                      From Gallery
                      <input type="file" accept="image/*"
                             onchange={(e) => { const f = (e.target as HTMLInputElement).files?.[0]; if (f) processLabelImage(f); }}
                             class="hidden" />
                    </label>
                  </div>

                  {#if ocrError}
                    <p class="text-xs text-red-400">{ocrError}</p>
                  {/if}
                </div>
              {/if}
            </div>

          <!-- Manual tab -->
          {:else if activeTab === 'manual'}
            <div class="p-4 space-y-3">
              <div>
                <label class="text-xs text-zinc-400 block mb-1">Food name</label>
                <input type="text" bind:value={manualName} placeholder="e.g. Chicken breast" class="input" />
              </div>
              <div>
                <label class="text-xs text-zinc-400 block mb-1">Brand <span class="text-zinc-600">(optional)</span></label>
                <input type="text" bind:value={manualBrand} placeholder="e.g. Kirkland" class="input" />
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
              <div>
                <label class="text-xs text-zinc-400 block mb-1">Serving Label <span class="text-zinc-600">(optional)</span></label>
                <input type="text" bind:value={manualServingLabel} placeholder="e.g. 1 cup" class="input" />
              </div>
              {#if !editingFood}
              <label class="flex items-center gap-2 text-sm text-zinc-400">
                <input type="checkbox" bind:checked={saveAsCustom} class="rounded bg-zinc-800 border-zinc-700" />
                Save as custom food
              </label>
              {/if}
              <button onclick={editingFood ? saveEditedFood : logManualEntry} disabled={!manualName.trim()}
                      class="btn-primary w-full disabled:opacity-40 disabled:cursor-not-allowed">
                {editingFood ? 'Save Changes' : 'Log Food'}
              </button>
            </div>

          <!-- Quick-add tab -->
          {:else if activeTab === 'quick'}
            <div class="p-4 space-y-4">
              <p class="text-xs text-zinc-500">Log calories fast — no food lookup needed.</p>
              <div>
                <label class="text-xs text-zinc-400 block mb-1">Calories *</label>
                <input type="number" bind:value={quickCal} placeholder="e.g. 450"
                       class="input text-2xl font-bold text-center h-16" autofocus />
              </div>
              <div>
                <label class="text-xs text-zinc-400 block mb-1">Protein (g, optional)</label>
                <input type="number" bind:value={quickProtein} placeholder="0" class="input" />
              </div>
              <div>
                <label class="text-xs text-zinc-400 block mb-1">Label (optional)</label>
                <input type="text" bind:value={quickLabel} placeholder="e.g. Protein shake" class="input" />
              </div>
              <div>
                <label class="text-xs text-zinc-400 block mb-1">Meal</label>
                <div class="grid grid-cols-4 gap-1.5">
                  {#each ['breakfast', 'lunch', 'dinner', 'snack'] as m}
                    <button onclick={() => quickMeal = m}
                            class="py-2 text-xs rounded-lg transition-colors font-medium
                                   {quickMeal === m ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
                      {m.charAt(0).toUpperCase() + m.slice(1)}
                    </button>
                  {/each}
                </div>
              </div>
              <button onclick={logQuickAdd}
                      disabled={!quickCal || quickCal <= 0 || quickSaving}
                      class="btn-primary w-full disabled:opacity-40 disabled:cursor-not-allowed">
                {quickSaving ? 'Logging…' : `Log ${quickCal ? quickCal + ' kcal' : ''}`}
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
                <div class="flex items-center gap-1 rounded-lg hover:bg-zinc-800 transition-colors">
                  <button onclick={() => startEditingFood(food)}
                          class="flex-1 text-left px-3 py-2.5">
                    <p class="text-sm text-white truncate">
                      {food.name}
                      {#if food.source === 'pending'}
                        <span class="text-[10px] ml-1 px-1.5 py-0.5 rounded-full bg-amber-500/15 text-amber-400">Pending{#if food.submission_count} ({food.submission_count}){/if}</span>
                      {:else if food.source === 'community'}
                        <span class="text-[10px] ml-1 px-1.5 py-0.5 rounded-full bg-green-500/15 text-green-400">Community</span>
                      {/if}
                    </p>
                    <p class="text-xs text-zinc-500">
                      {food.brand ?? 'Custom'}
                      {#if food.calories_per_100g != null}
                        · {Math.round(food.calories_per_100g)} cal/100g
                      {/if}
                    </p>
                  </button>
                  <button onclick={() => startEditingFood(food)}
                          class="px-2 py-2 text-zinc-500 hover:text-blue-400"
                          title="Edit saved food">
                    ✎
                  </button>
                  <button onclick={async () => {
                            if (!confirm(`Delete "${food.name}"?`)) return;
                            await deleteCustomFood(food.id);
                            customFoods = customFoods.filter(f => f.id !== food.id);
                          }}
                          class="px-2 py-2 text-zinc-500 hover:text-red-400"
                          title="Delete saved food">
                    ✕
                  </button>
                </div>
              {/each}
              {#if customFoods.length === 0}
                <p class="text-center text-zinc-500 text-sm py-8">No saved foods yet.<br><span class="text-zinc-600 text-xs">Log a food manually and check "Save as custom food".</span></p>
              {/if}
            </div>

          <!-- Recipes tab -->
          {:else if activeTab === 'recipes'}
            {#if selectedRecipe}
              <!-- Recipe log view -->
              <div class="p-4 space-y-4">
                <button onclick={() => selectedRecipe = null} class="text-xs text-zinc-500 hover:text-zinc-300">← Back to recipes</button>
                <div>
                  <h3 class="font-semibold text-white">{selectedRecipe.name}</h3>
                  {#if selectedRecipe.description}
                    <p class="text-xs text-zinc-500 mt-0.5">{selectedRecipe.description}</p>
                  {/if}
                </div>
                <div class="grid grid-cols-4 gap-2">
                  {#each [['kcal', selectedRecipe.total_calories, 'text-orange-400'], ['P', selectedRecipe.total_protein, 'text-blue-400'], ['C', selectedRecipe.total_carbs, 'text-green-400'], ['F', selectedRecipe.total_fat, 'text-yellow-400']] as [lbl, val, cls]}
                    <div class="text-center py-2 bg-zinc-800/60 rounded-lg">
                      <p class="text-sm font-bold {cls}">{Math.round(val as number)}{lbl !== 'kcal' ? 'g' : ''}</p>
                      <p class="text-xs text-zinc-500">{lbl}</p>
                    </div>
                  {/each}
                </div>
                <div>
                  <label class="text-xs text-zinc-400 block mb-1">Servings</label>
                  <div class="flex items-center gap-3">
                    <button onclick={() => recipeServings = Math.max(0.5, recipeServings - 0.5)}
                            class="w-8 h-8 rounded-full bg-zinc-800 text-white text-lg flex items-center justify-center">−</button>
                    <span class="font-bold text-white w-8 text-center">{recipeServings}</span>
                    <button onclick={() => recipeServings += 0.5}
                            class="w-8 h-8 rounded-full bg-zinc-800 text-white text-lg flex items-center justify-center">+</button>
                  </div>
                </div>
                <div class="grid grid-cols-4 gap-1.5">
                  {#each ['breakfast', 'lunch', 'dinner', 'snack'] as m}
                    <button onclick={() => recipeMeal = m}
                            class="py-2 text-xs rounded-lg transition-colors font-medium
                                   {recipeMeal === m ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}">
                      {m.charAt(0).toUpperCase() + m.slice(1)}
                    </button>
                  {/each}
                </div>
                <button onclick={logSelectedRecipe} disabled={recipeLogging}
                        class="btn-primary w-full disabled:opacity-40">
                  {recipeLogging ? 'Logging…' : 'Log Recipe'}
                </button>
              </div>
            {:else if showRecipeBuilder}
              <!-- Recipe builder -->
              <div class="p-4 space-y-3 overflow-y-auto">
                <button onclick={() => showRecipeBuilder = false} class="text-xs text-zinc-500 hover:text-zinc-300">← Back</button>
                {#if recipeBuilderSource === 'selection'}
                  <div class="rounded-xl border border-primary-500/20 bg-primary-500/10 px-3 py-2">
                    <p class="text-xs text-primary-300">
                      Prefilled from {selectedEntries.length} selected food log item{selectedEntries.length !== 1 ? 's' : ''}. Adjust anything below before saving.
                    </p>
                  </div>
                {/if}
                <input type="text" bind:value={newRecipeName} placeholder="Recipe name *" class="input" />
                <input type="text" bind:value={newRecipeDesc} placeholder="Description (optional)" class="input" />
                <div class="flex items-center gap-2">
                  <label class="text-xs text-zinc-400">Servings:</label>
                  <input type="number" bind:value={newRecipeServings} min="1" class="input w-20" />
                </div>
                <div class="space-y-2">
                  <div class="flex items-center justify-between">
                    <p class="text-xs font-semibold text-zinc-300">Ingredients</p>
                    <button onclick={() => newRecipeIngredients = [...newRecipeIngredients, {name:'',quantity:'1',unit:'serving',calories:'',protein:'',carbs:'',fat:''}]}
                            class="text-xs text-primary-400 hover:text-primary-300">+ Add</button>
                  </div>
                  {#each newRecipeIngredients as ing, i}
                    <div class="bg-zinc-800/60 rounded-xl p-3 space-y-2">
                      <div class="flex gap-2">
                        <input type="text" bind:value={ing.name} placeholder="Name" class="input flex-1 text-sm" />
                        <button onclick={() => newRecipeIngredients = newRecipeIngredients.filter((_,j) => j !== i)}
                                class="text-zinc-500 hover:text-red-400 text-lg px-1">×</button>
                      </div>
                      <div class="grid grid-cols-2 gap-2">
                        <input type="number" bind:value={ing.quantity} placeholder="Qty" class="input text-sm" />
                        <input type="text" bind:value={ing.unit} placeholder="Unit" class="input text-sm" />
                      </div>
                      <div class="grid grid-cols-4 gap-1.5">
                        <div><input type="number" bind:value={ing.calories} placeholder="kcal" class="input text-xs text-center" /><p class="text-zinc-600 text-xs text-center">kcal</p></div>
                        <div><input type="number" bind:value={ing.protein} placeholder="P" class="input text-xs text-center" /><p class="text-zinc-600 text-xs text-center">P(g)</p></div>
                        <div><input type="number" bind:value={ing.carbs} placeholder="C" class="input text-xs text-center" /><p class="text-zinc-600 text-xs text-center">C(g)</p></div>
                        <div><input type="number" bind:value={ing.fat} placeholder="F" class="input text-xs text-center" /><p class="text-zinc-600 text-xs text-center">F(g)</p></div>
                      </div>
                    </div>
                  {/each}
                  {#if newRecipeIngredients.length === 0}
                    <p class="text-xs text-zinc-600 text-center py-2">No ingredients yet — add one above</p>
                  {/if}
                </div>
                <button onclick={saveNewRecipe} disabled={!newRecipeName.trim() || recipeSaving}
                        class="btn-primary w-full disabled:opacity-40">
                  {recipeSaving ? 'Saving…' : 'Save Recipe'}
                </button>
              </div>
            {:else}
              <!-- Recipe list -->
              <div class="p-3 flex justify-between items-center">
                <p class="text-xs text-zinc-500">{recipes.length} recipe{recipes.length !== 1 ? 's' : ''}</p>
                <button onclick={() => showRecipeBuilder = true}
                        class="text-xs text-primary-400 hover:text-primary-300 font-medium">+ New Recipe</button>
              </div>
              <div class="px-2 space-y-1 overflow-y-auto">
                {#each recipes as recipe}
                  <button onclick={() => { selectedRecipe = recipe; recipeServings = 1; }}
                          class="w-full text-left px-3 py-2.5 hover:bg-zinc-800 rounded-xl transition-colors">
                    <p class="text-sm text-white font-medium">{recipe.name}</p>
                    <p class="text-xs text-zinc-500">{Math.round(recipe.total_calories)} kcal · P:{Math.round(recipe.total_protein)}g · {recipe.servings} serving{recipe.servings !== 1 ? 's' : ''}</p>
                  </button>
                {/each}
                {#if recipes.length === 0}
                  <div class="text-center py-8">
                    <p class="text-zinc-500 text-sm">No recipes yet</p>
                    <button onclick={() => showRecipeBuilder = true}
                            class="mt-2 text-primary-400 text-xs hover:text-primary-300">Create your first recipe →</button>
                  </div>
                {/if}
              </div>
            {/if}

          <!-- Alcohol calculator tab -->
          {:else if activeTab === 'alcohol'}
            <div class="p-4 space-y-4">
              <p class="text-xs text-zinc-500">Calculate and log calories from alcoholic drinks.</p>

              <!-- Drink type selector -->
              <div class="grid grid-cols-4 gap-1.5">
                {#each [['beer', '🍺', 'Beer'], ['wine', '🍷', 'Wine'], ['spirit', '🥃', 'Spirit'], ['custom', '✏️', 'Custom']] as [type, emoji, name]}
                  <button onclick={() => alcoholDrinkType = type as typeof alcoholDrinkType}
                          class="py-2 rounded-xl text-center transition-colors
                                 {alcoholDrinkType === type ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
                    <div class="text-lg">{emoji}</div>
                    <div class="text-xs font-medium">{name}</div>
                  </button>
                {/each}
              </div>

              <!-- Volume + ABV inputs -->
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="text-xs text-zinc-400 block mb-1">Volume (mL)</label>
                  <input type="number" bind:value={alcoholVolumeMl} min="1" class="input" />
                </div>
                <div>
                  <label class="text-xs text-zinc-400 block mb-1">ABV (%)</label>
                  <input type="number" bind:value={alcoholAbv} min="0" max="100" step="0.1" class="input" />
                </div>
              </div>

              {#if alcoholDrinkType === 'custom'}
                <div>
                  <label class="text-xs text-zinc-400 block mb-1">Drink name</label>
                  <input type="text" bind:value={alcoholName} placeholder="e.g. IPA" class="input" />
                </div>
              {/if}

              <!-- Calorie estimate -->
              <div class="bg-zinc-800/80 rounded-xl p-4 text-center">
                <p class="text-3xl font-bold text-orange-400">{alcoholCalories}</p>
                <p class="text-xs text-zinc-500 mt-1">estimated kcal</p>
                <p class="text-xs text-zinc-600 mt-0.5">vol × ABV × 0.789 × 7</p>
              </div>

              <!-- Meal picker -->
              <div class="grid grid-cols-4 gap-1.5">
                {#each ['breakfast', 'lunch', 'dinner', 'snack'] as m}
                  <button onclick={() => alcoholMeal = m}
                          class="py-2 text-xs rounded-lg transition-colors font-medium
                                 {alcoholMeal === m ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}">
                    {m.charAt(0).toUpperCase() + m.slice(1)}
                  </button>
                {/each}
              </div>

              <button onclick={logAlcohol} disabled={alcoholLogging || alcoholCalories <= 0}
                      class="btn-primary w-full disabled:opacity-40">
                {alcoholLogging ? 'Logging…' : `Log ${alcoholCalories} kcal`}
              </button>
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

<!-- ─── Phase Setup Wizard ───────────────────────────────────────────────── -->
{#if showPhaseWizard}
  <div class="fixed inset-0 bg-black/80 flex items-end sm:items-center justify-center z-50">
    <div class="bg-zinc-900 w-full sm:max-w-md sm:rounded-2xl rounded-t-2xl max-h-[92vh] flex flex-col border border-zinc-800 shadow-2xl">

      <div class="flex items-center justify-between px-4 py-3 border-b border-zinc-800 shrink-0">
        <h3 class="font-semibold text-white">
          {wizardStep === 1 ? 'Choose Phase' : wizardStep === 2 ? 'Settings' : 'Preview'}
        </h3>
        <button onclick={() => showPhaseWizard = false} class="text-zinc-400 hover:text-white text-xl">✕</button>
      </div>

      <div class="p-4 overflow-y-auto space-y-4">
        {#if wizardStep === 1}
          <!-- Step 1: Phase type -->
          {#each [['cut', '✂️', 'Lose fat, preserve muscle'], ['bulk', '📈', 'Build muscle with controlled surplus'], ['maintenance', '⚖️', 'Maintain current weight']] as [type, icon, desc]}
            <button onclick={() => { wizPhaseType = type as any; wizRate = type === 'cut' ? 0.7 : type === 'bulk' ? 0.3 : 0; wizDuration = type === 'bulk' ? 12 : 8; wizardStep = 2; }}
                    class="w-full text-left p-4 rounded-xl border transition-colors
                           {wizPhaseType === type ? 'border-primary-500 bg-primary-500/10' : 'border-zinc-800 hover:border-zinc-700 hover:bg-zinc-800/50'}">
              <div class="flex items-center gap-3">
                <span class="text-2xl">{icon}</span>
                <div>
                  <p class="font-semibold text-white capitalize">{type}</p>
                  <p class="text-xs text-zinc-500">{desc}</p>
                </div>
              </div>
            </button>
          {/each}

        {:else if wizardStep === 2}
          <!-- Step 2: Settings -->
          {#if wizPhaseType !== 'maintenance'}
            <div>
              <label class="text-xs text-zinc-400 block mb-2">
                Rate: {wizRate}% body weight / week
                <span class="text-zinc-600">
                  ({wizPhaseType === 'cut' ? '0.5% conservative – 1.0% aggressive' : '0.25% lean – 0.5% standard'})
                </span>
              </label>
              <input type="range" bind:value={wizRate}
                     min={wizPhaseType === 'cut' ? 0.5 : 0.25} max={wizPhaseType === 'cut' ? 1.0 : 0.5} step="0.05"
                     class="w-full accent-primary-500" />
            </div>
          {/if}

          <div>
            <label class="text-xs text-zinc-400 block mb-2">Duration</label>
            <div class="flex gap-2">
              {#each [4, 8, 12, 16] as w}
                <button onclick={() => wizDuration = w}
                        class="flex-1 py-2 rounded-lg text-sm font-medium transition-colors
                               {wizDuration === w ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
                  {w} wk
                </button>
              {/each}
            </div>
          </div>

          <div>
            <label class="text-xs text-zinc-400 block mb-2">Activity Level</label>
            <div class="space-y-1">
              {#each ACTIVITY_LABELS as [val, label]}
                <button onclick={() => wizActivity = val}
                        class="w-full text-left px-3 py-2 rounded-lg text-sm transition-colors
                               {wizActivity === val ? 'bg-primary-600/20 text-primary-400 font-medium' : 'text-zinc-400 hover:bg-zinc-800'}">
                  {label}
                </button>
              {/each}
            </div>
          </div>

          <div>
            <button onclick={() => wizShowTdee = !wizShowTdee}
                    class="text-xs text-zinc-500 hover:text-zinc-300 transition-colors">
              {wizShowTdee ? '▾ Hide' : '▸'} I know my maintenance calories
            </button>
            {#if wizShowTdee}
              <input type="number" bind:value={wizTdeeOverride} placeholder="e.g. 2500" class="input mt-2" />
            {/if}
          </div>

          <div>
            <label class="text-xs text-zinc-400 block mb-2">Carb Preference</label>
            <div class="flex gap-2">
              {#each [['high', 'High Carb'], ['moderate', 'Moderate'], ['low', 'Low Carb']] as [val, label]}
                <button onclick={() => wizCarb = val as any}
                        class="flex-1 py-2 rounded-lg text-sm font-medium transition-colors
                               {wizCarb === val ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
                  {label}
                </button>
              {/each}
            </div>
          </div>

          <!-- Body composition & protein -->
          <div>
            <label class="text-xs text-zinc-400 block mb-2">
              Estimated Body Fat %
              <span class="text-zinc-600">(optional — used for lean mass protein calc)</span>
            </label>
            <input type="number" bind:value={wizBodyFat}
                   placeholder="e.g. 25" min="5" max="60" step="1" class="input" />
          </div>

          <div>
            <label class="text-xs text-zinc-400 block mb-2">
              Protein: {wizProtein ? `${wizProtein} g/lb` : 'auto'}
              <span class="text-zinc-600">
                ({wizPhaseType === 'cut'
                  ? wizBodyFat ? '1.2 g/lb lean mass' : '1.0 g/lb total'
                  : wizBodyFat ? '1.0 g/lb lean mass' : '0.8 g/lb total'} default)
              </span>
            </label>
            <input type="range" bind:value={wizProtein}
                   min="0.6" max="1.4" step="0.05"
                   class="w-full accent-primary-500" />
            <div class="flex justify-between text-[10px] text-zinc-600 mt-1">
              <span>0.6 g/lb</span>
              <button onclick={() => wizProtein = null}
                      class="text-primary-500 hover:text-primary-400">Reset to auto</button>
              <span>1.4 g/lb</span>
            </div>
          </div>

          <div class="flex gap-2 pt-2">
            <button onclick={() => wizardStep = 1} class="btn-ghost flex-1">Back</button>
            <button onclick={() => wizardStep = 3} class="btn-primary flex-1">Preview</button>
          </div>

        {:else}
          <!-- Step 3: Preview -->
          <div class="text-center mb-2">
            <span class="text-3xl">{PHASE_ICONS[wizPhaseType]}</span>
            <h4 class="font-semibold text-white capitalize mt-1">{wizPhaseType} Phase</h4>
            <p class="text-xs text-zinc-500">{wizDuration} weeks · {wizRate}%/wk · {wizCarb} carb</p>
          </div>

          <p class="text-xs text-zinc-500 text-center">
            Macros will be auto-calculated from your body weight and adjusted weekly based on weigh-in trends.
          </p>

          <div class="flex gap-2 pt-2">
            <button onclick={() => wizardStep = 2} class="btn-ghost flex-1">Back</button>
            <button onclick={startPhase} disabled={wizCreating}
                    class="btn-primary flex-1 disabled:opacity-50">
              {wizCreating ? 'Starting…' : 'Start Phase'}
            </button>
          </div>
        {/if}
      </div>
    </div>
  </div>
{/if}
