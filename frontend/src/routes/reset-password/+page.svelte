<script lang="ts">
  import { onMount } from 'svelte';
  import { resetPassword } from '$lib/api';

  let token = $state('');
  let password = $state('');
  let confirmPassword = $state('');
  let loading = $state(false);
  let done = $state(false);
  let error = $state('');

  onMount(() => {
    const params = new URLSearchParams(window.location.search);
    token = params.get('token') || '';
    if (!token) error = 'No reset token in this link.';
  });

  async function handleSubmit() {
    error = '';
    if (password !== confirmPassword) {
      error = 'Passwords do not match.';
      return;
    }
    if (password.length < 6) {
      error = 'Password must be at least 6 characters.';
      return;
    }
    loading = true;
    try {
      await resetPassword(token, password);
      done = true;
    } catch (e: any) {
      error = e.response?.data?.detail || 'Reset failed — the link may be expired.';
    }
    loading = false;
  }
</script>

<div class="min-h-screen flex items-center justify-center p-4">
  <div class="w-full max-w-sm space-y-6">
    <div class="text-center">
      <h1 class="text-2xl font-bold text-primary-400">Onyx</h1>
      <p class="text-sm text-zinc-500 mt-1">Choose a new password</p>
    </div>

    {#if done}
      <div class="card text-center space-y-3">
        <p class="text-4xl">✅</p>
        <p>Password updated</p>
        <a href="/login" class="btn-primary block mt-4">Sign in</a>
      </div>
    {:else}
      <form onsubmit={(e) => { e.preventDefault(); handleSubmit(); }} class="card space-y-4">
        {#if error}
          <div class="bg-red-500/10 border border-red-500/30 rounded-lg px-3 py-2 text-sm text-red-400">{error}</div>
        {/if}
        <div>
          <label for="rp-password" class="text-xs text-zinc-400 block mb-1">New password</label>
          <input id="rp-password" type="password" bind:value={password} required autocomplete="new-password"
                 minlength="6" class="input" placeholder="At least 6 characters" />
        </div>
        <div>
          <label for="rp-confirm" class="text-xs text-zinc-400 block mb-1">Confirm password</label>
          <input id="rp-confirm" type="password" bind:value={confirmPassword} required autocomplete="new-password"
                 class="input" placeholder="Repeat password" />
        </div>
        <button type="submit" disabled={loading || !token || !password || password.length < 6 || password !== confirmPassword}
                class="btn-primary w-full !py-3 disabled:opacity-50">
          {loading ? 'Saving…' : 'Reset password'}
        </button>
      </form>
    {/if}
  </div>
</div>
