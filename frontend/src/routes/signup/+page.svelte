<script lang="ts">
  import { authRegister, saveAuthTokens, isAuthenticated } from '$lib/api';
  import { onMount } from 'svelte';

  let username = $state('');
  let password = $state('');
  let confirmPassword = $state('');
  let error = $state('');
  let loading = $state(false);

  onMount(() => {
    if (isAuthenticated()) window.location.href = '/';
  });

  async function handleSignup() {
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
      const auth = await authRegister({ username, password });
      saveAuthTokens(auth);
      window.location.href = '/';
    } catch (e: any) {
      error = e.response?.data?.detail || 'Registration failed. Please try again.';
    }
    loading = false;
  }
</script>

<div class="min-h-screen flex items-center justify-center p-4">
  <div class="w-full max-w-sm space-y-6">
    <div class="text-center">
      <h1 class="text-2xl font-bold text-primary-400">Onyx Expenditure</h1>
      <p class="text-sm text-zinc-500 mt-1">Create your account</p>
    </div>

    <form onsubmit={(e) => { e.preventDefault(); handleSignup(); }} class="card space-y-4">
      {#if error}
        <div class="bg-red-500/10 border border-red-500/30 rounded-lg px-3 py-2 text-sm text-red-400">{error}</div>
      {/if}

      <div>
        <label for="signup-username" class="text-xs text-zinc-400 block mb-1">Username</label>
        <input id="signup-username" type="text" bind:value={username} required autocomplete="username"
               class="input" placeholder="Choose a username" />
      </div>

      <div>
        <label for="signup-password" class="text-xs text-zinc-400 block mb-1">Password</label>
        <input id="signup-password" type="password" bind:value={password} required autocomplete="new-password"
               minlength="6"
               class="input" placeholder="At least 6 characters" />
      </div>

      <div>
        <label for="signup-confirm" class="text-xs text-zinc-400 block mb-1">Confirm Password</label>
        <input id="signup-confirm" type="password" bind:value={confirmPassword} required autocomplete="new-password"
               class="input" placeholder="Repeat password" />
      </div>

      {#if password && password.length < 6}
        <p class="text-xs text-amber-400">Password must be at least 6 characters ({6 - password.length} more needed)</p>
      {/if}
      {#if password && confirmPassword && password !== confirmPassword}
        <p class="text-xs text-red-400">Passwords do not match</p>
      {/if}

      <button type="submit" disabled={loading || !username || !password || password.length < 6 || !confirmPassword || password !== confirmPassword}
              class="btn-primary w-full !py-3 disabled:opacity-50">
        {loading ? 'Creating account...' : 'Create Account'}
      </button>

      <p class="text-center text-sm text-zinc-500">
        Already have an account? <a href="/login" class="text-primary-400 hover:text-primary-300">Sign in</a>
      </p>
    </form>
  </div>
</div>
