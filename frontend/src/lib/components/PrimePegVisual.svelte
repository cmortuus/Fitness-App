<script lang="ts">
  /**
   * Prime machine 3-peg plate breakdown — shows 3 horizontal pegs
   * with colored plates on each, and weight labels per peg.
   * Props: pegWeights (per-side kg/lbs), isLbs, prevPegWeights
   */
  interface PegWeights {
    peg1: number;
    peg2: number;
    peg3: number;
  }

  interface Props {
    pegWeights: PegWeights;
    isLbs: boolean;
    prevPegWeights?: PegWeights | null;
  }

  let { pegWeights, isLbs, prevPegWeights = null }: Props = $props();

  const PLATES_LBS: [number, string, string][] = [
    [45, '#3b82f6', '2.4rem'],
    [35, '#eab308', '2.2rem'],
    [25, '#22c55e', '2rem'],
    [10, '#d4d4d8', '1.6rem'],
    [5,  '#d4d4d8', '1.2rem'],
    [2.5,'#d4d4d8', '0.9rem'],
  ];

  const PLATES_KG: [number, string, string][] = [
    [25,   '#ef4444', '2.4rem'],
    [20,   '#3b82f6', '2.4rem'],
    [15,   '#eab308', '2.2rem'],
    [10,   '#22c55e', '2rem'],
    [5,    '#d4d4d8', '1.6rem'],
    [2.5,  '#d4d4d8', '1.2rem'],
    [1.25, '#d4d4d8', '0.9rem'],
  ];

  interface PlateSlice {
    weight: number;
    color: string;
    height: string;
    count: number;
  }

  function calcPlates(weight: number): PlateSlice[] {
    if (weight <= 0) return [];
    const available = isLbs ? PLATES_LBS : PLATES_KG;
    let remaining = weight;
    const result: PlateSlice[] = [];
    for (const [w, color, height] of available) {
      const count = Math.floor(remaining / w);
      if (count > 0) {
        result.push({ weight: w, color, height, count });
        remaining -= count * w;
      }
    }
    if (remaining > 0.1) return [];
    return result;
  }

  function pegDelta(pegKey: 'peg1' | 'peg2' | 'peg3'): string | null {
    if (!prevPegWeights) return null;
    const diff = pegWeights[pegKey] - (prevPegWeights[pegKey] ?? 0);
    if (Math.abs(diff) < 0.1) return null;
    return diff > 0 ? `+${diff}` : `${diff}`;
  }

  const pegEntries = $derived(
    (['peg1', 'peg2', 'peg3'] as const).map((key, i) => ({
      key,
      label: `Peg ${i + 1}`,
      weight: pegWeights[key],
      plates: calcPlates(pegWeights[key]),
      delta: pegDelta(key),
    }))
  );

  let totalPerSide = $derived(pegWeights.peg1 + pegWeights.peg2 + pegWeights.peg3);
  let unit = $derived(isLbs ? 'lbs' : 'kg');
</script>

{#if totalPerSide > 0}
  <div class="flex flex-col gap-1 mt-1">
    {#each pegEntries as peg}
      <div class="flex items-center gap-1">
        <!-- Peg label -->
        <span class="text-[9px] text-zinc-400 w-8 text-right font-mono">{peg.label}</span>
        <!-- Machine body (mount point) -->
        <div style="width: 6px; height: {peg.plates.length > 0 ? '12px' : '4px'}; background: #3f3f46; border-radius: 1px;"></div>
        <!-- Peg rod -->
        <div style="width: 16px; height: 3px; background: #71717a; border-radius: 0 1px 1px 0;"></div>
        <!-- Plates on this peg -->
        {#if peg.plates.length > 0}
          {#each peg.plates as plate}
            {#each Array(plate.count) as _}
              <div
                style="width: 5px; height: {plate.height}; background: {plate.color}; border-radius: 1px;"
                title="{plate.weight} {unit}"
              ></div>
            {/each}
          {/each}
        {:else if peg.weight > 0}
          <!-- weight doesn't break into exact plates -->
          <span class="text-[8px] text-zinc-500 italic">~</span>
        {/if}
        <!-- Weight value -->
        <span class="text-[9px] text-zinc-300 ml-1 font-mono">
          {peg.weight > 0 ? peg.weight : '—'}
          {#if peg.delta}
            <span class="{peg.delta.startsWith('+') ? 'text-green-400' : 'text-red-400'}">{peg.delta}</span>
          {/if}
        </span>
      </div>
    {/each}
    <!-- Total per side -->
    <p class="text-[9px] text-zinc-500 text-center mt-0.5">
      {totalPerSide} {unit}/side · {totalPerSide * 2} {unit} total
    </p>
  </div>
{/if}
