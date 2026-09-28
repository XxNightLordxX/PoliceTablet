import { useEffect, useRef, useState, type CSSProperties } from 'react';
import { cx } from '../cx';
import { t } from '../i18n';
import type { Notification } from '../types';
import { Icon, type IconName } from './Icon';

const ICONS: Record<Notification['kind'], IconName> = {
  info: 'info',
  success: 'checkCircle',
  warning: 'alert',
  error: 'xCircle',
};

function ToastItem({ n, onDismiss }: { n: Notification; onDismiss: (id: Notification['id']) => void }) {
  const [leaving, setLeaving] = useState(false);
  const [hover, setHover] = useState(false);
  const remaining = useRef(n.duration);
  const startedAt = useRef(Date.now());

  const dismiss = () => {
    setLeaving(true);
    setTimeout(() => onDismiss(n.id), 180);
  };

  useEffect(() => {
    if (!(n.duration > 0) || hover || leaving) return;
    startedAt.current = Date.now();
    const id = setTimeout(dismiss, Math.max(0, remaining.current));
    return () => {
      clearTimeout(id);
      remaining.current -= Date.now() - startedAt.current;
    };
  }, [hover, leaving]);

  const kind = ICONS[n.kind] ? n.kind : 'info';
  return (
    <div
      className={cx('cp-toast', `cp-toast--${kind}`, leaving && 'is-leaving')}
      role={kind === 'error' || kind === 'warning' ? 'alert' : 'status'}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      <span className="cp-toast__icon">
        <Icon name={ICONS[kind]} size={18} />
      </span>
      <div className="cp-toast__content">
        {n.title ? <div className="cp-toast__title">{n.title}</div> : null}
        <div className="cp-toast__text">{n.text}</div>
      </div>
      <button type="button" className="cp-toast__close" aria-label={t('common.dismiss')} onClick={dismiss}>
        <Icon name="x" size={14} />
      </button>
      {n.duration > 0 ? (
        <span className="cp-toast__timer" style={{ animationDuration: `${n.duration}ms`, animationPlayState: hover ? 'paused' : 'running' }} />
      ) : null}
    </div>
  );
}

export interface ToastsProps {
  toasts: Notification[];
  onDismiss: (id: Notification['id']) => void;
  /** Visual scale (HUD scale for the viewport). */
  scale?: number;
  /** Position override (App anchors the stack inside the open tablet). */
  style?: CSSProperties;
}

/** Top-right toast stack. Each toast auto-dismisses after its duration (hover pauses it). */
export function Toasts({ toasts, onDismiss, scale = 1, style }: ToastsProps) {
  if (!toasts.length) return null;
  return (
    <div className="cp-toasts" style={{ transform: scale !== 1 ? `scale(${scale})` : undefined, ...style }} aria-live="polite">
      {toasts.map((n) => (
        <ToastItem key={n.id} n={n} onDismiss={onDismiss} />
      ))}
    </div>
  );
}
