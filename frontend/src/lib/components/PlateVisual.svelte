<script lang="ts">
  /**
   * Visual plate breakdown — shows colored plates on a bar, per side.
   * Props: totalWeight, barWeight, isLbs, oneSided, prevWeight
   */
  interface Props {
    totalWeight: number;
    barWeight: number;
    isLbs: boolean;
    oneSided?: boolean; // t-bar row, landmine — plates on one end only
    prevWeight?: number | null; // previous exercise/set weight for delta display
  }

  let { totalWeight, barWeight, isLbs, oneSided = false, prevWeight = null }: Props = $props();

  // Standard gym plate colors (lbs) — sizes proportional to real plates
  const PLATES_LBS: [number, string, string][] = [
    [45, '#3b82f6', '3.2rem'],  // blue (full-size bumper)
    [35, '#eab308', '3rem'],    // yellow
    [25, '#22c55e', '2.8rem'],  // green
    [10, '#d4d4d8', '2rem'],    // white/silver (change plate)
    [5,  '#d4d4d8', '1.6rem'],  // silver, smaller
    [2.5,'#d4d4d8', '1.2rem'],  // silver, smallest
  ];

  // IWF competition plate colors (kg)
  const PLATES_KG: [number, string, string][] = [
    [25,   '#ef4444', '3.2rem'],  // red
    [20,   '#3b82f6', '3.2rem'],  // blue
    [15,   '#eab308', '3rem'],    // yellow
    [10,   '#22c55e', '2.8rem'],  // green
    [5,    '#d4d4d8', '2rem'],    // silver
    [2.5,  '#d4d4d8', '1.6rem'],  // silver
    [1.25, '#d4d4d8', '1.2rem'],  // silver
  ];

  interface PlateSlice {
    weight: number;
    color: string;
    height: string;
    count: number;
  }

  interface PlateBreakdown {
    plates: PlateSlice[];
    remainder: number;
    targetPerSide: number;
    loadablePerSide: number;
  }

  function calcPlates(weight: number): PlateBreakdown {
    const perSide = oneSided ? (weight - barWeight) : (weight - barWeight) / 2;
    if (perSide <= 0) {
      return {
        plates: [],
        remainder: 0,
        targetPerSide: 0,
        loadablePerSide: 0,
      };
    }

    const available = isLbs ? PLATES_LBS : PLATES_KG;
    let remaining = perSide;
    const plates: PlateSlice[] = [];

    for (const [w, color, height] of available) {
      const count = Math.floor(remaining / w);
      if (count > 0) {
        plates.push({ weight: w, color, height, count });
        remaining -= count * w;
      }
    }
    return {
      plates,
      remainder: remaining,
      targetPerSide: perSide,
      loadablePerSide: perSide - remaining,
    };
  }

  let breakdown = $derived(calcPlates(totalWeight));
  let plates = $derived(breakdown.plates);
  let hasExactDistribution = $derived(breakdown.remainder <= 0.1);
  let unmatchedLabel = $derived.by(() => {
    if (hasExactDistribution || breakdown.remainder <= 0) return null;
    const rounded = Number(breakdown.remainder.toFixed(2));
    return `${rounded} ${isLbs ? 'lb' : 'kg'}${rounded === 1 ? '' : 's'}`;
  });
  let closestLoadableTotal = $derived.by(() => {
    if (oneSided) return barWeight + breakdown.loadablePerSide;
    return barWeight + breakdown.loadablePerSide * 2;
  });

  // Plate delta — what to add/remove compared to previous weight
  let plateDelta = $derived.by(() => {
    if (prevWeight == null || prevWeight === totalWeight || prevWeight <= barWeight) return null;
    const prevBreakdown = calcPlates(prevWeight);
    const prevPlates = prevBreakdown.plates;
    if (!hasExactDistribution || prevBreakdown.remainder > 0.1 || prevPlates.length === 0 || plates.length === 0) return null;

    // Build weight→count maps
    const prevMap = new Map<number, number>();
    for (const p of prevPlates) prevMap.set(p.weight, p.count);
    const curMap = new Map<number, number>();
    for (const p of plates) curMap.set(p.weight, p.count);

    const allWeights = new Set([...prevMap.keys(), ...curMap.keys()]);
    const add: string[] = [];
    const remove: string[] = [];

    for (const w of [...allWeights].sort((a, b) => b - a)) {
      const prev = prevMap.get(w) ?? 0;
      const cur = curMap.get(w) ?? 0;
      if (cur > prev) add.push(`${cur - prev}×${w}`);
      else if (prev > cur) remove.push(`${prev - cur}×${w}`);
    }

    if (add.length === 0 && remove.length === 0) return null;
    return { add, remove };
  });

  function compactOneSidedWidth(height: string): string {
    const match = height.match(/^([\d.]+)rem$/);
    if (!match) return '1.1rem';
    const scaled = Math.max(0.8, Number(match[1]) * 0.45);
    return `${scaled.toFixed(2)}rem`;
  }
