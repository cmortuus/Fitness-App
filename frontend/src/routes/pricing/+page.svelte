<script lang="ts">
  import { onMount } from 'svelte';
  import { createCheckoutSession, isAuthenticated, getStoredUser } from '$lib/api';
  import { track } from '$lib/telemetry';

  let starting = $state(false);
  let error = $state('');
  let user = $state(getStoredUser());

  onMount(() => {
    track('pricing_viewed');
  });

  async function startSubscription() {
    error = '';
    if (!isAuthenticated()) {
      window.location.href = '/signup?redirect=/pricing';
      return;
    }
    starting = true;
    try {
      track('checkout_started', { price: 'yearly' });
      const { url } = await createCheckoutSession();
      window.location.href = url;
    } catch (e: any) {
      error = e.response?.data?.detail || 'Unable to start checkout. Try again in a moment.';
      starting = false;
    }
  }

  let trialDaysLeft = $derived.by(() => {
    if (!user?.trial_ends_at) return null;
    const ms = new Date(user.trial_ends_at).getTime() - Date.now();
    return ms > 0 ? Math.ceil(ms / (1000 * 60 * 60 * 24)) : 0;
  });

  let alreadySubscribed = $derived(user?.subscription_status === 'active' || user?.subscription_status === 'trialing');
</script>

<div class="min-h-screen flex items-center justify-center p-4">
  <div class="w-full max-w-lg">
    <div class="text-center mb-8">
      <h1 class="text-3xl font-bold text-primary-400">Onyx</h1>
      <p class="text-zinc-400 mt-2">The home-gym tracker that just works.</p>
    </div>

    <div class="card space-y-6">
      <div class="text-center">
        <p class="text-5xl font-bold">$30<span class="text-lg text-zinc-500">/year</span></p>
        <p class="text-xs text-zinc-500 mt-1">about $2.50 a month</p>
      </div>

      <ul class="space-y-2 text-sm">
        <li class="flex gap-2"><span class="text-primary-400">✓</span> Progressive-overload engine with RIR & fatigue modeling</li>
        <li class="flex gap-2"><span class="text-primary-400">✓</span> Free-flow logging for unplanned sessions</li>
        <li class="flex gap-2"><span class="text-primary-400">✓</span> Nutrition + body-weight tracking</li>
        <li class="flex gap-2"><span class="text-primary-400">✓</span> Full data export, anytime</li>
        <li class="flex gap-2"><span class="text-primary-400">✓</span> 30-day free trial — no credit card to start</li>
      </ul>

      {#if error}
        <div class="bg-red-500/10 border border-red-500/30 rounded-lg px-3 py-2 text-sm text-red-400">{error}</div>
      {/if}

      {#if alreadySubscribed}
        <a href="/settings/billing" class="btn-secondary w-full text-center">You're subscribed · Manage</a>
      {:else if trialDaysLeft !== null && trialDaysLeft > 0}
        <button onclick={startSubscription} disabled={starting} class="btn-primary w-full !py-3 disabled:opacity-50">
          {starting ? 'Loading…' : `Subscribe now (${trialDaysLeft} trial days left)`}
        </button>
      {:else}
        <button onclick={startSubscription} disabled={starting} class="btn-primary w-full !py-3 disabled:opacity-50">
          {starting ? 'Loading…' : isAuthenticated() ? 'Subscribe — $30/year' : 'Start your 30-day free trial'}
        </button>
      {/if}

      <p class="text-center text-xs text-zinc-500">
        <a href="/" class="hover:text-zinc-300">Back to app</a>
      </p>
    </div>

    <p class="text-center text-xs text-zinc-600 mt-6">
      Self-host for free from <a href="https://github.com/cmortuus/Fitness-App" class="underline">GitHub</a> — the code is MIT-licensed.
    </p>
  </div>
</div>
