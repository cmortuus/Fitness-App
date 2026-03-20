<script lang="ts">
  import '../app.css';
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { currentSession, exercises, latestBodyWeight, workoutPlans } from '$lib/stores';
  import { getExercises, getLatestBodyWeight, getPlans } from '$lib/api';

  const navItems = [
    { path: '/', label: 'Dashboard', icon: '📊' },
    { path: '/workout/active', label: 'Workout', icon: '🏋️' },
    { path: '/plans', label: 'Plans', icon: '📋' },
    { path: '/progress', label: 'Progress', icon: '📈' },
    { path: '/settings', label: 'Settings', icon: '⚙️' },
  ];

  let { children } = $props<{ children: import('svelte').Snippet }>();

  onMount(async () => {
    try {
      const [exercisesData, plansData, latestBW] = await Promise.all([
        getExercises(),
        getPlans(),
        getLatestBodyWeight(),
      ]);
      exercises.set(exercisesData);
      workoutPlans.set(plansData);
      latestBodyWeight.set(latestBW);
    } catch (error) {
      console.error('Failed to load initial data:', error);
    }
  });
</script>

<!-- Full-height flex column so the content row can fill remaining space -->
<div class="h-screen flex flex-col bg-gray-900">
  <!-- Header -->
  <header class="shrink-0 bg-gray-800 border-b border-gray-700">
    <div class="max-w-7xl mx-auto px-4 py-4 flex items-center justify-between">
      <h1 class="text-xl font-bold text-primary-400">Home Gym Tracker</h1>
      <div class="flex items-center gap-4">
        {#if $currentSession}
          <a
            href="/workout/active"
            class="text-sm text-primary-400 hover:text-primary-300 font-medium animate-pulse"
          >
            ● Active workout
          </a>
        {/if}
      </div>
    </div>
  </header>

  <!-- Sidebar + main — fills all remaining height, no overflow at this level -->
  <div class="flex flex-1 overflow-hidden">
    <!-- Sidebar nav -->
    <nav class="w-56 bg-gray-800 shrink-0 overflow-y-auto p-4">
      <ul class="space-y-1">
        {#each navItems as item}
          <li>
            <a
              href={item.path}
              class="flex items-center gap-3 px-3 py-2 rounded-lg transition-colors {
                $page.url.pathname === item.path || ($page.url.pathname.startsWith(item.path) && item.path !== '/')
                  ? 'bg-primary-600 text-white'
                  : 'hover:bg-gray-700 text-gray-300'
              }"
            >
              <span>{item.icon}</span>
              <span class="text-sm">{item.label}</span>
            </a>
          </li>
        {/each}
      </ul>
    </nav>

    <!-- Main content — scrolls normally for regular pages, flex-col for workout -->
    <main class="flex-1 min-w-0 overflow-y-auto flex flex-col">
      {@render children()}
    </main>
  </div>
</div>
