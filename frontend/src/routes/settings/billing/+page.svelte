<script lang="ts">
  import { onMount } from 'svelte';
  import { authGetMe, createCheckoutSession, createPortalSession, getStoredUser } from '$lib/api';
  import type { AuthUser } from '$lib/api';

  let user = $state<AuthUser | null>(null);
  let loading = $state(true);
  let acting = $state(false);
  let error = $state('');
  let statusParam = $state<string | null>(null);

  onMount(async () => {
    const params = new URLSearchParams(window.location.search);
    statusParam = params.get('status');
    try {
      user = await authGetMe();
      localStorage.setItem('hgt_user', JSON.stringify(user));
    } catch {
      user = getStoredUser();
    } finally {
      loading = false;
    }
  });

  async function openPortal() {
    error = '';
    acting = true;
    try {
      const { url } = await createPortalSession();
      window.location.href = url;
    } catch (e: any) {
      error = e.response?.data?.detail || 'Unable to open billing portal.';
      acting = false;
    }
  }

  async function startCheckout() {
    error = '';
    acting = true;
    try {
      const { url } = await createCheckoutSession();
      window.location.href = url;
    } catch (e: any) {
      error = e.response?.data?.detail || 'Unable to start checkout.';
      acting = false;
    }
  }

  let status = $derived(user?.subscription_status ?? null);
  let trialEnds = $derived(user?.trial_ends_at ? new Date(user.trial_ends_at) : null);
  let periodEnd = $derived(user?.subscription_current_period_end ? new Date(user.subscription_current_period_end) : null);
  let trialDaysLeft = $derived.by(() => {
    if (!trialEnds) return null;
    const ms = trialEnds.getTime() - Date.now();
    return ms > 0 ? Math.ceil(ms / (1000 * 60 * 60 * 24)) : 0;
  });
  let hasAccess = $derived(user?.has_access === true);

  function fmt(d: Date | null) {
    return d ? d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '—';
  }
</script>

<div class="max-w-lg mx-auto p-4 space-y-6">
  <div>
    <a href="/settings" class="text-sm text-zinc-500 hover:text-zinc-300">← Settings</a>
    <h1 class="text-2xl font-bold mt-2">Billing</h1>
  </div>

  {#if statusParam === 'success'}
    <div class="bg-green-500/10 border border-green-500/30 rounded-lg px-3 py-3 text-sm text-green-400">
      🎉 Subscription active. You can manage or cancel anytime.
    </div>
  {:else if statusParam === 'canceled'}
    <div class="bg-amber-500/10 border border-amber-500/30 rounded-lg px-3 py-3 text-sm text-amber-300">
      Checkout canceled.  No charge was made.
    </div>
  {/if}

  {#if loading}
    <p class="text-zinc-400 text-sm">Loading…</p>
  {:else if user}
    <div class="card space-y-3">
      <div class="flex justify-between text-sm">
        <span class="text-zinc-500">Status</span>
        <span class="font-medium capitalize">{status ?? (hasAccess ? 'Trial' : 'No subscription')}</span>
      </div>

      {#if !status && trialEnds}
        <div class="flex justify-between text-sm">
          <span class="text-zinc-500">Trial ends</span>
          <span>{fmt(trialEnds)} ({trialDaysLeft} days)</span>
        </div>
      {/if}

      {#if periodEnd}
        <div class="flex justify-between text-sm">
          <span class="text-zinc-500">Renews</span>
          <span>{fmt(periodEnd)}</span>
        </div>
      {/if}
    </div>

    {#if error}
      <div class="bg-red-500/10 border border-red-500/30 rounded-lg px-3 py-2 text-sm text-red-400">{error}</div>
    {/if}

    {#if user.stripe_customer_id || status}
      <button onclick={openPortal} disabled={acting} class="btn-primary w-full !py-3 disabled:opacity-50">
        {acting ? 'Loading…' : 'Manage subscription'}
      </button>
    {:else}
      <button onclick={startCheckout} disabled={acting} class="btn-primary w-full !py-3 disabled:opacity-50">
        {acting ? 'Loading…' : 'Subscribe — $30/year'}
      </button>
    {/if}

    <p class="text-center text-xs text-zinc-600">
      Hosted billing powered by Stripe · <a href="/pricing" class="hover:text-zinc-400">see pricing</a>
    </p>
  {/if}
</div>
