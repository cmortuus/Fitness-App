<script lang="ts">
  let weight = $state<number | null>(null);
  let reps = $state<number | null>(null);
  let unit = $state<'lbs' | 'kg'>('lbs');

  // 1RM formulas
  const formulas = {
    epley:     (w: number, r: number) => r === 1 ? w : w * (1 + r / 30),
    brzycki:   (w: number, r: number) => r === 1 ? w : w * (36 / (37 - r)),
    lombardi:  (w: number, r: number) => w * Math.pow(r, 0.1),
    oconner:   (w: number, r: number) => w * (1 + r * 0.025),
    wathan:    (w: number, r: number) => r === 1 ? w : (100 * w) / (48.8 + 53.8 * Math.exp(-0.075 * r)),
  };

  let results = $derived((() => {
    if (!weight || !reps || weight <= 0 || reps <= 0 || reps > 30) return null;
    const w = weight;
    const r = reps;
    return Object.entries(formulas).map(([name, fn]) => ({
      name: name.charAt(0).toUpperCase() + name.slice(1),
      value: Math.round(fn(w, r)),
    }));
  })());

  let average = $derived(results ? Math.round(results.reduce((s, r) => s + r.value, 0) / results.length) : null);

  // Percentage table
  const percentages = [100, 95, 90, 85, 80, 75, 70, 65, 60, 55, 50];
  let percentageTable = $derived(average ? percentages.map(pct => ({
    pct,
    weight: Math.round(average! * pct / 100),
    reps: pct === 100 ? 1 : Math.round((average! / (average! * pct / 100) - 1) * 30),
  })) : null);
</script>

<div class="space-y-6 max-w-lg mx-auto p-6 pb-24">
  <h2 class="text-2xl font-bold">1RM Calculator</h2>
  <p class="text-sm text-zinc-400">Enter a weight and rep count to estimate your one-rep max across multiple formulas.</p>

  <!-- Input -->
  <div class="card space-y-4">
    <div class="flex gap-4">
      <div class="flex-1">
        <label class="text-xs text-zinc-400 block mb-1">Weight</label>
        <input type="number" inputmode="decimal" bind:value={weight} min="1" placeholder={unit}
               class="input text-center text-lg" style="font-size: 16px;" />
      </div>
      <div class="flex-1">
        <label class="text-xs text-zinc-400 block mb-1">Reps</label>
        <input type="number" inputmode="numeric" bind:value={reps} min="1" max="30" placeholder="reps"
               class="input text-center text-lg" style="font-size: 16px;" />
      </div>
    </div>
    <div class="flex gap-2">
      <button onclick={() => unit = 'lbs'}
              class="flex-1 py-2 rounded-lg text-sm font-medium transition-colors {unit === 'lbs' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}">lbs</button>
      <button onclick={() => unit = 'kg'}
              class="flex-1 py-2 rounded-lg text-sm font-medium transition-colors {unit === 'kg' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-400'}">kg</button>
    </div>
  </div>

  <!-- Results -->
  {#if results && average}
    <div class="card space-y-3">
      <div class="text-center">
        <p class="text-xs text-zinc-500 uppercase tracking-wider">Estimated 1RM</p>
        <p class="text-4xl font-bold text-primary-400">{average} <span class="text-lg text-zinc-500">{unit}</span></p>
      </div>

      <div class="space-y-1 pt-2 border-t border-zinc-800">
        {#each results as r}
          <div class="flex justify-between text-sm">
            <span class="text-zinc-400">{r.name}</span>
            <span class="font-mono text-zinc-200">{r.value} {unit}</span>
          </div>
        {/each}
      </div>
    </div>

    <!-- Percentage table -->
    <div class="card space-y-3">
      <h3 class="text-sm font-semibold">Training Percentages</h3>
      <div class="space-y-1">
        <div class="flex justify-between text-xs text-zinc-500 pb-1 border-b border-zinc-800">
          <span>%1RM</span>
          <span>Weight</span>
          <span>~Reps</span>
        </div>
        {#each percentageTable! as row}
          <div class="flex justify-between text-sm {row.pct === 100 ? 'font-bold text-primary-400' : ''}">
            <span class="text-zinc-400 w-12">{row.pct}%</span>
            <span class="font-mono">{row.weight} {unit}</span>
            <span class="text-zinc-500 w-8 text-right">{row.reps}</span>
          </div>
        {/each}
      </div>
    </div>
  {/if}
</div>
