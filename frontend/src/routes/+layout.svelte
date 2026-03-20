<script lang="ts">
  import '../app.css';
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { currentSession, exercises, latestBodyWeight, workoutPlans } from '$lib/stores';
  import { getExercises, getLatestBodyWeight, getPlans } from '$lib/api';

  const navItems = [
    { path: '/',              label: 'Home',    icon: '🏠' },
    { path: '/workout/active', label: 'Workout', icon: '🏋️' },
    { path: '/plans',         label: 'Plans',   icon: '📋' },
    { path: '/progress',      label: 'Progress', icon: '📈' },
    { path: '/settings',      label: 'Settings', icon: '⚙️' },
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

  function isActive(path: string) {
    if (path === '/') return $page.url.pathname === '/';
    return $page.url.pathname.startsWith(path);
  }
</script>

<!-- ── Full-height shell ──────────────────────────────────────────────── -->
<div class="min-h-screen flex flex-col bg-zinc-950">

  <!-- ── Top header bar ────────────────────────────────────────────────── -->
  <header class="shrink-0 sticky top-0 z-30 bg-zinc-950/90 border-b border-white/5"
          style="padding-top: env(safe-area-inset-top);"
  >
    <div class="flex items-center justify-between px-4 h-14">
      <span class="text-lg font-bold gradient-text tracking-tight">GymTracker</span>

      <div class="flex items-center gap-3">
        {#if $currentSession}
          <a href="/workout/active"
             class="flex items-center gap-1.5 text-xs font-semibold text-primary-400
                    bg-primary-500/10 border border-primary-500/30 rounded-full px-3 py-1.5
                    animate-pulse hover:bg-primary-500/20 transition-colors">
            <span class="w-1.5 h-1.5 rounded-full bg-primary-400"></span>
            Active
          </a>
        {/if}

        <!-- Desktop nav links (hidden on mobile) -->
        <nav class="hidden md:flex items-center gap-1">
          {#each navItems as item}
            <a href={item.path}
               class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm transition-colors
                      {isActive(item.path)
                        ? 'bg-primary-600/20 text-primary-400 font-semibold'
                        : 'text-zinc-400 hover:text-zinc-200 hover:bg-zinc-800'}">
              <span class="text-base leading-none">{item.icon}</span>
              <span>{item.label}</span>
            </a>
          {/each}
        </nav>
      </div>
    </div>
  </header>

  <!-- ── Main content ────────────────────────────────────────────────────── -->
  <main class="flex-1 w-full max-w-2xl mx-auto md:max-w-4xl">
    {@render children()}
  </main>

  <!-- ── Bottom nav (mobile only) ──────────────────────────────────────── -->
  <nav class="bottom-nav md:hidden">
    {#each navItems as item}
      <a href={item.path}
         class="bottom-nav-item {isActive(item.path) ? 'active' : ''}">
        <span class="text-xl leading-none">{item.icon}</span>
        <span class="text-[10px] font-medium">{item.label}</span>
      </a>
    {/each}
  </nav>
</div>
