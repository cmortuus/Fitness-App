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

  let total = $derived(pegWeights.peg1 + pegWeights.peg2 + pegWeights.peg3);
  let unit = $derived(isLbs ? 'lbs' : 'kg');
</script>

{#if total > 0}
  <div class="flex items-end justify-center gap-4 mt-1">
    {#each pegEntries as peg}
      <div class="flex flex-col items-center gap-0.5">
        <!-- Weight value -->
        <span class="text-[9px] text-zinc-300 font-mono">
          {peg.weight > 0 ? peg.weight : '—'}
          {#if peg.delta}
            <span class="{peg.delta.startsWith('+') ? 'text-green-400' : 'text-red-400'}">{peg.delta}</span>
          {/if}
        </span>
        <!-- Plates stacked vertically (bottom-up) -->
        <div class="flex flex-col-reverse items-center gap-0.5">
          {#if peg.plates.length > 0}
            {#each peg.plates as plate}
              {#each Array(plate.count) as _}
                <div
                  style="width: {plate.height}; height: 5px; background: {plate.color}; border-radius: 1px;"
                  title="{plate.weight} {unit}"
                ></div>
              {/each}
            {/each}
          {/if}
        </div>
        <!-- Peg rod (vertical) -->
        <div style="width: 3px; height: 16px; background: #71717a; border-radius: 1px 1px 0 0;"></div>
        <!-- Machine body (base) -->
        <div style="width: 14px; height: 4px; background: #3f3f46; border-radius: 1px;"></div>
        <!-- Peg label -->
        <span class="text-[9px] text-zinc-400 font-mono">{peg.label}</span>
      </div>
    {/each}
  </div>
  <p class="text-[9px] text-zinc-500 text-center mt-0.5">
    {total} {unit} total
  </p>
{/if}
