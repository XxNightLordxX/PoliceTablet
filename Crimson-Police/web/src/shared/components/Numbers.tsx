import { cx } from '../cx';
import { formatDuration, formatMoney, formatNumber } from '../format';
import { useCountdown } from '../hooks';
import { t } from '../i18n';
import { Icon } from './Icon';

/** "$1,040" in tabular numbers. `sign` prefixes "+" for positive amounts. */
export function Money({ amount, sign, className }: { amount: number | null | undefined; sign?: boolean; className?: string }) {
  const n = Math.round(Number(amount) || 0);
  return <span className={cx('cp-money', 'cp-num', className)}>{(sign && n > 0 ? '+' : '') + formatMoney(n)}</span>;
}

/** "$1,040–$1,300" (a board card's cash range). Collapses to one value when min = max. */
export function MoneyRange({ range, className }: { range: [number, number] | number[]; className?: string }) {
  const [a, b] = [Number(range?.[0]) || 0, Number(range?.[1] ?? range?.[0]) || 0];
  return <span className={cx('cp-money', 'cp-num', className)}>{a === b ? formatMoney(a) : `${formatMoney(a)}–${formatMoney(b)}`}</span>;
}

/** "1,250 pts". `sign` shows +/−, `suffix={false}` drops "pts". */
export function Points({ value, sign, suffix = true, className }: { value: number | null | undefined; sign?: boolean; suffix?: boolean; className?: string }) {
  const n = Math.round(Number(value) || 0);
  return (
    <span className={cx('cp-points', 'cp-num', n < 0 && 'is-negative', className)}>
      {formatNumber(n, sign)}
      {suffix ? <span className="cp-points__suffix">{` ${t('common.pts')}`}</span> : null}
    </span>
  );
}

export interface CountdownProps {
  /** Seconds left (counted down locally). null renders "–". */
  seconds: number | null | undefined;
  paused?: boolean;
  /** Restart from `seconds` when this changes, even if the number is the same. */
  resetKey?: unknown;
  /** Warning colour at or below this many seconds. */
  warnBelow?: number;
  /** Danger colour at or below this many seconds. */
  dangerBelow?: number;
  /** Show a pause icon while paused (default true). */
  showPaused?: boolean;
  onDone?: () => void;
  className?: string;
}

/** m:ss timer counting down locally, with warning/danger colours and a paused state. */
export function Countdown({ seconds, paused, resetKey, warnBelow, dangerBelow, showPaused = true, onDone, className }: CountdownProps) {
  const left = useCountdown(seconds, { paused, resetKey, onDone });
  const tone =
    left === null ? '' : dangerBelow !== undefined && left <= dangerBelow ? 'is-danger' : warnBelow !== undefined && left <= warnBelow ? 'is-warning' : '';
  return (
    <span className={cx('cp-countdown', 'cp-num', tone, paused && 'is-paused', className)} aria-live="off">
      {paused && showPaused ? <Icon name="pause" size={12} className="cp-countdown__pause" label={t('common.paused')} /> : null}
      {left === null ? '–' : formatDuration(left)}
    </span>
  );
}
