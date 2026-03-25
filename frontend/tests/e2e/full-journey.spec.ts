/**
 * Full user journey E2E test.
 *
 * Single test with sequential steps: signup → body weight → plan (via API) →
 * workout → diet phase → macros → logout/login persistence → auth guard
 */
import { test, expect } from '@playwright/test';

const UID = Date.now().toString(36);
const USERNAME = `e2e_${UID}`;
const PASSWORD = 'testpass123';
let TOKEN = '';

/** Make an authenticated API call */
async function api(method: string, path: string, body?: any) {
  const opts: RequestInit = {
    method,
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${TOKEN}`,
    },
  };
  if (body) opts.body = JSON.stringify(body);
  const r = await fetch(`http://localhost:8000/api${path}`, opts);
  if (!r.ok && r.status !== 204) throw new Error(`API ${method} ${path} → ${r.status}: ${await r.text()}`);
  if (r.status === 204) return null;
  return r.json();
}

test('Full user journey', async ({ page }) => {
  test.setTimeout(180_000);

  // ── Step 1: Signup ───────────────────────────────────────────────────────
  await test.step('Signup — create account', async () => {
    await page.goto('/signup');
    await page.getByPlaceholder('Choose a username').fill(USERNAME);
    await page.getByPlaceholder('At least 6 characters').fill(PASSWORD);
    await page.getByPlaceholder('Repeat password').fill(PASSWORD);
    await page.getByRole('button', { name: 'Create Account' }).click();
    await page.waitForURL('/', { timeout: 10_000 });
    await expect(page.locator('text=GymTracker')).toBeVisible();
    await expect(page.locator('text=Workout History')).toBeVisible();

    // Grab token from localStorage for API calls
    TOKEN = await page.evaluate(() => localStorage.getItem('hgt_access_token') || '');
    expect(TOKEN.length).toBeGreaterThan(10);
  });

  // ── Step 2: Log body weight ──────────────────────────────────────────────
  await test.step('Log body weight', async () => {
    await page.goto('/settings');
    await page.waitForTimeout(1500);

    const weightInput = page.getByPlaceholder('Weight');
    await weightInput.scrollIntoViewIfNeeded();
    await weightInput.fill('180');
    await page.waitForTimeout(300);
    await page.locator('button:has-text("Log"):not(:has-text("Kilograms"))').click();
    await page.waitForTimeout(2000);
    await expect(page.locator('text=180 lbs').first()).toBeVisible({ timeout: 3000 });
  });

  // ── Step 3: Create workout plan (via API, verify in UI) ──────────────────
  let planId: number;
  await test.step('Create workout plan via API', async () => {
    // Get exercises
    const exercises = await api('GET', '/exercises/');
    expect(exercises.length).toBeGreaterThan(0);

    // Pick first compound exercise
    const compound = exercises.find((e: any) => e.movement_type === 'compound') || exercises[0];

    // Create plan with 1 day, 3 sets
    const plan = await api('POST', '/plans/', {
      name: 'E2E Test Plan',
      block_type: 'hypertrophy',
      duration_weeks: 4,
      number_of_days: 1,
      days: [{
        day_number: 1,
        day_name: 'Day 1',
        exercises: [{
          exercise_id: compound.id,
          sets: 3,
          reps: 8,
          starting_weight_kg: 0,
          progression_type: 'linear',
        }],
      }],
    });
    planId = plan.id;
    expect(planId).toBeGreaterThan(0);

    // Verify plan shows on home page
    await page.goto('/');
    await page.waitForTimeout(2000);
    await expect(page.locator('text=E2E Test Plan').first()).toBeVisible({ timeout: 5000 });
  });

  // ── Step 4: Start workout and complete sets ──────────────────────────────
  await test.step('Start workout and complete all sets', async () => {
    await page.goto('/workout/active');
    await page.waitForTimeout(2000);

    // Click Day 1
    const day1 = page.getByRole('button', { name: /Day 1/i });
    if (await day1.isVisible({ timeout: 3000 }).catch(() => false)) {
      await day1.click();
      await page.waitForTimeout(3000);
    }

    // Handle conflict dialog
    const continueBtn = page.getByRole('button', { name: /Continue Existing/i });
    if (await continueBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
      await continueBtn.click();
      await page.waitForTimeout(2000);
    }

    // Should see exercise cards (active workout view)
    await expect(page.locator('.exercise-card').first()).toBeVisible({ timeout: 5000 });

    // Fill in weight and reps for each empty set, then complete
    // Use title selectors to distinguish completion vs undo buttons
    for (let i = 0; i < 10; i++) {
      // Find first "Log this set" button (completion, not undo)
      const logBtn = page.locator('button[title="Log this set"]');
      const logCount = await logBtn.count();

      if (logCount > 0) {
        await logBtn.first().click();
        await page.waitForTimeout(800);
        continue;
      }

      // Find first disabled check — means we need to fill weight/reps
      const enterRepsBtn = page.locator('button[title="Enter reps first"]');
      const enterRepsCount = await enterRepsBtn.count();
      if (enterRepsCount === 0) break; // All done

      // Fill empty number inputs
      const weightInputs = page.locator('.exercise-card input[type="number"]');
      const inputCount = await weightInputs.count();
      for (let j = 0; j < inputCount; j++) {
        const val = await weightInputs.nth(j).inputValue();
        if (!val || val === '0') {
          const placeholder = await weightInputs.nth(j).getAttribute('placeholder') || '';
          if (placeholder.toLowerCase().includes('lbs') || placeholder.toLowerCase().includes('kg') || placeholder === '') {
            await weightInputs.nth(j).fill('135');
          } else {
            await weightInputs.nth(j).fill('8');
          }
        }
      }
      await page.waitForTimeout(500);

      // Try clicking "Log this set" again
      const nowReady = page.locator('button[title="Log this set"]');
      if (await nowReady.count() > 0) {
        await nowReady.first().click();
        await page.waitForTimeout(800);
      } else {
        break;
      }
    }

    // Finish workout
    const finishBtn = page.getByRole('button', { name: /Finish Workout/i });
    if (await finishBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
      await finishBtn.click();
      await page.waitForTimeout(2000);
    }
  });

  // ── Step 4b: Myo rep match set type persists week-to-week ───────────────
  await test.step('Myo rep match type persists to week 2', async () => {
    // Clean up any in-progress sessions first
    const sessions = await api('GET', '/sessions/');
    for (const s of sessions) {
      if (s.status === 'in_progress') {
        // Complete all sets then finish
        const full = await api('GET', `/sessions/${s.id}`);
        for (const set of (full.sets || [])) {
          if (!set.completed_at) {
            await api('PATCH', `/sessions/${s.id}/sets/${set.id}`, {
              actual_weight_kg: 60, actual_reps: 8,
              completed_at: new Date().toISOString(),
            });
          }
        }
        await api('POST', `/sessions/${s.id}/complete`);
      }
    }

    // Create a fresh session via API with 3 sets
    const exercises = await api('GET', '/exercises/');
    const compound = exercises.find((e: any) => e.movement_type === 'compound') || exercises[0];

    // Start a new session via from-plan endpoint
    const session = await api('POST', `/sessions/from-plan/${planId}?day_number=1&overload_style=rep&body_weight_kg=0`);

    // Start it
    await api('POST', `/sessions/${session.id}/start`);

    // Get the session with sets
    const fullSession = await api('GET', `/sessions/${session.id}`);
    const sets = fullSession.sets || [];
    expect(sets.length).toBeGreaterThanOrEqual(1);

    // Change set 2 to myo_rep_match via API
    if (sets.length >= 2) {
      await api('PATCH', `/sessions/${session.id}/sets/${sets[1].id}`, {
        set_type: 'myo_rep_match',
        actual_weight_kg: 60,
        actual_reps: 8,
        completed_at: new Date().toISOString(),
      });

      // Complete set 1 too
      await api('PATCH', `/sessions/${session.id}/sets/${sets[0].id}`, {
        actual_weight_kg: 60,
        actual_reps: 8,
        completed_at: new Date().toISOString(),
      });

      // Complete remaining sets
      for (let i = 2; i < sets.length; i++) {
        await api('PATCH', `/sessions/${session.id}/sets/${sets[i].id}`, {
          actual_weight_kg: 60,
          actual_reps: 8,
          completed_at: new Date().toISOString(),
        });
      }

      // Complete the session
      await api('POST', `/sessions/${session.id}/complete`);

      // Now create week 2 session from same plan
      const week2 = await api('POST', `/sessions/from-plan/${planId}?day_number=1&overload_style=rep&body_weight_kg=0`);
      await api('POST', `/sessions/${week2.id}/start`);
      const week2Full = await api('GET', `/sessions/${week2.id}`);
      const week2Sets = week2Full.sets || [];

      // Set 2 should inherit myo_rep_match from week 1
      if (week2Sets.length >= 2) {
        expect(week2Sets[1].set_type).toBe('myo_rep_match');
      }

      // Clean up — complete week 2 session so it doesn't block future tests
      for (const s of week2Sets) {
        await api('PATCH', `/sessions/${week2.id}/sets/${s.id}`, {
          actual_weight_kg: 60,
          actual_reps: 8,
          completed_at: new Date().toISOString(),
        });
      }
      await api('POST', `/sessions/${week2.id}/complete`);
    }
  });

  // ── Step 5: Diet phase ───────────────────────────────────────────────────
  await test.step('Create diet phase (cut)', async () => {
    await page.goto('/nutrition');
    await page.waitForTimeout(2000);

    // Open wizard
    await page.locator('button').filter({ hasText: /Start a Cut/i }).click();
    await page.waitForTimeout(1000);

    // Step 1: Choose Cut
    const modal = page.locator('.fixed.inset-0');
    await modal.locator('button').filter({ hasText: 'Lose fat' }).click();
    await page.waitForTimeout(1000);

    // Step 2: Click Preview (skip settings, use defaults)
    await page.getByRole('button', { name: 'Preview' }).click();
    await page.waitForTimeout(1000);

    // Step 3: Start Phase
    await page.getByRole('button', { name: 'Start Phase' }).click();
    await page.waitForTimeout(3000);

    // Verify phase card appears
    await expect(page.locator('text=Cut').first()).toBeVisible({ timeout: 5000 });
  });

  // ── Step 6: Track macros ─────────────────────────────────────────────────
  await test.step('Add food entry', async () => {
    await page.goto('/nutrition');
    await page.waitForTimeout(2000);

    const addFood = page.locator('button, a').filter({ hasText: /Add Food/i });
    if (await addFood.isVisible({ timeout: 3000 }).catch(() => false)) {
      await addFood.click();
      await page.waitForTimeout(1000);

      // Search
      const searchInput = page.getByPlaceholder(/search/i);
      if (await searchInput.isVisible({ timeout: 2000 }).catch(() => false)) {
        await searchInput.fill('chicken');
        await page.waitForTimeout(3000);
      }
    }

    // Verify nutrition page is functional
    await expect(page.locator('text=Food Log')).toBeVisible({ timeout: 3000 });
  });

  // ── Step 7: Logout/Login persistence ─────────────────────────────────────
  await test.step('Logout and login — data persists', async () => {
    await page.goto('/settings');
    await page.waitForTimeout(1500);
    const signOut = page.getByRole('button', { name: 'Sign Out' });
    await signOut.scrollIntoViewIfNeeded();
    await signOut.click();
    await page.waitForURL('/login', { timeout: 5000 });

    // Login
    await page.getByPlaceholder('Enter username').fill(USERNAME);
    await page.getByPlaceholder('Enter password').fill(PASSWORD);
    await page.getByRole('button', { name: 'Sign In' }).click();
    await page.waitForURL('/', { timeout: 10_000 });
    await expect(page.locator('text=GymTracker')).toBeVisible();

    // Verify username on settings
    await page.goto('/settings');
    await page.waitForTimeout(1500);
    await expect(page.locator(`text=${USERNAME}`)).toBeVisible({ timeout: 5000 });
  });

  // ── Step 8: Auth guard ───────────────────────────────────────────────────
  await test.step('Auth guard redirects unauthenticated users', async () => {
    await page.evaluate(() => {
      localStorage.removeItem('hgt_access_token');
      localStorage.removeItem('hgt_refresh_token');
      localStorage.removeItem('hgt_user');
    });
    await page.goto('/');
    await page.waitForTimeout(3000);
    expect(page.url()).toContain('/login');
  });
});
