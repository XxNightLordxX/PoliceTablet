// src/shared/format.ts · number/time formatting shared by components and screens.
// Numbers use en-US grouping ("$1,040") to match the spec's examples.

const nf = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });

/** 1040 -> "$1,040"; -50 -> "-$50". Rounded to whole dollars. */
export function formatMoney(amount: number | null | undefined): string {
  const n = Math.round(Number(amount) || 0);
  return (n < 0 ? '-$' : '$') + nf.format(Math.abs(n));
}

/** 12500 -> "12,500". `sign` adds "+" to positive values. */
export function formatNumber(value: number | null | undefined, sign = false): string {
  const n = Math.round(Number(value) || 0);
  const s = nf.format(Math.abs(n));
  if (n < 0) return '−' + s;
  return sign && n > 0 ? '+' + s : s;
}

/** 1.3 -> "×1.30". */
export function formatMultiplier(m: number | null | undefined, digits = 2): string {
  return '×' + (Number(m) || 0).toFixed(digits);
}

/** Seconds -> "m:ss" (or "h:mm:ss" from one hour). Negative values clamp to 0. */
export function formatDuration(seconds: number | null | undefined): string {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = (x: number) => String(x).padStart(2, '0');
  return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`;
}

/** Metres -> "850 m" / "1.2 km". */
export function formatDistance(metres: number | null | undefined): string {
  const m = Math.max(0, Number(metres) || 0);
  return m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(m < 10000 ? 1 : 0)} km`;
}

/** 0.6 -> "60%". */
export function formatPercent(share: number | null | undefined, digits = 0): string {
  return `${((Number(share) || 0) * 100).toFixed(digits)}%`;
}

/** os.time() seconds or an ISO/SQL date string -> "28 Sep, 14:05". */
export function formatDateTime(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === '') return '';
  const d = typeof value === 'number' ? new Date(value * 1000) : new Date(String(value).replace(' ', 'T'));
  if (isNaN(d.getTime())) return String(value);
  return d.toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}
