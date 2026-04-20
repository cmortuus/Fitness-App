<script lang="ts">
  import { onMount } from 'svelte';
  import { isAuthenticated } from '$lib/api';
  import { track } from '$lib/telemetry';

  onMount(() => {
    // Send authed visitors straight to the app
    if (isAuthenticated()) {
      window.location.href = '/';
      return;
    }
    track('landing_viewed');
  });
</script>

<svelte:head>
  <title>Onyx — the home-gym tracker that just works</title>
  <meta name="description" content="Log workouts, track progression, plan your next lift.  $30/year, 30-day free trial, MIT-licensed code.">
  <meta property="og:title" content="Onyx">
  <meta property="og:description" content="The home-gym tracker that just works.  $30/year.  30-day free trial.">
  <meta property="og:type" content="website">
</svelte:head>

<div class="min-h-screen bg-zinc-950 text-zinc-100">
  <!-- Header -->
  <header class="border-b border-white/5">
    <div class="max-w-5xl mx-auto px-4 h-14 flex items-center justify-between">
      <a href="/welcome" class="text-xl font-bold text-primary-400">Onyx</a>
      <nav class="flex items-center gap-4 text-sm">
        <a href="/pricing" class="text-zinc-400 hover:text-zinc-100">Pricing</a>
        <a href="/login" class="text-zinc-400 hover:text-zinc-100">Sign in</a>
        <a href="/signup" class="btn-primary !py-2 !px-3 !text-sm">Start free trial</a>
      </nav>
    </div>
  </header>

  <!-- Hero -->
  <section class="max-w-3xl mx-auto px-4 py-20 text-center">
    <h1 class="text-4xl sm:text-5xl font-bold tracking-tight">
      The home-gym tracker<br>that just works.
    </h1>
    <p class="text-zinc-400 text-lg mt-5 max-w-xl mx-auto">
      Log workouts, track progression, and lift heavier with a plan that actually progresses.
      No ads, no bloat, no AI coach.
    </p>
    <div class="mt-8 flex items-center justify-center gap-3 flex-wrap">
      <a href="/signup" class="btn-primary !py-3 !px-5 text-base">Start 30-day free trial</a>
      <a href="/pricing" class="btn-secondary !py-3 !px-5 text-base">See pricing</a>
    </div>
    <p class="text-xs text-zinc-600 mt-6">No credit card required to start. $30/year after trial.</p>
  </section>

  <!-- Features -->
  <section class="max-w-4xl mx-auto px-4 py-12 grid sm:grid-cols-2 gap-6">
    <div class="card">
      <p class="text-2xl">📈</p>
      <h3 class="font-semibold mt-2">Progressive overload that works</h3>
      <p class="text-sm text-zinc-400 mt-2">
        Epley-based weight progression, RIR targets, fatigue adjustment when you reorder your day.
        The math is done for you.
      </p>
    </div>
    <div class="card">
      <p class="text-2xl">🏋️</p>
      <h3 class="font-semibold mt-2">Free-flow when you're just lifting</h3>
      <p class="text-sm text-zinc-400 mt-2">
        Not every workout needs a program.  Skip the plan and just log what you did — sets,
        weight, reps — fast.
      </p>
    </div>
    <div class="card">
      <p class="text-2xl">🍽️</p>
      <h3 class="font-semibold mt-2">Nutrition, if you want it</h3>
      <p class="text-sm text-zinc-400 mt-2">
        Macros, phases, weekly check-ins.  Optional — ignore it entirely if food tracking
        isn't your thing.
      </p>
    </div>
    <div class="card">
      <p class="text-2xl">📤</p>
      <h3 class="font-semibold mt-2">Your data stays yours</h3>
      <p class="text-sm text-zinc-400 mt-2">
        Export your full history to CSV or JSON anytime.  Delete your account and everything
        goes with it.  The app is open source (MIT) — you can self-host for free.
      </p>
    </div>
  </section>

  <!-- Pricing tease -->
  <section class="max-w-2xl mx-auto px-4 py-12 text-center">
    <div class="card">
      <p class="text-5xl font-bold">$30<span class="text-lg text-zinc-500">/year</span></p>
      <p class="text-xs text-zinc-500 mt-1">about $2.50 a month</p>
      <p class="text-sm text-zinc-400 mt-4">One price.  Everything included.  30 days free to try.</p>
      <a href="/signup" class="btn-primary w-full !py-3 mt-5">Start free trial</a>
    </div>
  </section>

  <!-- Footer -->
  <footer class="border-t border-white/5 mt-12">
    <div class="max-w-5xl mx-auto px-4 py-8 text-sm text-zinc-500 flex flex-wrap items-center justify-between gap-3">
      <p>© 2026 Onyx · MIT licensed</p>
      <nav class="flex gap-4">
        <a href="/pricing" class="hover:text-zinc-300">Pricing</a>
        <a href="/about" class="hover:text-zinc-300">About</a>
        <a href="/terms" class="hover:text-zinc-300">Terms</a>
        <a href="/privacy" class="hover:text-zinc-300">Privacy</a>
        <a href="https://github.com/cmortuus/Fitness-App" class="hover:text-zinc-300">GitHub</a>
      </nav>
    </div>
  </footer>
</div>
