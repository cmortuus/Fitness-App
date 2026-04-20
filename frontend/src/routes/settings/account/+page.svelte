<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    authGetMe, changeEmail, changePassword, deleteAccount, exportUserData,
    getStoredUser, clearAuthTokens,
  } from '$lib/api';
  import type { AuthUser } from '$lib/api';
  import { track } from '$lib/telemetry';

  let user = $state<AuthUser | null>(null);

  // Change email
  let emailCurrentPw = $state('');
  let newEmail = $state('');
  let emailSaving = $state(false);
  let emailError = $state('');
  let emailSuccess = $state('');

  // Change password
  let currentPw = $state('');
  let newPw = $state('');
  let confirmPw = $state('');
  let pwSaving = $state(false);
  let pwError = $state('');
  let pwSuccess = $state('');

  // Delete account
  let deleteConfirm = $state('');
  let deleting = $state(false);
  let deleteError = $state('');

  // Export
  let exporting = $state(false);

  onMount(async () => {
    try {
      user = await authGetMe();
      localStorage.setItem('hgt_user', JSON.stringify(user));
    } catch {
      user = getStoredUser();
    }
  });

  async function handleChangeEmail() {
    emailError = '';
    emailSuccess = '';
    emailSaving = true;
    try {
      await changeEmail(emailCurrentPw, newEmail);
      emailSuccess = 'Email updated. Check your inbox to verify.';
      if (user) user.email = newEmail;
      emailCurrentPw = '';
      newEmail = '';
    } catch (e: any) {
      emailError = e.response?.data?.detail || 'Unable to change email.';
    }
    emailSaving = false;
  }

  async function handleChangePassword() {
    pwError = '';
    pwSuccess = '';
    if (newPw !== confirmPw) {
      pwError = 'Passwords do not match.';
      return;
    }
    if (newPw.length < 6) {
      pwError = 'New password must be at least 6 characters.';
      return;
    }
    pwSaving = true;
    try {
      await changePassword(currentPw, newPw);
      pwSuccess = 'Password updated.';
      currentPw = '';
      newPw = '';
      confirmPw = '';
    } catch (e: any) {
      pwError = e.response?.data?.detail || 'Unable to change password.';
    }
    pwSaving = false;
  }

  async function handleExport() {
    exporting = true;
    try {
      track('data_exported');
      const data = await exportUserData();
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      const date = new Date().toISOString().split('T')[0];
      a.href = url;
      a.download = `onyx-export-${date}.json`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (e) {
      console.error('Export failed:', e);
      alert('Export failed. Try again or email support@lethal.dev.');
    }
    exporting = false;
  }

  async function handleDelete() {
    deleteError = '';
    if (deleteConfirm !== 'DELETE') {
      deleteError = 'Type DELETE to confirm.';
      return;
    }
    deleting = true;
    try {
      track('account_deleted');
      await deleteAccount();
      clearAuthTokens();
      window.location.href = '/welcome?deleted=1';
    } catch (e: any) {
      deleteError = e.response?.data?.detail || 'Unable to delete account.';
      deleting = false;
    }
  }
</script>

<div class="max-w-lg mx-auto p-4 space-y-6">
  <div>
    <a href="/settings" class="text-sm text-zinc-500 hover:text-zinc-300">← Settings</a>
    <h1 class="text-2xl font-bold mt-2">Account</h1>
    {#if user}
      <p class="text-sm text-zinc-400 mt-1">{user.username} · {user.email}</p>
    {/if}
  </div>

  <!-- ── Change email ──────────────────────────────────────────── -->
  <div class="card space-y-3">
    <h2 class="font-semibold">Change email</h2>
    <form onsubmit={(e) => { e.preventDefault(); handleChangeEmail(); }} class="space-y-3">
      <input type="password" bind:value={emailCurrentPw} required placeholder="Current password"
             autocomplete="current-password" class="input" />
      <input type="email" bind:value={newEmail} required placeholder="New email"
             autocomplete="email" class="input" />
      {#if emailError}
        <p class="text-xs text-red-400">{emailError}</p>
      {/if}
      {#if emailSuccess}
        <p class="text-xs text-green-400">{emailSuccess}</p>
      {/if}
      <button type="submit" disabled={emailSaving || !emailCurrentPw || !newEmail}
              class="btn-primary w-full disabled:opacity-50">
        {emailSaving ? 'Saving…' : 'Update email'}
      </button>
    </form>
  </div>

  <!-- ── Change password ───────────────────────────────────────── -->
  <div class="card space-y-3">
    <h2 class="font-semibold">Change password</h2>
    <form onsubmit={(e) => { e.preventDefault(); handleChangePassword(); }} class="space-y-3">
      <input type="password" bind:value={currentPw} required placeholder="Current password"
             autocomplete="current-password" class="input" />
      <input type="password" bind:value={newPw} required minlength="6" placeholder="New password (6+ chars)"
             autocomplete="new-password" class="input" />
      <input type="password" bind:value={confirmPw} required placeholder="Confirm new password"
             autocomplete="new-password" class="input" />
      {#if pwError}
        <p class="text-xs text-red-400">{pwError}</p>
      {/if}
      {#if pwSuccess}
        <p class="text-xs text-green-400">{pwSuccess}</p>
      {/if}
      <button type="submit" disabled={pwSaving || !currentPw || !newPw}
              class="btn-primary w-full disabled:opacity-50">
        {pwSaving ? 'Saving…' : 'Update password'}
      </button>
    </form>
  </div>

  <!-- ── Export ────────────────────────────────────────────────── -->
  <div class="card space-y-3">
    <h2 class="font-semibold">Export your data</h2>
    <p class="text-xs text-zinc-500">Downloads a JSON file with every workout, plan, nutrition entry, and body-weight log on your account.</p>
    <button onclick={handleExport} disabled={exporting}
            class="btn-secondary w-full disabled:opacity-50">
      {exporting ? 'Preparing…' : 'Download JSON'}
    </button>
  </div>

  <!-- ── Delete account ────────────────────────────────────────── -->
  <div class="card space-y-3 border border-red-500/30">
    <h2 class="font-semibold text-red-400">Delete account</h2>
    <p class="text-xs text-zinc-400">
      This permanently removes your account, cancels any active subscription,
      and wipes all your workout data.  This can't be undone.
    </p>
    <input type="text" bind:value={deleteConfirm} placeholder='Type "DELETE" to confirm'
           class="input" />
    {#if deleteError}
      <p class="text-xs text-red-400">{deleteError}</p>
    {/if}
    <button onclick={handleDelete} disabled={deleting || deleteConfirm !== 'DELETE'}
            class="w-full py-3 rounded-lg text-sm font-medium bg-red-500/10 text-red-400 border border-red-500/30 hover:bg-red-500/20 disabled:opacity-50">
      {deleting ? 'Deleting…' : 'Delete my account'}
    </button>
  </div>
</div>
