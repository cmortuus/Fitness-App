<script lang="ts">
  /**
   * Visual plate breakdown — shows colored plates on a bar, per side.
   * Props: totalWeight, barWeight, isLbs
   */
  interface Props {
    totalWeight: number;
    barWeight: number;
    isLbs: boolean;
  }

  let { totalWeight, barWeight, isLbs }: Props = $props();

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

  let plates = $derived.by(() => {
    const perSide = (totalWeight - barWeight) / 2;
    if (perSide <= 0) return [];

    const available = isLbs ? PLATES_LBS : PLATES_KG;
    let remaining = perSide;
    const result: PlateSlice[] = [];

    for (const [weight, color, height] of available) {
      const count = Math.floor(remaining / weight);
      if (count > 0) {
        result.push({ weight, color, height, count });
        remaining -= count * weight;
      }
    }
    if (remaining > 0.1) return []; // can't make exact weight
    return result;
  });
</script>

{#if plates.length > 0}
  <!-- Desktop: horizontal barbell view -->
  <div class="hidden md:flex items-center gap-0.5 justify-center mt-0.5">
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
  </div>

  <!-- Mobile: plate stack (shown above keyboard when weight input focused) -->
  <div class="flex flex-col items-center mt-0.5 gap-px md:hidden">
    {#each [...plates].reverse() as plate}
      {#each Array(plate.count) as _}
        <div
          style="width: {plate.height}; height: 3px; background: {plate.color}; border-radius: 1px;"
          title="{plate.weight} {isLbs ? 'lbs' : 'kg'}"
        ></div>
      {/each}
    {/each}
  </div>

  <p class="text-[9px] text-zinc-500 text-center">
    {plates.map(p => `${p.count}×${p.weight}`).join(' + ')} /side
  </p>
{/if}
