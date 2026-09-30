// Department theming (SPEC "Departments & tablet theming").

import type { Theme } from './types';

export const DEFAULT_THEME: Theme = {
    primary: '#a4161a',
    accent: '#e5383b',
    background: '#0b090a',
    surface: '#161a1d',
    text: '#f5f3f4',
};

type RGB = [number, number, number];

const HEX6 = /^#[0-9a-fA-F]{6}$/;

export function isHexColour(v: unknown): v is string {
    return typeof v === 'string' && HEX6.test(v);
}

export function hexToRgb(hex: string): RGB {
    const n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export function rgbToHex([r, g, b]: RGB): string {
    const c = (x: number) =>
        Math.max(0, Math.min(255, Math.round(x)))
            .toString(16)
            .padStart(2, '0');
    return `#${c(r)}${c(g)}${c(b)}`;
}

// Linear mix: t = 0 gives a, t = 1 gives b.
export function mix(a: string, b: string, t: number): string {
    const x = hexToRgb(a);
    const y = hexToRgb(b);
    return rgbToHex([x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t]);
}

// WCAG relative luminance.
export function luminance(hex: string): number {
    const ch = hexToRgb(hex).map(v => {
        const s = v / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}

export function contrastRatio(a: string, b: string): number {
    const la = luminance(a);
    const lb = luminance(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

const WHITE = '#ffffff';
const DARK = '#111111';

// Same rule as CP.U.contrastText: white or near-black, whichever contrasts more.
export function contrastText(bg: string): string {
    if (!isHexColour(bg)) return WHITE;
    return contrastRatio(bg, WHITE) >= contrastRatio(bg, DARK) ? WHITE : DARK;
}

// Text for a filled control: prefers white while it stays readable (≥ 3.5:1).
function onFill(fill: string): string {
    const w = contrastRatio(fill, WHITE);
    return w >= 3.5 || w >= contrastRatio(fill, DARK) ? WHITE : DARK;
}

// Lighten (towards white) or darken until `fg` reaches `min` contrast on `bg`.
function legibleOn(fg: string, bg: string, min: number): string {
    if (contrastRatio(fg, bg) >= min) return fg;
    const target = luminance(bg) < 0.4 ? WHITE : '#000000';
    for (let i = 1; i <= 10; i++) {
        const c = mix(fg, target, i * 0.1);
        if (contrastRatio(c, bg) >= min) return c;
    }
    return target;
}

// Validate every key; invalid or missing colours fall back per key.
export function normalizeTheme(theme?: Partial<Theme> | null): Theme {
    const t = theme ?? {};
    const primary = isHexColour(t.primary) ? t.primary : DEFAULT_THEME.primary;
    const accent = isHexColour(t.accent) ? t.accent : DEFAULT_THEME.accent;
    const background = isHexColour(t.background) ? t.background : DEFAULT_THEME.background;
    const surface = isHexColour(t.surface) ? t.surface : DEFAULT_THEME.surface;
    const text = isHexColour(t.text)
        ? t.text
        : isHexColour(t.background)
          ? contrastText(background)
          : DEFAULT_THEME.text;
    return { primary, accent, background, surface, text };
}

const rgbVar = (hex: string) => hexToRgb(hex).join(', ');

// Every CSS variable for a theme, as a plain object (usable as a React `style`).
export function themeVars(theme?: Partial<Theme> | null): Record<string, string> {
    const th = normalizeTheme(theme);
    const lightText = luminance(th.text) > luminance(th.background);
    return {
        '--cp-primary': th.primary,
        '--cp-accent': th.accent,
        '--cp-bg': th.background,
        '--cp-surface': th.surface,
        '--cp-text': th.text,
        '--cp-surface-2': mix(th.surface, th.text, 0.05),
        '--cp-surface-3': mix(th.surface, th.text, 0.09),
        '--cp-border': mix(th.surface, th.text, lightText ? 0.12 : 0.16),
        '--cp-border-strong': mix(th.surface, th.text, lightText ? 0.22 : 0.28),
        '--cp-muted': mix(th.text, th.background, 0.4),
        '--cp-subtle': mix(th.text, th.background, 0.58),
        '--cp-primary-contrast': onFill(th.primary),
        '--cp-accent-contrast': onFill(th.accent),
        '--cp-primary-hover': mix(th.primary, WHITE, 0.12),
        '--cp-primary-text': legibleOn(th.primary, th.surface, 4.5), // WCAG AA for small text (FIB's navy primary)
        '--cp-accent-text': legibleOn(th.accent, th.surface, 4.5),
        '--cp-primary-rgb': rgbVar(th.primary),
        '--cp-accent-rgb': rgbVar(th.accent),
        '--cp-bg-rgb': rgbVar(th.background),
        '--cp-surface-rgb': rgbVar(th.surface),
        '--cp-text-rgb': rgbVar(th.text),
    };
}

// Write the theme's CSS variables on an element.
export function applyTheme(el: HTMLElement | null | undefined, theme?: Partial<Theme> | null): void {
    if (!el) return;
    const vars = themeVars(theme);
    for (const key of Object.keys(vars)) el.style.setProperty(key, vars[key]);
}

// ============================================================================
//                      THE OFFICER'S LOOK (Session.prefs)
// ============================================================================
// Appearance and personal accent change only the officer's own tablet. The primary colour, the logo and the
// watermark always stay the department's (SPEC Officer profile).

export const APPEARANCES = ['department', 'midnight', 'high_contrast', 'colourblind'];

const BLACK = '#000000';

// Colour-blind safe status colours (Okabe-Ito).
const COLOURBLIND_VARS: Record<string, string> = {
    '--cp-success': '#0072b2',
    '--cp-success-rgb': '0, 114, 178',
    '--cp-danger': '#d55e00',
    '--cp-danger-rgb': '213, 94, 0',
    '--cp-warning': '#e69f00',
    '--cp-warning-rgb': '230, 159, 0',
    '--cp-info': '#56b4e9',
    '--cp-info-rgb': '86, 180, 233',
};
const HIGH_CONTRAST_VARS: Record<string, string> = {
    '--cp-muted': '#e2e2e2',
    '--cp-subtle': '#c4c4c4',
};

// The department theme with the officer's appearance and accent applied. An accent is used only when it is one
// of the department's personal accents (accents; the server checks the level when it is saved).
export function mergeAppearance(
    theme: Partial<Theme> | null | undefined,
    appearance?: string | null,
    accent?: string | null,
    accents?: { colour: string }[] | null,
): Theme {
    const th = normalizeTheme(theme);
    const allowed = !accents || accents.some(a => a.colour.toLowerCase() === String(accent).toLowerCase());
    const out: Theme = { ...th, accent: isHexColour(accent) && allowed ? accent.toLowerCase() : th.accent };
    if (appearance === 'midnight') {
        // SPEC: background and surface 40% darker
        out.background = mix(th.background, BLACK, 0.4);
        out.surface = mix(th.surface, BLACK, 0.4);
    } else if (appearance === 'high_contrast') {
        out.background = BLACK;
        out.surface = '#0d0d0d';
        out.text = WHITE;
        out.accent = legibleOn(out.accent, out.surface, 7);
    }
    out.primary = th.primary;
    return out;
}

// CSS variables an appearance sets on top of the theme's (status colours, text shades).
export function appearanceVars(appearance?: string | null): Record<string, string> {
    if (appearance === 'colourblind') return { ...COLOURBLIND_VARS };
    if (appearance === 'high_contrast') return { ...HIGH_CONTRAST_VARS };
    return {};
}

const APPEARANCE_VAR_KEYS = [...Object.keys(COLOURBLIND_VARS), ...Object.keys(HIGH_CONTRAST_VARS)];

// Write the theme and the appearance's extra variables on an element (the extras of another appearance go).
export function applyAppearance(el: HTMLElement | null | undefined, theme: Theme, appearance?: string | null): void {
    if (!el) return;
    for (const key of APPEARANCE_VAR_KEYS) el.style.removeProperty(key);
    applyTheme(el, theme);
    const vars = appearanceVars(appearance);
    for (const key of Object.keys(vars)) el.style.setProperty(key, vars[key]);
}
