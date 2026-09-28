// src/shared/toast.ts · the Crimson-Police toast bus. App renders the stack (<Toasts/>, top-right);
// anything can raise one: toast('error', t('err.timeout')). Lua toasts arrive as `notify`.
import type { Notification, NotificationKind } from './types';

type Listener = (n: Notification) => void;
const listeners = new Set<Listener>();
let seq = 0;

export const TOAST_DEFAULT_MS: Record<NotificationKind, number> = {
  info: 5000,
  success: 5000,
  warning: 7000,
  error: 7000,
};

/** Raise a toast. `text` and `title` are already translated. Returns the toast id. */
export function toast(kind: NotificationKind, text: string, opts: { title?: string; duration?: number } = {}): string {
  const id = `ui-${Date.now()}-${++seq}`;
  const n: Notification = { id, kind, text, title: opts.title, duration: opts.duration ?? TOAST_DEFAULT_MS[kind] };
  listeners.forEach((fn) => fn(n));
  return id;
}

/** Deliver an already-built notification (used for Lua `notify` messages). */
export function pushNotification(n: Notification): void {
  listeners.forEach((fn) => fn(n));
}

export function subscribeToasts(fn: Listener): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}
