// src/shared/session.tsx · the open UI's session (ARCHITECTURE §9.2) and tablet controls.
//   const session = useSession();            // Session (inside Officer/Supervisor/Admin UIs)
//   const can = useCan(); can('forceRecall') // session.actions contains it
//   const { close, switchUi } = useTablet();
import { createContext, useContext } from 'react';
import type { Session, UiKind } from './types';

export interface SessionContextValue {
  session: Session | null;
  /** The open UI, or null when only the HUD/toasts are showing. */
  ui: UiKind | null;
  /** Close the open UI (POST close). */
  close: () => void;
  /** Switch between officer and supervisor (POST switchUi, which returns the new Session). */
  switchUi: (ui: UiKind) => Promise<boolean>;
  /** Re-fetch the session for the open UI (request getSession). */
  refreshSession: () => Promise<void>;
  switching: boolean;
}

export const SessionContext = createContext<SessionContextValue>({
  session: null,
  ui: null,
  close: () => undefined,
  switchUi: async () => false,
  refreshSession: async () => undefined,
  switching: false,
});

/** The current Session. Only call it inside a UI screen/layout (a session always exists there). */
export function useSession(): Session {
  const { session } = useContext(SessionContext);
  if (!session) throw new Error('useSession() used outside an open UI');
  return session;
}

/** The session or null (safe in HUD/overlay code). */
export function useOptionalSession(): Session | null {
  return useContext(SessionContext).session;
}

/** Tablet controls: close, switchUi, refreshSession, the open ui and a switching flag. */
export function useTablet(): SessionContextValue {
  return useContext(SessionContext);
}

/** can(action): true when session.actions lists it (the server re-checks every action anyway). */
export function useCan(): (action: string) => boolean {
  const { session } = useContext(SessionContext);
  return (a: string) => !!session && Array.isArray(session.actions) && session.actions.includes(a);
}

/** "San Andreas State Troopers · SAST · Sergeant · 2L-14" (callsign null → the no-callsign text). */
export function officerLine(officer: Session['officer'], noCallsign: string): string {
  if (!officer) return '';
  return [officer.departmentLabel, officer.departmentShort, officer.rank, officer.callsign || noCallsign].filter(Boolean).join(' · ');
}
