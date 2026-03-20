<script lang="ts">
  import { onMount } from 'svelte';
  import { settings, latestBodyWeight } from '$lib/stores';
  import type { RestDurations } from '$lib/stores';
  import { addBodyWeight, deleteBodyWeight, getBodyWeights } from '$lib/api';
  import type { BodyWeightEntry } from '$lib/api';

  // ── Rest timer ────────────────────────────────────────────────────────
  const restCategories: {
    key: keyof RestDurations;
    label: string;
    sub: string;
    presets: number[];
  }[] = [
    { key: 'upperCompound',  label: 'Upper Body',  sub: 'Compound',  presets: [90, 120, 180, 240, 300] },
    { key: 'upperIsolation', label: 'Upper Body',  sub: 'Isolation', presets: [45, 60, 90, 120, 180]  },
    { key: 'lowerCompound',  label: 'Lower Body',  sub: 'Compound',  presets: [120, 180, 240, 300, 360] },
    { key: 'lowerIsolation', label: 'Lower Body',  sub: 'Isolation', presets: [60, 90, 120, 180, 240]  },
  ];

  function fmtSecs(s: number) {
    const m = Math.floor(s / 60);
    const sec = s % 60;
    return sec === 0 ? `${m}m` : `${m}:${String(sec).padStart(2, '0')}`;
  }

  function setRest(key: keyof RestDurations, secs: number) {
    settings.update(s => ({ ...s, restDurations: { ...s.restDurations, [key]: secs } }));
  }

  // Custom input state per category — initialized from current settings
  let customMins = $state<Record<string, number>>(
    Object.fromEntries(restCategories.map(c => [c.key, Math.floor($settings.restDurations[c.key] / 60)]))
  );
  let customSecs = $state<Record<string, number>>(
    Object.fromEntries(restCategories.map(c => [c.key, $settings.restDurations[c.key] % 60]))
  );

  function applyCustom(key: keyof RestDurations) {
    const total = (customMins[key] ?? 0) * 60 + (customSecs[key] ?? 0);
    if (total > 0) setRest(key, total);
  }

  // ── Body weight weigh-in ──────────────────────────────────────────────
  let weighIns = $state<BodyWeightEntry[]>([]);
  let newWeight = $state<number | null>(null);
  let newNotes = $state('');
  let savingWeighIn = $state(false);

  const KG_TO_LBS = 2.20462;
  const LBS_TO_KG = 0.453592;

  function toDisplayWeight(kg: number): number {
    return $settings.weightUnit === 'lbs'
      ? Math.round(kg * KG_TO_LBS * 4) / 4
      : Math.round(kg * 100) / 100;
  }

  function fmtDate(iso: string): string {
    return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  }

  onMount(async () => {
    weighIns = await getBodyWeights(30);
  });

  async function logWeighIn() {
    if (!newWeight || newWeight <= 0) return;
    savingWeighIn = true;
    try {
      const kg = $settings.weightUnit === 'lbs'
        ? Math.round(newWeight * LBS_TO_KG * 100) / 100
        : newWeight;
      const entry = await addBodyWeight({
        weight_kg: kg,
        notes: newNotes || undefined,
      });
      weighIns = [entry, ...weighIns];
      latestBodyWeight.set(entry);
      newWeight = null;
      newNotes = '';
    } finally {
      savingWeighIn = false;
    }
  }

  async function removeWeighIn(id: number) {
    await deleteBodyWeight(id);
    weighIns = weighIns.filter(e => e.id !== id);
    // If we deleted the most recent, update the store
    if (weighIns.length > 0) {
      latestBodyWeight.set(weighIns[0]);
    } else {
      latestBodyWeight.set(null);
    }
  }
</script>

