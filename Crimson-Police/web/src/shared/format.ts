// Number/time formatting shared by components and screens. Numbers use en-US grouping ("$1,040") to match the spec's
// examples; the money symbol follows Config.Format (setMoneyFormat) and dates the locale's _meta.date_locale.

import { hasKey, t } from './i18n';

const nf = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const nf3 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 });

// Config.Format (Session.config.format): the money symbol and whether it goes after the number.
const money = { currency: '$', currencyAfter: false };

// Set from the session (the tablet layouts); a missing or bad value keeps the default "$" before the number.
export function setMoneyFormat(format: { currency?: unknown; currencyAfter?: unknown } | null | undefined): void {
    const c = format?.currency;
    money.currency = typeof c === 'string' && c.length > 0 && c.length <= 8 ? c : '$';
    money.currencyAfter = format?.currencyAfter === true;
}

// 1040 -> "$1,040"; -50 -> "-$50" (or "1,040 €" with currencyAfter). Rounded to whole units.
export function formatMoney(amount: number | null | undefined): string {
    const n = Math.round(Number(amount) || 0);
    const digits = nf.format(Math.abs(n));
    const sign = n < 0 ? '-' : '';
    return money.currencyAfter ? `${sign}${digits} ${money.currency}` : `${sign}${money.currency}${digits}`;
}

// A plain number with grouping and at most 3 decimals: 12500 -> "12,500", 0.85 -> "0.85".
export function fmtPlain(value: number | null | undefined): string {
    return nf3.format(Number(value) || 0);
}

// 12500 -> "12,500". `sign` adds "+" to positive values.
export function formatNumber(value: number | null | undefined, sign = false): string {
    const n = Math.round(Number(value) || 0);
    const s = nf.format(Math.abs(n));
    if (n < 0) return '−' + s;
    return sign && n > 0 ? '+' + s : s;
}

// 1.3 -> "×1.30".
export function formatMultiplier(m: number | null | undefined, digits = 2): string {
    return '×' + (Number(m) || 0).toFixed(digits);
}

// A config factor without trailing zeros: 2 -> "2", 1.5 -> "1.5".
export function formatFactor(m: number | null | undefined): string {
    return String(Math.round((Number(m) || 0) * 100) / 100);
}

// Seconds -> "m:ss" (or "h:mm:ss" from one hour). Negative values clamp to 0.
export function formatDuration(seconds: number | null | undefined): string {
    const s = Math.max(0, Math.floor(Number(seconds) || 0));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const pad = (x: number) => String(x).padStart(2, '0');
    return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`;
}

// Metres -> "850 m" / "1.2 km".
export function formatDistance(metres: number | null | undefined): string {
    const m = Math.max(0, Number(metres) || 0);
    return m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(m < 10000 ? 1 : 0)} km`;
}

// 0.6 -> "60%".
export function formatPercent(share: number | null | undefined, digits = 0): string {
    return `${((Number(share) || 0) * 100).toFixed(digits)}%`;
}

// os.time() seconds or an ISO/SQL date string -> "28 Sep, 14:05".
export function formatDateTime(value: number | string | null | undefined): string {
    if (value === null || value === undefined || value === '') return '';
    const d = typeof value === 'number' ? new Date(value * 1000) : new Date(String(value).replace(' ', 'T'));
    if (isNaN(d.getTime())) return String(value);
    return d.toLocaleString(dateLocale(), { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

// ============================================================================
//                         DATES IN THE LOCALE'S FORMAT
// ============================================================================
// The locale file may name its date locale (_meta.date_locale); en-GB otherwise.

function dateLocale(): string {
    const v = hasKey('_meta.date_locale') ? t('_meta.date_locale') : '';
    return v !== '' ? v : 'en-GB';
}

function toDate(value: number | string | null | undefined): Date | null {
    if (value === null || value === undefined || value === '') return null;
    const d = typeof value === 'number' ? new Date(value * 1000) : new Date(String(value).replace(' ', 'T'));
    return isNaN(d.getTime()) ? null : d;
}

// os.time() seconds or an ISO/SQL date string -> "28 Sep 2026".
export function fmtDate(value: number | string | null | undefined): string {
    const d = toDate(value);
    if (!d) return value === null || value === undefined ? '' : String(value);
    return d.toLocaleDateString(dateLocale(), { day: 'numeric', month: 'short', year: 'numeric' });
}

// os.time() seconds or an ISO/SQL date string -> "28 Sep 2026, 14:05".
export function fmtDateTime(value: number | string | null | undefined): string {
    const d = toDate(value);
    if (!d) return value === null || value === undefined ? '' : String(value);
    return d.toLocaleString(dateLocale(), {
        day: 'numeric',
        month: 'short',
        year: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
    });
}
