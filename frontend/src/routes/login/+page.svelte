<script lang="ts">
  import { authLogin, saveAuthTokens, isAuthenticated } from '$lib/api';
  import { onMount } from 'svelte';
  import { track, identify } from '$lib/telemetry';

  let username = $state('');
  let password = $state('');
  let error = $state('');
  let loading = $state(false);

  onMount(() => {
    if (isAuthenticated()) window.location.href = '/';
  });

  async function handleLogin() {
    error = '';
    loading = true;
    try {
      const auth = await authLogin({ username, password });
      saveAuthTokens(auth);
      if (auth?.user?.id) identify(auth.user.id, { username: auth.user.username });
      track('login');
      window.location.href = '/';
    } catch (e: any) {
      error = e.response?.data?.detail || 'Login failed. Please try again.';
    }
    loading = false;
  }
</script>

<div class="min-h-screen flex items-center justify-center p-4">
  <div class="w-full max-w-sm space-y-6">
    <div class="text-center">
      <h1 class="text-2xl font-bold text-primary-400">Onyx Expenditure</h1>
      <p class="text-sm text-zinc-500 mt-1">Sign in to your account</p>
    </div>

    <form onsubmit={(e) => { e.preventDefault(); handleLogin(); }} class="card space-y-4">
      {#if error}
        <div class="bg-red-500/10 border border-red-500/30 rounded-lg px-3 py-2 text-sm text-red-400">{error}</div>
      {/if}

      <div>
        <label for="login-username" class="text-xs text-zinc-400 block mb-1">Username</label>
        <input id="login-username" type="text" bind:value={username} required autocomplete="username"
               class="input" placeholder="Enter username" />
      </div>

      <div>
        <label for="login-password" class="text-xs text-zinc-400 block mb-1">Password</label>
        <input id="login-password" type="password" bind:value={password} required autocomplete="current-password"
               class="input" placeholder="Enter password" />
      </div>

      <button type="submit" disabled={loading || !username || !password}
              class="btn-primary w-full !py-3 disabled:opacity-50">
        {loading ? 'Signing in...' : 'Sign In'}
      </button>

      <p class="text-center text-sm text-zinc-500">
        Don't have an account? <a href="/signup" class="text-primary-400 hover:text-primary-300">Sign up</a>
      </p>
    </form>
  </div>
</div>
