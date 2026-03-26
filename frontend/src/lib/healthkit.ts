/**
 * HealthKit integration via @capgo/capacitor-health
 *
 * Only active on iOS (Capacitor native). On web, all functions are no-ops.
 * The app remains a PWA for non-iOS users — this module adds native
 * features when running inside the Capacitor iOS shell.
 */

import { Capacitor } from '@capacitor/core';

// Lazy-load the plugin only on native
let CapHealth: any = null;

async function getPlugin() {
  if (CapHealth) return CapHealth;
  if (!Capacitor.isNativePlatform()) return null;
  try {
    const mod = await import('@capgo/capacitor-health');
    CapHealth = mod.CapacitorHealth;
    return CapHealth;
  } catch {
    console.warn('[HealthKit] Plugin not available');
    return null;
  }
}

/** Check if HealthKit is available (iOS only) */
export async function isHealthKitAvailable(): Promise<boolean> {
  const plugin = await getPlugin();
  if (!plugin) return false;
  try {
    const result = await plugin.isAvailable();
    return result.available === true;
  } catch {
    return false;
  }
}

/** Request HealthKit permissions for all data types we use */
export async function requestHealthKitPermissions(): Promise<boolean> {
  const plugin = await getPlugin();
  if (!plugin) return false;
  try {
    await plugin.requestAuthorization({
      read: ['weight', 'height', 'steps', 'calories'],
      write: ['weight', 'workout', 'calories'],
    });
    return true;
  } catch (e) {
    console.error('[HealthKit] Permission request failed:', e);
    return false;
  }
}

/**
 * Write a completed workout to HealthKit
 * Called after doFinish() in the workout page
 */
export async function writeWorkout(params: {
  startDate: Date;
  endDate: Date;
  totalCalories?: number;
  totalDistance?: number;
  workoutName?: string;
}): Promise<boolean> {
  const plugin = await getPlugin();
  if (!plugin) return false;
  try {
    await plugin.store({
      startDate: params.startDate.toISOString(),
      endDate: params.endDate.toISOString(),
      dataType: 'workout',
      value: params.totalCalories ?? 0,
      unit: 'kcal',
      sourceBundleId: 'dev.lethal.gymtracker',
    });
    return true;
  } catch (e) {
    console.error('[HealthKit] Failed to write workout:', e);
    return false;
  }
}

/**
 * Write a body weight entry to HealthKit
 * Called when saving body weight in settings or body weight page
 */
export async function writeBodyWeight(weightKg: number, date?: Date): Promise<boolean> {
  const plugin = await getPlugin();
  if (!plugin) return false;
  try {
    await plugin.store({
      startDate: (date ?? new Date()).toISOString(),
      endDate: (date ?? new Date()).toISOString(),
      dataType: 'weight',
      value: weightKg,
      unit: 'kg',
      sourceBundleId: 'dev.lethal.gymtracker',
    });
    return true;
  } catch (e) {
    console.error('[HealthKit] Failed to write body weight:', e);
    return false;
  }
}

/**
 * Write nutrition data (calories, protein, carbs, fat) to HealthKit
 * Called when food entries are saved
 */
export async function writeNutrition(params: {
  calories: number;
  proteinG?: number;
  carbsG?: number;
  fatG?: number;
  date?: Date;
}): Promise<boolean> {
  const plugin = await getPlugin();
  if (!plugin) return false;
  try {
    const d = (params.date ?? new Date()).toISOString();
    // Write total calories
    await plugin.store({
      startDate: d,
      endDate: d,
      dataType: 'calories',
      value: params.calories,
      unit: 'kcal',
      sourceBundleId: 'dev.lethal.gymtracker',
    });
    return true;
  } catch (e) {
    console.error('[HealthKit] Failed to write nutrition:', e);
    return false;
  }
}

/**
 * Read recent body weight entries from HealthKit
 * Can be used to import weights the user logged elsewhere
 */
export async function readBodyWeights(daysBack: number = 30): Promise<Array<{ date: string; kg: number }>> {
  const plugin = await getPlugin();
  if (!plugin) return [];
  try {
    const start = new Date(Date.now() - daysBack * 24 * 60 * 60 * 1000);
    const result = await plugin.query({
      startDate: start.toISOString(),
      endDate: new Date().toISOString(),
      dataType: 'weight',
      limit: 100,
    });
    return (result.data ?? []).map((entry: any) => ({
      date: entry.startDate,
      kg: entry.value,
    }));
  } catch (e) {
    console.error('[HealthKit] Failed to read body weights:', e);
    return [];
  }
}
