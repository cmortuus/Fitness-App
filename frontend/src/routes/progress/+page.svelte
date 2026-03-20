<script lang="ts">
  import { onMount } from 'svelte';
  import { Line } from 'svelte-chartjs';
  import { getProgress, getRecommendations } from '$lib/api';
  import type { ProgressMetric } from '$lib/api';

  // Weight conversion
  const KG_TO_LBS = 2.20462;

  function kgToLbs(kg: number): number {
    return Math.round(kg * KG_TO_LBS * 10) / 10;
  }

  let progressData = $state<ProgressMetric[]>([]);
  let recommendations = $state<any[]>([]);
  let selectedExercise = $state<string>('all');
  let timeRange = $state<string>('30d');

  onMount(async () => {
    await loadData();
  });

  async function loadData() {
    try {
      const endDate = new Date().toISOString().split('T')[0];
      let startDate: string;

      switch (timeRange) {
        case '7d':
          startDate = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString().split('T')[0];
          break;
        case '90d':
          startDate = new Date(Date.now() - 90 * 24 * 60 * 60 * 1000).toISOString().split('T')[0];
          break;
        default:
          startDate = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0];
      }

      progressData = await getProgress({ start_date: startDate, end_date: endDate });
      recommendations = await getRecommendations(parseInt(timeRange.replace('d', '')));
    } catch (error) {
      console.error('Failed to load progress:', error);
    }
  }

  // Filter data by exercise
  let filteredData = $derived(selectedExercise === 'all'
    ? progressData
    : progressData.filter(p => p.exercise_name === selectedExercise));

  // Get unique exercises
  let exercises = $derived([...new Set(progressData.map(p => p.exercise_name))]);

  // Chart data - use type assertion for Chart.js compatibility
  let chartData = $derived({
    labels: [...new Set(filteredData.map(p => p.date))].sort(),
    datasets: exercises.length > 0 ? exercises.map((exercise, idx) => {
      const colors = ['#0ea5e9', '#22c55e', '#f59e0b', '#ef4444', '#8b5cf6'];
      const exerciseData = filteredData.filter(p => p.exercise_name === exercise);
      const dates = [...new Set(filteredData.map(p => p.date))].sort();

      return {
        label: exercise,
        data: dates.map(date => {
          const point = exerciseData.find(p => p.date === date);
          return point?.estimated_1rm ? kgToLbs(point.estimated_1rm) : null;
        }) as (number | null)[],
        borderColor: colors[idx % colors.length],
        backgroundColor: colors[idx % colors.length] + '20',
        tension: 0.1,
      };
    }) : [],
  } as any);

  const chartOptions = {
    responsive: true,
    plugins: {
      legend: {
        position: 'top' as const,
      },
      title: {
        display: true,
        text: 'Estimated 1RM Progress',
      },
    },
    scales: {
      y: {
        beginAtZero: false,
        title: {
          display: true,
          text: 'Weight (lbs)',
        },
      },
      x: {
        title: {
          display: true,
          text: 'Date',
        },
      },
    },
  };
</script>

<div class="space-y-6">
  <h2 class="text-2xl font-bold">Progress</h2>

  <!-- Filters -->
  <div class="card">
    <div class="flex flex-wrap gap-4">
      <div>
        <label class="label">Time Range</label>
        <select bind:value={timeRange} onchange={loadData} class="input">
          <option value="7d">Last 7 days</option>
          <option value="30d">Last 30 days</option>
          <option value="90d">Last 90 days</option>
        </select>
      </div>

      <div>
        <label class="label">Exercise</label>
        <select bind:value={selectedExercise} class="input">
          <option value="all">All Exercises</option>
          {#each exercises as exercise}
            <option value={exercise}>{exercise}</option>
          {/each}
        </select>
      </div>
    </div>
  </div>

  <!-- Progress Chart -->
  <div class="card">
    {#if progressData.length > 0}
      <Line data={chartData} options={chartOptions} />
    {:else}
      <p class="text-gray-400 text-center py-8">No progress data available. Start a workout to track progress.</p>
    {/if}
  </div>

  <!-- Recommendations -->
  {#if recommendations.length > 0}
    <div class="card">
      <h3 class="text-lg font-semibold mb-4">Progression Recommendations</h3>
      <div class="overflow-x-auto">
        <table class="w-full text-left">
          <thead>
            <tr class="border-b border-gray-700">
              <th class="py-2 px-4">Exercise</th>
              <th class="py-2 px-4">Current</th>
              <th class="py-2 px-4">Recommended</th>
              <th class="py-2 px-4">Reason</th>
            </tr>
          </thead>
          <tbody>
            {#each recommendations as rec}
              <tr class="border-b border-gray-700 hover:bg-gray-700">
                <td class="py-2 px-4 font-medium">{rec.exercise_name}</td>
                <td class="py-2 px-4">{kgToLbs(rec.current_weight).toFixed(1)} lbs</td>
                <td class="py-2 px-4">
                  <span class="{rec.recommended_weight > rec.current_weight ? 'text-green-400' : rec.recommended_weight < rec.current_weight ? 'text-red-400' : 'text-yellow-400'}">
                    {kgToLbs(rec.recommended_weight).toFixed(1)} lbs
                  </span>
                </td>
                <td class="py-2 px-4 text-sm text-gray-300">{rec.reason}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    </div>
  {/if}

  <!-- Detailed Stats -->
  <div class="card">
    <h3 class="text-lg font-semibold mb-4">Detailed Statistics</h3>
    {#if filteredData.length > 0}
      <div class="overflow-x-auto">
        <table class="w-full text-left">
          <thead>
            <tr class="border-b border-gray-700">
              <th class="py-2 px-4">Date</th>
              <th class="py-2 px-4">Exercise</th>
              <th class="py-2 px-4">Volume</th>
              <th class="py-2 px-4">Est. 1RM</th>
            </tr>
          </thead>
          <tbody>
            {#each filteredData as row}
              <tr class="border-b border-gray-700 hover:bg-gray-700">
                <td class="py-2 px-4">{row.date}</td>
                <td class="py-2 px-4">{row.exercise_name}</td>
                <td class="py-2 px-4">{kgToLbs(row.volume_load).toFixed(1)} lbs</td>
                <td class="py-2 px-4">{row.estimated_1rm ? kgToLbs(row.estimated_1rm).toFixed(1) : '-'} lbs</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else}
      <p class="text-gray-400 text-center py-4">No data for selected filters.</p>
    {/if}
  </div>
</div>