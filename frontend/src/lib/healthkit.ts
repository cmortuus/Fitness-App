/**
 * HealthKit integration stubs.
 *
 * The native SwiftUI app handles HealthKit directly.
 * These no-op exports keep existing imports working on web/PWA.
 */

export async function isHealthKitAvailable(): Promise<boolean> {
  return false;
}

export async function requestHealthKitPermissions(): Promise<boolean> {
  return false;
}

export async function writeWorkout(_params: {
  startDate: Date;
  endDate: Date;
  totalCalories?: number;
  totalDistance?: number;
  workoutName?: string;
}): Promise<boolean> {
  return false;
}

export async function writeBodyWeight(_weightKg: number, _date?: Date): Promise<boolean> {
  return false;
}

export async function writeNutrition(_params: {
  calories: number;
  proteinG?: number;
  carbsG?: number;
  fatG?: number;
  date?: Date;
}): Promise<boolean> {
  return false;
}

export async function readBodyWeights(_daysBack: number = 30): Promise<Array<{ date: string; kg: number }>> {
  return [];
}
