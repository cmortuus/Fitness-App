<script lang="ts">
  import { onMount } from 'svelte';
  import { settings, latestBodyWeight } from '$lib/stores';
  import type { RestDurations } from '$lib/stores';
  import { addBodyWeight, deleteBodyWeight, getBodyWeights, clearAuthTokens, getStoredUser, recalculateWeights } from '$lib/api';
  import { writeBodyWeight, isHealthKitAvailable, requestHealthKitPermissions } from '$lib/healthkit';

  let healthKitAvailable = $state(false);
  let healthKitConnected = $state(false);

  async function connectHealthKit() {
    healthKitConnected = await requestHealthKitPermissions();
  }
  import type { BodyWeightEntry } from '$lib/api';

  const currentUser = getStoredUser();

  // Collapsible sections
  let showBars = $state(false);
  let showPlateLoaded = $state(false);

  // Machine key → exercise name pattern for retroactive recalculation
  const MACHINE_PATTERNS: Record<string, string> = {
    smithMachine: 'smith', legPress: 'leg_press', hackSquat: 'hack_squat',
    tBarRow: 't_bar', beltSquat: 'belt', chestPress: 'chest_press',
    shoulderPress: 'shoulder_press', inclinePress: 'incline', declinePress: 'decline',
    calfRaise: 'calf', seatedRow: 'seated_row', latPulldown: 'lat_pulldown',
    pendulumSquat: 'pendulum', hipThrust: 'hip_thrust', legExtension: 'leg_extension',
    legCurl: 'leg_curl',
  };

  async function handleMachineWeightChange(key: string, newVal: number) {
    const oldVal = $settings.machineWeights?.[key] ?? 0;
    settings.update(s => ({ ...s, machineWeights: { ...s.machineWeights, [key]: newVal } }));

    if (oldVal > 0 && Math.abs(newVal - oldVal) > 0.1) {
      const pattern = MACHINE_PATTERNS[key];
      if (pattern) {
        const apply = confirm(
          `Apply this weight change retroactively to all past workouts on this machine?\n\n` +
          `OK = Recalculate past workouts\nCancel = Future workouts only`
        );
        if (apply) {
          try {
            const result = await recalculateWeights(
              pattern,
              oldVal * LBS_TO_KG,
              newVal * LBS_TO_KG
            );
            if (result.adjusted > 0) {
              alert(`Updated ${result.adjusted} historical sets.`);
            }
          } catch {
            alert('Failed to recalculate past workouts.');
          }
        }
      }
    }
  }

  function logout() {
    clearAuthTokens();
    window.location.href = '/login';
  }

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
    // Sync custom inputs so "Set" button doesn't overwrite the preset
    customMins[key] = Math.floor(secs / 60);
    customSecs[key] = secs % 60;
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
  let newBodyFat = $state<number | null>(null);
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
    healthKitAvailable = await isHealthKitAvailable();
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
        body_fat_pct: newBodyFat || undefined,
        notes: newNotes || undefined,
      });
      weighIns = [entry, ...weighIns];
      latestBodyWeight.set(entry);
      writeBodyWeight(kg).catch(() => {}); // sync to HealthKit (no-op on web)
      newWeight = null;
      newBodyFat = null;
      newNotes = '';
    } catch (e) {
      console.error('Failed to log weigh-in:', e);
      alert('Failed to save weigh-in. Please try again.');
    } finally {
      savingWeighIn = false;
    }
  }

  async function removeWeighIn(id: number) {
    try {
      await deleteBodyWeight(id);
      weighIns = weighIns.filter(e => e.id !== id);
      if (weighIns.length > 0) {
        latestBodyWeight.set(weighIns[0]);
      } else {
        latestBodyWeight.set(null);
      }
    } catch (e) {
      console.error('Failed to delete weigh-in:', e);
      alert('Failed to delete weigh-in. Please try again.');
    }
  }
</script>

