<script lang="ts">
  import { authRegister, saveAuthTokens, isAuthenticated } from '$lib/api';
  import { onMount } from 'svelte';

  let username = $state('');
  let email = $state('');
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
      const auth = await authRegister({ username, email, password });
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
      <h1 class="text-2xl font-bold text-primary-400">GymTracker</h1>
      <p class="text-sm text-zinc-500 mt-1">Create your account</p>
    </div>

    <form onsubmit={(e) => { e.preventDefault(); handleSignup(); }} class="card space-y-4">
      {#if error}
        <div class="bg-red-500/10 border border-red-500/30 rounded-lg px-3 py-2 text-sm text-red-400">{error}</div>
      {/if}

      <div>
        <label class="text-xs text-zinc-400 block mb-1">Username</label>
        <input type="text" bind:value={username} required autocomplete="username"
               minlength="3" maxlength="50"
               class="input" placeholder="Choose a username" />
      </div>

      <div>
        <label class="text-xs text-zinc-400 block mb-1">Email</label>
        <input type="email" bind:value={email} required autocomplete="email"
               class="input" placeholder="you@example.com" />
      </div>

      <div>
        <label class="text-xs text-zinc-400 block mb-1">Password</label>
        <input type="password" bind:value={password} required autocomplete="new-password"
               minlength="6"
               class="input" placeholder="At least 6 characters" />
      </div>

      <div>
        <label class="text-xs text-zinc-400 block mb-1">Confirm Password</label>
        <input type="password" bind:value={confirmPassword} required autocomplete="new-password"
               class="input" placeholder="Repeat password" />
      </div>

      <button type="submit" disabled={loading || !username || !email || !password || !confirmPassword}
              class="btn-primary w-full !py-3 disabled:opacity-50">
        {loading ? 'Creating account...' : 'Create Account'}
      </button>

      <p class="text-center text-sm text-zinc-500">
        Already have an account? <a href="/login" class="text-primary-400 hover:text-primary-300">Sign in</a>
      </p>
    </form>
  </div>
</div>
