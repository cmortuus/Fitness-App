<script lang="ts">
  import { onMount } from 'svelte';
  import { authGetMe, createCheckoutSession, getStoredUser } from '$lib/api';
  import type { AuthUser } from '$lib/api';
  import { track } from '$lib/telemetry';

  let user = $state<AuthUser | null>(null);
  let showModal = $state(false);
  let loading = $state(false);
  let dismissed = $state(false);

  onMount(async () => {
    user = getStoredUser();
    // Also listen for the 402 event from the api interceptor
    const handler = async (e: any) => {
      // Refresh user data to get latest trial/subscription state
      try {
        user = await authGetMe();
        localStorage.setItem('hgt_user', JSON.stringify(user));
      } catch { /* ignore */ }
      track('paywall_hit', { detail: e.detail });
      showModal = true;
    };
    window.addEventListener('onyx:subscription-required', handler);
    return () => window.removeEventListener('onyx:subscription-required', handler);
  });

  async function subscribe() {
    loading = true;
    try {
      track('checkout_started', { from: 'banner' });
      const { url } = await createCheckoutSession();
      window.location.href = url;
    } catch {
      window.location.href = '/pricing';
    }
  }

  let trialDaysLeft = $derived.by(() => {
    if (!user?.trial_ends_at) return null;
    const ms = new Date(user.trial_ends_at).getTime() - Date.now();
    return ms > 0 ? Math.ceil(ms / (1000 * 60 * 60 * 24)) : 0;
  });

  let trialExpired = $derived(user?.trial_ends_at ? new Date(user.trial_ends_at).getTime() <= Date.now() : false);
  let hasSubscription = $derived(user?.subscription_status === 'active' || user?.subscription_status === 'trialing');

  // Show trial banner only in the last 7 days; always show expired banner.
  let showTrialBanner = $derived(
    !dismissed &&
    !hasSubscription &&
    trialDaysLeft !== null &&
    trialDaysLeft > 0 &&
    trialDaysLeft <= 7
  );
  let showExpiredBanner = $derived(!hasSubscription && trialExpired);
</script>

{#if showTrialBanner && trialDaysLeft !== null}
  <div class="bg-amber-500/15 border-b border-amber-500/30 text-amber-100 text-sm px-4 py-2 flex items-center justify-between gap-3">
    <span>Trial ends in <strong>{trialDaysLeft} {trialDaysLeft === 1 ? 'day' : 'days'}</strong></span>
    <div class="flex gap-2 items-center">
      <a href="/pricing" class="text-xs underline hover:text-amber-50">Subscribe</a>
      <button onclick={() => (dismissed = true)} class="text-xs opacity-60 hover:opacity-100">✕</button>
    </div>
  </div>
{/if}

{#if showExpiredBanner}
  <div class="bg-red-500/15 border-b border-red-500/30 text-red-100 text-sm px-4 py-2 flex items-center justify-between gap-3">
    <span>Your trial ended — subscribe to keep logging workouts.</span>
    <a href="/pricing" class="text-xs underline font-medium hover:text-red-50">Subscribe</a>
  </div>
{/if}

{#if showModal}
  <div class="fixed inset-0 bg-black/80 flex items-center justify-center z-50 p-4" onclick={() => (showModal = false)}>
    <div class="bg-zinc-900 rounded-2xl border border-white/8 shadow-2xl max-w-sm w-full p-5 space-y-4" onclick={(e) => e.stopPropagation()}>
      <div class="text-center">
        <p class="text-4xl mb-2">🔒</p>
        <h3 class="font-semibold text-lg">Subscription required</h3>
        <p class="text-sm text-zinc-400 mt-1">Your trial has ended. Subscribe for $30/year to keep logging new workouts.  Your history stays available either way.</p>
      </div>
      <button onclick={subscribe} disabled={loading} class="btn-primary w-full !py-3 disabled:opacity-50">
        {loading ? 'Loading…' : 'Subscribe — $30/year'}
      </button>
      <button onclick={() => (showModal = false)} class="btn-secondary w-full">Not now</button>
    </div>
  </div>
{/if}