</script>

{#if oneSided}
  <!-- Upright single-pin view (T-bar row, landmine) — scaled to fit container -->
  <div class="flex flex-col items-center mt-0.5 max-w-full overflow-hidden">
    <div class="relative flex flex-col-reverse items-center justify-start min-h-[1.9rem]">
      <div style="width: 3px; height: 1.6rem; background: #52525b; border-radius: 2px;"></div>
      <div class="absolute bottom-[2px] left-1/2 -translate-x-1/2 flex flex-col-reverse items-center gap-px">
        {#each plates as plate}
          {#each Array(plate.count) as _}
            <div
              style="width: {compactOneSidedWidth(plate.height)}; height: 2px; background: {plate.color}; border-radius: 999px;"
              title="{plate.weight} {isLbs ? 'lbs' : 'kg'}"
            ></div>
          {/each}
        {/each}
      </div>
      <div class="absolute bottom-0" style="width: 0.75rem; height: 3px; background: #71717a; border-radius: 999px;"></div>
      <div class="absolute top-0" style="width: 6px; height: 4px; background: #3f3f46; border-radius: 999px;"></div>
    </div>
  </div>
{:else}
  <!-- Horizontal barbell view -->
  <div class="flex items-center gap-0.5 justify-center mt-0.5">
    <!-- Left bar end -->
    <div style="width: 10px; height: 4px; background: #52525b; border-radius: 1px 0 0 1px;"></div>
    <!-- Left side: smallest outside, biggest near bar -->
    {#each [...plates].reverse() as plate}
      {#each Array(plate.count) as _}
        <div
          style="width: 5px; height: {plate.height}; background: {plate.color}; border-radius: 1px;"
          title="{plate.weight} {isLbs ? 'lbs' : 'kg'}"
        ></div>
      {/each}
    {/each}
    <!-- Sleeve -->
    <div style="width: 12px; height: 6px; background: #71717a; border-radius: 1px;"></div>
    <!-- Bar -->
    <div style="width: 30px; height: 4px; background: #52525b; border-radius: 1px;"></div>
    <!-- Sleeve -->
    <div style="width: 12px; height: 6px; background: #71717a; border-radius: 1px;"></div>
    <!-- Right side: biggest near bar, smallest outside -->
    {#each plates as plate}
      {#each Array(plate.count) as _}
        <div
          style="width: 5px; height: {plate.height}; background: {plate.color}; border-radius: 1px;"
          title="{plate.weight} {isLbs ? 'lbs' : 'kg'}"
        ></div>
      {/each}
    {/each}
    <!-- Right bar end -->
    <div style="width: 10px; height: 4px; background: #52525b; border-radius: 0 1px 1px 0;"></div>
  </div>
{/if}
{#if plates.length > 0}
  <p class="text-[9px] text-zinc-500 text-center">
    {plates.map(p => `${p.count}×${p.weight}`).join(' + ')} {oneSided ? '' : '/side'}
  </p>
{:else}
  <p class="text-[9px] text-zinc-500 text-center">
    No plates needed
  </p>
{/if}
{#if !hasExactDistribution}
  <p class="text-[9px] text-amber-400 text-center mt-0.5">
    Can't load exactly. Closest is {closestLoadableTotal.toFixed(1).replace(/\.0$/, '')} {isLbs ? 'lb' : 'kg'}
    {#if unmatchedLabel}
      with {unmatchedLabel} left over {oneSided ? 'on the pin' : 'per side'}
    {/if}
    .
  </p>
{/if}
{#if plateDelta}
  <p class="text-[9px] text-center mt-0.5">
    {#if plateDelta.remove.length > 0}
      <span class="text-red-400">−{plateDelta.remove.join(', ')}</span>
    {/if}
    {#if plateDelta.remove.length > 0 && plateDelta.add.length > 0}
      <span class="text-zinc-600"> → </span>
    {/if}
    {#if plateDelta.add.length > 0}
      <span class="text-green-400">+{plateDelta.add.join(', ')}</span>
    {/if}
    {#if !oneSided}
      <span class="text-zinc-600"> /side</span>
    {/if}
  </p>
{/if}
