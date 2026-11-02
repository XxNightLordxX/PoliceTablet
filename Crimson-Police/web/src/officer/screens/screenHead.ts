// Officer UI screen heads and load states (step H2): every officer screen of part 1 (Home, Mission Board, Active
// Mission, Dispatch) shows the same header (title, then one line of help) and the same loading, error, empty and
// stale lines. Pure functions, checked by screenHead.walk.ts.

export type OfficerHeadKey = 'home' | 'board' | 'active' | 'dispatch';

// title: the screen name key; help: the one line under it (locale keys).
export interface OfficerHead {
    title: string;
    help: string;
}

export const OFFICER_HEADS: Record<OfficerHeadKey, OfficerHead> = {
    home: { title: 'ui.screen.home', help: 'ui.help.home' },
    board: { title: 'ui.screen.board', help: 'board.subtitle' },
    active: { title: 'ui.screen.active', help: 'ui.help.active' },
    dispatch: { title: 'ui.screen.dispatch', help: 'mc.subtitle' },
};

// loading: first fetch running; error: first fetch failed; empty: the reply had no data and no error;
// stale: data from before is shown but the last refresh failed; ready: data is shown.
export type ScreenState = 'loading' | 'error' | 'empty' | 'stale' | 'ready';

export function screenStateOf(hasData: boolean, loading: boolean, error: string | null | undefined): ScreenState {
    if (hasData) return error && !loading ? 'stale' : 'ready';
    if (loading) return 'loading';
    return error ? 'error' : 'empty';
}
