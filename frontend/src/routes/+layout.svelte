<script lang="ts">
  import '../app.css';
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { activeDietPhase, exercises, latestBodyWeight, workoutPlans, nextWorkoutUrl, settings } from '$lib/stores';
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
      // Load settings from DB first (syncs across devices)
      await settings.loadFromDb();

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

  let keyboardOpen = $state(false);

  $effect(() => {
    if (typeof window === 'undefined') return;
    const show = () => { keyboardOpen = true; };
    const hide = () => { keyboardOpen = false; };
    // Detect keyboard via visualViewport resize (reliable on iOS)
    if (window.visualViewport) {
      const vv = window.visualViewport;
      const check = () => { keyboardOpen = vv.height < window.innerHeight * 0.75; };
      vv.addEventListener('resize', check);
      return () => vv.removeEventListener('resize', check);
    }
    // Fallback: focus/blur on inputs
    document.addEventListener('focusin', (e) => {
      if ((e.target as HTMLElement)?.tagName === 'INPUT' || (e.target as HTMLElement)?.tagName === 'TEXTAREA') show();
    });
    document.addEventListener('focusout', hide);
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
  <nav class="bottom-nav md:hidden" class:hidden={keyboardOpen}>
    {#each staticNavItems as item}
      <a href={item.path} class="bottom-nav-item {isActive(item.path) ? 'active' : ''}">
        <span class="text-xl leading-none">{item.icon}</span>
        <span class="text-[10px] font-medium">{item.label}</span>
      </a>
    {/each}
  </nav>
</div>
{/if}
