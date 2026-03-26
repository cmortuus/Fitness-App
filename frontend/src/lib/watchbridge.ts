/**
 * Watch Bridge — sends workout state to Apple Watch via Capacitor native plugin.
 * No-op on web/PWA. Only active when running inside the iOS Capacitor shell.
 */

import { Capacitor, registerPlugin } from '@capacitor/core';

interface WatchBridgePlugin {
  sendWorkoutState(options: { state: string }): Promise<void>;
  sendWorkoutEnded(): Promise<void>;
}

const WatchBridge = registerPlugin<WatchBridgePlugin>('WatchBridge');

/** Check if we're running in native iOS */
function isNative(): boolean {
  return Capacitor.isNativePlatform();
}

/**
 * Send current workout state to the Watch.
 * Call this whenever the workout UI state changes (set completed, rest timer tick, etc.)
 */
export async function sendWorkoutStateToWatch(state: {
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
}): Promise<void> {
  if (!isNative()) return;
  try {
    await WatchBridge.sendWorkoutState({ state: JSON.stringify(state) });
  } catch (e) {
    // Silently fail — Watch may not be connected
  }
}

/** Notify Watch that workout has ended */
export async function sendWorkoutEndedToWatch(): Promise<void> {
  if (!isNative()) return;
  try {
    await WatchBridge.sendWorkoutEnded();
  } catch {
    // Silently fail
  }
}

/**
 * Listen for Watch actions (set complete, skip rest).
 * The native plugin dispatches CustomEvents on window.
 * Returns a cleanup function to remove listeners.
 */
export function listenForWatchActions(handlers: {
  onSetAction?: (exerciseId: number, setLocalId: string, action: 'complete' | 'skip') => void;
  onSkipRest?: () => void;
}): () => void {
  if (!isNative()) return () => {};

  const handleSetAction = (e: Event) => {
    const detail = (e as CustomEvent).detail;
    handlers.onSetAction?.(detail.exerciseId, detail.setLocalId, detail.action);
  };

  const handleSkipRest = () => {
    handlers.onSkipRest?.();
  };

  window.addEventListener('watchSetAction', handleSetAction);
  window.addEventListener('watchSkipRest', handleSkipRest);

  return () => {
    window.removeEventListener('watchSetAction', handleSetAction);
    window.removeEventListener('watchSkipRest', handleSkipRest);
  };
}