<div class="space-y-6 max-w-2xl p-6">
  <h2 class="text-2xl font-bold">Settings</h2>

  <!-- ── Weight Unit ─────────────────────────────────────────────────── -->
  <div class="card space-y-4">
    <div>
      <h3 class="text-lg font-semibold">Weight Unit</h3>
      <p class="text-sm text-gray-400 mt-1">Unit used for all weight inputs during workouts.</p>
    </div>
    <div class="flex gap-3">
      {#each [['lbs', 'Pounds (lbs)'], ['kg', 'Kilograms (kg)']] as [val, label]}
        <button
          onclick={() => settings.update(s => ({ ...s, weightUnit: val as 'lbs' | 'kg' }))}
          class="flex-1 py-2.5 rounded-lg text-sm font-medium transition-colors {
            $settings.weightUnit === val
              ? 'bg-primary-600 text-white'
              : 'bg-gray-700 hover:bg-gray-600 text-gray-300'
          }"
        >{label}</button>
      {/each}
    </div>
  </div>

  <!-- ── Body Weight / Weigh-in Log ──────────────────────────────────── -->
  <div class="card space-y-4">
    <div>
      <h3 class="text-lg font-semibold">Body Weight</h3>
      <p class="text-sm text-gray-400 mt-1">
        Track your body weight over time. The most recent entry is used to calculate
        load for bodyweight and assisted exercises.
      </p>
    </div>

    <!-- Current body weight display -->
    {#if $latestBodyWeight}
      <div class="flex items-center gap-3 bg-gray-800 rounded-lg px-4 py-3">
        <div class="flex-1">
          <p class="text-xs text-gray-500">Most recent</p>
          <p class="text-xl font-bold font-mono text-primary-400">
            {toDisplayWeight($latestBodyWeight.weight_kg)}
            <span class="text-sm font-normal text-gray-400">{$settings.weightUnit}</span>
          </p>
        </div>
        <p class="text-xs text-gray-500">{fmtDate($latestBodyWeight.recorded_at)}</p>
      </div>
    {:else}
      <p class="text-sm text-gray-500 italic">No weigh-ins logged yet.</p>
    {/if}

    <!-- Log new weigh-in -->
    <div class="space-y-2">
      <p class="text-xs text-gray-500 font-medium uppercase tracking-wide">Log weigh-in</p>
      <div class="flex items-center gap-2 flex-wrap">
        <div class="flex items-center gap-1.5">
          <input
            type="number"
            bind:value={newWeight}
            min="0"
            placeholder="Weight"
            style="width:7rem"
            class="bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-white text-center font-mono placeholder-gray-400 focus:outline-none focus:border-primary-500"
          />
          <span class="text-sm text-gray-400 shrink-0">{$settings.weightUnit}</span>
        </div>
        <button
          onclick={logWeighIn}
          disabled={savingWeighIn || !newWeight}
          class="px-4 py-2 bg-primary-600 hover:bg-primary-500 text-white text-sm font-medium rounded-lg transition-colors disabled:opacity-40 shrink-0"
        >{savingWeighIn ? 'Saving…' : 'Log'}</button>
      </div>
    </div>

    <!-- History -->
    {#if weighIns.length > 0}
      <div class="space-y-1 max-h-52 overflow-y-auto">
        {#each weighIns as entry}
          <div class="flex items-center justify-between py-1.5 px-2 rounded hover:bg-gray-800 group">
            <div class="flex items-center gap-3">
              <span class="font-mono text-sm font-medium">
                {toDisplayWeight(entry.weight_kg)} {$settings.weightUnit}
              </span>
              <span class="text-xs text-gray-500">{fmtDate(entry.recorded_at)}</span>
              {#if entry.notes}
                <span class="text-xs text-gray-600 italic">{entry.notes}</span>
              {/if}
            </div>
            <button
              onclick={() => removeWeighIn(entry.id)}
              class="opacity-0 group-hover:opacity-100 text-gray-600 hover:text-red-400 text-xs transition-all"
              title="Delete entry"
            >✕</button>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- ── Progression Style ───────────────────────────────────────────── -->
  <div class="card space-y-4">
    <div>
      <h3 class="text-lg font-semibold">Progression Style</h3>
      <p class="text-sm text-gray-400 mt-1">
        How to apply progressive overload when you hit your target reps.
        Both use the Epley 1RM formula — the difference is <em>when</em> weight increases.
      </p>
    </div>
    <div class="flex flex-col gap-3">
      {#each [
        ['rep',    'Rep first',    'Add 1 rep each session. Weight goes up only when crossing a rep-range bracket (5-9 → 10-14 → 15+).'],
        ['weight', 'Weight first', 'Immediately translate the +1 rep into an equivalent weight increase via Epley. Reps stay fixed.'],
      ] as [val, label, desc]}
        <button
          onclick={() => settings.update(s => ({ ...s, progressionStyle: val as 'rep' | 'weight' }))}
          class="flex items-start gap-3 p-3 rounded-lg text-left transition-colors border {
            $settings.progressionStyle === val
              ? 'border-primary-500 bg-primary-600/10'
              : 'border-gray-700 bg-gray-800 hover:bg-gray-700'
          }"
        >
          <div class="mt-0.5 w-4 h-4 rounded-full border-2 shrink-0 {
            $settings.progressionStyle === val ? 'border-primary-400 bg-primary-400' : 'border-gray-500'
          }"></div>
          <div>
            <div class="text-sm font-medium">{label}</div>
            <div class="text-xs text-gray-400 mt-0.5">{desc}</div>
          </div>
        </button>
      {/each}
    </div>
  </div>

  <!-- ── Rest Timer ──────────────────────────────────────────────────── -->
  <div class="card space-y-5">
    <div>
      <h3 class="text-lg font-semibold">Rest Timer</h3>
      <p class="text-sm text-gray-400 mt-1">
        Default rest durations by movement category. You can also override per-exercise
        during a workout.
      </p>
    </div>

    {#each restCategories as cat}
      {@const current = $settings.restDurations[cat.key]}

      <div class="space-y-2">
        <!-- Label row -->
        <div class="flex items-center justify-between">
          <div>
            <span class="text-sm font-medium">{cat.label}</span>
            <span class="ml-2 text-xs px-1.5 py-0.5 rounded bg-gray-700 text-gray-300">{cat.sub}</span>
          </div>
          <span class="text-sm font-mono text-primary-400">{fmtSecs(current)}</span>
        </div>

        <!-- Presets -->
        <div class="flex flex-wrap gap-1.5">
          {#each cat.presets as p}
            <button
              onclick={() => setRest(cat.key, p)}
              class="px-2.5 py-1 rounded text-xs font-medium transition-colors {
                current === p
                  ? 'bg-primary-600 text-white'
                  : 'bg-gray-700 hover:bg-gray-600 text-gray-300'
              }"
            >{fmtSecs(p)}</button>
          {/each}
        </div>

        <!-- Custom input -->
        <div class="flex items-center gap-2">
          <span class="text-xs text-gray-500 w-14 shrink-0">Custom:</span>
          <input
            type="number"
            bind:value={customMins[cat.key]}
            min="0" max="59"
            class="input w-14 text-center text-sm font-mono py-1"
            placeholder="0"
          />
          <span class="text-xs text-gray-500">m</span>
          <input
            type="number"
            bind:value={customSecs[cat.key]}
            min="0" max="59"
            class="input w-14 text-center text-sm font-mono py-1"
            placeholder="0"
          />
          <span class="text-xs text-gray-500">s</span>
          <button
            onclick={() => applyCustom(cat.key)}
            class="text-xs px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-300 rounded transition-colors"
          >Set</button>
        </div>
      </div>

      {#if cat.key !== 'lowerIsolation'}
        <div class="border-t border-gray-700"></div>
      {/if}
    {/each}
  </div>
</div>
