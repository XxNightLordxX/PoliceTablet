// src/shared/i18n.tsx · UI text (docs/ARCHITECTURE.md §10).
//
// Text comes from session.locale (CP.Locale.all(), i.e. locales/en.json). Keys are flat and dotted;
// placeholders use {var}:   t('hud.objective_progress', { value: 12, max: 20 })
// An unknown key renders the key itself, so a missing string is visible instead of blank.
//
// The foundation's own part (locales/parts/ui.json) is bundled as a last-resort fallback so the HUD,
// result card and toasts stay readable even before the first session arrives. Session text always wins.

import { createContext, useContext, useMemo, type ReactNode } from 'react';
import uiFallback from '../../../locales/parts/ui.json';

export type Locale = Record<string, string>;
export type Vars = Record<string, string | number | boolean | null | undefined>;

const fallback: Locale = uiFallback as Locale;
let current: Locale = {};

function interpolate(s: string, vars?: Vars): string {
  if (!vars) return s;
  return s.replace(/\{([A-Za-z0-9_]+)\}/g, (whole, name: string) => {
    const v = vars[name];
    return v === undefined || v === null ? whole : String(v);
  });
}

/** Module-level translate: reads the latest locale. Safe in non-component code. */
export function t(key: string, vars?: Vars): string {
  if (!key) return '';
  const s = current[key] ?? fallback[key];
  return interpolate(s === undefined ? key : s, vars);
}

/** True when the key exists in the session locale (or the bundled ui fallback). */
export function hasKey(key: string): boolean {
  return current[key] !== undefined || fallback[key] !== undefined;
}

/** t(key) when the key exists, otherwise t(fallbackKey, vars) (e.g. optional per-id labels). */
export function tOr(key: string, fallbackKey: string, vars?: Vars): string {
  return hasKey(key) ? t(key, vars) : t(fallbackKey, vars);
}

/** Replace the module-level locale (LocaleProvider does this for you). */
export function setLocale(locale: Locale | null | undefined): void {
  current = locale ?? {};
}

const LocaleContext = createContext<Locale>({});

/** Feeds session.locale to t(). Children re-render when the locale object changes. */
export function LocaleProvider({ locale, children }: { locale: Locale | null | undefined; children: ReactNode }) {
  const value = locale ?? {};
  // Set during render so children rendered in this same pass already read the new strings.
  current = value;
  return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
}

/** Hook form of t(); the returned function changes identity when the locale changes. */
export function useT(): (key: string, vars?: Vars) => string {
  const locale = useContext(LocaleContext);
  return useMemo(() => {
    void locale;
    return (key: string, vars?: Vars) => t(key, vars);
  }, [locale]);
}

/** The raw locale map of the current session. */
export function useLocale(): Locale {
  return useContext(LocaleContext);
}
