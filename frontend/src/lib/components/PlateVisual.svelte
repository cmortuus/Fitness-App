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

  const PLATES_LBS: [number, string, string][] = [
    [45, '#3b82f6', '2rem'],    // blue, tallest
    [35, '#eab308', '1.75rem'], // yellow
    [25, '#22c55e', '1.5rem'],  // green
    [10, '#a1a1aa', '1.15rem'], // zinc/gray
    [5,  '#ef4444', '0.9rem'],  // red, small
    [2.5,'#71717a', '0.7rem'],  // dark gray, smallest
  ];

  const PLATES_KG: [number, string, string][] = [
    [20,   '#3b82f6', '2rem'],
    [15,   '#eab308', '1.75rem'],
    [10,   '#22c55e', '1.5rem'],
    [5,    '#a1a1aa', '1.15rem'],
    [2.5,  '#ef4444', '0.9rem'],
    [1.25, '#71717a', '0.7rem'],
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
  <div class="flex items-center gap-0.5 justify-center mt-0.5">
    <!-- Plates (per side) -->
    {#each plates as plate}
      {#each Array(plate.count) as _}
        <div
          style="width: 6px; height: {plate.height}; background: {plate.color}; border-radius: 1px;"
          title="{plate.weight} {isLbs ? 'lbs' : 'kg'}"
        ></div>
      {/each}
    {/each}
    <!-- Bar -->
    <div style="width: 18px; height: 5px; background: #52525b; border-radius: 1px;"></div>
    <!-- Plates (mirrored) -->
    {#each [...plates].reverse() as plate}
      {#each Array(plate.count) as _}
        <div
          style="width: 6px; height: {plate.height}; background: {plate.color}; border-radius: 1px;"
          title="{plate.weight} {isLbs ? 'lbs' : 'kg'}"
        ></div>
      {/each}
    {/each}
  </div>
  <p class="text-[9px] text-zinc-500 text-center">
    {plates.map(p => `${p.count}×${p.weight}`).join(' + ')} /side
  </p>
{/if}
