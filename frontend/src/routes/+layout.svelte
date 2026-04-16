<script lang="ts">
  import '../app.css';
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { activeDietPhase, exercises, latestBodyWeight, workoutPlans, nextWorkoutUrl, settings, isOnline, pendingSyncCount, syncStatus } from '$lib/stores';
  import { getExercises, getLatestBodyWeight, getPlans, getActivePhase, isAuthenticated, getStoredUser, clearAuthTokens } from '$lib/api';
  import type { AuthUser } from '$lib/api';
  import { initLocale } from '$lib/i18n';

  // Desktop shows all tabs including nutrition; mobile hides nutrition
  const desktopNavItems = [
    { path: '/',          label: 'Training',  icon: '🏋️' },
    { path: '/nutrition', label: 'Nutrition', icon: '🍽️' },
    { path: '/settings',  label: 'Settings',  icon: '⚙️' },
  ];
  const mobileNavItems = [
    { path: '/',          label: 'Training',  icon: '🏋️' },
    { path: '/settings',  label: 'Settings',  icon: '⚙️' },
  ];
  // Legacy alias for any code referencing staticNavItems
  const staticNavItems = desktopNavItems;

  let { children } = $props<{ children: import('svelte').Snippet }>();
  let authUser = $state<AuthUser | null>(null);
  let authChecked = $state(false);

  const PUBLIC_PATHS = ['/login', '/signup', '/verify-email', '/forgot-password', '/reset-password'];

  onMount(async () => {
    initLocale(); // load saved language preference
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

      // Ensure branch cookie matches DB preference (survives cache clears)
      if (typeof document !== 'undefined') {
        const wantsDev = $settings.branchPreference === 'dev';
        const hasCookie = document.cookie.includes('gymtracker_branch=dev');
        if (wantsDev && !hasCookie) {
          document.cookie = 'gymtracker_branch=dev; path=/; max-age=31536000; Secure; SameSite=Lax';
        } else if (!wantsDev && hasCookie) {
          document.cookie = 'gymtracker_branch=; path=/; max-age=0; Secure; SameSite=Lax';
        }
      }

      const [exercisesData, plansData, latestBW, phase] = await Promise.all([
        getExercises(),
        getPlans(),
        getLatestBodyWeight().catch(() => null),
        getActivePhase().catch(() => null),
      ]);
      exercises.set(exercisesData);
      workoutPlans.set(plansData);
      if (latestBW) latestBodyWeight.set(latestBW);
      if (phase) activeDietPhase.set(phase);
    } catch (error) {
      console.error('Failed to load initial data:', error);
    }
  });

  // ── Accessibility: larger touch targets ──────────────────────────────
  $effect(() => {
    if (typeof document !== 'undefined') {
      document.body.classList.toggle('large-targets', $settings.largerTouchTargets);
    }
  });

  // ── Theme preference ─────────────────────────────────────────────────
  $effect(() => {
    if (typeof document === 'undefined') return;
    const theme = $settings.themePreference ?? 'dark';
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
    document.body.dataset.theme = theme;

    const themeColor = theme === 'light' ? '#f4f4f5' : '#09090b';
    const meta = document.querySelector('meta[name="theme-color"]');
    meta?.setAttribute('content', themeColor);
  });

  // ── Offline detection + sync ──────────────────────────────────────────
  $effect(() => {
    if (typeof window === 'undefined') return;

    const goOnline = async () => {
      isOnline.set(true);
      // Auto-sync queued requests
      try {
        const { syncPendingRequests, getPendingCount } = await import('$lib/offline');
        const count = await getPendingCount();
        if (count > 0) {
          syncStatus.set('syncing');
          const result = await syncPendingRequests((done, total) => {
            pendingSyncCount.set(total - done);
          });
          pendingSyncCount.set(0);
          syncStatus.set(result.failed > 0 ? 'error' : 'idle');
          if (result.synced > 0) {
            console.info(`Synced ${result.synced} offline requests`);
          }
        }
      } catch (e) {
        console.error('Offline sync failed:', e);
        syncStatus.set('error');
      }
    };

    const goOffline = () => {
      isOnline.set(false);
    };

    window.addEventListener('online', goOnline);
    window.addEventListener('offline', goOffline);

    // Check on mount
    isOnline.set(navigator.onLine);
    if (navigator.onLine) goOnline(); // sync any pending from last session

    return () => {
      window.removeEventListener('online', goOnline);
      window.removeEventListener('offline', goOffline);
    };
  });

  let keyboardOpen = $state(false);

  $effect(() => {
    if (typeof window === 'undefined') return;
    const show = () => { keyboardOpen = true; };
    const hide = () => { keyboardOpen = false; };

    // Focus/blur on inputs — most reliable across all devices
    const onFocusIn = (e: FocusEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') show();
    };
    const onFocusOut = () => {
      setTimeout(hide, 100); // delay to avoid flicker between field switches
    };
    document.addEventListener('focusin', onFocusIn);
    document.addEventListener('focusout', onFocusOut);

    // Also use visualViewport as backup (catches keyboard dismiss without blur)
    let vpCleanup: (() => void) | null = null;
    if (window.visualViewport) {
      const vv = window.visualViewport;
      const check = () => { keyboardOpen = vv.height < window.innerHeight * 0.85; };
      vv.addEventListener('resize', check);
      vpCleanup = () => vv.removeEventListener('resize', check);
    }

    return () => {
      document.removeEventListener('focusin', onFocusIn);
      document.removeEventListener('focusout', onFocusOut);
      vpCleanup?.();
    };
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

  <!-- Skip to main content (screen reader / keyboard nav) -->
  <a href="#main-content"
     class="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-50 focus:bg-primary-600 focus:text-white focus:px-4 focus:py-2 focus:rounded-lg focus:text-sm">
    Skip to main content
  </a>

  <!-- ── Top header bar ────────────────────────────────────────────────── -->
  <header class="shrink-0 sticky top-0 z-30 bg-zinc-950/90 border-b border-white/5"
          style="padding-top: env(safe-area-inset-top);"
  >
    <div class="flex items-center justify-between px-4 h-14">
      <a href="/"
         class="text-lg font-bold gradient-text tracking-tight hover:opacity-90 focus:outline-none focus:ring-2 focus:ring-primary-500/60 rounded-sm"
      >
        Onyx Expenditure
      </a>

      <div class="flex items-center gap-3">
        <!-- Desktop nav links (hidden on mobile) -->
        <nav aria-label="Main navigation" class="hidden md:flex items-center gap-1">
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
  <main id="main-content" class="flex-1 w-full max-w-2xl mx-auto md:max-w-4xl">
    {@render children()}
  </main>

  <!-- ── Offline banner ──────────────────────────────────────────────── -->
  {#if !$isOnline}
    <div role="alert" class="fixed bottom-16 left-0 right-0 z-50 bg-amber-600 text-white text-center text-xs py-1.5 font-medium md:bottom-0">
      📡 Offline — changes will sync when reconnected
      {#if $pendingSyncCount > 0}
        <span class="ml-1 opacity-80">({$pendingSyncCount} pending)</span>
      {/if}
    </div>
  {:else if $syncStatus === 'syncing'}
    <div class="fixed bottom-16 left-0 right-0 z-50 bg-blue-600 text-white text-center text-xs py-1.5 font-medium md:bottom-0">
      🔄 Syncing offline changes... ({$pendingSyncCount} remaining)
    </div>
  {/if}

  <!-- ── Bottom nav (mobile only) — hidden during active workout so it doesn't cover the rest timer ── -->
  <nav aria-label="Mobile navigation" class="bottom-nav md:hidden" class:hidden={keyboardOpen || $page.url.pathname.startsWith('/workout/active')}>
    {#each mobileNavItems as item}
      <a href={item.path} class="bottom-nav-item {isActive(item.path) ? 'active' : ''}">
        <span class="text-xl leading-none">{item.icon}</span>
        <span class="text-[10px] font-medium">{item.label}</span>
      </a>
    {/each}
  </nav>
</div>
{/if}
