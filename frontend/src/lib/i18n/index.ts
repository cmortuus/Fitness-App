/**
 * Lightweight i18n system — JSON translation files + reactive store.
 *
 * Usage:
 *   import { t, locale, setLocale } from '$lib/i18n';
 *   t('nav.training')  → "Training" (en) or "Entrenamiento" (es)
 *
 * Adding a language:
 *   1. Create a new JSON file in this folder (e.g. fr.json)
 *   2. Add the locale code to SUPPORTED_LOCALES
 *   3. Add the dynamic import to loadTranslations()
 */

import { writable, derived, get } from 'svelte/store';

export const SUPPORTED_LOCALES = ['en', 'es', 'de', 'fr', 'pt', 'ja', 'ko', 'zh'] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];

export const LOCALE_NAMES: Record<Locale, string> = {
  en: 'English',
  es: 'Espa\u00f1ol',
  de: 'Deutsch',
  fr: 'Fran\u00e7ais',
  pt: 'Portugu\u00eas',
  ja: '\u65e5\u672c\u8a9e',
  ko: '\ud55c\uad6d\uc5b4',
  zh: '\u4e2d\u6587',
};

// Current locale
export const locale = writable<Locale>('en');

// Translation dictionaries — loaded lazily
const translations = writable<Record<string, Record<string, string>>>({ en: {} });

/** Load translations for a locale (lazy import) */
async function loadTranslations(loc: Locale): Promise<Record<string, string>> {
  const current = get(translations);
  if (current[loc] && Object.keys(current[loc]).length > 0) return current[loc];

  try {
    let mod: { default: Record<string, string> };
    switch (loc) {
      case 'en': mod = await import('./en.json'); break;
      case 'es': mod = await import('./es.json'); break;
      case 'de': mod = await import('./de.json'); break;
      case 'fr': mod = await import('./fr.json'); break;
      case 'pt': mod = await import('./pt.json'); break;
      case 'ja': mod = await import('./ja.json'); break;
      case 'ko': mod = await import('./ko.json'); break;
      case 'zh': mod = await import('./zh.json'); break;
      default: mod = await import('./en.json'); break;
    }
    translations.update(t => ({ ...t, [loc]: flatten(mod.default) }));
    return flatten(mod.default);
  } catch {
    console.warn(`[i18n] Failed to load locale: ${loc}`);
    return {};
  }
}

/** Flatten nested JSON: { nav: { home: "X" } } → { "nav.home": "X" } */
function flatten(obj: any, prefix = ''): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, val] of Object.entries(obj)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (typeof val === 'object' && val !== null && !Array.isArray(val)) {
      Object.assign(result, flatten(val, path));
    } else {
      result[path] = String(val);
    }
  }
  return result;
}

/** Set locale and load its translations */
export async function setLocale(loc: Locale) {
  await loadTranslations(loc);
  locale.set(loc);
  if (typeof localStorage !== 'undefined') {
    localStorage.setItem('hgt_locale', loc);
  }
}

/** Initialize — load saved locale or detect from browser */
export async function initLocale() {
  let saved: string | null = null;
  if (typeof localStorage !== 'undefined') {
    saved = localStorage.getItem('hgt_locale');
  }
  const detected = saved || (typeof navigator !== 'undefined' ? navigator.language.split('-')[0] : 'en');
  const loc = SUPPORTED_LOCALES.includes(detected as Locale) ? (detected as Locale) : 'en';
  await loadTranslations('en'); // always load English as fallback
  if (loc !== 'en') await loadTranslations(loc);
  locale.set(loc);
}

/**
 * Translation function — returns translated string for the current locale.
 * Falls back to English, then to the key itself.
 *
 * Supports simple interpolation: t('greeting', { name: 'John' }) → "Hello, John"
 */
export const t = derived([locale, translations], ([$locale, $translations]) => {
  return (key: string, params?: Record<string, string | number>): string => {
    let str = $translations[$locale]?.[key] ?? $translations['en']?.[key] ?? key;
    if (params) {
      for (const [k, v] of Object.entries(params)) {
        str = str.replace(new RegExp(`\\{${k}\\}`, 'g'), String(v));
      }
    }
    return str;
  };
});
