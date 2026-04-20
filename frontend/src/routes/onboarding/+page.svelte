<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { settings } from '$lib/stores';
  import { track } from '$lib/telemetry';

  type Experience = 'beginner' | 'experienced';
  type StartType = 'plan' | 'free_flow';

  let step = $state(1);
  let units = $state<'lbs' | 'kg'>('lbs');
  let experience = $state<Experience>('experienced');
  let startType = $state<StartType>('free_flow');
  let saving = $state(false);

  onMount(() => {
    track('onboarding_started');
    // Pre-fill from current settings if the user somehow revisits
    units = $settings.weightUnit ?? 'lbs';
  });

  function next() {
    if (step < 3) {
      step += 1;
    }
  }

  function back() {
    if (step > 1) step -= 1;
  }

  function markOnboardingComplete(meta: Record<string, unknown>) {
    try {
      localStorage.setItem(
        'onyx_onboarding',
        JSON.stringify({ completed: true, completedAt: new Date().toISOString(), ...meta }),
      );
    } catch { /* storage unavailable — non-fatal */ }
  }

  async function finish() {
    saving = true;
    try {
      track('onboarding_completed', { units, experience, startType });
      settings.update((s) => ({ ...s, weightUnit: units }));
      markOnboardingComplete({ experience, startType });
    } catch (e) {
      console.warn('Failed to persist onboarding answers', e);
    }
    if (startType === 'plan') {
      await goto('/plans/templates');
    } else {
      await goto('/workout/active?free_flow=1');
    }
  }

  async function skip() {
    track('onboarding_skipped', { step });
    markOnboardingComplete({ skipped: true });
    await goto('/');
  }
</script>

<div class="min-h-screen flex items-center justify-center p-4">
  <div class="w-full max-w-sm space-y-6">
    <div class="text-center">
      <h1 class="text-2xl font-bold text-primary-400">Welcome to Onyx</h1>
      <p class="text-sm text-zinc-500 mt-1">Three quick questions — under 30 seconds.</p>
    </div>

    <!-- Progress dots -->
    <div class="flex justify-center gap-1.5">
      {#each [1, 2, 3] as n}
        <div class="h-1.5 w-6 rounded-full transition-colors {n <= step ? 'bg-primary-500' : 'bg-zinc-800'}"></div>
      {/each}
    </div>

    <div class="card space-y-5">
      {#if step === 1}
        <div>
          <p class="text-sm font-medium mb-3">Weight units</p>
          <div class="grid grid-cols-2 gap-2">
            <button onclick={() => (units = 'lbs')}
                    class="py-3 rounded-lg text-sm font-medium transition-colors {units === 'lbs' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}">
              Pounds (lbs)
            </button>
            <button onclick={() => (units = 'kg')}
                    class="py-3 rounded-lg text-sm font-medium transition-colors {units === 'kg' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}">
              Kilograms (kg)
            </button>
          </div>
        </div>
      {:else if step === 2}
        <div>
          <p class="text-sm font-medium mb-3">How would you describe yourself?</p>
          <div class="space-y-2">
            <button onclick={() => (experience = 'beginner')}
                    class="w-full text-left px-4 py-3 rounded-lg text-sm transition-colors {experience === 'beginner' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}">
              <p class="font-medium">Beginner</p>
              <p class="text-xs opacity-80 mt-0.5">Less than a year of consistent training</p>
            </button>
            <button onclick={() => (experience = 'experienced')}
                    class="w-full text-left px-4 py-3 rounded-lg text-sm transition-colors {experience === 'experienced' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}">
              <p class="font-medium">Experienced</p>
              <p class="text-xs opacity-80 mt-0.5">Comfortable with programming, RIR, progressive overload</p>
            </button>
          </div>
        </div>
      {:else}
        <div>
          <p class="text-sm font-medium mb-3">How do you want to start?</p>
          <div class="space-y-2">
            <button onclick={() => (startType = 'plan')}
                    class="w-full text-left px-4 py-3 rounded-lg text-sm transition-colors {startType === 'plan' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}">
              <p class="font-medium">📋 Pick a plan template</p>
              <p class="text-xs opacity-80 mt-0.5">Follow a structured program with progressive overload</p>
            </button>
            <button onclick={() => (startType = 'free_flow')}
                    class="w-full text-left px-4 py-3 rounded-lg text-sm transition-colors {startType === 'free_flow' ? 'bg-primary-600 text-white' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}">
              <p class="font-medium">🏋️ Just log today's workout</p>
              <p class="text-xs opacity-80 mt-0.5">Free-flow mode — no plan, no suggestions, just log</p>
            </button>
          </div>
        </div>
      {/if}
    </div>

    <div class="flex gap-2">
      {#if step > 1}
        <button onclick={back} class="btn-secondary flex-1">← Back</button>
      {/if}
      {#if step < 3}
        <button onclick={next} class="btn-primary flex-1">Next →</button>
      {:else}
        <button onclick={finish} disabled={saving} class="btn-primary flex-1 disabled:opacity-50">
          {saving ? 'Saving…' : "Let's go"}
        </button>
      {/if}
    </div>

    <p class="text-center">
      <button onclick={skip} class="text-xs text-zinc-500 hover:text-zinc-300">Skip for now</button>
    </p>
  </div>
</div>
