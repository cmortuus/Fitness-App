<script lang="ts">
  import { onMount } from 'svelte';
  import { verifyEmail } from '$lib/api';

  let status = $state<'pending' | 'success' | 'error'>('pending');
  let error = $state('');

  onMount(async () => {
    const params = new URLSearchParams(window.location.search);
    const token = params.get('token');
    if (!token) {
      status = 'error';
      error = 'No verification token in this link.';
      return;
    }
    try {
      await verifyEmail(token);
      status = 'success';
    } catch (e: any) {
      status = 'error';
      error = e.response?.data?.detail || 'Verification failed. The link may be expired.';
    }
  });
</script>

<div class="min-h-screen flex items-center justify-center p-4">
  <div class="w-full max-w-sm space-y-6 text-center">
    <h1 class="text-2xl font-bold text-primary-400">Onyx</h1>

    {#if status === 'pending'}
      <p class="text-zinc-400">Verifying your email…</p>
    {:else if status === 'success'}
      <div class="card space-y-4">
        <p class="text-4xl">✅</p>
        <p class="font-medium">Email verified</p>
        <a href="/" class="btn-primary block">Continue to app</a>
      </div>
    {:else}
      <div class="card space-y-4">
        <p class="text-4xl">⚠️</p>
        <p class="text-sm text-red-400">{error}</p>
        <a href="/login" class="btn-secondary block">Back to login</a>
      </div>
    {/if}
  </div>
</div>
