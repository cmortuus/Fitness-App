<script lang="ts">
  import { requestPasswordReset } from '$lib/api';

  let email = $state('');
  let submitted = $state(false);
  let loading = $state(false);
  let error = $state('');

  async function handleSubmit() {
    error = '';
    loading = true;
    try {
      await requestPasswordReset(email);
      submitted = true;
    } catch (e: any) {
      error = e.response?.data?.detail || 'Something went wrong. Try again.';
    }
    loading = false;
  }
</script>

<div class="min-h-screen flex items-center justify-center p-4">
  <div class="w-full max-w-sm space-y-6">
    <div class="text-center">
      <h1 class="text-2xl font-bold text-primary-400">Onyx</h1>
      <p class="text-sm text-zinc-500 mt-1">Reset your password</p>
    </div>

    {#if submitted}
      <div class="card text-center space-y-3">
        <p class="text-4xl">📬</p>
        <p class="text-sm text-zinc-300">
          If an account exists for <strong>{email}</strong>, a reset link has been sent.
        </p>
        <p class="text-xs text-zinc-500">The link expires in 1 hour.</p>
        <a href="/login" class="btn-secondary block mt-4">Back to login</a>
      </div>
    {:else}
      <form onsubmit={(e) => { e.preventDefault(); handleSubmit(); }} class="card space-y-4">
        {#if error}
          <div class="bg-red-500/10 border border-red-500/30 rounded-lg px-3 py-2 text-sm text-red-400">{error}</div>
        {/if}
        <div>
          <label for="fp-email" class="text-xs text-zinc-400 block mb-1">Email</label>
          <input id="fp-email" type="email" bind:value={email} required autocomplete="email"
                 class="input" placeholder="you@example.com" />
        </div>
        <button type="submit" disabled={loading || !email} class="btn-primary w-full !py-3 disabled:opacity-50">
          {loading ? 'Sending…' : 'Send reset link'}
        </button>
        <p class="text-center text-sm text-zinc-500">
          <a href="/login" class="text-primary-400 hover:text-primary-300">Back to login</a>
        </p>
      </form>
    {/if}
  </div>
</div>
