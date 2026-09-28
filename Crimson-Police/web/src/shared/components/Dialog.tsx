import { createContext, useContext, useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { cx } from '../cx';
import { t } from '../i18n';
import { useEscapeLayer } from '../hooks';
import { Button, IconButton } from './Button';
import { Field, Textarea } from './Form';

/** The element dialogs render into (the tablet screen or the admin panel), so they scale and theme with it. */
export const LayerRootContext = createContext<HTMLElement | null>(null);

export interface DialogProps {
  open: boolean;
  onClose: () => void;
  title?: ReactNode;
  description?: ReactNode;
  children?: ReactNode;
  /** Buttons row (right aligned). */
  footer?: ReactNode;
  size?: 'sm' | 'md' | 'lg';
  /** Clicking the backdrop closes (default true). Escape always closes. */
  dismissible?: boolean;
  className?: string;
}

const FOCUSABLE = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** Modal dialog rendered in the current layer root. Escape closes it before it closes the UI. */
export function Dialog({ open, onClose, title, description, children, footer, size = 'md', dismissible = true, className }: DialogProps) {
  const root = useContext(LayerRootContext);
  const panel = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useEscapeLayer(open, onClose);

  useEffect(() => {
    if (!open) return;
    const prev = document.activeElement as HTMLElement | null;
    const el = panel.current;
    const first = el?.querySelector<HTMLElement>('[data-autofocus]') ?? el?.querySelector<HTMLElement>(FOCUSABLE);
    (first ?? el)?.focus();
    return () => prev?.focus?.();
  }, [open]);

  if (!open) return null;

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key !== 'Tab' || !panel.current) return;
    const items = Array.from(panel.current.querySelectorAll<HTMLElement>(FOCUSABLE));
    if (!items.length) return;
    const first = items[0];
    const last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  };

  const node = (
    <div
      className={cx('cp-dialog-backdrop', root ? 'cp-dialog-backdrop--layer' : 'cp-dialog-backdrop--fixed')}
      onMouseDown={(e) => {
        if (dismissible && e.target === e.currentTarget) onClose();
      }}
    >
      <div
        ref={panel}
        className={cx('cp-dialog', `cp-dialog--${size}`, className)}
        role="dialog"
        aria-modal="true"
        aria-labelledby={title ? titleId : undefined}
        tabIndex={-1}
        onKeyDown={onKeyDown}
      >
        {title ? (
          <div className="cp-dialog__header">
            <div>
              <h3 className="cp-dialog__title" id={titleId}>{title}</h3>
              {description ? <p className="cp-dialog__desc">{description}</p> : null}
            </div>
            <IconButton icon="x" label={t('common.close')} size="sm" onClick={onClose} />
          </div>
        ) : null}
        {children !== undefined && children !== null ? <div className="cp-dialog__body">{children}</div> : null}
        {footer ? <div className="cp-dialog__footer">{footer}</div> : null}
      </div>
    </div>
  );
  return createPortal(node, root ?? document.body);
}

export interface ConfirmDialogProps {
  open: boolean;
  title: ReactNode;
  message?: ReactNode;
  confirmLabel?: ReactNode;
  cancelLabel?: ReactNode;
  /** 'danger' for destructive actions (abandon, void, cancel operation). */
  tone?: 'primary' | 'danger';
  /** Ask for a reason (supervisor/admin actions). Confirm is disabled until it is filled when required. */
  reason?: boolean | { label?: string; placeholder?: string; required?: boolean; maxLength?: number };
  /** Receives the reason ('' when none was asked). May return a Promise: the button shows a spinner. */
  onConfirm: (reason: string) => void | Promise<unknown>;
  onCancel: () => void;
  /** External busy state (otherwise tracked from the onConfirm promise). */
  busy?: boolean;
}

export function ConfirmDialog({ open, title, message, confirmLabel, cancelLabel, tone = 'primary', reason, onConfirm, onCancel, busy }: ConfirmDialogProps) {
  const [text, setText] = useState('');
  const [pending, setPending] = useState(false);
  useEffect(() => {
    if (open) setText('');
  }, [open]);

  const reasonCfg = reason ? (reason === true ? {} : reason) : null;
  const required = reasonCfg ? reasonCfg.required !== false : false;
  const blocked = required && !text.trim();
  const isBusy = busy || pending;

  const confirm = async () => {
    if (blocked || isBusy) return;
    const r = onConfirm(text.trim());
    if (r && typeof (r as Promise<unknown>).then === 'function') {
      setPending(true);
      try {
        await r;
      } finally {
        setPending(false);
      }
    }
  };

  return (
    <Dialog
      open={open}
      onClose={isBusy ? () => undefined : onCancel}
      title={title}
      size="sm"
      footer={
        <>
          <Button variant="ghost" onClick={onCancel} disabled={isBusy}>
            {cancelLabel ?? t('common.cancel')}
          </Button>
          <Button variant={tone === 'danger' ? 'danger' : 'primary'} onClick={confirm} loading={isBusy} disabled={blocked} data-autofocus={reasonCfg ? undefined : true}>
            {confirmLabel ?? t('common.confirm')}
          </Button>
        </>
      }
    >
      {message ? <div className="cp-dialog__message">{message}</div> : null}
      {reasonCfg ? (
        <Field label={reasonCfg.label ?? t('common.reason')} required={required} hint={required ? undefined : t('common.optional')}>
          <Textarea
            value={text}
            onChange={setText}
            placeholder={reasonCfg.placeholder}
            maxLength={reasonCfg.maxLength ?? 200}
            rows={3}
            autoFocus
          />
        </Field>
      ) : null}
    </Dialog>
  );
}
