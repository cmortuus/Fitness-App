<script lang="ts">
  import '../app.css';
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { activeDietPhase, currentSession, exercises, latestBodyWeight, workoutPlans, nextWorkoutUrl } from '$lib/stores';
  import { getExercises, getLatestBodyWeight, getPlans, getActivePhase, isAuthenticated, getStoredUser, clearAuthTokens } from '$lib/api';
  import type { AuthUser } from '$lib/api';

  const staticNavItems = [
    { path: '/',          label: 'Home',      icon: '🏠' },
    { path: '/nutrition', label: 'Nutrition', icon: '🍽️' },
    { path: '/settings',  label: 'Settings',  icon: '⚙️' },
  ];

  let { children } = $props<{ children: import('svelte').Snippet }>();
  let authUser = $state<AuthUser | null>(null);
  let authChecked = $state(false);

  const PUBLIC_PATHS = ['/login', '/signup'];

  onMount(async () => {
    // Auth check
    const path = window.location.pathname;
    if (PUBLIC_PATHS.some(p => path.startsWith(p))) {
      authChecked = true;
      return; // Don't load data on auth pages
    }
    if (!isAuthenticated()) {
      window.location.href = '/login';
      return;
    }
    authUser = getStoredUser();
    authChecked = true;

    try {
      const [exercisesData, plansData, latestBW, phase] = await Promise.all([
        getExercises(),
        getPlans(),
        getLatestBodyWeight(),
        getActivePhase(),
      ]);
      exercises.set(exercisesData);
      workoutPlans.set(plansData);
      latestBodyWeight.set(latestBW);
      activeDietPhase.set(phase);
    } catch (error) {
      console.error('Failed to load initial data:', error);
    }
  });

  function logout() {
    clearAuthTokens();
    window.location.href = '/login';
  }

  function isActive(path: string) {
    if (path === '/') return $page.url.pathname === '/';
    return $page.url.pathname.startsWith(path);
  }
</script>

{#if !authChecked}
  <div class="min-h-screen flex items-center justify-center bg-zinc-950">
    <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-500"></div>
  </div>
{:else if PUBLIC_PATHS.some(p => $page.url.pathname.startsWith(p))}
  <!-- Auth pages — no nav shell -->
  <div class="min-h-screen bg-zinc-950">
    {@render children()}
  </div>
{:else}
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
          {#each staticNavItems as item}
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
    {#each staticNavItems as item}
      <a href={item.path} class="bottom-nav-item {isActive(item.path) ? 'active' : ''}">
        <span class="text-xl leading-none">{item.icon}</span>
        <span class="text-[10px] font-medium">{item.label}</span>
      </a>
    {/each}
  </nav>
</div>
{/if}