<div class="space-y-6 max-w-2xl mx-auto p-6 pb-24">
  <h2 class="text-2xl font-bold">Settings</h2>

  <!-- ── Profile ─────────────────────────────────────────────────────── -->
  <div class="card space-y-4">
    <div class="flex items-center justify-between">
      <div>
        <h3 class="text-lg font-semibold">Profile</h3>
        <p class="text-sm text-zinc-400 mt-1">Used for TDEE estimates and macro calculations.</p>
      </div>
      {#if $settings.profile.age && $settings.profile.sex && $settings.profile.heightIn}
        <span class="text-xs text-green-400 bg-green-500/10 px-2 py-1 rounded-full">✓ Saved</span>
      {/if}
    </div>

    <div class="grid grid-cols-2 gap-3">
      <div>
        <label for="settings-age" class="text-xs text-zinc-400 block mb-1">Age</label>
        <input id="settings-age" type="number" min="13" max="120" placeholder="—"
               value={$settings.profile.age ?? ''}
               onchange={(e) => {
                 const val = e.currentTarget.value ? Number(e.currentTarget.value) : null;
                 const clamped = val !== null ? Math.min(120, Math.max(13, val)) : null;
                 settings.update(s => ({ ...s, profile: { ...s.profile, age: clamped } }));
               }}
               class="input text-center" />
      </div>
      <div>
        <label class="text-xs text-zinc-400 block mb-1">Sex</label>
        <div class="flex gap-2">
          {#each [['male', 'Male'], ['female', 'Female']] as [val, label]}
            <button onclick={() => settings.update(s => ({ ...s, profile: { ...s.profile, sex: val as any } }))}
                    class="flex-1 py-2.5 rounded-lg text-sm font-medium transition-colors
                           {$settings.profile.sex === val ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
              {label}
            </button>
          {/each}
        </div>
      </div>
    </div>

    <div>
      <label class="text-xs text-zinc-400 block mb-1">Height</label>
      <!-- Unit selector -->
      <div class="flex gap-1 mb-2">
        {#each [['in', 'Inches'], ['ft', 'Feet + In'], ['cm', 'cm']] as [val, label]}
          <button onclick={() => settings.update(s => ({ ...s, heightUnit: val as any }))}
                  class="flex-1 py-1.5 rounded-lg text-xs font-medium transition-colors
                         {$settings.heightUnit === val ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
            {label}
          </button>
        {/each}
      </div>
      <!-- Input based on unit -->
      {#if $settings.heightUnit === 'cm'}
        <div class="flex gap-2 items-center">
          <input type="number" min="120" max="250" step="0.5" placeholder="—"
                 value={$settings.profile.heightIn ? Math.round($settings.profile.heightIn * 2.54 * 10) / 10 : ''}
                 onchange={(e) => {
                   const cm = e.currentTarget.value ? Number(e.currentTarget.value) : null;
                   settings.update(s => ({ ...s, profile: { ...s.profile, heightIn: cm ? Math.round(cm / 2.54) : null } }));
                 }}
                 class="input text-center w-24" />
          <span class="text-sm text-zinc-500">cm</span>
          {#if $settings.profile.heightIn}
            <span class="text-xs text-zinc-600">({Math.round($settings.profile.heightIn * 2.54)} cm)</span>
          {/if}
        </div>
      {:else if $settings.heightUnit === 'ft'}
        {@const totalIn = $settings.profile.heightIn ?? 0}
        {@const ft = Math.floor(totalIn / 12)}
        {@const inPart = totalIn % 12}
        <div class="flex gap-2 items-center">
          <input type="number" min="3" max="8" placeholder="—"
                 value={totalIn > 0 ? ft : ''}
                 onchange={(e) => {
                   const newFt = e.currentTarget.value ? Number(e.currentTarget.value) : 0;
                   const curIn = ($settings.profile.heightIn ?? 0) % 12;
                   settings.update(s => ({ ...s, profile: { ...s.profile, heightIn: newFt * 12 + curIn || null } }));
                 }}
                 class="input text-center w-16" />
          <span class="text-sm text-zinc-500">ft</span>
          <input type="number" min="0" max="11" placeholder="—"
                 value={totalIn > 0 ? inPart : ''}
                 onchange={(e) => {
                   const newIn = e.currentTarget.value ? Number(e.currentTarget.value) : 0;
                   const curFt = Math.floor(($settings.profile.heightIn ?? 0) / 12);
                   settings.update(s => ({ ...s, profile: { ...s.profile, heightIn: curFt * 12 + newIn || null } }));
                 }}
                 class="input text-center w-16" />
          <span class="text-sm text-zinc-500">in</span>
        </div>
      {:else}
        <div class="flex gap-2 items-center">
          <input type="number" min="48" max="96" placeholder="—"
                 value={$settings.profile.heightIn ?? ''}
                 onchange={(e) => settings.update(s => ({ ...s, profile: { ...s.profile, heightIn: e.currentTarget.value ? Number(e.currentTarget.value) : null } }))}
                 class="input text-center w-24" />
          <span class="text-sm text-zinc-500">inches</span>
          {#if $settings.profile.heightIn}
            <span class="text-xs text-zinc-600">({Math.floor($settings.profile.heightIn / 12)}'{$settings.profile.heightIn % 12}")</span>
          {/if}
        </div>
      {/if}
    </div>

    <div>
      <label class="text-xs text-zinc-400 block mb-1">Activity Level</label>
      <div class="space-y-1">
        {#each [[1.0, 'Sedentary'], [1.2, 'Light (1-2x/wk)'], [1.4, 'Moderate (3-4x/wk)'], [1.6, 'Active (5-6x/wk)'], [1.8, 'Very Active']] as [val, label]}
          <button onclick={() => settings.update(s => ({ ...s, profile: { ...s.profile, activityLevel: val as number } }))}
                  class="w-full text-left px-3 py-2 rounded-lg text-sm transition-colors
                         {$settings.profile.activityLevel === val ? 'bg-primary-600/20 text-primary-400 font-medium' : 'text-zinc-400 hover:bg-zinc-800'}">
            {label}
          </button>
        {/each}
      </div>
    </div>
  </div>

  <!-- ── Weight Unit ─────────────────────────────────────────────────── -->
  <div class="card space-y-4">
    <div>
      <h3 class="text-lg font-semibold">Weight Unit</h3>
      <p class="text-sm text-zinc-400 mt-1">Unit used for all weight inputs during workouts.</p>
    </div>
    <div class="flex gap-3">
      {#each [['lbs', 'Pounds (lbs)'], ['kg', 'Kilograms (kg)']] as [val, label]}
        <button
          onclick={() => settings.update(s => ({ ...s, weightUnit: val as 'lbs' | 'kg' }))}
          class="flex-1 py-2.5 rounded-lg text-sm font-medium transition-colors {
            $settings.weightUnit === val
              ? 'bg-primary-600 text-white'
              : 'bg-zinc-800 hover:bg-gray-600 text-gray-300'
          }"
        >{label}</button>
      {/each}
    </div>
  </div>

  <!-- ── Body Weight / Weigh-in Log ──────────────────────────────────── -->
  <div class="card space-y-4">
    <div>
      <h3 class="text-lg font-semibold">Body Weight</h3>
      <p class="text-sm text-zinc-400 mt-1">
        Track your body weight over time. The most recent entry is used to calculate
        load for bodyweight and assisted exercises.
      </p>
    </div>

    <!-- Current body weight display -->
    {#if $latestBodyWeight}
      <div class="flex items-center gap-3 bg-zinc-900 rounded-lg px-4 py-3">
        <div class="flex-1">
          <p class="text-xs text-zinc-500">Most recent</p>
          <p class="text-xl font-bold font-mono text-primary-400">
            {toDisplayWeight($latestBodyWeight.weight_kg)}
            <span class="text-sm font-normal text-zinc-400">{$settings.weightUnit}</span>
          </p>
        </div>
        <p class="text-xs text-zinc-500">{fmtDate($latestBodyWeight.recorded_at)}</p>
      </div>
    {:else}
      <p class="text-sm text-zinc-500 italic">No weigh-ins logged yet.</p>
    {/if}

    <!-- Log new weigh-in -->
    <div class="space-y-2">
      <p class="text-xs text-zinc-500 font-medium uppercase tracking-wide">Log weigh-in</p>
      <div class="flex items-center gap-2 flex-wrap">
        <div class="flex items-center gap-1.5">
          <input
            type="number"
            bind:value={newWeight}
            min="0"
            placeholder="Weight"
            style="width:7rem"
            class="bg-zinc-800 border border-gray-600 rounded-lg px-3 py-2 text-white text-center font-mono placeholder-gray-400 focus:outline-none focus:border-primary-500"
          />
          <span class="text-sm text-zinc-400 shrink-0">{$settings.weightUnit}</span>
        </div>
        <div class="flex items-center gap-1.5">
          <input
            type="number"
            bind:value={newBodyFat}
            min="3" max="60" step="0.1"
            placeholder="BF%"
            style="width:5rem"
            class="bg-zinc-800 border border-gray-600 rounded-lg px-3 py-2 text-white text-center font-mono placeholder-gray-400 focus:outline-none focus:border-primary-500"
          />
          <span class="text-sm text-zinc-400 shrink-0">%</span>
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
          <div class="flex items-center justify-between py-1.5 px-2 rounded hover:bg-zinc-900 group">
            <div class="flex items-center gap-3 flex-wrap">
              <span class="font-mono text-sm font-medium">
                {toDisplayWeight(entry.weight_kg)} {$settings.weightUnit}
              </span>
              {#if entry.body_fat_pct}
                <span class="text-xs text-primary-400">{entry.body_fat_pct}% BF</span>
                {#if entry.lean_mass_kg}
                  <span class="text-[10px] text-zinc-600">
                    lean {toDisplayWeight(entry.lean_mass_kg)} · fat {toDisplayWeight(entry.fat_mass_kg ?? 0)}
                  </span>
                {/if}
              {/if}
              <span class="text-xs text-zinc-500">{fmtDate(entry.recorded_at)}</span>
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
      <p class="text-sm text-zinc-400 mt-1">
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
              : 'border-zinc-800 bg-zinc-900 hover:bg-zinc-800'
          }"
        >
          <div class="mt-0.5 w-4 h-4 rounded-full border-2 shrink-0 {
            $settings.progressionStyle === val ? 'border-primary-400 bg-primary-400' : 'border-gray-500'
          }"></div>
          <div>
            <div class="text-sm font-medium">{label}</div>
            <div class="text-xs text-zinc-400 mt-0.5">{desc}</div>
          </div>
        </button>
      {/each}
    </div>

    <!-- Rep bracket explanation — shown when "Rep first" style is active -->
    {#if $settings.progressionStyle === 'rep'}
      <div class="text-xs text-zinc-400 bg-zinc-900 rounded-lg p-3 space-y-1">
        <p class="font-medium text-gray-300">How rep brackets work</p>
        <p>Your rep range is split into three brackets:</p>
        <ul class="list-disc list-inside space-y-0.5 pl-1">
          <li><span class="text-white font-mono">Bracket 1</span> — 1–9 reps</li>
          <li><span class="text-white font-mono">Bracket 2</span> — 10–14 reps</li>
          <li><span class="text-white font-mono">Bracket 3</span> — 15+ reps</li>
        </ul>
        <p class="pt-0.5">
          Each session you add 1 rep. When the next rep would push you into a higher bracket,
          weight increases instead (via the Epley 1RM formula) and reps reset to the bottom of
          the new bracket range.
        </p>
      </div>
    {/if}
  </div>

  <!-- ── Equipment Weights ──────────────────────────────────────────── -->
  <div class="card space-y-5">
    <div>
      <h3 class="text-lg font-semibold">Equipment Weights</h3>
      <p class="text-sm text-zinc-400 mt-1">Set the unloaded weight of your equipment for accurate plate calculations.</p>
    </div>

    <!-- Bars (collapsible) -->
    <div>
      <button onclick={() => showBars = !showBars}
              class="w-full flex items-center justify-between py-1">
        <h4 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">Bars</h4>
        <span class="text-zinc-500 text-sm transition-transform duration-200" class:rotate-180={showBars}>▾</span>
      </button>
      {#if showBars}
      <div class="space-y-2 mt-2">
        {#each [
          ['barbell', 'Standard Barbell (Olympic)'],
          ['ezBar', 'EZ Curl Bar'],
          ['ezBarRackable', 'Rackable EZ Bar'],
          ['safetySquatBar', 'Safety Squat Bar (SSB)'],
          ['trapBar', 'Trap / Hex Bar'],
        ] as [key, label]}
          <div class="flex items-center justify-between gap-4">
            <label for="mw-{key}" class="text-sm text-zinc-300 flex-1">{label}</label>
            <div class="flex items-center gap-2">
              <input id="mw-{key}" type="number" inputmode="decimal"
                     value={$settings.machineWeights?.[key] ?? 0}
                     onchange={(e) => {
                       const val = parseFloat((e.target as HTMLInputElement).value) || 0;
                       settings.update(s => ({
                         ...s,
                         machineWeights: { ...s.machineWeights, [key]: val }
                       }));
                     }}
                     class="w-20 text-center bg-zinc-800 border border-zinc-700 rounded-lg px-2 py-2 text-white"
                     style="font-size: 16px;" />
              <span class="text-xs text-zinc-500 w-6">{$settings.weightUnit}</span>
            </div>
          </div>
        {/each}
      </div>
      {/if}
    </div>

    <!-- Plate-loaded machines (collapsible) -->
    <div>
      <button onclick={() => showPlateLoaded = !showPlateLoaded}
              class="w-full flex items-center justify-between py-1">
        <h4 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">Plate-Loaded Machines</h4>
        <span class="text-zinc-500 text-sm transition-transform duration-200" class:rotate-180={showPlateLoaded}>▾</span>
      </button>
      {#if showPlateLoaded}
      <div class="space-y-3 mt-2">
        {#each [
          ['smithMachine', 'Smith Machine'],
          ['legPress', 'Leg Press'],
          ['hackSquat', 'Hack Squat'],
          ['tBarRow', 'T-Bar Row'],
          ['beltSquat', 'Belt Squat'],
          ['chestPress', 'Chest Press'],
          ['shoulderPress', 'Shoulder Press'],
          ['inclinePress', 'Incline Press'],
          ['declinePress', 'Decline Press'],
          ['calfRaise', 'Calf Raise'],
          ['seatedRow', 'Seated Row'],
          ['latPulldown', 'Lat Pulldown'],
          ['pendulumSquat', 'Pendulum Squat'],
          ['hipThrust', 'Hip Thrust Machine'],
          ['legExtension', 'Leg Extension'],
          ['legCurl', 'Leg Curl'],
        ] as [key, label]}
          <div class="space-y-1">
            <div class="flex items-center justify-between gap-4">
              <label for="mw-{key}" class="text-sm text-zinc-300 flex-1">{label}</label>
              <div class="flex items-center gap-2">
                <input id="mw-{key}" type="number" inputmode="decimal"
                       value={$settings.machineWeights?.[key] ?? 0}
                       onchange={(e) => {
                         const val = parseFloat((e.target as HTMLInputElement).value) || 0;
                         handleMachineWeightChange(key, val);
                       }}
                       class="w-20 text-center bg-zinc-800 border border-zinc-700 rounded-lg px-2 py-2 text-white"
                       style="font-size: 16px;" />
                <span class="text-xs text-zinc-500 w-6">{$settings.weightUnit}</span>
              </div>
            </div>
            <div class="flex items-center justify-between gap-4 pl-4">
              <span class="text-xs text-zinc-500 flex-1">Plate math base</span>
              <div class="flex items-center gap-2">
                <input type="number" inputmode="decimal"
                       value={$settings.machineWeights?.[`${key}_displayBase`] ?? $settings.machineWeights?.[key] ?? 0}
                       onchange={(e) => {
                         const val = parseFloat((e.target as HTMLInputElement).value) || 0;
                         settings.update(s => ({
                           ...s,
                           machineWeights: { ...s.machineWeights, [`${key}_displayBase`]: val }
                         }));
                       }}
                       class="w-20 text-center bg-zinc-800 border border-zinc-600 rounded-lg px-2 py-1.5 text-white text-sm"
                       style="font-size: 16px;" />
                <span class="text-xs text-zinc-500 w-6">{$settings.weightUnit}</span>
              </div>
            </div>
          </div>
        {/each}
      </div>
      {/if}
    </div>
  </div>

  <!-- ── Warmup Settings ────────────────────────────────────────────── -->
  <div class="card space-y-3">
    <h3 class="text-lg font-semibold">Warmups</h3>
    <div class="flex items-center justify-between gap-4">
      <div>
        <p class="text-sm text-zinc-300">Max warmup sets</p>
        <p class="text-xs text-zinc-500">Limit auto-generated warmup sets per exercise</p>
      </div>
      <div class="flex items-center gap-2">
        {#each [1, 2, 3, 4] as n}
          <button onclick={() => settings.update(s => ({ ...s, maxWarmupSets: n }))}
                  class="w-8 h-8 rounded-lg text-sm font-medium transition-colors {$settings.maxWarmupSets === n ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
            {n}
          </button>
        {/each}
      </div>
    </div>
  </div>

  <!-- ── Plate Math ────────────────────────────────────────────────── -->
  <div class="card space-y-3">
    <h3 class="text-lg font-semibold">Plate Math</h3>
    <div class="flex items-center justify-between gap-4">
      <div>
        <p class="text-sm text-zinc-300">Show plate breakdown</p>
        <p class="text-xs text-zinc-500">Display plate visualization when entering weight for barbell/plate-loaded exercises</p>
      </div>
      <button
        onclick={() => settings.update(s => ({ ...s, showPlateMath: !s.showPlateMath }))}
        class="w-12 h-7 rounded-full transition-colors relative {$settings.showPlateMath ? 'bg-primary-600' : 'bg-zinc-700'}"
      >
        <span class="absolute top-0.5 left-0.5 w-6 h-6 rounded-full bg-white transition-transform {$settings.showPlateMath ? 'translate-x-5' : ''}"></span>
      </button>
    </div>
  </div>

  <!-- ── Deload ───────────────────────────────────────────────────── -->
  <div class="card space-y-4">
    <div>
      <h3 class="text-lg font-semibold">Deload</h3>
      <p class="text-sm text-zinc-400 mt-1">Configure how deload weeks reduce intensity and volume.</p>
    </div>

    <div class="flex items-center justify-between gap-4">
      <div>
        <p class="text-sm text-zinc-300">Sessions per deload</p>
        <p class="text-xs text-zinc-500">0 = match your plan's days</p>
      </div>
      <div class="flex items-center gap-2">
        {#each [0, 1, 2, 3, 4, 5] as n}
          <button onclick={() => settings.update(s => ({ ...s, deload: { ...s.deload, sessions: n } }))}
                  class="w-8 h-8 rounded-lg text-sm font-medium transition-colors {($settings.deload?.sessions ?? 0) === n ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
            {n === 0 ? 'Auto' : n}
          </button>
        {/each}
      </div>
    </div>

    <div class="flex items-center justify-between gap-4">
      <div>
        <p class="text-sm text-zinc-300">Weight reduction</p>
        <p class="text-xs text-zinc-500">% of working weight to use</p>
      </div>
      <div class="flex items-center gap-2">
        {#each [50, 60, 70, 80] as pct}
          <button onclick={() => settings.update(s => ({ ...s, deload: { ...s.deload, weightPercent: pct } }))}
                  class="w-10 h-8 rounded-lg text-sm font-medium transition-colors {($settings.deload?.weightPercent ?? 70) === pct ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
            {pct}%
          </button>
        {/each}
      </div>
    </div>

    <div class="flex items-center justify-between gap-4">
      <div>
        <p class="text-sm text-zinc-300">Volume reduction</p>
        <p class="text-xs text-zinc-500">% of working sets to keep</p>
      </div>
      <div class="flex items-center gap-2">
        {#each [40, 50, 60, 80] as pct}
          <button onclick={() => settings.update(s => ({ ...s, deload: { ...s.deload, volumePercent: pct } }))}
                  class="w-10 h-8 rounded-lg text-sm font-medium transition-colors {($settings.deload?.volumePercent ?? 60) === pct ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
            {pct}%
          </button>
        {/each}
      </div>
    </div>
  </div>

  <!-- ── Progression / Autoregulation ───────────────────────────────── -->
  <div class="card space-y-5">
    <div>
      <h3 class="text-lg font-semibold">Progression</h3>
      <p class="text-sm text-zinc-400 mt-1">
        Controls how fast the app suggests increasing weight and volume.
      </p>
    </div>

    <!-- Training level -->
    <div class="flex items-center justify-between">
      <div>
        <p class="text-sm text-zinc-300">Training Level</p>
        <p class="text-xs text-zinc-500">Sets default increments and rep ranges</p>
      </div>
      <div class="flex rounded-lg overflow-hidden border border-zinc-700">
        {#each [['beginner', 'Beginner'], ['intermediate', 'Intermediate'], ['advanced', 'Advanced']] as [val, label]}
          <button onclick={() => {
            const presets: Record<string, any> = {
              beginner:     { upperWeightIncrement: 5, lowerWeightIncrement: 10, maxSetsPerExercise: 5, minRepsForIncrease: 8, maxRepsForIncrease: 12 },
              intermediate: { upperWeightIncrement: 2.5, lowerWeightIncrement: 5, maxSetsPerExercise: 6, minRepsForIncrease: 6, maxRepsForIncrease: 10 },
              advanced:     { upperWeightIncrement: 1.25, lowerWeightIncrement: 2.5, maxSetsPerExercise: 8, minRepsForIncrease: 5, maxRepsForIncrease: 8 },
            };
            settings.update(s => ({ ...s, progression: { ...s.progression, trainingLevel: val as any, ...presets[val] } }));
          }}
          class="px-3 py-1.5 text-xs transition-colors {$settings.progression?.trainingLevel === val ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
            {label}
          </button>
        {/each}
      </div>
    </div>

    <!-- Weight increments -->
    <div class="grid grid-cols-2 gap-4">
      <div>
        <label class="label">Upper body increment ({$settings.weightUnit})</label>
        <input type="number" step="0.5" min="0.5" max="20"
               value={$settings.progression?.upperWeightIncrement ?? 2.5}
               onchange={(e) => settings.update(s => ({ ...s, progression: { ...s.progression, upperWeightIncrement: parseFloat((e.target as HTMLInputElement).value) } }))}
               class="input" style="font-size: 16px;" />
      </div>
      <div>
        <label class="label">Lower body increment ({$settings.weightUnit})</label>
        <input type="number" step="0.5" min="0.5" max="20"
               value={$settings.progression?.lowerWeightIncrement ?? 5}
               onchange={(e) => settings.update(s => ({ ...s, progression: { ...s.progression, lowerWeightIncrement: parseFloat((e.target as HTMLInputElement).value) } }))}
               class="input" style="font-size: 16px;" />
      </div>
    </div>

    <!-- Rep range -->
    <div class="grid grid-cols-2 gap-4">
      <div>
        <label class="label">Min reps to increase weight</label>
        <input type="number" min="1" max="30"
               value={$settings.progression?.minRepsForIncrease ?? 8}
               onchange={(e) => settings.update(s => ({ ...s, progression: { ...s.progression, minRepsForIncrease: parseInt((e.target as HTMLInputElement).value) } }))}
               class="input" style="font-size: 16px;" />
      </div>
      <div>
        <label class="label">Max reps before forced increase</label>
        <input type="number" min="1" max="50"
               value={$settings.progression?.maxRepsForIncrease ?? 12}
               onchange={(e) => settings.update(s => ({ ...s, progression: { ...s.progression, maxRepsForIncrease: parseInt((e.target as HTMLInputElement).value) } }))}
               class="input" style="font-size: 16px;" />
      </div>
    </div>

    <!-- Max sets -->
    <div class="flex items-center justify-between">
      <div>
        <p class="text-sm text-zinc-300">Max sets per exercise</p>
        <p class="text-xs text-zinc-500">Upper limit for auto-added volume</p>
      </div>
      <div class="flex items-center gap-2">
        {#each [4, 5, 6, 7, 8] as n}
          <button onclick={() => settings.update(s => ({ ...s, progression: { ...s.progression, maxSetsPerExercise: n } }))}
                  class="w-8 h-8 rounded-lg text-sm font-medium transition-colors {($settings.progression?.maxSetsPerExercise ?? 6) === n ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}">
            {n}
          </button>
        {/each}
      </div>
    </div>
  </div>

  <!-- ── Rest Timer ──────────────────────────────────────────────────── -->
  <div class="card space-y-5">
    <div>
      <h3 class="text-lg font-semibold">Rest Timer</h3>
      <p class="text-sm text-zinc-400 mt-1">
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
            <span class="ml-2 text-xs px-1.5 py-0.5 rounded bg-zinc-800 text-gray-300">{cat.sub}</span>
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
                  : 'bg-zinc-800 hover:bg-gray-600 text-gray-300'
              }"
            >{fmtSecs(p)}</button>
          {/each}
        </div>

        <!-- Custom input -->
        <div class="flex items-center gap-2">
          <span class="text-xs text-zinc-500 w-14 shrink-0">Custom:</span>
          <input
            type="number"
            bind:value={customMins[cat.key]}
            min="0" max="59"
            class="input w-14 text-center text-sm font-mono py-1"
            placeholder="0"
          />
          <span class="text-xs text-zinc-500">m</span>
          <input
            type="number"
            bind:value={customSecs[cat.key]}
            min="0" max="59"
            class="input w-14 text-center text-sm font-mono py-1"
            placeholder="0"
          />
          <span class="text-xs text-zinc-500">s</span>
          <button
            onclick={() => applyCustom(cat.key)}
            class="text-xs px-3 py-1.5 bg-zinc-800 hover:bg-gray-600 text-gray-300 rounded transition-colors"
          >Set</button>
        </div>
      </div>

      {#if cat.key !== 'lowerIsolation'}
        <div class="border-t border-zinc-800"></div>
      {/if}
    {/each}
  </div>

  <!-- ── Apple Health ──────────────────────────────────────────────── -->
  {#if healthKitAvailable}
    <div class="card space-y-3">
      <h3 class="text-lg font-semibold">Apple Health</h3>
      <p class="text-sm text-zinc-400">Sync workouts, body weight, and nutrition to Apple Health.</p>
      {#if healthKitConnected}
        <div class="flex items-center gap-2">
          <span class="w-2 h-2 rounded-full bg-green-500"></span>
          <span class="text-sm text-green-400">Connected</span>
        </div>
      {:else}
        <button onclick={connectHealthKit}
                class="w-full py-2.5 rounded-lg text-sm font-medium bg-red-500/10 text-red-400 border border-red-500/20 hover:bg-red-500/20 transition-colors">
          Connect Apple Health
        </button>
      {/if}
    </div>
  {/if}

  <!-- ── Developer ────────────────────────────────────────────────────── -->
  {#if typeof document !== 'undefined'}
    {@const onDev = document.cookie.includes('gymtracker_branch=dev')}
    <div class="card space-y-3">
      <h3 class="text-lg font-semibold">Developer</h3>
      <div class="flex items-center justify-between">
        <div>
          <p class="text-sm text-zinc-300">
            Branch: <span class="font-mono {onDev ? 'text-amber-400' : 'text-green-400'}">{onDev ? 'dev' : 'main'}</span>
          </p>
          <p class="text-xs text-zinc-500">{onDev ? 'You are on the development build' : 'You are on the stable build'}</p>
        </div>
        <button
          onclick={() => {
            const switchingToDev = !document.cookie.includes('gymtracker_branch=dev');
            if (switchingToDev) {
              document.cookie = 'gymtracker_branch=dev; path=/; max-age=31536000; Secure; SameSite=Lax';
            } else {
              document.cookie = 'gymtracker_branch=; path=/; max-age=0; Secure; SameSite=Lax';
            }
            // Persist to DB so it survives cache clears
            settings.update(s => ({ ...s, branchPreference: switchingToDev ? 'dev' : 'main' }));
            window.location.reload();
          }}
          class="px-4 py-2 rounded-lg text-sm font-medium transition-colors {onDev ? 'bg-green-600/20 text-green-400 hover:bg-green-600/30' : 'bg-amber-600/20 text-amber-400 hover:bg-amber-600/30'}"
        >
          Switch to {onDev ? 'main' : 'dev'}
        </button>
      </div>
      <!-- Force update -->
      <div class="flex items-center justify-between pt-2 border-t border-zinc-800">
        <div>
          <p class="text-sm text-zinc-300">Force update</p>
          <p class="text-xs text-zinc-500">Clear cache and load the latest version</p>
        </div>
        <button
          onclick={async () => {
            // Set flag to suppress the "new version" banner after reload
            sessionStorage.setItem('gymtracker_force_updated', '1');
            // Clear caches but DON'T unregister SW — that causes a re-registration
            // cycle that triggers the update banner again (#263) and can lose auth (#269)
            if ('caches' in window) {
              const keys = await caches.keys();
              await Promise.all(keys.map(k => caches.delete(k)));
            }
            // Tell the SW to skip waiting if there's a new version queued
            if (navigator.serviceWorker?.controller) {
              navigator.serviceWorker.controller.postMessage({ type: 'SKIP_WAITING' });
            }
            window.location.reload();
          }}
          class="px-4 py-2 rounded-lg text-sm font-medium transition-colors bg-primary-600/20 text-primary-400 hover:bg-primary-600/30"
        >
          Update Now
        </button>
      </div>
    </div>
  {/if}

  <!-- ── Account ──────────────────────────────────────────────────────── -->
  <div class="card space-y-3">
    <h3 class="text-lg font-semibold">Account</h3>
    {#if currentUser}
      <p class="text-sm text-zinc-400">Signed in as <span class="text-white font-medium">{currentUser.username}</span></p>
    {/if}
    <div class="flex gap-2">
      <button
        onclick={async () => {
          try {
            const token = localStorage.getItem('hgt_access_token');
            const res = await fetch('/api/sessions/export/csv', {
              headers: { 'Authorization': `Bearer ${token}` }
            });
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url; a.download = 'gymtracker-export.csv';
            a.click(); URL.revokeObjectURL(url);
          } catch { alert('Export failed'); }
        }}
        class="flex-1 py-2.5 rounded-lg text-sm font-medium bg-zinc-800 text-zinc-300 hover:bg-zinc-700 transition-colors">
        Export CSV
      </button>
      <button onclick={logout}
              class="flex-1 py-2.5 rounded-lg text-sm font-medium bg-red-500/10 text-red-400 border border-red-500/20 hover:bg-red-500/20 transition-colors">
        Sign Out
      </button>
    </div>
  </div>
</div>
