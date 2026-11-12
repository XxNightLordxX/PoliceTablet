// The screen an 'open' without a screen of its own lands on: the officer option openOn, saved with the

// The screen an 'open' without a screen of its own lands on: the officer option openOn, saved with the
// character. 'last' (as before) keeps the screen the tablet was closed on; 'home' opens Home; 'active_on_run' opens
// Unit while the unit's ready check waits for the officer's answer, Active Mission while he is on a run, else the
// last screen. Only the Officer UI: the Supervisor and Admin UIs keep their screens.

import type { ScreenKey } from './navigation';
import type { Session, UiKind } from './types';

// null = keep the last screen.
export function openScreenFor(ui: UiKind, session: Session | null): ScreenKey | null {
    if (ui !== 'officer' || !session) return null;
    const on = session.options?.openOn;
    if (on === 'home') return 'home';
    if (on === 'active_on_run') {
        if (session.opening?.readyCheck) return 'unit';
        if (session.opening?.onRun) return 'active';
    }
    return null;
}
