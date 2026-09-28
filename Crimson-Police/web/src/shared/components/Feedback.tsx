import type { ReactNode } from 'react';
import { cx } from '../cx';
import { t } from '../i18n';
import { Icon, type IconName } from './Icon';

export type Tone = 'neutral' | 'primary' | 'accent' | 'success' | 'warning' | 'danger';

// ── Spinner ───────────────────────────────────────────────────────────────────

export function Spinner({ size = 18, label, className }: { size?: number; label?: string; className?: string }) {
  return (
    <span
      className={cx('cp-spinner', className)}
      style={{ width: size, height: size, borderWidth: Math.max(2, Math.round(size / 8)) }}
      role={label ? 'status' : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    />
  );
}

/** Centered spinner with an optional text, for a loading screen or card. */
export function LoadingBlock({ text, className }: { text?: string; className?: string }) {
  return (
    <div className={cx('cp-loading-block', className)} role="status">
      <Spinner size={22} />
      <span>{text ?? t('common.loading')}</span>
    </div>
  );
}

// ── ProgressBar ───────────────────────────────────────────────────────────────

export interface ProgressBarProps {
  value: number;
  max?: number;
  tone?: Exclude<Tone, 'neutral'>;
  size?: 'sm' | 'md' | 'lg';
  /** Text above the bar (left). */
  label?: ReactNode;
  /** Show "value / max" (or a custom node) above the bar (right). */
  showValue?: boolean | ReactNode;
  className?: string;
}

export function ProgressBar({ value, max = 100, tone = 'primary', size = 'md', label, showValue, className }: ProgressBarProps) {
  const safeMax = max > 0 ? max : 1;
  const pct = Math.max(0, Math.min(100, (Number(value) / safeMax) * 100 || 0));
  return (
    <div className={cx('cp-progress', `cp-progress--${size}`, `cp-progress--${tone}`, className)}>
      {label !== undefined || showValue ? (
        <div className="cp-progress__head">
          <span className="cp-progress__label">{label}</span>
          {showValue ? (
            <span className="cp-progress__value cp-num">{showValue === true ? `${value} / ${max}` : showValue}</span>
          ) : null}
        </div>
      ) : null}
      <div className="cp-progress__track" role="progressbar" aria-valuemin={0} aria-valuemax={max} aria-valuenow={value}>
        <div className="cp-progress__fill" style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

// ── Stat ──────────────────────────────────────────────────────────────────────

export interface StatProps {
  label: ReactNode;
  value: ReactNode;
  hint?: ReactNode;
  icon?: IconName;
  tone?: Tone;
  size?: 'sm' | 'md' | 'lg';
  className?: string;
}

/** A labelled number tile: label (small caps), big tabular value, optional hint line. */
export function Stat({ label, value, hint, icon, tone = 'neutral', size = 'md', className }: StatProps) {
  return (
    <div className={cx('cp-stat', `cp-stat--${size}`, `cp-tone--${tone}`, className)}>
      <div className="cp-stat__label">
        {icon ? <Icon name={icon} size={14} /> : null}
        <span>{label}</span>
      </div>
      <div className="cp-stat__value cp-num">{value}</div>
      {hint ? <div className="cp-stat__hint">{hint}</div> : null}
    </div>
  );
}

// ── EmptyState ────────────────────────────────────────────────────────────────

export interface EmptyStateProps {
  title: ReactNode;
  text?: ReactNode;
  icon?: IconName;
  action?: ReactNode;
  compact?: boolean;
  className?: string;
}

export function EmptyState({ title, text, icon = 'inbox', action, compact, className }: EmptyStateProps) {
  return (
    <div className={cx('cp-empty', compact && 'cp-empty--compact', className)}>
      <div className="cp-empty__icon">
        <Icon name={icon} size={compact ? 20 : 26} />
      </div>
      <div className="cp-empty__title">{title}</div>
      {text ? <div className="cp-empty__text">{text}</div> : null}
      {action ? <div className="cp-empty__action">{action}</div> : null}
    </div>
  );
}

/** An error block for a failed request: translated err.* key plus an optional retry. */
export function ErrorState({ error, onRetry, compact }: { error: string | null | undefined; onRetry?: () => void; compact?: boolean }) {
  return (
    <EmptyState
      compact={compact}
      icon="alert"
      className="cp-empty--error"
      title={t('common.error')}
      text={error ? t(error) : undefined}
      action={
        onRetry ? (
          <button type="button" className="cp-btn cp-btn--secondary cp-btn--sm" onClick={onRetry}>
            <Icon name="refresh" size={14} />
            <span className="cp-btn__label">{t('common.retry')}</span>
          </button>
        ) : undefined
      }
    />
  );
}
