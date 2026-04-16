/**
 * Telemetry — Sentry + PostHog wrappers.
 *
 * Both are optional: if the corresponding PUBLIC_* env var isn't set at
 * build time, the init is a no-op and all track/capture calls become
 * silent. Safe to call from any component.
 */
import { browser } from '$app/environment';
import { PUBLIC_SENTRY_DSN, PUBLIC_POSTHOG_KEY, PUBLIC_POSTHOG_HOST } from '$env/static/public';

let _posthog: any = null;
let _sentryReady = false;

// ── Sentry ────────────────────────────────────────────────────────────
export async function initSentry() {
  if (!browser || !PUBLIC_SENTRY_DSN || _sentryReady) return;
  try {
    const Sentry = await import('@sentry/sveltekit');
    Sentry.init({
      dsn: PUBLIC_SENTRY_DSN,
      tracesSampleRate: 0.1,
      replaysSessionSampleRate: 0,
      replaysOnErrorSampleRate: 1.0,
    });
    _sentryReady = true;
  } catch (err) {
    console.warn('Sentry init failed:', err);
  }
}

// ── PostHog ───────────────────────────────────────────────────────────
export async function initPostHog() {
  if (!browser || !PUBLIC_POSTHOG_KEY || _posthog) return;
  try {
    const { default: posthog } = await import('posthog-js');
    posthog.init(PUBLIC_POSTHOG_KEY, {
      api_host: PUBLIC_POSTHOG_HOST || 'https://us.i.posthog.com',
      capture_pageview: true,
      capture_pageleave: true,
      persistence: 'localStorage+cookie',
      // Respect DNT / privacy opt-out — users can toggle in Settings later
      opt_out_capturing_by_default: hasOptedOut(),
    });
    _posthog = posthog;
  } catch (err) {
    console.warn('PostHog init failed:', err);
  }
}

function hasOptedOut(): boolean {
  if (!browser) return true;
  // Honor Do Not Track
  // @ts-ignore
  if (navigator.doNotTrack === '1' || window.doNotTrack === '1') return true;
  // User-set preference
  try {
    return localStorage.getItem('onyx_analytics_opt_out') === '1';
  } catch {
    return false;
  }
}

export function setAnalyticsOptOut(optedOut: boolean) {
  if (!browser) return;
  try {
    if (optedOut) {
      localStorage.setItem('onyx_analytics_opt_out', '1');
      _posthog?.opt_out_capturing();
    } else {
      localStorage.removeItem('onyx_analytics_opt_out');
      _posthog?.opt_in_capturing();
    }
  } catch {
    /* ignore storage failures */
  }
}

// ── Events ────────────────────────────────────────────────────────────
export function track(event: string, properties?: Record<string, unknown>) {
  if (!_posthog) return;
  try {
    _posthog.capture(event, properties);
  } catch {
    /* ignore */
  }
}

export function identify(userId: number | string, properties?: Record<string, unknown>) {
  if (!_posthog) return;
  try {
    _posthog.identify(String(userId), properties);
  } catch {
    /* ignore */
  }
}

export function resetAnalyticsIdentity() {
  if (!_posthog) return;
  try {
    _posthog.reset();
  } catch {
    /* ignore */
  }
}
