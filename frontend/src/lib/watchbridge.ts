/**
 * Watch Bridge stubs.
 *
 * The native SwiftUI app communicates with Apple Watch directly.
 * These no-op exports keep existing imports working on web/PWA.
 */

export async function sendWorkoutStateToWatch(_state: {
  sessionId: number;
  workoutName: string;
  exercises: Array<{
    id: number;
    name: string;
    sets: Array<{
      id: string;
      setNumber: number;
      weight: number | null;
      reps: number | null;
      done: boolean;
      skipped: boolean;
      unit: string;
    }>;
  }>;
  currentExerciseIndex: number;
  currentSetIndex: number;
  elapsed: number;
  restActive: boolean;
  restSecs: number;
}): Promise<void> {}

export async function sendWorkoutEndedToWatch(): Promise<void> {}

export function listenForWatchActions(_handlers: {
  onSetAction?: (exerciseId: number, setLocalId: string, action: 'complete' | 'skip') => void;
  onSkipRest?: () => void;
}): () => void {
  return () => {};
}
