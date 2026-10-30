// The screen an 'open' without a screen of its own lands on (step O9): the officer option openOn, saved with the

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
